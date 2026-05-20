# =====================================================================
# Restore-ClaudeBackup.ps1
# Restores from the auto-backup system (two-tier: PRIMARY + ARCHIVE).
#
# Usage (PowerShell as Administrator):
#
#   Interactive (recommended) - reads both locations automatically:
#     .\Restore-ClaudeBackup.ps1
#
#   Specify a backup root manually:
#     .\Restore-ClaudeBackup.ps1 -BackupRoot "F:\ClaudeBackups"
#
#   Restore latest hourly state (from PRIMARY, fastest):
#     .\Restore-ClaudeBackup.ps1 -From latest
#
#   Restore from a specific daily snapshot (auto-uses ARCHIVE if older than 3 days):
#     .\Restore-ClaudeBackup.ps1 -From daily -Date "2026-05-18"
#
#   Restore only Claude Desktop:
#     .\Restore-ClaudeBackup.ps1 -From latest -Only ClaudeDesktop
#
#   Preview restore (recommended first time) - puts files in temp folder:
#     .\Restore-ClaudeBackup.ps1 -From latest -PreviewTo "C:\restore-test"
#
# =====================================================================

param(
    [string]$BackupRoot = "",
    [ValidateSet("latest","daily","weekly")]
    [string]$From = "",
    [string]$Date = "",
    [string]$Only = "",
    [string]$PreviewTo = "",
    [switch]$Force
)

$ErrorActionPreference = "Continue"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  CLAUDE BACKUP RESTORE" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# =====================================================================
# Find available backup locations
# =====================================================================
$locations = @()

# If user gave a specific root, use only that
if ($BackupRoot) {
    if (Test-Path $BackupRoot) {
        $locations += @{ Type = "Manual"; Root = $BackupRoot }
    } else {
        Write-Host "ERROR: $BackupRoot not found." -ForegroundColor Red
        exit 1
    }
} else {
    # Read config to find PRIMARY and ARCHIVE
    $configPath = "$env:LOCALAPPDATA\ClaudeAutoBackup\config.json"
    if (Test-Path $configPath) {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        if ($config.PrimaryRoot -and (Test-Path $config.PrimaryRoot)) {
            $locations += @{ Type = "PRIMARY"; Root = $config.PrimaryRoot }
        }
        if ($config.ArchiveRoot -and (Test-Path $config.ArchiveRoot)) {
            $locations += @{ Type = "ARCHIVE"; Root = $config.ArchiveRoot }
        }
    }

    if ($locations.Count -eq 0) {
        Write-Host "ERROR: No backup locations found." -ForegroundColor Red
        Write-Host "Run with -BackupRoot to specify manually, or run Setup-AutoBackup.ps1 first." -ForegroundColor Yellow
        exit 1
    }
}

Write-Host "Available backup locations:" -ForegroundColor Yellow
foreach ($loc in $locations) {
    $exists = if ($loc.Root) { (Test-Path $loc.Root) } else { $false }
    $marker = if ($exists) { "[OK]" } else { "[MISSING]" }
    Write-Host "  $marker $($loc.Type): $($loc.Root)" -ForegroundColor $(if($exists){"Green"}else{"Yellow"})
}
Write-Host ""

# =====================================================================
# Build a unified view of all available snapshots from all locations
# =====================================================================
function Get-AllSnapshots($locations) {
    $snapshots = @()

    foreach ($loc in $locations) {
        $root = $loc.Root
        if (-not (Test-Path $root)) { continue }

        # Latest
        $latestPath = Join-Path $root "latest"
        if (Test-Path $latestPath) {
            $snapshots += @{
                Type = $loc.Type
                Kind = "latest"
                Date = ""
                Path = $latestPath
                Time = (Get-Item $latestPath).LastWriteTime
            }
        }

        # Dailies
        $dailyParent = Join-Path $root "daily"
        if (Test-Path $dailyParent) {
            Get-ChildItem $dailyParent -Directory | ForEach-Object {
                $snapshots += @{
                    Type = $loc.Type
                    Kind = "daily"
                    Date = $_.Name
                    Path = $_.FullName
                    Time = $_.LastWriteTime
                }
            }
        }

        # Weeklies (archive only)
        $weeklyParent = Join-Path $root "weekly"
        if (Test-Path $weeklyParent) {
            Get-ChildItem $weeklyParent -Directory | ForEach-Object {
                $snapshots += @{
                    Type = $loc.Type
                    Kind = "weekly"
                    Date = $_.Name
                    Path = $_.FullName
                    Time = $_.LastWriteTime
                }
            }
        }
    }

    return $snapshots
}

$allSnapshots = Get-AllSnapshots $locations

# =====================================================================
# Pick which snapshot to restore from
# =====================================================================
$sourceDir = $null

if ($From) {
    # User specified -From: find the best matching snapshot
    if ($From -eq "latest") {
        # Prefer PRIMARY for latest (it's usually most recent)
        $candidate = $allSnapshots | Where-Object { $_.Kind -eq "latest" } |
                     Sort-Object @{Expression={ if($_.Type -eq "PRIMARY"){0}else{1} }}, Time -Descending |
                     Select-Object -First 1
    } else {
        if (-not $Date) {
            Write-Host "ERROR: -Date required when -From is '$From'" -ForegroundColor Red
            exit 1
        }
        # Prefer ARCHIVE for daily/weekly (it has more retention)
        $candidate = $allSnapshots | Where-Object { $_.Kind -eq $From -and $_.Date -eq $Date } |
                     Sort-Object @{Expression={ if($_.Type -eq "ARCHIVE"){0}else{1} }} |
                     Select-Object -First 1
    }

    if (-not $candidate) {
        Write-Host "ERROR: No matching snapshot found." -ForegroundColor Red
        exit 1
    }
    $sourceDir = $candidate.Path
    Write-Host "Selected: $($candidate.Type) / $($candidate.Kind) $($candidate.Date)" -ForegroundColor Green
    Write-Host "Path: $sourceDir" -ForegroundColor DarkGray
} else {
    # Interactive picker
    Write-Host "All available snapshots:" -ForegroundColor Yellow
    Write-Host ""

    $latestOnes = $allSnapshots | Where-Object { $_.Kind -eq "latest" } | Sort-Object Time -Descending
    if ($latestOnes) {
        Write-Host "  --- LATEST (most recent hourly) ---" -ForegroundColor Cyan
        $i = 1
        foreach ($s in $latestOnes) {
            Write-Host "    [L$i] $($s.Type) latest  ($($s.Time))" -ForegroundColor Green
            $i++
        }
        Write-Host ""
    }

    $dailies = $allSnapshots | Where-Object { $_.Kind -eq "daily" } | Sort-Object Date -Descending |
        Sort-Object Date -Unique  # dedupe across PRIMARY/ARCHIVE, prefer one
    if ($dailies) {
        Write-Host "  --- DAILY snapshots ---" -ForegroundColor Cyan
        $i = 1
        foreach ($s in $dailies) {
            $sources = ($allSnapshots | Where-Object { $_.Kind -eq "daily" -and $_.Date -eq $s.Date } |
                ForEach-Object { $_.Type }) -join ","
            Write-Host "    [D$i] $($s.Date)  (in: $sources)"
            $i++
        }
        Write-Host ""
    }

    $weeklies = $allSnapshots | Where-Object { $_.Kind -eq "weekly" } | Sort-Object Date -Descending |
        Sort-Object Date -Unique
    if ($weeklies) {
        Write-Host "  --- WEEKLY snapshots ---" -ForegroundColor Cyan
        $i = 1
        foreach ($s in $weeklies) {
            $sources = ($allSnapshots | Where-Object { $_.Kind -eq "weekly" -and $_.Date -eq $s.Date } |
                ForEach-Object { $_.Type }) -join ","
            Write-Host "    [W$i] $($s.Date)  (in: $sources)"
            $i++
        }
        Write-Host ""
    }

    $choice = Read-Host "Enter your choice (e.g. L1, D2, W1)"
    $choice = $choice.ToUpper().Trim()

    if ($choice -match '^L(\d+)$') {
        $idx = [int]$matches[1] - 1
        $sourceDir = $latestOnes[$idx].Path
    } elseif ($choice -match '^D(\d+)$') {
        $idx = [int]$matches[1] - 1
        $date = $dailies[$idx].Date
        # Prefer ARCHIVE
        $cand = $allSnapshots | Where-Object { $_.Kind -eq "daily" -and $_.Date -eq $date } |
                Sort-Object @{Expression={ if($_.Type -eq "ARCHIVE"){0}else{1} }} | Select-Object -First 1
        $sourceDir = $cand.Path
    } elseif ($choice -match '^W(\d+)$') {
        $idx = [int]$matches[1] - 1
        $date = $weeklies[$idx].Date
        $cand = $allSnapshots | Where-Object { $_.Kind -eq "weekly" -and $_.Date -eq $date } |
                Sort-Object @{Expression={ if($_.Type -eq "ARCHIVE"){0}else{1} }} | Select-Object -First 1
        $sourceDir = $cand.Path
    } else {
        Write-Host "ERROR: Unrecognized choice." -ForegroundColor Red
        exit 1
    }
}

if (-not $sourceDir -or -not (Test-Path $sourceDir)) {
    Write-Host "ERROR: Selected snapshot not found." -ForegroundColor Red
    exit 1
}

Write-Host "`nRestore source: $sourceDir" -ForegroundColor Green
$sourceTime = (Get-Item $sourceDir).LastWriteTime
Write-Host "Source was last updated: $sourceTime" -ForegroundColor DarkGray

# =====================================================================
# Pick what to restore
# =====================================================================
$availableFolders = Get-ChildItem $sourceDir -Directory | Select-Object -ExpandProperty Name

if ($Only) {
    if ($availableFolders -notcontains $Only) {
        Write-Host "ERROR: '$Only' not found. Available: $($availableFolders -join ', ')" -ForegroundColor Red
        exit 1
    }
    $foldersToRestore = @($Only)
} else {
    Write-Host "`nFolders in this snapshot:" -ForegroundColor Yellow
    $i = 1
    foreach ($f in $availableFolders) {
        Write-Host "  [$i] $f"
        $i++
    }
    Write-Host ""
    $choice = Read-Host "Restore which? Enter numbers (e.g. 1,3) or 'all'"
    if ($choice -eq 'all') {
        $foldersToRestore = $availableFolders
    } else {
        $indices = $choice -split ',' | ForEach-Object { [int]($_.Trim()) - 1 }
        $foldersToRestore = $indices | ForEach-Object { $availableFolders[$_] }
    }
}

# =====================================================================
# Map folder names back to real destinations
# =====================================================================
function Get-RestoreDestination($folderName) {
    switch -Wildcard ($folderName) {
        "ClaudeDesktop" {
            $existing = Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -Filter "Claude_*" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($existing) { return $existing.FullName }
            return "$env:LOCALAPPDATA\Packages\Claude_pzs8sxrjxfjjc"
        }
        "Claude-ProgramData" { return "C:\ProgramData\Claude" }
        "ClaudeCode-.claude" { return "$env:USERPROFILE\.claude" }
        "ClaudeCode-claude-code" { return "$env:APPDATA\claude-code" }
        "ClaudeCode-claude" { return "$env:USERPROFILE\.config\claude" }
        "Extra-*" {
            $configPath = "$env:LOCALAPPDATA\ClaudeAutoBackup\config.json"
            if (Test-Path $configPath) {
                $config = Get-Content $configPath -Raw | ConvertFrom-Json
                $baseName = $folderName -replace '^Extra-', ''
                foreach ($p in $config.ExtraPaths) {
                    if ((Split-Path $p -Leaf) -eq $baseName) { return $p }
                }
            }
            return $null
        }
        default { return $null }
    }
}

# =====================================================================
# Plan + confirm + restore
# =====================================================================
Write-Host "`nPlanned restore actions:" -ForegroundColor Yellow
$plan = @()
foreach ($folder in $foldersToRestore) {
    $src = Join-Path $sourceDir $folder
    if ($PreviewTo) {
        $dst = Join-Path $PreviewTo $folder
    } else {
        $dst = Get-RestoreDestination $folder
    }

    if (-not $dst) {
        Write-Host "  SKIP $folder - couldn't determine destination" -ForegroundColor Yellow
        continue
    }
    Write-Host "  $folder"
    Write-Host "    From: $src"
    Write-Host "    To:   $dst"
    $plan += @{Folder=$folder; Source=$src; Dest=$dst}
}

if ($plan.Count -eq 0) {
    Write-Host "`nNothing to restore." -ForegroundColor Yellow
    exit 0
}

if (-not $PreviewTo) {
    Write-Host "`n*** WARNING: This will OVERWRITE existing data at the destinations above. ***" -ForegroundColor Red
    Write-Host "If unsure, run with -PreviewTo to restore to a temp folder first." -ForegroundColor Yellow
}

if (-not $Force) {
    $confirm = Read-Host "`nProceed? (y/N)"
    if ($confirm -ne 'y') {
        Write-Host "Cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# Stop Claude services if restoring its data
$restoringClaude = $plan | Where-Object { $_.Folder -eq "ClaudeDesktop" -or $_.Folder -eq "Claude-ProgramData" }
if ($restoringClaude -and -not $PreviewTo) {
    Write-Host "`nStopping Claude Desktop and CoworkVMService before restore..." -ForegroundColor Yellow
    Get-Process -Name "Claude*" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Stop-Service CoworkVMService -ErrorAction SilentlyContinue -Force
    Start-Sleep -Seconds 3
}

# Do the restore
$succeeded = 0; $failed = 0
foreach ($item in $plan) {
    Write-Host "`nRestoring $($item.Folder)..." -ForegroundColor Cyan

    $destParent = Split-Path $item.Dest -Parent
    if (-not (Test-Path $destParent)) {
        New-Item -ItemType Directory -Path $destParent -Force | Out-Null
    }

    $rcArgs = @(
        $item.Source, $item.Dest,
        '/MIR', '/R:1', '/W:1', '/MT:4', '/XJ',
        '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS'
    )
    $rc = & robocopy @rcArgs 2>&1
    $rcExit = $LASTEXITCODE

    if ($rcExit -lt 8) {
        Write-Host "  [OK] Restored (robocopy exit: $rcExit)" -ForegroundColor Green
        $succeeded++
    } else {
        Write-Host "  [FAILED] robocopy exit: $rcExit" -ForegroundColor Red
        Write-Host $rc -ForegroundColor DarkRed
        $failed++
    }
}

# Restart services
if ($restoringClaude -and -not $PreviewTo) {
    Write-Host "`nRestarting CoworkVMService..." -ForegroundColor Yellow
    Start-Service CoworkVMService -ErrorAction SilentlyContinue
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  RESTORE SUMMARY" -ForegroundColor Cyan
Write-Host "  Succeeded: $succeeded" -ForegroundColor Green
Write-Host "  Failed:    $failed" -ForegroundColor $(if($failed -eq 0){"Green"}else{"Red"})
Write-Host "========================================`n" -ForegroundColor Cyan

if ($PreviewTo) {
    Write-Host "Files restored to PREVIEW location: $PreviewTo" -ForegroundColor Yellow
    Write-Host "Inspect them. If they look right, run again without -PreviewTo." -ForegroundColor Yellow
}
