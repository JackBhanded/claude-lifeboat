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

# If we're being piped from iex (no local files), download the release ourselves
# so the one-line installer works end to end.
$repo = "JackBhanded/claude-lifeboat"
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { $null }
if (-not $scriptDir -or -not (Test-Path (Join-Path $scriptDir "src\lifeboat.ps1"))) {
    Write-Step "Downloading Claude Lifeboat..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $tempDir = Join-Path $env:TEMP "claude-lifeboat-$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    # Prefer a clean packaged release asset (claude-lifeboat-vX.Y.Z.zip); fall
    # back to GitHub's source archive for older asset-less releases, and to main
    # if there's no published release at all.
    $zipUrl = $null
    try {
        if ($Version -eq "latest") {
            $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" `
                -Headers @{ "User-Agent" = "claude-lifeboat-installer" }
        } else {
            $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/tags/$Version" `
                -Headers @{ "User-Agent" = "claude-lifeboat-installer" }
        }
        $tag = $rel.tag_name
        $asset = $rel.assets | Where-Object { $_.name -like "claude-lifeboat-*.zip" } | Select-Object -First 1
        if ($asset) {
            $zipUrl = $asset.browser_download_url
        } elseif ($tag) {
            $zipUrl = "https://github.com/$repo/archive/refs/tags/$tag.zip"
        }
    } catch {
        Write-Host "    (no published release yet - falling back to the latest code)" -ForegroundColor DarkGray
    }
    if (-not $zipUrl) { $zipUrl = "https://github.com/$repo/archive/refs/heads/main.zip" }

    $zipPath = Join-Path $tempDir "lifeboat.zip"
    Write-Host "    From: $zipUrl"
    try {
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
        Expand-Archive -Path $zipPath -DestinationPath $tempDir -Force
    } catch {
        Write-Host ""
        Write-Host "  ! Couldn't download Claude Lifeboat ($($_.Exception.Message))." -ForegroundColor Red
        Write-Host "    Check your internet connection and try again, or download the zip" -ForegroundColor Yellow
        Write-Host "    from https://github.com/$repo and run install.ps1 from inside it." -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }

    # The archive unpacks into a subfolder (claude-lifeboat-<tag/main>); find the
    # one that actually contains the source.
    $extracted = Get-ChildItem -Path $tempDir -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName "src\lifeboat.ps1") } |
        Select-Object -First 1
    if (-not $extracted) {
        Write-Host ""
        Write-Host "  ! The download didn't contain the expected files. Aborting safely." -ForegroundColor Red
        Write-Host ""
        exit 1
    }
    $scriptDir = $extracted.FullName
    Write-Host "  $([char]0x2713) Downloaded" -ForegroundColor Green
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

    # Bring the tray up right away so you can see it now (it also auto-starts at
    # each logon via its scheduled task).
    Write-Step "Starting the tray..."
    & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $InstallTo "lifeboat.ps1") tray
    Write-Host "  $([char]0x2713) Look for the lifebuoy in your system tray (near the clock)." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "  $([char]0x2713) Installation complete. Run 'lifeboat install' when ready." -ForegroundColor Green
}

Write-Host ""
