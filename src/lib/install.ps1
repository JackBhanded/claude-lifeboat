# lifeboat install - the friendly two-question setup

function Invoke-Install {
    param($Flags)

    Require-Admin

    Write-Host ""
    Write-Host "  ===============================================" -ForegroundColor Cyan
    Write-Host "    Claude Lifeboat v$($script:LifeboatVersion)" -ForegroundColor Cyan
    Write-Host "    Your Claude Desktop data, safe and restorable" -ForegroundColor DarkCyan
    Write-Host "  ===============================================" -ForegroundColor Cyan
    Write-Host ""

    # Detect existing install
    $existingConfig = Get-LifeboatConfig
    if ($existingConfig -and -not $Flags.force) {
        Write-Warning2 "Lifeboat is already installed."
        Write-Info "Primary:  $($existingConfig.Primary.Root)"
        Write-Info "Archive:  $(if($existingConfig.Archive.Root){$existingConfig.Archive.Root}else{'(none)'})"
        Write-Host ""
        Write-Prompt "Reinstall? (y/N):"
        $answer = Read-Host
        if ($answer -ne 'y') {
            Write-Info "Cancelled."
            return
        }
    }

    # Check that Claude Desktop is actually installed
    $claudePackage = Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -Filter "Claude_*" -ErrorAction SilentlyContinue
    if (-not $claudePackage) {
        Write-Warning2 "Claude Desktop doesn't appear to be installed for this user."
        Write-Info "Lifeboat will still set up, but won't have Claude data to back up until you install and run Claude."
        Write-Host ""
    }

    # ----- Question 1: Primary drive -----
    Write-Heading "Step 1 of 3: Primary backup location"
    Write-Host "  Pick a drive that's always available (internal recommended)."
    Write-Host "  Every backup goes here. Fast, reliable, always-on."
    Write-Host ""

    $available = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
        Where-Object { $_.Free -gt 1GB }

    Write-Host "  Available drives:"
    foreach ($d in $available) {
        $freeGB = [math]::Round($d.Free / 1GB, 1)
        $totalGB = [math]::Round(($d.Free + $d.Used) / 1GB, 1)
        $type = if ((Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='$($d.Name):'").DriveType -eq 2) { "removable" } else { "fixed" }
        Write-Host ("    $($d.Name):  $freeGB GB free of $totalGB GB  ($type)") -ForegroundColor DarkGray
    }
    Write-Host ""

    $suggested = Suggest-PrimaryDrive
    $script:SuggestedPrimary = $suggested
    Write-Prompt "Primary drive [default: $suggested]:"
    $primaryInput = Read-Host
    if (-not $primaryInput) { $primaryInput = $suggested }
    $primaryDrive = ($primaryInput.Trim().TrimEnd('\').TrimEnd(':') + ':')
    if (-not (Test-Path $primaryDrive)) {
        Write-Failure "Drive $primaryDrive not found."
        return
    }
    $primaryRoot = Join-Path $primaryDrive "ClaudeLifeboat"
    Write-Success "Primary: $primaryRoot"

    # ----- Question 2: Archive drive (optional) -----
    Write-Heading "Step 2 of 3: Archive drive (optional)"
    Write-Host "  An external drive for long-term versioned backups (7 daily + 4 weekly)."
    Write-Host "  Gets synced from primary automatically when plugged in."
    Write-Host ""
    Write-Host "  Skip this if you don't have an external drive. You can add one later"
    Write-Host "  by running 'lifeboat install' again."
    Write-Host ""

    Write-Prompt "Archive drive (or blank to skip):"
    $archiveInput = Read-Host
    $archiveRoot = $null
    if ($archiveInput) {
        $archiveDrive = ($archiveInput.Trim().TrimEnd('\').TrimEnd(':') + ':')
        if (-not (Test-Path $archiveDrive)) {
            Write-Warning2 "Drive $archiveDrive not currently connected."
            Write-Info "That's fine - Lifeboat will sync when you plug it in."
            Write-Prompt "Continue with $archiveDrive anyway? (Y/n):"
            $confirm = Read-Host
            if ($confirm -eq 'n') { $archiveDrive = $null }
        }
        if ($archiveDrive) {
            $archiveRoot = Join-Path $archiveDrive "ClaudeLifeboat"
            Write-Success "Archive: $archiveRoot"
        }
    } else {
        Write-Info "No archive drive configured. You can add one later."
    }

    # ----- Question 3: Backup mode (lean vs full) -----
    Write-Heading "Step 3 of 3: How much to keep"
    Write-Host "  Your Cowork VM includes a large, regenerable OS image (rootfs.vhdx -"
    Write-Host "  often 8+ GB) that Claude rebuilds on its own. Your actual work lives in"
    Write-Host "  a tiny sessiondata file that's always kept either way."
    Write-Host ""
    Write-Host "    [1] Lean  (recommended)  Skip the regenerable OS image. ~99% smaller."
    Write-Host "    [2] Full                 Keep everything - self-contained restore, but big."
    Write-Host ""
    Write-Prompt "Choose [1]:"
    $modeInput = Read-Host
    $backupMode = if ($modeInput -eq '2') { 'full' } else { 'lean' }
    Write-Success $(if ($backupMode -eq 'lean') { "Lean backups - your work, minus the regenerable OS image" } else { "Full backups - everything included" })

    # ----- Build config -----
    Write-Heading "Configuring..."
    $config = Get-DefaultConfig
    $config.Primary.Root = $primaryRoot
    if ($archiveRoot) { $config.Archive.Root = $archiveRoot }
    $config.BackupMode = $backupMode
    Save-LifeboatConfig $config
    Write-Success "Config saved to $script:ConfigPath"

    # Ensure backup roots exist
    New-Item -ItemType Directory -Path $primaryRoot -Force | Out-Null
    if ($archiveRoot -and (Test-Path (($archiveRoot -split ':')[0] + ':'))) {
        New-Item -ItemType Directory -Path $archiveRoot -Force | Out-Null
    }

    # ----- Register scheduled tasks -----
    Register-LifeboatTasks
    Write-Success "Scheduled tasks registered"

    # ----- Run first backup -----
    Write-Heading "Running first backup to verify everything works..."
    Invoke-Backup -Flags @{ silent = $true }

    # ----- Done -----
    Write-Heading "Installed!"
    Write-Host "  Your Claude data will be backed up automatically:"
    Write-Host "    - Every hour while your computer is on"
    Write-Host "    - When you log in"
    Write-Host "    - When your laptop sleeps (lid close)"
    if ($archiveRoot) {
        Write-Host "    - When the archive drive is plugged in"
    }
    Write-Host "    - When idle for 10+ minutes"
    Write-Host ""
    Write-Host "  Useful commands:"
    Write-Host "    lifeboat status       # quick health check" -ForegroundColor DarkGray
    Write-Host "    lifeboat dashboard    # visual dashboard" -ForegroundColor DarkGray
    Write-Host "    lifeboat backup       # run a backup now" -ForegroundColor DarkGray
    Write-Host "    lifeboat restore      # restore something" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Questions? https://github.com/JackBhanded/claude-lifeboat" -ForegroundColor DarkCyan
    Write-Host ""
}

function Register-LifeboatTasks {
    $config = Get-LifeboatConfig
    if (-not $config) { return }

    # Remove existing
    Get-ScheduledTask -TaskName "ClaudeLifeboat-*" -ErrorAction SilentlyContinue |
        Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue

    # Install the backup runner script to a stable location
    $runnerSource = Join-Path $script:ScriptRoot "lifeboat-runner.ps1"
    if (Test-Path $runnerSource) {
        Copy-Item $runnerSource (Join-Path $script:LifeboatHome "lifeboat-runner.ps1") -Force
    }
    # Also copy lib folder so the runner can find its dependencies
    $libDest = Join-Path $script:LifeboatHome "lib"
    if (Test-Path $libDest) { Remove-Item $libDest -Recurse -Force }
    Copy-Item (Join-Path $script:ScriptRoot "lib") $libDest -Recurse

    $runnerPath = Join-Path $script:LifeboatHome "lifeboat-runner.ps1"

    # RunLevel Highest so scheduled backups run elevated - required for VSS to
    # snapshot locked files (the live Cowork sessiondata.vhdx). With S4U there's
    # no UAC prompt; it runs with the full token quietly in the background.
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
        -MultipleInstances IgnoreNew

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runnerPath`" backup"

    # Hourly
    if ($config.Schedule.HourlyEnabled) {
        $trigger = New-ScheduledTaskTrigger -Once `
            -At (Get-Date).Date.AddHours((Get-Date).Hour + 1) `
            -RepetitionInterval (New-TimeSpan -Hours 1)
        Register-ScheduledTask -TaskName "ClaudeLifeboat-Hourly" `
            -Description "Backs up Claude data every hour" `
            -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
    }

    # On logon
    if ($config.Schedule.OnLogon) {
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        Register-ScheduledTask -TaskName "ClaudeLifeboat-OnLogon" `
            -Description "Runs backup at login" `
            -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
    }

    # On sleep (lid close)
    if ($config.Schedule.OnSleep) {
        $sleepXml = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-Kernel-Power''] and (EventID=42)]]</Select></Query></QueryList>'
        try {
            $cls = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
            $et = New-CimInstance -CimClass $cls -ClientOnly
            $et.Enabled = $true; $et.Subscription = $sleepXml
            Register-ScheduledTask -TaskName "ClaudeLifeboat-OnSleep" `
                -Description "Runs backup when computer is going to sleep" `
                -Action $action -Trigger $et -Principal $principal -Settings $settings | Out-Null
        } catch {}
    }

    # On drive connect (if archive configured)
    if ($config.Schedule.OnDriveConnect -and $config.Archive.Root) {
        $pnpXml = '<QueryList><Query Id="0" Path="Microsoft-Windows-Ntfs/Operational"><Select Path="Microsoft-Windows-Ntfs/Operational">*[System[(EventID=98)]]</Select></Query></QueryList>'
        try {
            $cls = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
            $et = New-CimInstance -CimClass $cls -ClientOnly
            $et.Enabled = $true; $et.Subscription = $pnpXml
            Register-ScheduledTask -TaskName "ClaudeLifeboat-OnDriveConnect" `
                -Description "Runs backup when a drive is mounted" `
                -Action $action -Trigger $et -Principal $principal -Settings $settings | Out-Null
        } catch {}
    }

    # On idle
    if ($config.Schedule.OnIdle) {
        $idleSettings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -RunOnlyIfIdle `
            -IdleDuration (New-TimeSpan -Minutes 10) `
            -IdleWaitTimeout (New-TimeSpan -Minutes 30) `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
            -MultipleInstances IgnoreNew
        $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        Register-ScheduledTask -TaskName "ClaudeLifeboat-OnIdle" `
            -Description "Runs backup when machine is idle" `
            -Action $action -Trigger $logonTrigger -Principal $principal -Settings $idleSettings | Out-Null
    }

    # Health check task (every N hours, shows notification on issues)
    if ($config.Notifications.Enabled) {
        $statusAction = New-ScheduledTaskAction `
            -Execute "powershell.exe" `
            -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runnerPath`" status --quiet --notify"
        $trigger = New-ScheduledTaskTrigger -Once `
            -At (Get-Date).AddMinutes(30) `
            -RepetitionInterval (New-TimeSpan -Hours $config.Notifications.HealthCheckIntervalHours)
        Register-ScheduledTask -TaskName "ClaudeLifeboat-HealthCheck" `
            -Description "Periodic health check with notifications" `
            -Action $statusAction -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
    }
}

function Invoke-Uninstall {
    param($Flags)
    Require-Admin

    Write-Heading "Uninstall Claude Lifeboat"

    if (-not $Flags.force) {
        Write-Host "  This will:"
        Write-Host "    - Remove all scheduled tasks"
        Write-Host "    - Remove the config at $script:ConfigPath"
        Write-Host ""
        Write-Host "  This will NOT:"
        Write-Host "    - Delete your backup files (they stay on your drives)"
        Write-Host "    - Affect Claude Desktop itself"
        Write-Host ""
        Write-Prompt "Continue? (y/N):"
        $answer = Read-Host
        if ($answer -ne 'y') {
            Write-Info "Cancelled."
            return
        }
    }

    Get-ScheduledTask -TaskName "ClaudeLifeboat-*" -ErrorAction SilentlyContinue |
        Unregister-ScheduledTask -Confirm:$false
    Write-Success "Scheduled tasks removed"

    if (Test-Path $script:LifeboatHome) {
        Remove-Item $script:LifeboatHome -Recurse -Force -ErrorAction SilentlyContinue
        Write-Success "Config removed"
    }

    Write-Host ""
    Write-Info "Your backup files are untouched. Delete them manually if you want."
    Write-Host ""
}
