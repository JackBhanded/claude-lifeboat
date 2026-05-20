# =====================================================================
# Backup-BeforeUpgrade.ps1
# Comprehensive backup before Windows 10 Home -> Pro upgrade
#
# Usage:
#   1. Plug in your external SSD backup drive
#   2. Open PowerShell as Administrator
#   3. Run: .\Backup-BeforeUpgrade.ps1 -BackupDrive "E:"
#      (replace E: with your backup drive letter)
#
# What it backs up:
#   - User profile: Documents, Desktop, Pictures, Downloads, Videos, Music
#   - Claude Desktop data (AppData\Local\Packages\Claude_*)
#   - Cowork VM bundles and session data
#   - Claude Code config (if installed)
#   - IIS configuration and wwwroot
#   - Installed app list (for reference / reinstall checklist)
#   - Browser bookmarks (Chrome, Edge, Firefox)
#   - SSH keys, Git config
#   - Hosts file, environment variables
#   - Windows product key (current Home key, for reference)
#   - Registry exports for key apps
#   - Scheduled tasks list
#   - Service list (so you can verify nothing critical disappears)
# =====================================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$BackupDrive
)

$ErrorActionPreference = "Continue"  # Keep going if individual items fail
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$backupRoot = Join-Path $BackupDrive "PreUpgradeBackup_$timestamp"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  PRE-UPGRADE BACKUP" -ForegroundColor Cyan
Write-Host "  Destination: $backupRoot" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Verify backup drive exists and has space
if (-not (Test-Path $BackupDrive)) {
    Write-Host "ERROR: Backup drive $BackupDrive not found. Plug in the drive." -ForegroundColor Red
    exit 1
}

$drive = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='$($BackupDrive.TrimEnd('\'))'"
$freeGB = [math]::Round($drive.FreeSpace / 1GB, 1)
Write-Host "Backup drive free space: ${freeGB} GB" -ForegroundColor Green
if ($freeGB -lt 50) {
    Write-Host "WARNING: Less than 50GB free. Make sure this is enough for your data." -ForegroundColor Yellow
    Read-Host "Press Enter to continue or Ctrl+C to cancel"
}

# Create backup directory structure
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
$dirs = @("UserFiles","ClaudeDesktop","ClaudeCode","IIS","SQL","AppLists","Browsers","Dev","System","Registry")
foreach ($d in $dirs) { New-Item -ItemType Directory -Path "$backupRoot\$d" -Force | Out-Null }

$log = "$backupRoot\backup-log.txt"
function Log($msg) {
    $line = "$(Get-Date -Format 'HH:mm:ss')  $msg"
    Write-Host $line
    Add-Content -Path $log -Value $line
}

Log "Backup started"

# ---------- 1. USER FILES ----------
Write-Host "`n[1/11] Backing up user folders..." -ForegroundColor Yellow
$userFolders = @("Documents","Desktop","Pictures","Downloads","Videos","Music","Favorites","Contacts")
foreach ($folder in $userFolders) {
    $src = "$env:USERPROFILE\$folder"
    if (Test-Path $src) {
        Log "Copying $folder..."
        $dst = "$backupRoot\UserFiles\$folder"
        # robocopy is faster and handles long paths better than Copy-Item
        robocopy $src $dst /E /R:1 /W:1 /MT:8 /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    }
}

# ---------- 2. CLAUDE DESKTOP ----------
Write-Host "`n[2/11] Backing up Claude Desktop..." -ForegroundColor Yellow
$claudePackage = Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -Filter "Claude_*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($claudePackage) {
    Log "Found Claude package: $($claudePackage.Name)"
    Log "Copying Claude package data (VM bundles, settings, cache)..."
    robocopy $claudePackage.FullName "$backupRoot\ClaudeDesktop\$($claudePackage.Name)" /E /R:1 /W:1 /MT:8 /NFL /NDL /NJH /NJS /NC /NS | Out-Null
} else {
    Log "Claude Desktop package not found at expected location"
}

# Also grab the machine-wide ProgramData logs and any config
if (Test-Path "C:\ProgramData\Claude") {
    Log "Copying C:\ProgramData\Claude..."
    robocopy "C:\ProgramData\Claude" "$backupRoot\ClaudeDesktop\ProgramData_Claude" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS | Out-Null
}

# ---------- 3. CLAUDE CODE (CLI) ----------
Write-Host "`n[3/11] Backing up Claude Code config (if installed)..." -ForegroundColor Yellow
$claudeCodePaths = @(
    "$env:USERPROFILE\.claude",
    "$env:APPDATA\claude-code",
    "$env:USERPROFILE\.config\claude"
)
foreach ($p in $claudeCodePaths) {
    if (Test-Path $p) {
        Log "Found Claude Code config at $p"
        $name = Split-Path $p -Leaf
        robocopy $p "$backupRoot\ClaudeCode\$name" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    }
}

# ---------- 4. IIS ----------
Write-Host "`n[4/11] Backing up IIS configuration and sites..." -ForegroundColor Yellow
$iisInstalled = Get-Service W3SVC -ErrorAction SilentlyContinue
if ($iisInstalled) {
    Log "IIS detected - backing up configuration"

    # IIS config files
    if (Test-Path "C:\Windows\System32\inetsrv\config") {
        robocopy "C:\Windows\System32\inetsrv\config" "$backupRoot\IIS\config" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    }

    # Default wwwroot
    if (Test-Path "C:\inetpub\wwwroot") {
        Log "Backing up C:\inetpub\wwwroot..."
        robocopy "C:\inetpub\wwwroot" "$backupRoot\IIS\wwwroot" /E /R:1 /W:1 /MT:8 /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    }

    # Custom site paths from applicationHost.config
    try {
        Import-Module WebAdministration -ErrorAction Stop
        $sites = Get-Website
        $sites | Select Name, ID, State, PhysicalPath, Bindings | Export-Csv "$backupRoot\IIS\sites-list.csv" -NoTypeInformation
        Log "Exported list of $($sites.Count) IIS sites to sites-list.csv"

        # Back up each site's physical path if it's outside inetpub
        foreach ($site in $sites) {
            $path = $site.PhysicalPath -replace '%SystemDrive%', 'C:'
            if ((Test-Path $path) -and ($path -notlike "C:\inetpub*")) {
                $safeName = $site.Name -replace '[^\w]', '_'
                Log "Backing up custom site path: $path"
                robocopy $path "$backupRoot\IIS\sites\$safeName" /E /R:1 /W:1 /MT:8 /NFL /NDL /NJH /NJS /NC /NS | Out-Null
            }
        }

        # App pools
        Get-ChildItem IIS:\AppPools | Select Name, State, ManagedRuntimeVersion, ManagedPipelineMode |
            Export-Csv "$backupRoot\IIS\apppools.csv" -NoTypeInformation

        # Full appcmd export (best for restore reference)
        & "$env:windir\System32\inetsrv\appcmd.exe" list site /config /xml > "$backupRoot\IIS\sites-full.xml" 2>$null
        & "$env:windir\System32\inetsrv\appcmd.exe" list apppool /config /xml > "$backupRoot\IIS\apppools-full.xml" 2>$null
    } catch {
        Log "WebAdministration module not available - skipping detailed IIS export"
    }
} else {
    Log "IIS not installed - skipping"
}

# ---------- 5. SQL SERVER DATABASES ----------
Write-Host "`n[5/11] Backing up SQL Server databases..." -ForegroundColor Yellow

# Discover all SQL Server instances on this machine
$sqlInstances = @()
$regPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL"
if (Test-Path $regPath) {
    $instanceProps = Get-ItemProperty $regPath
    foreach ($instanceName in ($instanceProps.PSObject.Properties | Where-Object { $_.Name -notmatch "^PS" }).Name) {
        # MSSQLSERVER is the default instance — connect as just the hostname
        # Anything else is a named instance — connect as HOSTNAME\INSTANCENAME
        if ($instanceName -eq "MSSQLSERVER") {
            $sqlInstances += $env:COMPUTERNAME
        } else {
            $sqlInstances += "$env:COMPUTERNAME\$instanceName"
        }
    }
}

# Also check for LocalDB instances
if (Get-Command sqllocaldb -ErrorAction SilentlyContinue) {
    $localDbList = & sqllocaldb info 2>$null
    foreach ($lname in $localDbList) {
        if ($lname -and $lname.Trim()) {
            $sqlInstances += "(localdb)\$($lname.Trim())"
        }
    }
}

if ($sqlInstances.Count -eq 0) {
    Log "No SQL Server instances detected - skipping SQL backup"
} else {
    Log "Found $($sqlInstances.Count) SQL instance(s): $($sqlInstances -join ', ')"

    # Save the instance list for restore reference
    $sqlInstances | Out-File "$backupRoot\SQL\instances.txt"

    # Determine if we have sqlcmd available
    $sqlcmd = Get-Command sqlcmd -ErrorAction SilentlyContinue
    if (-not $sqlcmd) {
        # Try common install paths
        $sqlcmdCandidates = @(
            "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\SQLCMD.EXE",
            "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\130\Tools\Binn\SQLCMD.EXE",
            "C:\Program Files (x86)\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\SQLCMD.EXE",
            "C:\Program Files\Microsoft SQL Server\150\Tools\Binn\SQLCMD.EXE",
            "C:\Program Files\Microsoft SQL Server\140\Tools\Binn\SQLCMD.EXE",
            "C:\Program Files\Microsoft SQL Server\130\Tools\Binn\SQLCMD.EXE",
            "C:\Program Files\Microsoft SQL Server\110\Tools\Binn\SQLCMD.EXE"
        )
        $sqlcmdPath = $sqlcmdCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    } else {
        $sqlcmdPath = $sqlcmd.Source
    }

    if (-not $sqlcmdPath) {
        Log "WARNING: sqlcmd not found. Install SQL Server Command Line Utilities or SSMS."
        Log "Skipping SQL backup. You can do this manually with SSMS later."
    } else {
        Log "Using sqlcmd: $sqlcmdPath"

        foreach ($instance in $sqlInstances) {
            $safeInstanceName = $instance -replace '[\\(\):]', '_'
            $instanceDir = "$backupRoot\SQL\$safeInstanceName"
            New-Item -ItemType Directory -Path $instanceDir -Force | Out-Null

            Log "Connecting to instance: $instance"

            # Get list of user databases (skip system DBs: master/model/msdb/tempdb)
            # Use Windows Authentication (-E flag)
            $dbListQuery = "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE database_id > 4 AND state_desc = 'ONLINE' AND name NOT IN ('ReportServer','ReportServerTempDB')"
            $dbList = & $sqlcmdPath -S $instance -E -h -1 -W -Q $dbListQuery 2>$null | Where-Object { $_ -and $_.Trim() -and $_ -notmatch "^\s*$" }

            if (-not $dbList) {
                Log "  No user databases found on $instance (or could not connect)"
                continue
            }

            Log "  Found $(@($dbList).Count) database(s): $($dbList -join ', ')"

            foreach ($db in $dbList) {
                $db = $db.Trim()
                if (-not $db) { continue }

                $bakFile = "$instanceDir\$db.bak"
                Log "  Backing up: $db"

                # BACKUP DATABASE with COMPRESSION (if Enterprise) and CHECKSUM for integrity
                # INIT overwrites if file exists. FORMAT creates a new media header.
                $backupQuery = @"
BACKUP DATABASE [$db] TO DISK = N'$bakFile'
WITH FORMAT, INIT, NAME = N'$db Pre-Upgrade Backup',
SKIP, NOREWIND, NOUNLOAD, CHECKSUM, STATS = 25;
"@
                $result = & $sqlcmdPath -S $instance -E -Q $backupQuery 2>&1

                if (Test-Path $bakFile) {
                    $bakSizeMB = [math]::Round((Get-Item $bakFile).Length / 1MB, 1)
                    Log "    OK - ${bakSizeMB} MB saved"
                } else {
                    Log "    FAILED: $result"
                }
            }

            # Also export schema-only scripts as a safety net (useful if .bak files won't restore)
            Log "  Exporting list of databases, logins, and SQL Server version info..."
            & $sqlcmdPath -S $instance -E -Q "SELECT @@VERSION" > "$instanceDir\version.txt" 2>$null
            & $sqlcmdPath -S $instance -E -Q "SELECT name, database_id, create_date, collation_name, state_desc, recovery_model_desc FROM sys.databases" > "$instanceDir\databases-info.txt" 2>$null
            & $sqlcmdPath -S $instance -E -Q "SELECT name, type_desc, create_date, is_disabled FROM sys.server_principals WHERE type IN ('S','U','G') AND name NOT LIKE '##%' AND name NOT LIKE 'NT %'" > "$instanceDir\logins.txt" 2>$null
        }

        Log "SQL backup phase complete"
    }
}

# ---------- 6. INSTALLED APPS LIST ----------
Write-Host "`n[6/11] Exporting installed apps list..." -ForegroundColor Yellow
# From registry (most complete)
$apps = @()
$apps += Get-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue
$apps += Get-ItemProperty "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue
$apps += Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue
$apps | Where-Object DisplayName | Select DisplayName, DisplayVersion, Publisher, InstallDate |
    Sort-Object DisplayName | Export-Csv "$backupRoot\AppLists\installed-apps.csv" -NoTypeInformation
Log "Exported $($apps.Count) installed apps to installed-apps.csv"

# Microsoft Store apps
Get-AppxPackage | Select Name, Version, Publisher, InstallLocation |
    Export-Csv "$backupRoot\AppLists\store-apps.csv" -NoTypeInformation
Log "Exported Microsoft Store apps to store-apps.csv"

# winget list if winget is available
if (Get-Command winget -ErrorAction SilentlyContinue) {
    winget list --accept-source-agreements > "$backupRoot\AppLists\winget-list.txt" 2>$null
    Log "Exported winget list"
}

# ---------- 7. BROWSERS ----------
Write-Host "`n[7/11] Backing up browser bookmarks..." -ForegroundColor Yellow
$chromeBookmarks = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Bookmarks"
$edgeBookmarks = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Bookmarks"
$firefoxProfiles = "$env:APPDATA\Mozilla\Firefox\Profiles"

if (Test-Path $chromeBookmarks) { Copy-Item $chromeBookmarks "$backupRoot\Browsers\Chrome-Bookmarks.json"; Log "Chrome bookmarks saved" }
if (Test-Path $edgeBookmarks)   { Copy-Item $edgeBookmarks "$backupRoot\Browsers\Edge-Bookmarks.json"; Log "Edge bookmarks saved" }
if (Test-Path $firefoxProfiles) {
    robocopy $firefoxProfiles "$backupRoot\Browsers\Firefox-Profiles" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    Log "Firefox profiles saved"
}

# ---------- 8. DEV ENVIRONMENT ----------
Write-Host "`n[8/11] Backing up dev environment..." -ForegroundColor Yellow

# SSH keys
if (Test-Path "$env:USERPROFILE\.ssh") {
    robocopy "$env:USERPROFILE\.ssh" "$backupRoot\Dev\ssh" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    Log "SSH keys backed up"
}

# Git config
if (Test-Path "$env:USERPROFILE\.gitconfig") {
    Copy-Item "$env:USERPROFILE\.gitconfig" "$backupRoot\Dev\gitconfig"
    Log "Git config backed up"
}

# npm config
if (Test-Path "$env:USERPROFILE\.npmrc") {
    Copy-Item "$env:USERPROFILE\.npmrc" "$backupRoot\Dev\npmrc"
}

# VS Code settings
$vscodeUser = "$env:APPDATA\Code\User"
if (Test-Path $vscodeUser) {
    robocopy $vscodeUser "$backupRoot\Dev\vscode-user" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    Log "VS Code user settings backed up"
    # Extensions list
    if (Get-Command code -ErrorAction SilentlyContinue) {
        code --list-extensions > "$backupRoot\Dev\vscode-extensions.txt" 2>$null
    }
}

# Hosts file
Copy-Item "C:\Windows\System32\drivers\etc\hosts" "$backupRoot\Dev\hosts.txt" -ErrorAction SilentlyContinue
Log "Hosts file backed up"

# ---------- 9. SYSTEM INFO ----------
Write-Host "`n[9/11] Capturing system info..." -ForegroundColor Yellow

# Current Windows edition and key
(Get-WmiObject Win32_OperatingSystem).Caption | Out-File "$backupRoot\System\current-edition.txt"
$key = (Get-WmiObject -Query "SELECT OA3xOriginalProductKey FROM SoftwareLicensingService").OA3xOriginalProductKey
if ($key) { $key | Out-File "$backupRoot\System\OEM-product-key.txt" }

# Environment variables
Get-ChildItem env: | Export-Csv "$backupRoot\System\environment-variables.csv" -NoTypeInformation

# Services list
Get-Service | Select Name, DisplayName, Status, StartType | Export-Csv "$backupRoot\System\services.csv" -NoTypeInformation

# Scheduled tasks
Get-ScheduledTask | Select TaskName, TaskPath, State |
    Export-Csv "$backupRoot\System\scheduled-tasks.csv" -NoTypeInformation

# Network adapters and IP config
ipconfig /all > "$backupRoot\System\ipconfig.txt"

# Drivers
Get-WmiObject Win32_PnPSignedDriver | Select DeviceName, Manufacturer, DriverVersion, DriverDate |
    Export-Csv "$backupRoot\System\drivers.csv" -NoTypeInformation

Log "System info captured"

# ---------- 10. REGISTRY EXPORTS ----------
Write-Host "`n[10/11] Exporting key registry hives..." -ForegroundColor Yellow
$regExports = @{
    "HKCU-Software"       = "HKCU\Software"
    "HKLM-Software-MS"    = "HKLM\Software\Microsoft\Windows"
    "Environment-User"    = "HKCU\Environment"
    "Environment-System"  = "HKLM\System\CurrentControlSet\Control\Session Manager\Environment"
}
foreach ($name in $regExports.Keys) {
    reg export $regExports[$name] "$backupRoot\Registry\$name.reg" /y 2>$null | Out-Null
}
Log "Registry exports complete"

# ---------- 11. SUMMARY ----------
Write-Host "`n[11/11] Generating summary..." -ForegroundColor Yellow
$summary = @"
PRE-UPGRADE BACKUP SUMMARY
==========================
Created: $(Get-Date)
Destination: $backupRoot

Source machine:
  User: $env:USERNAME
  Computer: $env:COMPUTERNAME
  OS: $((Get-WmiObject Win32_OperatingSystem).Caption)
  Build: $((Get-WmiObject Win32_OperatingSystem).BuildNumber)

Backup contents:
  UserFiles/    - Documents, Desktop, Pictures, Downloads, Videos, Music
  ClaudeDesktop/ - Claude Desktop package data + ProgramData logs
  ClaudeCode/   - Claude Code CLI configs (if installed)
  IIS/          - IIS config, wwwroot, custom site folders, sites/apppools lists
  SQL/          - SQL Server .bak files per instance + version/logins/db info
  AppLists/     - installed-apps.csv, store-apps.csv, winget-list.txt
  Browsers/     - Chrome/Edge/Firefox bookmarks
  Dev/          - SSH keys, git/npm config, VS Code settings, hosts file
  System/       - edition, env vars, services, tasks, drivers, ipconfig
  Registry/     - HKCU\Software, environment variables, etc.

After upgrade succeeds, you can keep this backup for 30 days, then delete
if everything is working fine.

If upgrade fails or something doesn't work:
  - UserFiles/ has your actual data
  - AppLists/installed-apps.csv tells you what to reinstall
  - IIS/sites-full.xml + apppools-full.xml are the IIS restore reference
  - SQL/<instance>/*.bak files are restored with Restore-SqlDatabases.ps1
  - Registry/*.reg files can be merged back if needed
"@
$summary | Out-File "$backupRoot\README.txt"
Write-Host $summary -ForegroundColor Green

# Total size
$size = (Get-ChildItem $backupRoot -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
$sizeGB = [math]::Round($size / 1GB, 2)
Log "Total backup size: ${sizeGB} GB"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  BACKUP COMPLETE" -ForegroundColor Green
Write-Host "  Location: $backupRoot" -ForegroundColor Green
Write-Host "  Size: ${sizeGB} GB" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Cyan
Write-Host "Review the log: $log" -ForegroundColor Yellow
Write-Host "Review README:  $backupRoot\README.txt" -ForegroundColor Yellow
