# Common utilities used by all subcommands

function Test-IsAdmin {
    $user = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $user.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Require-Admin {
    if (-not (Test-IsAdmin)) {
        Write-Failure "This command needs Administrator privileges."
        Write-Info "Right-click PowerShell -> 'Run as administrator', then retry."
        exit 1
    }
}

function Get-LifeboatConfig {
    if (-not (Test-Path $script:ConfigPath)) { return $null }
    try {
        return Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
    } catch {
        Write-Failure "Config file is corrupted: $script:ConfigPath"
        return $null
    }
}

function Save-LifeboatConfig($config) {
    $dir = Split-Path $script:ConfigPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $script:ConfigPath -Encoding UTF8
}

function Get-FormattedSize($bytes) {
    if ($bytes -lt 1KB) { return "$bytes B" }
    if ($bytes -lt 1MB) { return "{0:N1} KB" -f ($bytes / 1KB) }
    if ($bytes -lt 1GB) { return "{0:N1} MB" -f ($bytes / 1MB) }
    return "{0:N2} GB" -f ($bytes / 1GB)
}

function Get-FormattedDuration($timespan) {
    if ($timespan.TotalMinutes -lt 1) { return "$([math]::Round($timespan.TotalSeconds))s" }
    if ($timespan.TotalHours -lt 1) { return "$([math]::Round($timespan.TotalMinutes))min" }
    if ($timespan.TotalDays -lt 1) { return "$([math]::Round($timespan.TotalHours, 1))h" }
    return "$([math]::Round($timespan.TotalDays, 1))d"
}

function Get-ClaudeDataPaths {
    # Returns a hashtable of [name -> path] for all Claude-related data we know about.
    # This is the heart of what makes lifeboat Claude-aware.
    $paths = @{}

    # Claude Desktop MSIX package
    $pkg = Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -Filter "Claude_*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkg) { $paths["ClaudeDesktop"] = $pkg.FullName }

    # ProgramData (machine-wide logs and VM service files)
    if (Test-Path "C:\ProgramData\Claude") {
        $paths["Claude-System"] = "C:\ProgramData\Claude"
    }

    # Claude Code CLI configs (multiple possible locations)
    $ccCandidates = @(
        @{ Name = "ClaudeCode-user";   Path = "$env:USERPROFILE\.claude" },
        @{ Name = "ClaudeCode-appdata"; Path = "$env:APPDATA\claude-code" },
        @{ Name = "ClaudeCode-xdg";    Path = "$env:USERPROFILE\.config\claude" }
    )
    foreach ($c in $ccCandidates) {
        if (Test-Path $c.Path) { $paths[$c.Name] = $c.Path }
    }

    return $paths
}

function Invoke-Robocopy($source, $destination, [switch]$Mirror, [string[]]$ExtraExcludeFiles = @()) {
    # Wrapper for robocopy with sensible defaults.
    # Returns @{ Success = bool; ExitCode = int; Output = string }
    $argList = @($source, $destination)
    if ($Mirror) { $argList += '/MIR' } else { $argList += '/E' }
    $argList += @('/R:1', '/W:1', '/MT:8', '/XJ', '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS', '/NP')
    # Skip volatile files that get rewritten mid-copy (cookies + SQLite
    # journals cause benign "ERROR 2" failures) and big regenerable cache
    # dirs. These aren't worth backing up and they're what flag false failures.
    $argList += @('/XF', '*.tmp', '*.lock', '*.partial', '*-journal', '*-wal', '*-shm', 'Cookies', 'Cookies-journal', 'LOCK', 'lockfile')
    $argList += @('/XD', 'Cache', 'GPUCache', 'Code Cache', 'DawnGraphiteCache', 'DawnWebGPUCache', 'GrShaderCache', 'ShaderCache', 'Service Worker', 'CacheStorage')
    if ($ExtraExcludeFiles -and $ExtraExcludeFiles.Count -gt 0) { $argList += @('/XF') + $ExtraExcludeFiles }

    $output = & robocopy @argList 2>&1 | Out-String
    $code = $LASTEXITCODE
    # robocopy exit codes: 0=no change, 1=copied, 2=extra, 3=copied+extra, 4-7=warnings, 8+=errors
    return @{
        Success = ($code -lt 8)
        ExitCode = $code
        Output = $output
    }
}

function Invoke-RobocopyLive($source, $destination, $label, [switch]$Mirror, [string[]]$ExtraExcludeFiles = @()) {
    # Same as Invoke-Robocopy, but animates a spinner + elapsed time + a live
    # "copied so far" size on the console while robocopy runs, so a long copy
    # (the multi-GB Cowork VM bundle) doesn't look frozen. Interactive use only
    # -- scheduled/silent runs use Invoke-Robocopy (no console to draw on).
    $argList = @($source, $destination)
    if ($Mirror) { $argList += '/MIR' } else { $argList += '/E' }
    $argList += @('/R:1', '/W:1', '/MT:8', '/XJ', '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS', '/NP')
    # Skip volatile files that get rewritten mid-copy (cookies + SQLite
    # journals cause benign "ERROR 2" failures) and big regenerable cache
    # dirs. These aren't worth backing up and they're what flag false failures.
    $argList += @('/XF', '*.tmp', '*.lock', '*.partial', '*-journal', '*-wal', '*-shm', 'Cookies', 'Cookies-journal', 'LOCK', 'lockfile')
    $argList += @('/XD', 'Cache', 'GPUCache', 'Code Cache', 'DawnGraphiteCache', 'DawnWebGPUCache', 'GrShaderCache', 'ShaderCache', 'Service Worker', 'CacheStorage')
    if ($ExtraExcludeFiles -and $ExtraExcludeFiles.Count -gt 0) { $argList += @('/XF') + $ExtraExcludeFiles }

    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath "robocopy.exe" -ArgumentList $argList `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    } catch {
        # If Start-Process fails for any reason, fall back to the blocking call.
        Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
        return Invoke-Robocopy $source $destination -Mirror:$Mirror
    }

    $spin = @('|', '/', '-', '\')
    $i = 0
    $start = Get-Date
    $sizeStr = ""
    while (-not $proc.HasExited) {
        $elapsed = [int]((Get-Date) - $start).TotalSeconds
        # Recompute the copied-so-far size only every ~2s (every 10 ticks) so
        # we don't hammer the disk recursively while robocopy is writing.
        if ($i % 10 -eq 0) {
            try {
                if (Test-Path $destination) {
                    $bytes = (Get-ChildItem $destination -Recurse -File -ErrorAction SilentlyContinue |
                              Measure-Object Length -Sum).Sum
                    $sizeStr = if ($bytes) { " - $(Get-FormattedSize $bytes)" } else { "" }
                }
            } catch {}
        }
        $line = ("    {0}  {1}  ({2}s{3})" -f $spin[$i % 4], $label, $elapsed, $sizeStr)
        Write-Host ("`r" + $line.PadRight(60)) -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Milliseconds 200
        $i++
    }
    $code = $proc.ExitCode
    Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
    # Clear the spinner line so the caller can print a clean result.
    Write-Host ("`r" + (" " * 60) + "`r") -NoNewline
    return @{
        Success = ($code -lt 8)
        ExitCode = $code
        Output = ""
    }
}

function New-VolumeShadowCopy {
    # Snapshot a volume so we can copy files a running app (Claude Desktop /
    # Cowork) holds locked - chiefly the live sessiondata.vhdx. Returns a small
    # object describing the snapshot, or $null if VSS isn't available (e.g. not
    # elevated). Callers MUST treat $null as "just copy live" and carry on.
    param([string]$Drive = $env:SystemDrive)
    if (-not $Drive) { $Drive = "C:" }
    try {
        $class = [WMICLASS]"root\cimv2:Win32_ShadowCopy"
        $res = $class.Create("$Drive\", "ClientAccessible")
        if (-not $res -or $res.ReturnValue -ne 0) { return $null }
        $sc = Get-WmiObject Win32_ShadowCopy | Where-Object { $_.ID -eq $res.ShadowID }
        if (-not $sc) { return $null }
        $target = $sc.DeviceObject + "\"   # trailing slash is required for the link
        # Mount at the drive root (no spaces in that path -> no quoting headaches).
        $mount = Join-Path "$Drive\" ("lifeboat-vss-" + [Guid]::NewGuid().ToString("N").Substring(0,8))
        & cmd.exe /c mklink /d $mount $target *> $null
        if (-not (Test-Path $mount)) {
            try { $sc.Delete() } catch {}
            return $null
        }
        return [PSCustomObject]@{ Id = $sc.ID; MountPath = $mount; Drive = $Drive }
    } catch {
        return $null
    }
}

function Remove-VolumeShadowCopy($snap) {
    if (-not $snap) { return }
    try {
        if ($snap.MountPath -and (Test-Path $snap.MountPath)) {
            & cmd.exe /c rmdir $snap.MountPath *> $null   # removes the symlink, not the target
        }
    } catch {}
    try {
        $sc = Get-WmiObject Win32_ShadowCopy | Where-Object { $_.ID -eq $snap.Id }
        if ($sc) { $sc.Delete() }
    } catch {}
}

function ConvertTo-ShadowPath($sourcePath, $snap) {
    # Map a real path on the snapshot's drive to its location inside the snapshot
    # mount. Returns $null if the source isn't on that drive.
    if (-not $snap) { return $null }
    $drive = $snap.Drive
    if ($sourcePath -like "$drive\*") {
        $rel = $sourcePath.Substring($drive.Length).TrimStart('\')
        return (Join-Path $snap.MountPath $rel)
    }
    return $null
}

function Get-BackupTargetDrives {
    # Drives we can offer as on-demand backup targets: ready, not the system
    # drive, not a CD/DVD. Returns letter + free space + label for each.
    $sys = $env:SystemDrive
    $out = @()
    try {
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            try {
                if (-not $d.IsReady) { continue }
                $letter = $d.Name.TrimEnd('\')          # e.g. "E:"
                if ($letter -eq $sys) { continue }
                if ($d.DriveType -eq 'CDRom') { continue }
                $freeGB = [math]::Round($d.AvailableFreeSpace / 1GB, 1)
                $label = if ($d.VolumeLabel) { $d.VolumeLabel } else { "$($d.DriveType)" }
                $out += [PSCustomObject]@{ Letter = $letter; FreeGB = $freeGB; Label = $label; Type = "$($d.DriveType)" }
            } catch {}
        }
    } catch {}
    return $out
}

function Write-LifeboatLog($message, [string]$level = "INFO") {
    if (-not (Test-Path $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }
    $logFile = Join-Path $script:LogDir "lifeboat-$(Get-Date -Format 'yyyy-MM-dd').log"
    $line = "$(Get-Date -Format 'HH:mm:ss')  [$level]  $message"
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
}

function Test-DrivePath($drivePath) {
    # Tests if a drive (e.g. "D:") is currently available. Handles edge cases.
    if (-not $drivePath) { return $false }
    $letter = ($drivePath -split ':')[0]
    if (-not $letter) { return $false }
    return Test-Path "${letter}:\"
}

function Get-DriveStats($drivePath) {
    if (-not (Test-DrivePath $drivePath)) {
        return @{ Available = $false }
    }
    $letter = ($drivePath -split ':')[0]
    $drive = Get-PSDrive -Name $letter -PSProvider FileSystem -ErrorAction SilentlyContinue
    if (-not $drive) { return @{ Available = $false } }
    $total = $drive.Free + $drive.Used
    return @{
        Available = $true
        Letter = $letter
        TotalBytes = $total
        FreeBytes = $drive.Free
        UsedBytes = $drive.Used
        PercentUsed = if ($total -gt 0) { [math]::Round(($drive.Used / $total) * 100, 1) } else { 0 }
    }
}

function Stop-ClaudeProcesses {
    # Cleanly stops Claude Desktop and the Cowork VM service. Used before restore.
    $stopped = @()
    Get-Process -Name "Claude*" -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_.CloseMainWindow() | Out-Null } catch {}
    }
    Start-Sleep -Seconds 2
    Get-Process -Name "Claude*" -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        $stopped += $_.ProcessName
    }
    $svc = Get-Service CoworkVMService -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        Stop-Service CoworkVMService -Force -ErrorAction SilentlyContinue
        $stopped += "CoworkVMService"
    }
    return $stopped
}

function Start-ClaudeServices {
    Start-Service CoworkVMService -ErrorAction SilentlyContinue
}
