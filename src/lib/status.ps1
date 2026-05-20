# lifeboat status - traffic-light health check

function Invoke-Status {
    param($Flags)

    $config = Get-LifeboatConfig
    if (-not $config) {
        if ($Flags.json) {
            @{ OverallStatus = "red"; Error = "not installed" } | ConvertTo-Json
        } else {
            Write-Failure "Lifeboat is not installed. Run: lifeboat install"
        }
        exit 2
    }

    $script:checks = @()
    function Add-Check($name, $status, $message, $detail = "") {
        $script:checks += [PSCustomObject]@{
            Name = $name; Status = $status; Message = $message; Detail = $detail
        }
    }

    # Read status file
    $primaryStatus = $null
    $statusPath = Join-Path $config.Primary.Root "status.json"
    if (Test-Path $statusPath) {
        try { $primaryStatus = Get-Content $statusPath -Raw | ConvertFrom-Json } catch {}
    }

    # Check: last backup time
    if ($primaryStatus) {
        $lastRun = [DateTime]::Parse($primaryStatus.LastRun)
        $age = (New-TimeSpan -Start $lastRun -End (Get-Date))
        if ($age.TotalHours -lt 2) {
            Add-Check "Last backup" "green" "Recent" "$(Get-FormattedDuration $age) ago"
        } elseif ($age.TotalHours -lt 6) {
            Add-Check "Last backup" "yellow" "Older than expected" "$(Get-FormattedDuration $age) ago"
        } else {
            Add-Check "Last backup" "red" "Stale" "$(Get-FormattedDuration $age) ago"
        }
    } else {
        Add-Check "Last backup" "red" "No backup yet" "Run: lifeboat backup"
    }

    # Primary drive
    $primaryStats = Get-DriveStats $config.Primary.Root
    if ($primaryStats.Available) {
        $freeGB = [math]::Round($primaryStats.FreeBytes / 1GB, 1)
        if ($primaryStats.PercentUsed -lt 80 -and $freeGB -gt 10) {
            Add-Check "PRIMARY drive" "green" "${freeGB} GB free" "$(($primaryStats.PercentUsed))% used"
        } elseif ($primaryStats.PercentUsed -lt 95) {
            Add-Check "PRIMARY drive" "yellow" "${freeGB} GB free (getting low)" "$(($primaryStats.PercentUsed))% used"
        } else {
            Add-Check "PRIMARY drive" "red" "${freeGB} GB free (critical)" "Backups may fail soon"
        }
    } else {
        Add-Check "PRIMARY drive" "red" "Not available" $config.Primary.Root
    }

    # Archive drive
    if ($config.Archive.Root) {
        $archiveStats = Get-DriveStats $config.Archive.Root
        if ($archiveStats.Available) {
            $freeGB = [math]::Round($archiveStats.FreeBytes / 1GB, 1)
            if ($freeGB -gt 20) {
                Add-Check "ARCHIVE drive" "green" "Connected, ${freeGB} GB free" "$($archiveStats.PercentUsed)% used"
            } else {
                Add-Check "ARCHIVE drive" "yellow" "Connected, ${freeGB} GB free (low)" "$($archiveStats.PercentUsed)% used"
            }
            # Last sync
            $syncFile = Join-Path $config.Archive.Root ".last_sync"
            if (Test-Path $syncFile) {
                try {
                    $lastSync = [DateTime]::Parse((Get-Content $syncFile | Select-Object -First 1))
                    $syncAge = (New-TimeSpan -Start $lastSync -End (Get-Date))
                    if ($syncAge.TotalHours -lt 24) {
                        Add-Check "Last archive sync" "green" "$(Get-FormattedDuration $syncAge) ago" ""
                    } else {
                        Add-Check "Last archive sync" "yellow" "$(Get-FormattedDuration $syncAge) ago" ""
                    }
                } catch {}
            }
        } else {
            Add-Check "ARCHIVE drive" "yellow" "Unplugged" "PRIMARY still backing up. Plug in to sync."
        }
    }

    # Scheduled tasks
    $tasks = Get-ScheduledTask -TaskName "ClaudeLifeboat-*" -ErrorAction SilentlyContinue
    if (-not $tasks) {
        Add-Check "Scheduled tasks" "red" "None found" "Run: lifeboat install"
    } else {
        $failed = @()
        foreach ($t in $tasks) {
            $info = Get-ScheduledTaskInfo -TaskName $t.TaskName
            $r = $info.LastTaskResult
            # 0=ok, 267011 / 0x41303=not yet run, 267009 / 0x41301=running
            if ($r -ne 0 -and $r -ne 267011 -and $r -ne 267009) {
                $failed += "$($t.TaskName -replace 'ClaudeLifeboat-','') (0x{0:X})" -f $r
            }
        }
        if ($failed.Count -gt 0) {
            Add-Check "Scheduled tasks" "red" "$($failed.Count) task(s) failed" ($failed -join '; ')
        } else {
            Add-Check "Scheduled tasks" "green" "All $($tasks.Count) tasks healthy" ""
        }
    }

    # Integrity
    if ($primaryStatus -and $null -ne $primaryStatus.IntegrityOK) {
        if ($primaryStatus.IntegrityOK) {
            Add-Check "Last integrity check" "green" "Passed" ""
        } else {
            Add-Check "Last integrity check" "yellow" "Failed" "Some files unreadable"
        }
    }

    # Today's log errors
    $todayLog = Join-Path $script:LogDir "lifeboat-$(Get-Date -Format 'yyyy-MM-dd').log"
    if (Test-Path $todayLog) {
        $errCount = (Select-String -Path $todayLog -Pattern "\[ERROR\]" -ErrorAction SilentlyContinue).Count
        if ($errCount -eq 0) {
            Add-Check "Today's log" "green" "No errors" ""
        } else {
            Add-Check "Today's log" "yellow" "$errCount error(s) today" $todayLog
        }
    }

    $hasRed = ($script:checks | Where-Object { $_.Status -eq "red" }).Count -gt 0
    $hasYellow = ($script:checks | Where-Object { $_.Status -eq "yellow" }).Count -gt 0

    if ($Flags.json) {
        @{
            OverallStatus = if ($hasRed) { "red" } elseif ($hasYellow) { "yellow" } else { "green" }
            CheckedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            Checks = $script:checks
        } | ConvertTo-Json -Depth 5
    } else {
        $quiet = [bool]$Flags.quiet
        if (-not $quiet -or $hasRed -or $hasYellow) {
            Write-Heading "Lifeboat Status"
            foreach ($c in $script:checks) {
                $sym = switch ($c.Status) {
                    'green' { [char]0x2713; break }
                    'yellow' { '!'; break }
                    'red' { [char]0x2717; break }
                }
                $col = switch ($c.Status) {
                    'green' { 'Green'; break }
                    'yellow' { 'Yellow'; break }
                    'red' { 'Red'; break }
                }
                Write-Host ("  $sym " + ("{0,-26} " -f $c.Name) + $c.Message) -ForegroundColor $col
                if ($c.Detail) {
                    Write-Host ("    " + $c.Detail) -ForegroundColor DarkGray
                }
            }
            Write-Host ""
            if ($hasRed) {
                Write-Host "  Overall: ATTENTION NEEDED" -ForegroundColor Red
                Write-Info "Try: lifeboat doctor"
            } elseif ($hasYellow) {
                Write-Host "  Overall: OK with warnings" -ForegroundColor Yellow
            } else {
                Write-Host "  Overall: ALL GREEN" -ForegroundColor Green
            }
            Write-Host ""
        }
    }

    # Notification
    if ($Flags.notify -and ($hasRed -or $hasYellow)) {
        try {
            $title = if ($hasRed) { "Lifeboat: Attention needed" } else { "Lifeboat: Warning" }
            $issues = $script:checks | Where-Object { $_.Status -ne "green" }
            $body = ($issues | ForEach-Object { "$($_.Name): $($_.Message)" }) -join "`n"
            if ($body.Length -gt 200) { $body = $body.Substring(0, 197) + "..." }
            Show-ToastNotification $title $body
        } catch {}
    }

    if ($hasRed) { exit 2 } elseif ($hasYellow) { exit 1 } else { exit 0 }
}

function Show-ToastNotification($title, $body) {
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $textNodes = $template.GetElementsByTagName("text")
        $textNodes.Item(0).AppendChild($template.CreateTextNode($title)) | Out-Null
        $textNodes.Item(1).AppendChild($template.CreateTextNode($body)) | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("ClaudeLifeboat")
        $notifier.Show($toast)
    } catch {}
}
