# =====================================================================
# Claude-AutoBackup.ps1
# Two-tier backup strategy:
#   PRIMARY (always-on, e.g. D:):  hourly full mirror + 3 daily snapshots
#   ARCHIVE (external, e.g. F:):   full versioning - latest + 7 daily + 4 weekly
#
# This script is run by Task Scheduler. Don't run directly.
#
# Behavior on each run:
#   1. Back up Claude data + extras to PRIMARY (D:) - always works
#   2. If ARCHIVE drive (F:) is plugged in, sync PRIMARY -> ARCHIVE
#      and create daily/weekly snapshots there
#   3. If F: is missing, log it and continue. No errors, no popups.
#
# Config file: $env:LOCALAPPDATA\ClaudeAutoBackup\config.json
# =====================================================================

$ErrorActionPreference = "Continue"
$configPath = "$env:LOCALAPPDATA\ClaudeAutoBackup\config.json"

if (-not (Test-Path $configPath)) {
    Write-Host "Config not found. Run Setup-AutoBackup.ps1 first."
    exit 1
}

$config = Get-Content $configPath -Raw | ConvertFrom-Json

# Both roots come from config. PrimaryRoot is required; ArchiveRoot is optional.
$primaryRoot = $config.PrimaryRoot
$archiveRoot = $config.ArchiveRoot

if (-not $primaryRoot) {
    Write-Host "ERROR: PrimaryRoot not set in config."
    exit 1
}

# =====================================================================
# Local logging (always works, lives in LocalAppData)
# =====================================================================
$localLogDir = "$env:LOCALAPPDATA\ClaudeAutoBackup\logs"
New-Item -ItemType Directory -Path $localLogDir -Force | Out-Null
$logFile = Join-Path $localLogDir "backup-$(Get-Date -Format 'yyyy-MM-dd').log"
function Log($msg) {
    $line = "$(Get-Date -Format 'HH:mm:ss')  $msg"
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
}

Log "===== Backup started ====="

# =====================================================================
# Check PRIMARY drive (D:) is reachable. If not, we can't do anything.
# =====================================================================
$primaryDriveLetter = ($primaryRoot -split ':')[0] + ':'
if (-not (Test-Path $primaryDriveLetter)) {
    Log "ERROR: Primary drive $primaryDriveLetter not available. Aborting."
    exit 1
}

# Make sure the primary root path exists
New-Item -ItemType Directory -Path $primaryRoot -Force | Out-Null

# Check free space on primary - need at least 2 GB to be safe
$primaryDrive = Get-PSDrive -Name $primaryDriveLetter.TrimEnd(':') -ErrorAction SilentlyContinue
if ($primaryDrive -and ($primaryDrive.Free / 1GB) -lt 2) {
    Log "WARNING: Primary drive has less than 2 GB free. Backup may fail."
}

# =====================================================================
# Define what to back up
# =====================================================================
$pathsToBackup = @{}

# Claude Desktop (MSIX package data)
$claudePackage = Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -Filter "Claude_*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($claudePackage) {
    $pathsToBackup["ClaudeDesktop"] = $claudePackage.FullName
}

# Claude logs and machine-wide data
if (Test-Path "C:\ProgramData\Claude") {
    $pathsToBackup["Claude-ProgramData"] = "C:\ProgramData\Claude"
}

# Claude Code CLI configs
$ccPaths = @(
    "$env:USERPROFILE\.claude",
    "$env:APPDATA\claude-code",
    "$env:USERPROFILE\.config\claude"
)
foreach ($p in $ccPaths) {
    if (Test-Path $p) {
        $name = "ClaudeCode-" + (Split-Path $p -Leaf)
        $pathsToBackup[$name] = $p
    }
}

# Extra paths
if ($config.ExtraPaths) {
    foreach ($p in $config.ExtraPaths) {
        if (Test-Path $p) {
            $name = "Extra-" + (Split-Path $p -Leaf)
            $pathsToBackup[$name] = $p
        }
    }
}

# =====================================================================
# STEP 1: Mirror to PRIMARY (latest/)
# This is the fast path - internal drive, runs every backup.
# =====================================================================
Log "--- Mirroring to PRIMARY: $primaryRoot ---"

$primaryLatest = Join-Path $primaryRoot "latest"
New-Item -ItemType Directory -Path $primaryLatest -Force | Out-Null

foreach ($name in $pathsToBackup.Keys) {
    $src = $pathsToBackup[$name]
    $dst = Join-Path $primaryLatest $name

    $rcArgs = @(
        $src, $dst,
        '/MIR', '/R:1', '/W:1', '/MT:4', '/XJ',
        '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS'
    )
    & robocopy @rcArgs 2>&1 | Out-Null
    $rc = $LASTEXITCODE
    if ($rc -ge 8) {
        Log "  ERROR: $name failed (robocopy exit $rc)"
    } else {
        Log "  OK: $name (exit $rc)"
    }
}

# =====================================================================
# STEP 2: PRIMARY versioning (small - only 3 daily snapshots)
# Local SSD is space-constrained, so keep retention tight here.
# Real long-term versioning lives on ARCHIVE (external) drive.
# =====================================================================
$today = Get-Date -Format "yyyy-MM-dd"
$primaryDaily = Join-Path $primaryRoot "daily\$today"
$primaryDailyParent = Join-Path $primaryRoot "daily"

if (-not (Test-Path $primaryDaily)) {
    Log "Creating PRIMARY daily snapshot for $today"
    New-Item -ItemType Directory -Path $primaryDaily -Force | Out-Null
    robocopy $primaryLatest $primaryDaily /E /R:1 /W:1 /MT:4 /XJ /NFL /NDL /NJH /NJS /NC /NS | Out-Null
}

# Prune: keep only last 3 dailies on PRIMARY
if (Test-Path $primaryDailyParent) {
    $old = Get-ChildItem $primaryDailyParent -Directory | Sort-Object Name -Descending | Select-Object -Skip 3
    foreach ($d in $old) {
        Log "Pruning PRIMARY daily: $($d.Name)"
        Remove-Item $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# =====================================================================
# STEP 3: Try ARCHIVE drive (e.g. F:)
# If it's plugged in, sync everything over and do full versioning.
# If it's not, skip silently. PRIMARY has us covered.
# =====================================================================
$archiveAvailable = $false
if ($archiveRoot) {
    $archiveDriveLetter = ($archiveRoot -split ':')[0] + ':'
    if (Test-Path $archiveDriveLetter) {
        $archiveAvailable = $true
        Log "--- ARCHIVE drive $archiveDriveLetter is available ---"
    } else {
        Log "ARCHIVE drive $archiveDriveLetter not connected. Skipping archive sync."
    }
}

if ($archiveAvailable) {
    New-Item -ItemType Directory -Path $archiveRoot -Force | Out-Null
    $archiveLatest = Join-Path $archiveRoot "latest"
    $archiveLogDir = Join-Path $archiveRoot "logs"
    New-Item -ItemType Directory -Path $archiveLatest -Force | Out-Null
    New-Item -ItemType Directory -Path $archiveLogDir -Force | Out-Null

    # Detect if this is a "catch-up" sync (archive was unplugged for a while)
    $lastSyncFile = Join-Path $archiveRoot ".last_archive_sync"
    $isCatchUp = $false
    if (Test-Path $lastSyncFile) {
        $lastSync = Get-Content $lastSyncFile -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($lastSync) {
            try {
                $lastSyncTime = [DateTime]::Parse($lastSync)
                $hoursSince = ((Get-Date) - $lastSyncTime).TotalHours
                if ($hoursSince -gt 6) {
                    $isCatchUp = $true
                    Log "Catch-up sync detected - archive was last synced $([math]::Round($hoursSince,1)) hours ago"
                }
            } catch {}
        }
    } else {
        $isCatchUp = $true
        Log "First sync to this ARCHIVE - doing initial copy"
    }

    # Sync PRIMARY latest -> ARCHIVE latest
    Log "Syncing PRIMARY/latest -> ARCHIVE/latest"
    $syncArgs = @(
        $primaryLatest, $archiveLatest,
        '/MIR', '/R:1', '/W:1', '/MT:8', '/XJ',
        '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS'
    )
    & robocopy @syncArgs 2>&1 | Out-Null
    $rc = $LASTEXITCODE
    if ($rc -ge 8) {
        Log "  ERROR: archive sync failed (robocopy exit $rc)"
    } else {
        Log "  OK: archive synced (exit $rc)"
    }

    # ARCHIVE versioning - the real long-term retention lives here
    $archiveDaily = Join-Path $archiveRoot "daily\$today"
    $archiveWeekly = Join-Path $archiveRoot "weekly\$today"

    # Daily snapshot on archive
    if (-not (Test-Path $archiveDaily)) {
        Log "Creating ARCHIVE daily snapshot for $today"
        New-Item -ItemType Directory -Path $archiveDaily -Force | Out-Null
        robocopy $archiveLatest $archiveDaily /E /R:1 /W:1 /MT:4 /XJ /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    }

    # Weekly snapshot on archive (Sundays)
    if ((Get-Date).DayOfWeek -eq 'Sunday' -and -not (Test-Path $archiveWeekly)) {
        Log "Creating ARCHIVE weekly snapshot for $today (Sunday)"
        New-Item -ItemType Directory -Path $archiveWeekly -Force | Out-Null
        robocopy $archiveLatest $archiveWeekly /E /R:1 /W:1 /MT:4 /XJ /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    }

    # If catch-up: also bring across any missing daily snapshots from PRIMARY
    if ($isCatchUp) {
        Log "Catch-up: copying any missing daily snapshots from PRIMARY"
        $primaryDailies = Get-ChildItem $primaryDailyParent -Directory -ErrorAction SilentlyContinue
        foreach ($pd in $primaryDailies) {
            $matchingArchive = Join-Path $archiveRoot "daily\$($pd.Name)"
            if (-not (Test-Path $matchingArchive)) {
                Log "  Copying $($pd.Name) from PRIMARY"
                New-Item -ItemType Directory -Path $matchingArchive -Force | Out-Null
                robocopy $pd.FullName $matchingArchive /E /R:1 /W:1 /MT:4 /XJ /NFL /NDL /NJH /NJS /NC /NS | Out-Null
            }
        }
    }

    # ARCHIVE retention: 7 daily + 4 weekly
    $archiveDailyParent = Join-Path $archiveRoot "daily"
    if (Test-Path $archiveDailyParent) {
        $old = Get-ChildItem $archiveDailyParent -Directory | Sort-Object Name -Descending | Select-Object -Skip 7
        foreach ($d in $old) {
            Log "Pruning ARCHIVE daily: $($d.Name)"
            Remove-Item $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $archiveWeeklyParent = Join-Path $archiveRoot "weekly"
    if (Test-Path $archiveWeeklyParent) {
        $old = Get-ChildItem $archiveWeeklyParent -Directory | Sort-Object Name -Descending | Select-Object -Skip 4
        foreach ($w in $old) {
            Log "Pruning ARCHIVE weekly: $($w.Name)"
            Remove-Item $w.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Update the last-sync marker
    (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") | Set-Content -Path $lastSyncFile

    # Also drop a copy of today's log on archive
    Copy-Item $logFile -Destination $archiveLogDir -Force -ErrorAction SilentlyContinue
}

# =====================================================================
# Status file (written to both locations when archive is online)
# =====================================================================
$status = @{
    LastRun = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    PrimaryRoot = $primaryRoot
    ArchiveRoot = $archiveRoot
    ArchiveSynced = $archiveAvailable
    BackedUp = @($pathsToBackup.Keys)
    PrimaryDailyCount = (Get-ChildItem $primaryDailyParent -Directory -ErrorAction SilentlyContinue).Count
    ArchiveDailyCount = if ($archiveAvailable) { (Get-ChildItem (Join-Path $archiveRoot "daily") -Directory -ErrorAction SilentlyContinue).Count } else { -1 }
    ArchiveWeeklyCount = if ($archiveAvailable) { (Get-ChildItem (Join-Path $archiveRoot "weekly") -Directory -ErrorAction SilentlyContinue).Count } else { -1 }
}
$statusJson = $status | ConvertTo-Json -Depth 5
$statusJson | Set-Content -Path (Join-Path $primaryRoot "status.json")
if ($archiveAvailable) {
    $statusJson | Set-Content -Path (Join-Path $archiveRoot "status.json")
}

Log "===== Backup complete ====="
if (-not $archiveAvailable -and $archiveRoot) {
    Log "Note: archive drive was offline. Plug in $((($archiveRoot -split ':')[0]) + ':') to sync."
}
