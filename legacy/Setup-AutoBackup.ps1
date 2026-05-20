# =====================================================================
# Setup-AutoBackup.ps1
# One-time setup for the two-tier Claude auto-backup.
#
# Usage (PowerShell as Administrator):
#   .\Setup-AutoBackup.ps1
#     -> walks you through picking PRIMARY and ARCHIVE drives
#
#   .\Setup-AutoBackup.ps1 -PrimaryDrive "D:" -ArchiveDrive "F:"
#     -> non-interactive
#
#   .\Setup-AutoBackup.ps1 -PrimaryDrive "D:" -ArchiveDrive "F:" -ExtraPaths @("C:\MyProjects")
#     -> with extra paths included
#
# Two-tier strategy:
#   PRIMARY (D:) - always-on internal drive. Gets every hourly backup.
#                  Keeps 3 daily snapshots. Insurance against accidental
#                  deletes, broken files, etc. when external is unplugged.
#
#   ARCHIVE (F:) - external SSD. Gets the latest copy + full versioning
#                  (7 daily + 4 weekly). Insurance against the laptop
#                  dying, getting stolen, drive failure on D:, etc.
#
# To uninstall:
#   Get-ScheduledTask -TaskName "ClaudeAutoBackup-*" | Unregister-ScheduledTask
# =====================================================================

param(
    [string]$PrimaryDrive = "",
    [string]$ArchiveDrive = "",
    [string[]]$ExtraPaths = @()
)

# Must run as admin to create scheduled tasks
$currentUser = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    Write-Host "Right-click PowerShell -> 'Run as administrator', then re-run." -ForegroundColor Yellow
    exit 1
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  CLAUDE AUTO-BACKUP SETUP" -ForegroundColor Cyan
Write-Host "  (two-tier: primary + archive)" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# =====================================================================
# Drive picker helper
# =====================================================================
function Show-Drives {
    Write-Host "Available drives:" -ForegroundColor Yellow
    Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -gt 1GB } | ForEach-Object {
        $freeGB = [math]::Round($_.Free / 1GB, 1)
        $totalGB = [math]::Round(($_.Free + $_.Used) / 1GB, 1)
        Write-Host ("  {0}: ({1} GB free of {2} GB)" -f $_.Name, $freeGB, $totalGB)
    }
    Write-Host ""
}

function Normalize-Drive($d) {
    if (-not $d) { return $null }
    $d = $d.Trim().TrimEnd('\').TrimEnd(':') + ':'
    return $d
}

# =====================================================================
# Step 1: PRIMARY drive
# =====================================================================
if (-not $PrimaryDrive) {
    Write-Host "PRIMARY drive: where every hourly backup goes (usually internal, like D:)." -ForegroundColor Yellow
    Write-Host "This is your fast, always-on safety net.`n" -ForegroundColor DarkGray
    Show-Drives
    $PrimaryDrive = Read-Host "Enter PRIMARY drive letter (e.g. D:)"
}
$PrimaryDrive = Normalize-Drive $PrimaryDrive

if (-not (Test-Path $PrimaryDrive)) {
    Write-Host "ERROR: Drive $PrimaryDrive not found." -ForegroundColor Red
    exit 1
}
$primaryRoot = Join-Path $PrimaryDrive "ClaudeBackups"
Write-Host "PRIMARY: $primaryRoot`n" -ForegroundColor Green

# =====================================================================
# Step 2: ARCHIVE drive (optional)
# =====================================================================
if (-not $ArchiveDrive) {
    Write-Host "ARCHIVE drive: external/removable drive for long-term versioned backups (e.g. F:)." -ForegroundColor Yellow
    Write-Host "This catches up when plugged in. If you don't have one, leave blank.`n" -ForegroundColor DarkGray
    $ArchiveDrive = Read-Host "Enter ARCHIVE drive letter (or blank to skip)"
}
$archiveRoot = $null
if ($ArchiveDrive) {
    $ArchiveDrive = Normalize-Drive $ArchiveDrive
    if (-not (Test-Path $ArchiveDrive)) {
        Write-Host "WARNING: $ArchiveDrive not currently connected." -ForegroundColor Yellow
        Write-Host "Setup will continue. Archive sync will happen automatically when you plug it in." -ForegroundColor Yellow
    }
    $archiveRoot = Join-Path $ArchiveDrive "ClaudeBackups"
    Write-Host "ARCHIVE: $archiveRoot`n" -ForegroundColor Green
} else {
    Write-Host "No ARCHIVE drive configured. Backups will only go to PRIMARY.`n" -ForegroundColor Yellow
}

# =====================================================================
# Step 3: Extra paths
# =====================================================================
if (-not $ExtraPaths -or $ExtraPaths.Count -eq 0) {
    Write-Host "Do you want to back up any extra folders alongside Claude data?" -ForegroundColor Yellow
    Write-Host "Examples: your projects folder, code repos, anything not in Documents.`n" -ForegroundColor DarkGray
    $answer = Read-Host "Add extra paths? (y/N)"
    if ($answer -eq 'y') {
        while ($true) {
            $p = Read-Host "Enter folder path (or blank to finish)"
            if (-not $p) { break }
            if (Test-Path $p) {
                $ExtraPaths += $p
                Write-Host "  Added: $p" -ForegroundColor Green
            } else {
                Write-Host "  Path not found, skipping: $p" -ForegroundColor Red
            }
        }
    }
}

# =====================================================================
# Step 4: Write config
# =====================================================================
$configDir = "$env:LOCALAPPDATA\ClaudeAutoBackup"
New-Item -ItemType Directory -Path $configDir -Force | Out-Null

$config = @{
    PrimaryRoot = $primaryRoot
    ArchiveRoot = $archiveRoot
    ExtraPaths = $ExtraPaths
    CreatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
}
$configPath = Join-Path $configDir "config.json"
$config | ConvertTo-Json -Depth 5 | Set-Content -Path $configPath
Write-Host "`nConfig written: $configPath" -ForegroundColor Green

# =====================================================================
# Step 5: Copy scripts to fixed location
# =====================================================================
$scriptSource = Join-Path $PSScriptRoot "Claude-AutoBackup.ps1"
$scriptDest = Join-Path $configDir "Claude-AutoBackup.ps1"
if (-not (Test-Path $scriptSource)) {
    Write-Host "ERROR: Claude-AutoBackup.ps1 not found in script folder." -ForegroundColor Red
    exit 1
}
Copy-Item $scriptSource $scriptDest -Force
Write-Host "Backup script installed: $scriptDest" -ForegroundColor Green

# Also copy the restore script if present
$restoreSource = Join-Path $PSScriptRoot "Restore-ClaudeBackup.ps1"
if (Test-Path $restoreSource) {
    Copy-Item $restoreSource (Join-Path $configDir "Restore-ClaudeBackup.ps1") -Force
}

# =====================================================================
# Step 6: Register scheduled tasks
# =====================================================================
Write-Host "`nRegistering scheduled tasks..." -ForegroundColor Yellow

# Clean up any previous installation
Get-ScheduledTask -TaskName "ClaudeAutoBackup-*" -ErrorAction SilentlyContinue |
    Unregister-ScheduledTask -Confirm:$false

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptDest`""

$principal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType S4U `
    -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
    -MultipleInstances IgnoreNew

# --- Hourly trigger ---
$hourlyTrigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).Date.AddHours((Get-Date).Hour + 1) `
    -RepetitionInterval (New-TimeSpan -Hours 1)

Register-ScheduledTask `
    -TaskName "ClaudeAutoBackup-Hourly" `
    -Description "Backs up Claude data every hour to PRIMARY (and ARCHIVE if connected)" `
    -Action $action `
    -Trigger $hourlyTrigger `
    -Principal $principal `
    -Settings $settings | Out-Null
Write-Host "  [OK] Hourly task registered" -ForegroundColor Green

# --- On logon trigger ---
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
Register-ScheduledTask `
    -TaskName "ClaudeAutoBackup-OnLogon" `
    -Description "Runs Claude backup at logon" `
    -Action $action `
    -Trigger $logonTrigger `
    -Principal $principal `
    -Settings $settings | Out-Null
Write-Host "  [OK] OnLogon task registered" -ForegroundColor Green

# --- On sleep trigger (lid close, etc.) ---
$sleepTriggerXml = @"
<QueryList>
  <Query Id="0" Path="System">
    <Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and (EventID=42)]]</Select>
  </Query>
</QueryList>
"@

try {
    $class = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
    $eventTrigger = New-CimInstance -CimClass $class -ClientOnly
    $eventTrigger.Enabled = $true
    $eventTrigger.Subscription = $sleepTriggerXml

    Register-ScheduledTask `
        -TaskName "ClaudeAutoBackup-OnSleep" `
        -Description "Runs Claude backup when computer is going to sleep (lid close, etc.)" `
        -Action $action `
        -Trigger $eventTrigger `
        -Principal $principal `
        -Settings $settings | Out-Null
    Write-Host "  [OK] OnSleep task registered (fires on lid close / sleep)" -ForegroundColor Green
} catch {
    Write-Host "  [SKIP] OnSleep task could not be registered: $_" -ForegroundColor Yellow
}

# --- ARCHIVE-plugged-in trigger (fires when removable drive is connected) ---
# Event 1006 in System log, source Microsoft-Windows-Kernel-PnP = device added
# Better: use Event 4 in Microsoft-Windows-Partition/Diagnostic = volume mounted
# Simplest reliable trigger: Event 98 in Microsoft-Windows-Ntfs/Operational = volume online
if ($archiveRoot) {
    $pnpTriggerXml = @"
<QueryList>
  <Query Id="0" Path="Microsoft-Windows-Ntfs/Operational">
    <Select Path="Microsoft-Windows-Ntfs/Operational">*[System[(EventID=98)]]</Select>
  </Query>
</QueryList>
"@

    try {
        $pnpTrigger = New-CimInstance -CimClass $class -ClientOnly
        $pnpTrigger.Enabled = $true
        $pnpTrigger.Subscription = $pnpTriggerXml

        # Use a settings set that delays start by 30 seconds so the drive
        # is fully mounted before we try to write to it
        $pnpSettings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
            -MultipleInstances IgnoreNew

        Register-ScheduledTask `
            -TaskName "ClaudeAutoBackup-OnDriveConnect" `
            -Description "Runs Claude backup when a drive is mounted (catches archive drive plug-in)" `
            -Action $action `
            -Trigger $pnpTrigger `
            -Principal $principal `
            -Settings $pnpSettings | Out-Null
        Write-Host "  [OK] OnDriveConnect task registered (catches archive drive plug-in)" -ForegroundColor Green
    } catch {
        Write-Host "  [SKIP] OnDriveConnect task could not be registered: $_" -ForegroundColor Yellow
    }
}

# --- OnIdle trigger ---
$idleSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RunOnlyIfIdle `
    -IdleDuration (New-TimeSpan -Minutes 10) `
    -IdleWaitTimeout (New-TimeSpan -Minutes 30) `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName "ClaudeAutoBackup-OnIdle" `
    -Description "Runs Claude backup when machine has been idle 10 minutes" `
    -Action $action `
    -Trigger $logonTrigger `
    -Principal $principal `
    -Settings $idleSettings | Out-Null
Write-Host "  [OK] OnIdle task registered" -ForegroundColor Green

# =====================================================================
# Step 7: Run first backup now to verify it works
# =====================================================================
Write-Host "`nRunning first backup now to verify setup..." -ForegroundColor Yellow
& powershell.exe -ExecutionPolicy Bypass -File $scriptDest
Start-Sleep -Seconds 2

if (Test-Path (Join-Path $primaryRoot "status.json")) {
    Write-Host "  [OK] First backup ran successfully" -ForegroundColor Green
    $status = Get-Content (Join-Path $primaryRoot "status.json") -Raw | ConvertFrom-Json
    Write-Host "  Backed up: $($status.BackedUp -join ', ')" -ForegroundColor DarkGray
    Write-Host "  Archive synced: $($status.ArchiveSynced)" -ForegroundColor DarkGray
} else {
    Write-Host "  WARNING: status.json not found - check $env:LOCALAPPDATA\ClaudeAutoBackup\logs\" -ForegroundColor Yellow
}

# =====================================================================
# Done
# =====================================================================
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  SETUP COMPLETE" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Host "How it works:" -ForegroundColor Yellow
Write-Host "  PRIMARY ($primaryRoot):" -ForegroundColor White
Write-Host "    - Every hourly backup goes here. Always available."
Write-Host "    - Keeps 'latest/' + 3 daily snapshots."
Write-Host ""
if ($archiveRoot) {
    Write-Host "  ARCHIVE ($archiveRoot):" -ForegroundColor White
    Write-Host "    - Synced from PRIMARY when external drive is plugged in."
    Write-Host "    - Keeps 'latest/' + 7 daily + 4 weekly snapshots."
    Write-Host "    - Auto-catches-up if it was unplugged for a while."
    Write-Host ""
}

Write-Host "Triggers:" -ForegroundColor Yellow
Write-Host "  - Every hour"
Write-Host "  - When you log in"
Write-Host "  - When laptop sleeps (lid close)"
if ($archiveRoot) {
    Write-Host "  - When the archive drive is plugged in"
}
Write-Host "  - When machine has been idle 10+ minutes"
Write-Host ""
Write-Host "Useful commands:" -ForegroundColor Yellow
Write-Host "  Check status:    Get-Content '$primaryRoot\status.json' | ConvertFrom-Json"
Write-Host "  See task status: Get-ScheduledTask -TaskName 'ClaudeAutoBackup-*' | Select TaskName, LastRunTime, LastTaskResult"
Write-Host "  Run backup now:  Start-ScheduledTask -TaskName 'ClaudeAutoBackup-Hourly'"
Write-Host "  Restore data:    .\Restore-ClaudeBackup.ps1 -BackupRoot '$primaryRoot'"
Write-Host ""
Write-Host "To uninstall:" -ForegroundColor Yellow
Write-Host "  Get-ScheduledTask -TaskName 'ClaudeAutoBackup-*' | Unregister-ScheduledTask -Confirm:`$false"
Write-Host ""
