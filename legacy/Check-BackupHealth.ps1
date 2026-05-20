# =====================================================================
# Check-BackupHealth.ps1
# Quick traffic-light status of your backup system.
# Run anytime, or schedule it to email you / show a notification.
#
# Usage:
#   .\Check-BackupHealth.ps1                  # text output
#   .\Check-BackupHealth.ps1 -Notify          # also show toast notification if issues
#   .\Check-BackupHealth.ps1 -Quiet           # only show output if there are issues
#   .\Check-BackupHealth.ps1 -Json            # output as JSON (for scripting)
#
# Exit codes:
#   0 = all green
#   1 = warnings (yellow)
#   2 = errors (red)
# =====================================================================

param(
    [switch]$Notify,
    [switch]$Quiet,
    [switch]$Json
)

$ErrorActionPreference = "Continue"

# Load config
$configPath = "$env:LOCALAPPDATA\ClaudeAutoBackup\config.json"
if (-not (Test-Path $configPath)) {
    Write-Host "ERROR: No config found. Run Setup-AutoBackup.ps1 first." -ForegroundColor Red
    exit 2
}
$config = Get-Content $configPath -Raw | ConvertFrom-Json

# =====================================================================
# Run all checks, collect results
# =====================================================================
$checks = @()

function Add-Check($name, $status, $message, $detail) {
    # status: "green", "yellow", "red"
    $script:checks += [PSCustomObject]@{
        Name = $name
        Status = $status
        Message = $message
        Detail = $detail
    }
}

# --- Check 1: Last successful backup time ---
$primaryStatus = $null
$primaryStatusPath = Join-Path $config.PrimaryRoot "status.json"
if (Test-Path $primaryStatusPath) {
    $primaryStatus = Get-Content $primaryStatusPath -Raw | ConvertFrom-Json
    $lastRun = [DateTime]::Parse($primaryStatus.LastRun)
    $hoursSince = ((Get-Date) - $lastRun).TotalHours

    if ($hoursSince -lt 2) {
        Add-Check "Last backup" "green" "Recent" "$([math]::Round($hoursSince*60)) min ago"
    } elseif ($hoursSince -lt 6) {
        Add-Check "Last backup" "yellow" "Older than expected" "$([math]::Round($hoursSince,1)) hours ago"
    } else {
        Add-Check "Last backup" "red" "Stale" "$([math]::Round($hoursSince,1)) hours ago - something is wrong"
    }
} else {
    Add-Check "Last backup" "red" "No backup status file found" "Check $primaryStatusPath"
}

# --- Check 2: PRIMARY drive available and has space ---
$primaryDriveLetter = ($config.PrimaryRoot -split ':')[0]
if (Test-Path "${primaryDriveLetter}:") {
    $drive = Get-PSDrive -Name $primaryDriveLetter -ErrorAction SilentlyContinue
    if ($drive) {
        $freeGB = [math]::Round($drive.Free / 1GB, 1)
        $totalGB = [math]::Round(($drive.Free + $drive.Used) / 1GB, 1)
        $pctFree = if ($totalGB -gt 0) { ($drive.Free / ($drive.Free + $drive.Used)) * 100 } else { 0 }

        if ($freeGB -gt 20 -and $pctFree -gt 10) {
            Add-Check "PRIMARY drive ($primaryDriveLetter`:)" "green" "${freeGB} GB free" "${pctFree:N0}% free of ${totalGB} GB"
        } elseif ($freeGB -gt 5) {
            Add-Check "PRIMARY drive ($primaryDriveLetter`:)" "yellow" "Getting low: ${freeGB} GB free" "${pctFree:N0}% free of ${totalGB} GB"
        } else {
            Add-Check "PRIMARY drive ($primaryDriveLetter`:)" "red" "Critical: ${freeGB} GB free" "Backups will fail soon"
        }
    }
} else {
    Add-Check "PRIMARY drive ($primaryDriveLetter`:)" "red" "Not available!" "Internal drive missing - serious issue"
}

# --- Check 3: ARCHIVE drive status ---
if ($config.ArchiveRoot) {
    $archiveDriveLetter = ($config.ArchiveRoot -split ':')[0]
    $archiveDriveAvailable = Test-Path "${archiveDriveLetter}:"

    if ($archiveDriveAvailable) {
        $drive = Get-PSDrive -Name $archiveDriveLetter -ErrorAction SilentlyContinue
        if ($drive) {
            $freeGB = [math]::Round($drive.Free / 1GB, 1)
            $totalGB = [math]::Round(($drive.Free + $drive.Used) / 1GB, 1)

            if ($freeGB -gt 30) {
                Add-Check "ARCHIVE drive ($archiveDriveLetter`:)" "green" "Connected, ${freeGB} GB free" "of ${totalGB} GB"
            } elseif ($freeGB -gt 10) {
                Add-Check "ARCHIVE drive ($archiveDriveLetter`:)" "yellow" "Connected, ${freeGB} GB free (low)" "of ${totalGB} GB"
            } else {
                Add-Check "ARCHIVE drive ($archiveDriveLetter`:)" "red" "Connected but only ${freeGB} GB free" "Old backups may not prune fast enough"
            }
        }

        # Check last archive sync
        $lastSyncFile = Join-Path $config.ArchiveRoot ".last_archive_sync"
        if (Test-Path $lastSyncFile) {
            $lastSync = Get-Content $lastSyncFile | Select-Object -First 1
            try {
                $lastSyncTime = [DateTime]::Parse($lastSync)
                $hoursSinceArchive = ((Get-Date) - $lastSyncTime).TotalHours
                if ($hoursSinceArchive -lt 2) {
                    Add-Check "Last archive sync" "green" "Recent" "$([math]::Round($hoursSinceArchive*60)) min ago"
                } elseif ($hoursSinceArchive -lt 24) {
                    Add-Check "Last archive sync" "green" "Today" "$([math]::Round($hoursSinceArchive,1)) hours ago"
                } else {
                    Add-Check "Last archive sync" "yellow" "Aging" "$([math]::Round($hoursSinceArchive/24,1)) days ago"
                }
            } catch {}
        }
    } else {
        # Archive drive unplugged. How long has it been?
        $lastSyncFile = Join-Path $config.ArchiveRoot ".last_archive_sync"
        # We can't read the file if the drive is unplugged. Check primary status for hint.
        if ($primaryStatus -and $primaryStatus.ArchiveSynced -eq $false) {
            # We don't know exact last sync time without the archive
            # But we can estimate from when PRIMARY ran without archive
            Add-Check "ARCHIVE drive ($archiveDriveLetter`:)" "yellow" "Unplugged" "Plug in to sync. PRIMARY still backing up normally."
        } else {
            Add-Check "ARCHIVE drive ($archiveDriveLetter`:)" "yellow" "Unplugged" "PRIMARY still backing up. Plug in to catch up."
        }
    }
} else {
    Add-Check "ARCHIVE drive" "yellow" "Not configured" "No off-site backup. Consider adding one."
}

# --- Check 4: Scheduled tasks are healthy ---
$tasks = Get-ScheduledTask -TaskName "ClaudeAutoBackup-*" -ErrorAction SilentlyContinue
if (-not $tasks) {
    Add-Check "Scheduled tasks" "red" "No backup tasks found!" "Run Setup-AutoBackup.ps1 to register them"
} else {
    $taskCount = $tasks.Count
    $failedTasks = @()
    $disabledTasks = @()

    foreach ($t in $tasks) {
        $info = Get-ScheduledTaskInfo -TaskName $t.TaskName
        if ($t.State -eq "Disabled") {
            $disabledTasks += $t.TaskName
        }
        # LastTaskResult 0 = success, 0x41301 = task currently running, 0x41303 = task never run yet (OK)
        if ($info.LastTaskResult -ne 0 -and $info.LastTaskResult -ne 0x41301 -and $info.LastTaskResult -ne 0x41303 -and $info.LastTaskResult -ne 267011) {
            $failedTasks += "$($t.TaskName) (code: 0x{0:X})" -f $info.LastTaskResult
        }
    }

    if ($failedTasks.Count -gt 0) {
        Add-Check "Scheduled tasks" "red" "$($failedTasks.Count) task(s) failed" ($failedTasks -join '; ')
    } elseif ($disabledTasks.Count -gt 0) {
        Add-Check "Scheduled tasks" "yellow" "$($disabledTasks.Count) task(s) disabled" ($disabledTasks -join '; ')
    } else {
        Add-Check "Scheduled tasks" "green" "All $taskCount tasks healthy" ""
    }
}

# --- Check 5: Backup data integrity (basic) ---
if ($primaryStatus) {
    $latestPath = Join-Path $config.PrimaryRoot "latest"
    if (Test-Path $latestPath) {
        # Make sure the expected folders are there
        $expected = @($primaryStatus.BackedUp)
        $actual = Get-ChildItem $latestPath -Directory | Select-Object -ExpandProperty Name
        $missing = $expected | Where-Object { $actual -notcontains $_ }

        if ($missing.Count -eq 0) {
            $sizeGB = [math]::Round((Get-ChildItem $latestPath -Recurse -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1GB, 2)
            Add-Check "Backup contents" "green" "All expected folders present ($($actual.Count))" "${sizeGB} GB total"
        } else {
            Add-Check "Backup contents" "yellow" "$($missing.Count) expected folder(s) missing" ($missing -join ', ')
        }
    } else {
        Add-Check "Backup contents" "red" "'latest' folder missing" "Backup may have failed completely"
    }
}

# --- Check 6: Recent errors in log ---
$today = Get-Date -Format 'yyyy-MM-dd'
$todayLog = "$env:LOCALAPPDATA\ClaudeAutoBackup\logs\backup-$today.log"
if (Test-Path $todayLog) {
    $errors = Select-String -Path $todayLog -Pattern "ERROR:" -ErrorAction SilentlyContinue
    if ($errors) {
        Add-Check "Today's log" "red" "$($errors.Count) error(s) logged today" "Check $todayLog"
    } else {
        $entries = (Get-Content $todayLog | Measure-Object -Line).Lines
        Add-Check "Today's log" "green" "No errors today" "$entries log entries"
    }
}

# =====================================================================
# Output
# =====================================================================
$hasRed = ($checks | Where-Object { $_.Status -eq "red" }).Count -gt 0
$hasYellow = ($checks | Where-Object { $_.Status -eq "yellow" }).Count -gt 0

if ($Json) {
    $result = @{
        OverallStatus = if ($hasRed) { "red" } elseif ($hasYellow) { "yellow" } else { "green" }
        CheckedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Checks = $checks
    }
    $result | ConvertTo-Json -Depth 5
    exit (if ($hasRed) { 2 } elseif ($hasYellow) { 1 } else { 0 })
}

if (-not $Quiet -or $hasRed -or $hasYellow) {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  CLAUDE BACKUP HEALTH CHECK" -ForegroundColor Cyan
    Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
    Write-Host "========================================`n" -ForegroundColor Cyan

    foreach ($c in $checks) {
        $icon = switch ($c.Status) {
            "green"  { "[OK]   " }
            "yellow" { "[WARN] " }
            "red"    { "[FAIL] " }
        }
        $color = switch ($c.Status) {
            "green"  { "Green" }
            "yellow" { "Yellow" }
            "red"    { "Red" }
        }
        Write-Host ("$icon{0,-30} {1}" -f $c.Name, $c.Message) -ForegroundColor $color
        if ($c.Detail) {
            Write-Host ("       {0}" -f $c.Detail) -ForegroundColor DarkGray
        }
    }

    Write-Host "`n----------------------------------------" -ForegroundColor Cyan
    if ($hasRed) {
        Write-Host "OVERALL: ATTENTION NEEDED" -ForegroundColor Red
    } elseif ($hasYellow) {
        Write-Host "OVERALL: OK with warnings" -ForegroundColor Yellow
    } else {
        Write-Host "OVERALL: ALL GREEN" -ForegroundColor Green
    }
    Write-Host ""
}

# =====================================================================
# Toast notification (Windows 10/11)
# =====================================================================
if ($Notify -and ($hasRed -or $hasYellow)) {
    try {
        $title = if ($hasRed) { "Claude Backup: Attention needed" } else { "Claude Backup: Warning" }
        $issues = $checks | Where-Object { $_.Status -ne "green" }
        $body = ($issues | ForEach-Object { "- $($_.Name): $($_.Message)" }) -join "`n"
        if ($body.Length -gt 200) { $body = $body.Substring(0, 197) + "..." }

        # Use Windows.UI.Notifications via PowerShell
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $textNodes = $template.GetElementsByTagName("text")
        $textNodes.Item(0).AppendChild($template.CreateTextNode($title)) | Out-Null
        $textNodes.Item(1).AppendChild($template.CreateTextNode($body)) | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("ClaudeBackup")
        $notifier.Show($toast)
    } catch {
        # Toast failed (older Windows, missing assemblies, etc.)
        # Fall back to a simple message box
        try {
            Add-Type -AssemblyName PresentationFramework
            $title = if ($hasRed) { "Claude Backup: Attention needed" } else { "Claude Backup: Warning" }
            $issues = $checks | Where-Object { $_.Status -ne "green" }
            $body = ($issues | ForEach-Object { "- $($_.Name): $($_.Message)" }) -join "`n"
            [System.Windows.MessageBox]::Show($body, $title, 'OK', 'Warning') | Out-Null
        } catch {}
    }
}

if ($hasRed) { exit 2 }
elseif ($hasYellow) { exit 1 }
else { exit 0 }
