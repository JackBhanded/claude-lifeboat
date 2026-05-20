# Claude Lifeboat one-line installer
#
# Usage:
#   irm https://github.com/JackBhanded/claude-lifeboat/raw/main/install.ps1 | iex
#
# Or from a downloaded zip:
#   Expand-Archive claude-lifeboat.zip; cd claude-lifeboat; .\install.ps1

[CmdletBinding()]
param(
    [string]$Version = "latest",
    [string]$InstallTo = "$env:LOCALAPPDATA\Programs\ClaudeLifeboat",
    [switch]$NoSetup
)

$ErrorActionPreference = "Stop"

function Write-Step($text, $color = 'Cyan') {
    Write-Host ""
    Write-Host "  $text" -ForegroundColor $color
}

Write-Host @"

  ===============================================
    Claude Lifeboat Installer
    Your Claude Desktop data, safe and restorable
  ===============================================
"@ -ForegroundColor Cyan

# Check admin
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host ""
    Write-Host "  ! This installer needs Administrator privileges." -ForegroundColor Yellow
    Write-Host "    Please re-run from an elevated PowerShell." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# Check PowerShell version
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host ""
    Write-Host "  ! PowerShell 5.0 or newer required (you have $($PSVersionTable.PSVersion))." -ForegroundColor Red
    Write-Host ""
    exit 1
}

Write-Step "Checking environment..."
Write-Host "    User: $env:USERNAME"
Write-Host "    OS: $((Get-WmiObject Win32_OperatingSystem).Caption)"
Write-Host "    PS: $($PSVersionTable.PSVersion)"

# If we're being piped from iex, download the release zip
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { $null }
if (-not $scriptDir -or -not (Test-Path (Join-Path $scriptDir "src\lifeboat.ps1"))) {
    Write-Step "Downloading latest release..."
    $tempDir = Join-Path $env:TEMP "claude-lifeboat-$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    # In production this would download from GitHub releases.
    # For now, give an error since we're not piped from a real release.
    if (-not $scriptDir) {
        Write-Host ""
        Write-Host "  ! Could not auto-download. Please run from a cloned repo or downloaded zip." -ForegroundColor Red
        Write-Host "    Clone: git clone https://github.com/JackBhanded/claude-lifeboat" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
}

# Copy files to install location
Write-Step "Installing to: $InstallTo"
if (Test-Path $InstallTo) {
    Remove-Item $InstallTo -Recurse -Force
}
New-Item -ItemType Directory -Path $InstallTo -Force | Out-Null
Copy-Item (Join-Path $scriptDir "src\*") $InstallTo -Recurse -Force

# Set up the lifeboat command as a PowerShell function in user profile
Write-Step "Setting up 'lifeboat' command..."

# Add to PATH for current user
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$InstallTo*") {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$InstallTo", "User")
    Write-Host "    Added to PATH (restart shell to use 'lifeboat' command directly)"
}

# Create a wrapper batch file so 'lifeboat' works from cmd too
$wrapper = @"
@echo off
powershell.exe -ExecutionPolicy Bypass -File "$InstallTo\lifeboat.ps1" %*
"@
$wrapper | Set-Content -Path (Join-Path $InstallTo "lifeboat.cmd") -Encoding ASCII

Write-Host ""
Write-Host "  $([char]0x2713) Files installed" -ForegroundColor Green

# Run setup unless --NoSetup
if (-not $NoSetup) {
    Write-Step "Running initial setup..."
    & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $InstallTo "lifeboat.ps1") install
} else {
    Write-Host ""
    Write-Host "  $([char]0x2713) Installation complete. Run 'lifeboat install' when ready." -ForegroundColor Green
}

Write-Host ""
