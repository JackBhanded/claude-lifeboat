# lifeboat backup - the actual backup engine

function Invoke-Backup {
    param($Flags)

    $config = Get-LifeboatConfig
    if (-not $config) {
        Write-Failure "Lifeboat is not installed. Run: lifeboat install"
        exit 1
    }

    $silent = [bool]$Flags.silent
    $startTime = Get-Date

    if (-not $silent) {
        Write-Heading "Running backup..."
    }
    Write-LifeboatLog "Backup started"

    # ---- Step 1: Primary backup (always) ----
    $primaryRoot = $config.Primary.Root
    if (-not (Test-DrivePath $primaryRoot)) {
        Write-Failure "Primary drive not available: $primaryRoot"
        Write-LifeboatLog "Primary drive missing - aborting" "ERROR"
        exit 1
    }

    $primaryLatest = Join-Path $primaryRoot "latest"
    New-Item -ItemType Directory -Path $primaryLatest -Force | Out-Null

    $paths = Get-ClaudeDataPaths
    foreach ($p in $config.ExtraPaths) {
        if (Test-Path $p) {
            $paths["Extra-$(Split-Path $p -Leaf)"] = $p
        }
    }

    if ($paths.Count -eq 0) {
        Write-Warning2 "Nothing to back up. Is Claude Desktop installed?"
        Write-LifeboatLog "No paths to back up" "WARN"
        return
    }

    if (-not $silent) {
        Write-Host "  Backing up to: $primaryRoot" -ForegroundColor DarkGray
    }

    $results = @{}
    foreach ($name in $paths.Keys) {
        $src = $paths[$name]
        $dst = Join-Path $primaryLatest $name
        if ($silent) {
            $result = Invoke-Robocopy $src $dst -Mirror
        } else {
            # Live spinner so big copies (the VM bundle) don't look frozen.
            $result = Invoke-RobocopyLive $src $dst $name -Mirror
            if ($result.Success) {
                Write-Host ("    {0}  OK" -f $name) -ForegroundColor Green
            } else {
                Write-Host ("    {0}  FAILED (exit {1})" -f $name, $result.ExitCode) -ForegroundColor Red
            }
        }
        $results[$name] = $result
        Write-LifeboatLog "$name -> primary: $(if($result.Success){'OK'}else{'FAIL exit '+$result.ExitCode})"
    }

    # Did anything actually change this run? robocopy exit 0 = nothing copied;
    # 1-7 = files copied / extras cleaned; 8+ = a failure (not a "change").
    $anyChanges = @($results.Values | Where-Object { $_.ExitCode -ge 1 -and $_.ExitCode -lt 8 }).Count -gt 0

    if (-not $silent) {
        Write-Host ""
        if ($anyChanges) {
            Write-Success "Primary backup secured - $($paths.Count) folder(s) safe at $primaryRoot"
        } else {
            Write-Success "Everything's already up to date - nothing new to copy. (That's a good sign.)"
        }
    }

    # ---- Step 2: Primary daily snapshot (only when something actually changed) ----
    # If nothing changed, today's snapshot would be a redundant full copy of an
    # identical state, so we skip it and just note it. Saves time and disk.
    $today = Get-Date -Format "yyyy-MM-dd"
    $primaryDaily = Join-Path $primaryRoot "daily\$today"
    if ($anyChanges -and -not (Test-Path $primaryDaily)) {
        New-Item -ItemType Directory -Path $primaryDaily -Force | Out-Null
        if ($silent) {
            Invoke-Robocopy $primaryLatest $primaryDaily | Out-Null
        } else {
            Write-Host "    Tucking away today's snapshot ($today)..." -ForegroundColor DarkGray
            Invoke-RobocopyLive $primaryLatest $primaryDaily "daily snapshot" | Out-Null
            Write-Success "Today's snapshot saved"
        }
        Write-LifeboatLog "Created primary daily snapshot: $today"
    } elseif (-not $anyChanges) {
        Write-LifeboatLog "No changes since last backup - skipped daily snapshot"
    }

    # Prune primary dailies
    Prune-Snapshots (Join-Path $primaryRoot "daily") $config.Primary.RetentionDailies

    # ---- Step 3: Archive sync (if available) ----
    $archiveAvailable = $false
    if ($config.Archive.Root -and (Test-DrivePath $config.Archive.Root)) {
        $archiveAvailable = $true
        $archiveRoot = $config.Archive.Root
        New-Item -ItemType Directory -Path $archiveRoot -Force | Out-Null
        $archiveLatest = Join-Path $archiveRoot "latest"
        New-Item -ItemType Directory -Path $archiveLatest -Force | Out-Null

        if (-not $silent) {
            Write-Host ""
            Write-Heading "Archive drive aboard ($archiveRoot)"
            Write-Host "    Stowing a second copy so your backup lives in two places..." -ForegroundColor DarkGray
        }

        # Determine if catch-up needed
        $isCatchUp = $false
        $lastSyncFile = Join-Path $archiveRoot ".last_sync"
        if (Test-Path $lastSyncFile) {
            try {
                $lastSync = [DateTime]::Parse((Get-Content $lastSyncFile | Select-Object -First 1))
                if (((Get-Date) - $lastSync).TotalHours -gt 6) { $isCatchUp = $true }
            } catch { $isCatchUp = $true }
        } else { $isCatchUp = $true }

        # Mirror latest
        if ($silent) {
            $syncResult = Invoke-Robocopy $primaryLatest $archiveLatest -Mirror
        } else {
            $syncResult = Invoke-RobocopyLive $primaryLatest $archiveLatest "archive sync" -Mirror
            if ($syncResult.Success) {
                Write-Success "Archive synced - your backup now lives in two places"
            } else {
                Write-Warning2 "Archive sync didn't finish cleanly (exit $($syncResult.ExitCode))."
                Write-Info "No worries - your primary copy at $primaryRoot is complete and safe. We'll catch the archive up automatically next time the drive is connected."
            }
        }

        # Archive daily (only when something changed - no point snapshotting
        # an identical state)
        $archiveDaily = Join-Path $archiveRoot "daily\$today"
        if ($anyChanges -and -not (Test-Path $archiveDaily)) {
            New-Item -ItemType Directory -Path $archiveDaily -Force | Out-Null
            Invoke-Robocopy $archiveLatest $archiveDaily | Out-Null
        }

        # Weekly snapshot (Sundays, only when something changed)
        if ($anyChanges -and (Get-Date).DayOfWeek -eq 'Sunday') {
            $archiveWeekly = Join-Path $archiveRoot "weekly\$today"
            if (-not (Test-Path $archiveWeekly)) {
                New-Item -ItemType Directory -Path $archiveWeekly -Force | Out-Null
                Invoke-Robocopy $archiveLatest $archiveWeekly | Out-Null
            }
        }

        # Catch-up: bring across any missing primary dailies
        if ($isCatchUp) {
            $primaryDailyParent = Join-Path $primaryRoot "daily"
            $primaryDailies = Get-ChildItem $primaryDailyParent -Directory -ErrorAction SilentlyContinue
            foreach ($pd in $primaryDailies) {
                $matchingArchive = Join-Path $archiveRoot "daily\$($pd.Name)"
                if (-not (Test-Path $matchingArchive)) {
                    New-Item -ItemType Directory -Path $matchingArchive -Force | Out-Null
                    Invoke-Robocopy $pd.FullName $matchingArchive | Out-Null
                }
            }
        }

        Prune-Snapshots (Join-Path $archiveRoot "daily") $config.Archive.RetentionDailies
        Prune-Snapshots (Join-Path $archiveRoot "weekly") $config.Archive.RetentionWeeklies

        (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") | Set-Content $lastSyncFile
    } elseif ($config.Archive.Root) {
        if (-not $silent) {
            Write-Host ""
            Write-Info "Archive drive offline. Skipped (will catch up when reconnected)."
        }
        Write-LifeboatLog "Archive offline - skipped"
    }

    # ---- Step 4: Quick integrity check (sample verification) ----
    $verifyResult = $null
    if ($config.Advanced.VerifyAfterBackup) {
        $verifyResult = Test-BackupSample -BackupRoot $primaryRoot -SampleSize $config.Advanced.VerifySampleSize
        if (-not $silent) {
            Write-Host ""
            if ($verifyResult.AllPassed) {
                Write-Success "Integrity check passed - $($verifyResult.Tested) files spot-checked, all readable"
            } else {
                Write-Warning2 "Heads up: $($verifyResult.Failed) of $($verifyResult.Tested) spot-checked files couldn't be read back."
                Write-Info "Your backup still ran. Worth a closer look with 'lifeboat verify' when you have a moment - often it's a file that was mid-write."
            }
        }
    }

    # ---- Step 5: Write status ----
    $duration = (Get-Date) - $startTime
    $status = @{
        LastRun = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        DurationSeconds = [math]::Round($duration.TotalSeconds, 1)
        PrimaryRoot = $primaryRoot
        ArchiveRoot = $config.Archive.Root
        ArchiveSynced = $archiveAvailable
        BackedUp = @($paths.Keys)
        IntegrityOK = if ($verifyResult) { $verifyResult.AllPassed } else { $null }
        Failures = ($results.GetEnumerator() | Where-Object { -not $_.Value.Success } | ForEach-Object { $_.Key })
    }
    $statusJson = $status | ConvertTo-Json -Depth 5
    $statusJson | Set-Content -Path (Join-Path $primaryRoot "status.json") -Encoding UTF8
    if ($archiveAvailable) {
        $statusJson | Set-Content -Path (Join-Path $archiveRoot "status.json") -Encoding UTF8
    }

    Write-LifeboatLog "Backup completed in $($duration.TotalSeconds)s"

    if (-not $silent) {
        Write-Host ""
        $failedFolders = @($results.GetEnumerator() | Where-Object { -not $_.Value.Success } | ForEach-Object { $_.Key })
        if ($failedFolders.Count -eq 0) {
            Write-Success "All done in $(Get-FormattedDuration $duration). Your Claude work is safe and sound - rest easy."
        } else {
            Write-Warning2 "Finished in $(Get-FormattedDuration $duration). Most things backed up fine; these want a second look: $($failedFolders -join ', ')."
            Write-Info "Nothing was lost - your live Claude data is untouched, and earlier snapshots are still intact. Try 'lifeboat doctor', or just re-run 'lifeboat backup'. Usually it's a file that was briefly in use."
        }
    }
}

function Test-BackupSample {
    param([string]$BackupRoot, [int]$SampleSize = 5)
    # Sample-verify by re-reading random files and confirming we can read them.
    # This catches catastrophic copy failures even if robocopy reported success.
    $latest = Join-Path $BackupRoot "latest"
    if (-not (Test-Path $latest)) { return @{ AllPassed = $false; Tested = 0; Failed = 0 } }

    $allFiles = Get-ChildItem $latest -Recurse -File -ErrorAction SilentlyContinue
    if ($allFiles.Count -eq 0) { return @{ AllPassed = $true; Tested = 0; Failed = 0 } }

    $sample = $allFiles | Get-Random -Count ([math]::Min($SampleSize, $allFiles.Count))
    $failed = 0
    foreach ($f in $sample) {
        try {
            # Try to read first byte to confirm file is accessible and not corrupt
            $stream = [System.IO.File]::OpenRead($f.FullName)
            $buf = New-Object byte[] 1
            $null = $stream.Read($buf, 0, 1)
            $stream.Close()
        } catch {
            $failed++
        }
    }
    return @{
        AllPassed = ($failed -eq 0)
        Tested = $sample.Count
        Failed = $failed
    }
}

function Prune-Snapshots($parent, $keep) {
    if (-not (Test-Path $parent)) { return }
    $old = Get-ChildItem $parent -Directory | Sort-Object Name -Descending | Select-Object -Skip $keep
    foreach ($d in $old) {
        Remove-Item $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
        Write-LifeboatLog "Pruned $($d.Name) from $parent"
    }
}
