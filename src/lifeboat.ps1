<#
.SYNOPSIS
  Claude Lifeboat - automated, versioned backup of Claude Desktop data.

.DESCRIPTION
  Subcommands:
    install    Set up backup tasks and config (interactive, two questions)
    status     Show current backup health (use --json for machine-readable)
    backup     Run a backup right now
    restore    Restore from a snapshot (interactive)
    doctor     Diagnose and auto-fix common issues
    dashboard  Open the live HTML dashboard
    verify     Verify a backup is restorable (integrity check)
    uninstall  Remove scheduled tasks and config (keeps your backups)

.EXAMPLE
  lifeboat install
  lifeboat status
  lifeboat backup
  lifeboat restore --preview
  lifeboat doctor

.LINK
  https://github.com/JackBhanded/claude-lifeboat
#>

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet("install","status","backup","restore","doctor","dashboard","verify","uninstall","tray","version","help")]
    [string]$Command = "help",

    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Arguments
)

$script:LifeboatVersion = "0.1.5"
$script:LifeboatHome = "$env:LOCALAPPDATA\ClaudeLifeboat"
$script:ConfigPath = Join-Path $LifeboatHome "config.json"
$script:LogDir = Join-Path $LifeboatHome "logs"

# Color helpers - graceful if console doesn't support colors
function Write-Heading($text) {
    Write-Host ""
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host ""
}
function Write-Success($text) { Write-Host "  $([char]0x2713) $text" -ForegroundColor Green }
function Write-Warning2($text) { Write-Host "  ! $text" -ForegroundColor Yellow }
function Write-Failure($text) { Write-Host "  $([char]0x2717) $text" -ForegroundColor Red }
function Write-Info($text) { Write-Host "    $text" -ForegroundColor DarkGray }
function Write-Prompt($text) { Write-Host "  $text " -NoNewline -ForegroundColor Yellow }

# Get the directory where this script lives, so subcommands can find each other
$script:ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# Load all sub-modules
. (Join-Path $ScriptRoot "lib\common.ps1")
. (Join-Path $ScriptRoot "lib\config.ps1")
. (Join-Path $ScriptRoot "lib\backup.ps1")
. (Join-Path $ScriptRoot "lib\restore.ps1")
. (Join-Path $ScriptRoot "lib\status.ps1")
. (Join-Path $ScriptRoot "lib\doctor.ps1")
. (Join-Path $ScriptRoot "lib\install.ps1")
. (Join-Path $ScriptRoot "lib\dashboard.ps1")
. (Join-Path $ScriptRoot "lib\verify.ps1")

function Show-Help {
    Write-Host @"

  Claude Lifeboat v$LifeboatVersion
  Automated, versioned backup of Claude Desktop data

  USAGE
    lifeboat <command> [options]

  COMMANDS
    install      Set up the backup system (run this first)
    status       Show current backup health
    backup       Run a backup right now
    restore      Restore from a snapshot
    verify       Check that a backup is restorable
    doctor       Diagnose and auto-fix issues
    dashboard    Open the live HTML dashboard
    tray         Put Claude Lifeboat in your system tray (status light + menu)
    uninstall    Remove scheduled tasks (keeps your backups)

  OPTIONS
    --json       (status, verify) Machine-readable output
    --quiet      (status) Only show output if there are issues
    --notify     (status) Show Windows toast if issues found
    --preview    (restore) Restore to a temp folder first (recommended)
    --force      (restore, uninstall) Skip confirmations
    --to=X:      (backup) One-time backup to a specific drive right now (e.g. a USB)

  EXAMPLES
    lifeboat install                    # First-time setup
    lifeboat status                     # Quick health check
    lifeboat backup                     # Run a backup now
    lifeboat backup --to=E:             # One-time backup to a USB / removable drive
    lifeboat restore --preview          # Safe restore (recommended first time)
    lifeboat doctor                     # Fix what you can automatically
    lifeboat dashboard                  # Open visual dashboard

  More: https://github.com/JackBhanded/claude-lifeboat

"@
}

# Parse arguments into flags
$flags = @{}
foreach ($arg in $Arguments) {
    if ($arg -match '^--(.+?)(?:=(.+))?$') {
        $flags[$matches[1]] = if ($matches[2]) { $matches[2] } else { $true }
    }
}

# Dispatch
switch ($Command) {
    "install"   { Invoke-Install -Flags $flags }
    "status"    { Invoke-Status -Flags $flags }
    "backup"    {
                    # 'lifeboat backup --to=E:' (or '--to E:') does a one-time
                    # backup to a drive you pick, leaving your configured archive alone.
                    $target = $null
                    if ($flags.ContainsKey('to')) {
                        if ($flags.to -ne $true) { $target = $flags.to }
                        else { $target = ($Arguments | Where-Object { $_ -notmatch '^--' } | Select-Object -First 1) }
                    }
                    if ($target) { Invoke-BackupToDrive -Target $target -Flags $flags }
                    else { Invoke-Backup -Flags $flags }
                }
    "restore"   { Invoke-Restore -Flags $flags }
    "verify"    { Invoke-Verify -Flags $flags }
    "doctor"    { Invoke-Doctor -Flags $flags }
    "dashboard" { Invoke-Dashboard -Flags $flags }
    "uninstall" { Invoke-Uninstall -Flags $flags }
    "tray"      {
                    $trayScript = Join-Path $ScriptRoot "lifeboat-tray.ps1"
                    if (-not (Test-Path $trayScript)) {
                        Write-Failure "Tray script not found at $trayScript"
                    } else {
                        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$trayScript`""
                        Write-Success "Claude Lifeboat is now in your system tray - right-click the buoy icon for the menu."
                    }
                }
    "version"   { Write-Host "claude-lifeboat v$LifeboatVersion" }
    default     { Show-Help }
}
