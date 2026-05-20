# Runner script - installed at $LifeboatHome and invoked by scheduled tasks.
# This is a thin wrapper that loads the lib/ files and dispatches to the right
# subcommand. Doing it this way means we can re-register tasks pointing at a
# stable path regardless of where the user originally cloned/downloaded.

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [string]$Command = "status",
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Arguments
)

$script:LifeboatVersion = "0.1.0"
$script:LifeboatHome = "$env:LOCALAPPDATA\ClaudeLifeboat"
$script:ConfigPath = Join-Path $LifeboatHome "config.json"
$script:LogDir = Join-Path $LifeboatHome "logs"
$script:ScriptRoot = $LifeboatHome

# Color helpers (no-ops when running hidden)
function Write-Heading($text) { Write-Host ""; Write-Host "  $text" -ForegroundColor Cyan; Write-Host "" }
function Write-Success($text) { Write-Host "  $([char]0x2713) $text" -ForegroundColor Green }
function Write-Warning2($text) { Write-Host "  ! $text" -ForegroundColor Yellow }
function Write-Failure($text) { Write-Host "  $([char]0x2717) $text" -ForegroundColor Red }
function Write-Info($text) { Write-Host "    $text" -ForegroundColor DarkGray }
function Write-Prompt($text) { Write-Host "  $text " -NoNewline -ForegroundColor Yellow }

$libDir = Join-Path $LifeboatHome "lib"
. (Join-Path $libDir "common.ps1")
. (Join-Path $libDir "config.ps1")
. (Join-Path $libDir "backup.ps1")
. (Join-Path $libDir "status.ps1")
. (Join-Path $libDir "restore.ps1")
. (Join-Path $libDir "doctor.ps1")
. (Join-Path $libDir "verify.ps1")
. (Join-Path $libDir "dashboard.ps1")
. (Join-Path $libDir "install.ps1")

$flags = @{}
foreach ($arg in $Arguments) {
    if ($arg -match '^--(.+?)(?:=(.+))?$') {
        $flags[$matches[1]] = if ($matches[2]) { $matches[2] } else { $true }
    }
}

switch ($Command) {
    "backup"    { Invoke-Backup -Flags $flags }
    "status"    { Invoke-Status -Flags $flags }
    "restore"   { Invoke-Restore -Flags $flags }
    "verify"    { Invoke-Verify -Flags $flags }
    "doctor"    { Invoke-Doctor -Flags $flags }
    "dashboard" { Invoke-Dashboard -Flags $flags }
    default     { Invoke-Status -Flags $flags }
}
