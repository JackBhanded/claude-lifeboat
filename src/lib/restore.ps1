# lifeboat restore - safe, undoable restore

function Invoke-Restore {
    param($Flags)

    $config = Get-LifeboatConfig
    if (-not $config) {
        Write-Failure "Lifeboat is not installed. Run: lifeboat install"
        exit 1
    }

    Write-Heading "Restore from backup"

    # Gather all available snapshots from both locations
    $allSnapshots = Get-AllSnapshots $config
    if ($allSnapshots.Count -eq 0) {
        Write-Failure "No snapshots found. Nothing to restore from."
        Write-Info "Try running: lifeboat backup"
        return
    }

    # Pick a snapshot
    $snapshot = if ($Flags.from) {
        Find-Snapshot -Snapshots $allSnapshots -From $Flags.from -Date $Flags.date
    } else {
        Select-Snapshot-Interactive $allSnapshots
    }

    if (-not $snapshot) {
        Write-Info "No snapshot selected. Cancelled."
        return
    }

    Write-Host ""
    Write-Host "  Selected: $($snapshot.Location) / $($snapshot.Kind) $($snapshot.Date)" -ForegroundColor Cyan
    Write-Host "  Source:   $($snapshot.Path)" -ForegroundColor DarkGray
    Write-Host "  Captured: $($snapshot.Time)" -ForegroundColor DarkGray

    # Pick what to restore
    $availableFolders = Get-ChildItem $snapshot.Path -Directory | Select-Object -ExpandProperty Name
    $foldersToRestore = if ($Flags.only) {
        @($Flags.only)
    } else {
        Select-Folders-Interactive $availableFolders
    }
    if ($foldersToRestore.Count -eq 0) { Write-Info "Nothing selected."; return }

    # Plan
    $isPreview = [bool]$Flags.preview
    # Preview restores go to a SINGLE temp folder (never the Desktop) so they
    # don't clutter anything, all folders land together, and Windows can clean
    # the temp area up on its own. We open it in Explorer afterwards.
    $previewRoot = Join-Path $env:TEMP "ClaudeLifeboat-preview-$(Get-Date -Format 'yyyy-MM-dd_HHmmss')"
    $plan = @()
    foreach ($f in $foldersToRestore) {
        $src = Join-Path $snapshot.Path $f
        $dst = if ($isPreview) {
            Join-Path $previewRoot $f
        } else {
            Resolve-OriginalDestination $f $config
        }
        if (-not $dst) {
            Write-Warning2 "Skipping $f - couldn't determine destination"
            continue
        }
        $plan += @{ Folder = $f; Source = $src; Dest = $dst }
    }
    if ($plan.Count -eq 0) { Write-Info "Nothing to restore."; return }

    Write-Host ""
    Write-Host "  Plan:" -ForegroundColor Yellow
    foreach ($item in $plan) {
        Write-Host "    $($item.Folder)"
        Write-Host "      from: $($item.Source)" -ForegroundColor DarkGray
        Write-Host "      to:   $($item.Dest)" -ForegroundColor DarkGray
    }

    # Confirm
    if (-not $Flags.force) {
        Write-Host ""
        if ($isPreview) {
            Write-Info "Preview mode: files go to a temp folder, nothing overwritten."
        } else {
            Write-Warning2 "This will OVERWRITE the destinations above."
            Write-Info "A safety snapshot of current state will be taken first."
        }
        Write-Prompt "Continue? (y/N):"
        if ((Read-Host) -ne 'y') { Write-Info "Cancelled."; return }
    }

    # ---- Safety snapshot (the Time Machine trick) ----
    if (-not $isPreview) {
        # Capture the timestamp ONCE so the folder name and the undo hint
        # below always match (two separate Get-Date calls could differ by a
        # second and break the undo command).
        $safetyStamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
        $safetyDir = Join-Path $config.Primary.Root "safety\pre-restore-$safetyStamp"
        Write-Host ""
        Write-Host "  Creating safety snapshot at $safetyDir..." -ForegroundColor Cyan
        New-Item -ItemType Directory -Path $safetyDir -Force | Out-Null
        foreach ($item in $plan) {
            if (Test-Path $item.Dest) {
                $safetyTarget = Join-Path $safetyDir $item.Folder
                Invoke-RobocopyLive $item.Dest $safetyTarget "safety: $($item.Folder)" | Out-Null
            }
        }
        Write-Success "Safety snapshot saved - we can always roll back to right now"
        Write-Info "If anything goes wrong, undo with: lifeboat restore --from safety --date $safetyStamp"
    }

    # ---- Stop Claude services if restoring Claude data ----
    $stoppedServices = @()
    $needsStop = $plan | Where-Object { $_.Folder -eq "ClaudeDesktop" -or $_.Folder -eq "Claude-System" }
    if ($needsStop -and -not $isPreview) {
        Write-Host ""
        Write-Host "  Stopping Claude services..." -ForegroundColor Cyan
        $stoppedServices = Stop-ClaudeProcesses
        if ($stoppedServices.Count -gt 0) {
            Write-Info "Stopped: $($stoppedServices -join ', ')"
        }
    }

    # ---- Do the restore ----
    Write-Host ""
    Write-Host "  Restoring..." -ForegroundColor Cyan
    $success = 0; $failed = 0
    foreach ($item in $plan) {
        $destParent = Split-Path $item.Dest -Parent
        if (-not (Test-Path $destParent)) {
            New-Item -ItemType Directory -Path $destParent -Force | Out-Null
        }
        $result = Invoke-RobocopyLive $item.Source $item.Dest "$($item.Folder)" -Mirror
        if ($result.Success) {
            Write-Host ("    {0}  restored" -f $item.Folder) -ForegroundColor Green
            $success++
        } else {
            Write-Host ("    {0}  hit a snag (exit {1})" -f $item.Folder, $result.ExitCode) -ForegroundColor Red
            $failed++
        }
    }

    # ---- Restart services ----
    if ($needsStop -and -not $isPreview) {
        Write-Host ""
        Write-Host "  Restarting Claude services..." -ForegroundColor Cyan
        Start-ClaudeServices
        Write-Success "Done"
    }

    # ---- Summary ----
    Write-Host ""
    if ($failed -eq 0) {
        if ($isPreview) {
            Write-Success "Preview complete - $success folder(s) laid out for you to inspect"
            Write-Host ""
            Write-Info "They're in a temp folder (safe to delete anytime):"
            Write-Info "  $previewRoot"
            Write-Info "Opening it in Explorer now. If the files look right, re-run restore without --preview."
            Start-Process explorer.exe $previewRoot -ErrorAction SilentlyContinue
        } else {
            Write-Success "Restore complete - $success folder(s) back in place. Welcome back."
        }
    } else {
        Write-Warning2 "$failed of $($plan.Count) folder(s) didn't restore cleanly."
        if (-not $isPreview) {
            Write-Info "You're not stuck - we took a safety snapshot before touching anything, so the previous state is fully recoverable:"
            Write-Info "  lifeboat restore --from safety --date $safetyStamp"
            Write-Info "Details in the log: $script:LogDir"
        } else {
            Write-Info "This was only a preview, so nothing real was touched. Check the log for details: $script:LogDir"
        }
    }
}

function Get-AllSnapshots($config) {
    $snapshots = @()

    $locations = @(
        @{ Name = "PRIMARY"; Root = $config.Primary.Root },
        @{ Name = "ARCHIVE"; Root = $config.Archive.Root }
    )

    foreach ($loc in $locations) {
        if (-not $loc.Root) { continue }
        if (-not (Test-DrivePath $loc.Root)) { continue }

        # latest
        $lp = Join-Path $loc.Root "latest"
        if (Test-Path $lp) {
            $snapshots += [PSCustomObject]@{
                Location = $loc.Name; Kind = "latest"; Date = ""
                Path = $lp; Time = (Get-Item $lp).LastWriteTime
            }
        }
        # dailies
        foreach ($d in (Get-ChildItem (Join-Path $loc.Root "daily") -Directory -ErrorAction SilentlyContinue)) {
            $snapshots += [PSCustomObject]@{
                Location = $loc.Name; Kind = "daily"; Date = $d.Name
                Path = $d.FullName; Time = $d.LastWriteTime
            }
        }
        # weeklies
        foreach ($w in (Get-ChildItem (Join-Path $loc.Root "weekly") -Directory -ErrorAction SilentlyContinue)) {
            $snapshots += [PSCustomObject]@{
                Location = $loc.Name; Kind = "weekly"; Date = $w.Name
                Path = $w.FullName; Time = $w.LastWriteTime
            }
        }
        # safety snapshots (auto-taken before each restore). Folder name is
        # "pre-restore-<timestamp>"; we expose <timestamp> as Date so the
        # `lifeboat restore --from safety --date <timestamp>` undo works.
        foreach ($s in (Get-ChildItem (Join-Path $loc.Root "safety") -Directory -ErrorAction SilentlyContinue)) {
            $snapshots += [PSCustomObject]@{
                Location = $loc.Name; Kind = "safety"; Date = ($s.Name -replace '^pre-restore-', '')
                Path = $s.FullName; Time = $s.LastWriteTime
            }
        }
    }

    return $snapshots
}

function Select-Snapshot-Interactive($snapshots) {
    Write-Host ""
    Write-Host "  Available snapshots:" -ForegroundColor Yellow

    $latests = $snapshots | Where-Object { $_.Kind -eq 'latest' } | Sort-Object Time -Descending
    $dailies = $snapshots | Where-Object { $_.Kind -eq 'daily' } | Sort-Object Date -Descending |
        Group-Object Date | ForEach-Object { $_.Group[0] }
    $weeklies = $snapshots | Where-Object { $_.Kind -eq 'weekly' } | Sort-Object Date -Descending |
        Group-Object Date | ForEach-Object { $_.Group[0] }

    $menu = @{}
    $i = 1
    if ($latests) {
        Write-Host ""
        Write-Host "  Most recent state:" -ForegroundColor Cyan
        foreach ($s in $latests) {
            $age = (New-TimeSpan -Start $s.Time -End (Get-Date))
            Write-Host ("    [$i] $($s.Location) latest  ($(Get-FormattedDuration $age) ago)")
            $menu[$i.ToString()] = $s; $i++
        }
    }
    if ($dailies) {
        Write-Host ""
        Write-Host "  Daily snapshots:" -ForegroundColor Cyan
        foreach ($s in $dailies) {
            Write-Host ("    [$i] daily " + $s.Date + "  ($($s.Location))")
            $menu[$i.ToString()] = $s; $i++
        }
    }
    if ($weeklies) {
        Write-Host ""
        Write-Host "  Weekly snapshots:" -ForegroundColor Cyan
        foreach ($s in $weeklies) {
            Write-Host ("    [$i] weekly " + $s.Date + "  ($($s.Location))")
            $menu[$i.ToString()] = $s; $i++
        }
    }

    Write-Host ""
    Write-Prompt "Pick a number (or blank to cancel):"
    $choice = Read-Host
    if (-not $choice) { return $null }
    return $menu[$choice.Trim()]
}

function Find-Snapshot($Snapshots, $From, $Date) {
    if ($From -eq 'latest') {
        return $Snapshots | Where-Object { $_.Kind -eq 'latest' } |
            Sort-Object @{Expression={if($_.Location -eq 'PRIMARY'){0}else{1}}}, Time -Descending |
            Select-Object -First 1
    }
    return $Snapshots | Where-Object { $_.Kind -eq $From -and $_.Date -eq $Date } |
        Sort-Object @{Expression={if($_.Location -eq 'ARCHIVE'){0}else{1}}} |
        Select-Object -First 1
}

function Select-Folders-Interactive($folders) {
    Write-Host ""
    Write-Host "  What to restore:" -ForegroundColor Yellow
    $i = 1
    foreach ($f in $folders) {
        Write-Host "    [$i] $f"
        $i++
    }
    Write-Host ""
    Write-Prompt "Numbers (e.g. 1,3) or 'all':"
    $choice = Read-Host
    if ($choice -eq 'all') { return $folders }
    if (-not $choice) { return @() }
    $idx = $choice -split ',' | ForEach-Object { [int]($_.Trim()) - 1 }
    return $idx | ForEach-Object { $folders[$_] }
}

function Resolve-OriginalDestination($folderName, $config) {
    switch -Wildcard ($folderName) {
        "ClaudeDesktop" {
            $existing = Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -Filter "Claude_*" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($existing) { return $existing.FullName }
            return "$env:LOCALAPPDATA\Packages\Claude_pzs8sxrjxfjjc"
        }
        "Claude-System" { return "C:\ProgramData\Claude" }
        "ClaudeCode-user" { return "$env:USERPROFILE\.claude" }
        "ClaudeCode-appdata" { return "$env:APPDATA\claude-code" }
        "ClaudeCode-xdg" { return "$env:USERPROFILE\.config\claude" }
        "Extra-*" {
            $base = $folderName -replace '^Extra-', ''
            foreach ($p in $config.ExtraPaths) {
                if ((Split-Path $p -Leaf) -eq $base) { return $p }
            }
            return $null
        }
        default { return $null }
    }
}
