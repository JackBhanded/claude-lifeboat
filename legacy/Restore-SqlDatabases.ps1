# =====================================================================
# Restore-SqlDatabases.ps1
# Restores SQL .bak files from the pre-upgrade backup
#
# Usage:
#   1. Find your backup folder (e.g. E:\PreUpgradeBackup_2026-05-20_143022\SQL)
#   2. Open PowerShell as Administrator
#   3. Run interactively:
#        .\Restore-SqlDatabases.ps1 -BackupPath "E:\PreUpgradeBackup_2026-05-20_143022\SQL"
#      This lists all .bak files found and asks which to restore.
#
#   4. Or restore all in one go:
#        .\Restore-SqlDatabases.ps1 -BackupPath "E:\...\SQL" -All
#
#   5. Or restore one specific database:
#        .\Restore-SqlDatabases.ps1 -BackupPath "E:\...\SQL" -Database "MyDB" -Instance "MYPC"
#
# What it does:
#   - Connects to your local SQL Server using Windows Authentication
#   - For each .bak file selected, runs RESTORE DATABASE
#   - Handles WITH MOVE to put data/log files in the correct path
#   - Sets database to single-user mode briefly to drop existing connections
#   - Reports success/failure for each restore
# =====================================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$BackupPath,

    [string]$Instance = "",      # Specific instance to restore TO (default: auto-detect)
    [string]$Database = "",      # Specific DB to restore (default: prompt)
    [switch]$All,                # Restore everything found
    [switch]$Force               # Don't prompt for overwrite confirmation
)

$ErrorActionPreference = "Continue"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  SQL DATABASE RESTORE" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

if (-not (Test-Path $BackupPath)) {
    Write-Host "ERROR: Backup path not found: $BackupPath" -ForegroundColor Red
    exit 1
}

# Find sqlcmd
$sqlcmd = Get-Command sqlcmd -ErrorAction SilentlyContinue
if (-not $sqlcmd) {
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
    Write-Host "ERROR: sqlcmd not found. Install SQL Server tools first." -ForegroundColor Red
    exit 1
}

Write-Host "Using sqlcmd: $sqlcmdPath" -ForegroundColor DarkGray

# Auto-detect instance if not specified
if (-not $Instance) {
    # Try the default instance first, then named ones
    $candidates = @($env:COMPUTERNAME)
    $regPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL"
    if (Test-Path $regPath) {
        $iprops = Get-ItemProperty $regPath
        foreach ($iname in ($iprops.PSObject.Properties | Where-Object { $_.Name -notmatch "^PS" }).Name) {
            if ($iname -ne "MSSQLSERVER") {
                $candidates += "$env:COMPUTERNAME\$iname"
            }
        }
    }

    foreach ($c in $candidates) {
        $test = & $sqlcmdPath -S $c -E -Q "SELECT 1" -h -1 -W 2>$null
        if ($LASTEXITCODE -eq 0) {
            $Instance = $c
            Write-Host "Auto-detected instance: $Instance" -ForegroundColor Green
            break
        }
    }
}

if (-not $Instance) {
    Write-Host "ERROR: No SQL Server instance found. Specify with -Instance" -ForegroundColor Red
    exit 1
}

# Find all .bak files in the backup
$bakFiles = Get-ChildItem -Path $BackupPath -Filter "*.bak" -Recurse -File
if ($bakFiles.Count -eq 0) {
    Write-Host "ERROR: No .bak files found under $BackupPath" -ForegroundColor Red
    exit 1
}

Write-Host "`nFound $($bakFiles.Count) backup file(s):" -ForegroundColor Yellow
$i = 1
foreach ($f in $bakFiles) {
    $sizeMB = [math]::Round($f.Length / 1MB, 1)
    $relPath = $f.FullName.Substring($BackupPath.Length).TrimStart('\')
    Write-Host ("  [{0}] {1} ({2} MB)" -f $i, $relPath, $sizeMB)
    $i++
}

# Decide what to restore
$toRestore = @()
if ($All) {
    $toRestore = $bakFiles
    Write-Host "`n-All flag set: will restore all $($bakFiles.Count) databases" -ForegroundColor Yellow
} elseif ($Database) {
    $match = $bakFiles | Where-Object { $_.BaseName -eq $Database }
    if (-not $match) {
        Write-Host "ERROR: No .bak file found for database '$Database'" -ForegroundColor Red
        exit 1
    }
    $toRestore = @($match)
} else {
    Write-Host "`nWhich to restore? Enter numbers separated by commas (e.g. 1,3,5), or 'all'." -ForegroundColor Cyan
    $choice = Read-Host "Choice"
    if ($choice -eq 'all') {
        $toRestore = $bakFiles
    } else {
        $indices = $choice -split ',' | ForEach-Object { [int]($_.Trim()) }
        $toRestore = $indices | ForEach-Object { $bakFiles[$_ - 1] }
    }
}

if ($toRestore.Count -eq 0) {
    Write-Host "Nothing selected to restore." -ForegroundColor Yellow
    exit 0
}

# Get the SQL data and log default paths from the target instance
$dataPathQuery = "SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS NVARCHAR(500))"
$logPathQuery  = "SELECT CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS NVARCHAR(500))"
$defaultDataPath = (& $sqlcmdPath -S $Instance -E -h -1 -W -Q $dataPathQuery 2>$null | Select-Object -First 1).Trim()
$defaultLogPath  = (& $sqlcmdPath -S $Instance -E -h -1 -W -Q $logPathQuery 2>$null | Select-Object -First 1).Trim()

if (-not $defaultDataPath) { $defaultDataPath = "C:\Program Files\Microsoft SQL Server\MSSQL\DATA\" }
if (-not $defaultLogPath)  { $defaultLogPath  = $defaultDataPath }

Write-Host "`nTarget instance: $Instance" -ForegroundColor Green
Write-Host "Data path:       $defaultDataPath" -ForegroundColor Green
Write-Host "Log path:        $defaultLogPath`n" -ForegroundColor Green

# Restore each
$succeeded = 0
$failed = 0
foreach ($bak in $toRestore) {
    $dbName = $bak.BaseName  # filename without .bak
    Write-Host "`n--- Restoring: $dbName ---" -ForegroundColor Cyan
    Write-Host "From: $($bak.FullName)" -ForegroundColor DarkGray

    # Check if database already exists
    $existsQuery = "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name = N'$dbName'"
    $exists = (& $sqlcmdPath -S $Instance -E -h -1 -W -Q $existsQuery 2>$null | Select-Object -First 1).Trim()

    if ($exists -eq "1") {
        if (-not $Force) {
            Write-Host "Database '$dbName' already exists on $Instance." -ForegroundColor Yellow
            $confirm = Read-Host "Overwrite? (y/N)"
            if ($confirm -ne 'y') {
                Write-Host "Skipped." -ForegroundColor Yellow
                continue
            }
        }
        # Kick out users and switch to single-user so we can overwrite
        Write-Host "Setting $dbName to SINGLE_USER to drop connections..." -ForegroundColor DarkGray
        $kickQuery = "ALTER DATABASE [$dbName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE"
        & $sqlcmdPath -S $Instance -E -Q $kickQuery 2>&1 | Out-Null
    }

    # Read the logical file names from the .bak (needed for WITH MOVE)
    $listQuery = "RESTORE FILELISTONLY FROM DISK = N'$($bak.FullName)'"
    $fileList = & $sqlcmdPath -S $Instance -E -h -1 -W -s "|" -Q $listQuery 2>$null

    $moveClauses = @()
    foreach ($line in $fileList) {
        $cols = $line -split '\|'
        if ($cols.Count -ge 3) {
            $logicalName = $cols[0].Trim()
            $type = $cols[2].Trim()  # D = data, L = log
            if ($logicalName -and $logicalName -notmatch "^-+$" -and $logicalName -notmatch "LogicalName") {
                if ($type -eq "D") {
                    $newPath = Join-Path $defaultDataPath "$dbName.mdf"
                    # If multiple data files, append the logical name to differentiate
                    if (($moveClauses | Where-Object { $_ -match "\.mdf'" }).Count -gt 0) {
                        $newPath = Join-Path $defaultDataPath "$dbName`_$logicalName.ndf"
                    }
                    $moveClauses += "MOVE N'$logicalName' TO N'$newPath'"
                } elseif ($type -eq "L") {
                    $newPath = Join-Path $defaultLogPath "$dbName`_log.ldf"
                    $moveClauses += "MOVE N'$logicalName' TO N'$newPath'"
                }
            }
        }
    }

    $moveSql = $moveClauses -join ", `n  "

    $restoreQuery = @"
RESTORE DATABASE [$dbName]
FROM DISK = N'$($bak.FullName)'
WITH FILE = 1,
  $moveSql,
  NOUNLOAD, REPLACE, STATS = 25;
"@

    Write-Host "Running RESTORE..." -ForegroundColor DarkGray
    $output = & $sqlcmdPath -S $Instance -E -Q $restoreQuery 2>&1

    # Check if it worked
    $verifyQuery = "SET NOCOUNT ON; SELECT state_desc FROM sys.databases WHERE name = N'$dbName'"
    $state = (& $sqlcmdPath -S $Instance -E -h -1 -W -Q $verifyQuery 2>$null | Select-Object -First 1).Trim()

    if ($state -eq "ONLINE") {
        Write-Host "[OK] $dbName restored and ONLINE" -ForegroundColor Green
        $succeeded++

        # Set back to multi-user (in case it was single-user from our drop)
        & $sqlcmdPath -S $Instance -E -Q "ALTER DATABASE [$dbName] SET MULTI_USER" 2>&1 | Out-Null
    } else {
        Write-Host "[FAILED] $dbName state: $state" -ForegroundColor Red
        Write-Host $output -ForegroundColor DarkRed
        $failed++
    }
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  RESTORE SUMMARY" -ForegroundColor Cyan
Write-Host "  Succeeded: $succeeded" -ForegroundColor Green
Write-Host "  Failed:    $failed" -ForegroundColor $(if($failed -eq 0){"Green"}else{"Red"})
Write-Host "========================================`n" -ForegroundColor Cyan

if ($failed -gt 0) {
    Write-Host "For failed databases, try restoring manually via SSMS:" -ForegroundColor Yellow
    Write-Host "  1. Open SQL Server Management Studio" -ForegroundColor Yellow
    Write-Host "  2. Right-click Databases -> Restore Database" -ForegroundColor Yellow
    Write-Host "  3. Source: Device -> browse to the .bak file" -ForegroundColor Yellow
    Write-Host "  4. Under Options, check 'Overwrite the existing database (WITH REPLACE)'" -ForegroundColor Yellow
}
