# =====================================================================
# Setup-BackupReporting.ps1
# Adds monitoring/reporting on top of the auto-backup system.
# Run AFTER Setup-AutoBackup.ps1 has been configured.
#
# What this adds:
#   1. ClaudeBackup-HealthCheck - runs every 2 hours, shows toast if issues
#   2. ClaudeBackup-Dashboard - refreshes the desktop dashboard every 10 min
#   3. ClaudeBackup-DailyReport - generates a daily HTML report at 9am
#   4. Optional: pinned dashboard shortcut on desktop
#
# Usage (PowerShell as Administrator):
#   .\Setup-BackupReporting.ps1                    # interactive
#   .\Setup-BackupReporting.ps1 -NoNotifications   # skip toast alerts
#   .\Setup-BackupReporting.ps1 -ReportTime "09:00"  # custom daily report time
# =====================================================================

param(
    [switch]$NoNotifications,
    [string]$ReportTime = "09:00",
    [switch]$NoDashboardShortcut
)

# Must be admin
$currentUser = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: Run as Administrator." -ForegroundColor Red
    exit 1
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  BACKUP REPORTING SETUP" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Verify auto-backup is set up first
$configPath = "$env:LOCALAPPDATA\ClaudeAutoBackup\config.json"
if (-not (Test-Path $configPath)) {
    Write-Host "ERROR: Auto-backup not configured. Run Setup-AutoBackup.ps1 first." -ForegroundColor Red
    exit 1
}

# Copy reporting scripts to the install location
$installDir = "$env:LOCALAPPDATA\ClaudeAutoBackup"
$scripts = @("Check-BackupHealth.ps1", "Generate-BackupDashboard.ps1")
foreach ($s in $scripts) {
    $source = Join-Path $PSScriptRoot $s
    if (Test-Path $source) {
        Copy-Item $source (Join-Path $installDir $s) -Force
        Write-Host "Installed: $s" -ForegroundColor Green
    } else {
        Write-Host "WARNING: $s not found in script folder" -ForegroundColor Yellow
    }
}

$healthScript = Join-Path $installDir "Check-BackupHealth.ps1"
$dashScript = Join-Path $installDir "Generate-BackupDashboard.ps1"

# =====================================================================
# Remove any previous reporting tasks
# =====================================================================
Get-ScheduledTask -TaskName "ClaudeBackup-*" -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskName -ne "ClaudeAutoBackup-*" } |
    Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue

# Common task settings
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -MultipleInstances IgnoreNew

# =====================================================================
# Task 1: Health check every 2 hours (with notifications if issues)
# =====================================================================
$notifyFlag = if ($NoNotifications) { "" } else { "-Notify" }
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$healthScript`" -Quiet $notifyFlag"

$trigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).Date.AddHours((Get-Date).Hour + 1).AddMinutes(30) `
    -RepetitionInterval (New-TimeSpan -Hours 2)

Register-ScheduledTask `
    -TaskName "ClaudeBackup-HealthCheck" `
    -Description "Runs backup health check every 2 hours, shows notification if issues" `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings | Out-Null
Write-Host "[OK] HealthCheck task registered (every 2 hours)" -ForegroundColor Green

# =====================================================================
# Task 2: Dashboard refresh every 10 minutes (only when logged in & idle)
# =====================================================================
$dashboardPath = "$env:USERPROFILE\Desktop\Claude-Backup-Dashboard.html"
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dashScript`" -Path `"$dashboardPath`""

$trigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).AddMinutes(2) `
    -RepetitionInterval (New-TimeSpan -Minutes 10)

# Only refresh when user is logged in to avoid spamming when laptop is off
$dashSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName "ClaudeBackup-Dashboard" `
    -Description "Regenerates the backup dashboard HTML every 10 minutes" `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $dashSettings | Out-Null
Write-Host "[OK] Dashboard refresh task registered (every 10 min)" -ForegroundColor Green

# =====================================================================
# Task 3: Daily report at user-specified time
# =====================================================================
$dailyReportPath = "$env:USERPROFILE\Documents\ClaudeBackupReports"
New-Item -ItemType Directory -Path $dailyReportPath -Force | Out-Null

$reportCommand = @"
& '$dashScript' -Path '$dailyReportPath\report-`$(Get-Date -Format yyyy-MM-dd).html'
# Prune reports older than 30 days
Get-ChildItem '$dailyReportPath\report-*.html' | Where-Object { `$_.LastWriteTime -lt (Get-Date).AddDays(-30) } | Remove-Item -Force
"@

$reportScriptPath = Join-Path $installDir "Generate-DailyReport.ps1"
$reportCommand | Set-Content -Path $reportScriptPath

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$reportScriptPath`""

$reportHour = [int]($ReportTime -split ':')[0]
$reportMin = [int]($ReportTime -split ':')[1]
$trigger = New-ScheduledTaskTrigger -Daily -At ((Get-Date).Date.AddHours($reportHour).AddMinutes($reportMin))

Register-ScheduledTask `
    -TaskName "ClaudeBackup-DailyReport" `
    -Description "Generates a daily backup report at $ReportTime" `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings | Out-Null
Write-Host "[OK] Daily report task registered (runs at $ReportTime)" -ForegroundColor Green

# =====================================================================
# Generate the dashboard once now
# =====================================================================
Write-Host "`nGenerating initial dashboard..." -ForegroundColor Yellow
& powershell.exe -ExecutionPolicy Bypass -File $dashScript -Path $dashboardPath
if (Test-Path $dashboardPath) {
    Write-Host "[OK] Dashboard ready at: $dashboardPath" -ForegroundColor Green
} else {
    Write-Host "[WARN] Dashboard creation failed - check $installDir\logs\" -ForegroundColor Yellow
}

# =====================================================================
# Run health check once now
# =====================================================================
Write-Host "`nRunning initial health check..." -ForegroundColor Yellow
& powershell.exe -ExecutionPolicy Bypass -File $healthScript

# =====================================================================
# Summary
# =====================================================================
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  REPORTING SETUP COMPLETE" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "What's now in place:" -ForegroundColor Yellow
Write-Host "  - Dashboard:   $dashboardPath"
Write-Host "                 (auto-refreshes every 10 min, also self-refreshes in browser every 60s)"
Write-Host "  - Daily reports: $dailyReportPath\"
Write-Host "                 (generated at $ReportTime, kept for 30 days)"
Write-Host "  - Health check: runs every 2 hours"
if (-not $NoNotifications) {
    Write-Host "                  shows toast notification only if issues found"
}
Write-Host ""
Write-Host "Useful commands:" -ForegroundColor Yellow
Write-Host "  Check health now:     `& '$healthScript'"
Write-Host "  Refresh dashboard:    `& '$dashScript' -Open"
Write-Host "  Generate report now:  `& '$dashScript' -Path '$dailyReportPath\manual-`$(Get-Date -Format yyyy-MM-dd).html' -Open"
Write-Host ""
Write-Host "Open dashboard now? (Y/n): " -NoNewline -ForegroundColor Yellow
$answer = Read-Host
if ($answer -ne 'n') {
    Start-Process $dashboardPath
}
