# Build-Release.ps1 - package Claude Lifeboat into a clean, versioned release zip.
#
# Produces dist\claude-lifeboat-v<version>.zip containing only what an end user
# needs to install and run - NOT the dev workshop (no legacy/, no handoff notes,
# no CLAUDE.md). The version is read from src\lifeboat.ps1 so there is a single
# source of truth and no drift.
#
# Usage (from anywhere):
#   .\tools\Build-Release.ps1
#   .\tools\Build-Release.ps1 -OutDir C:\temp\out
#
# Zero dependencies (Compress-Archive / Get-FileHash ship with PowerShell 5+).

[CmdletBinding()]
param(
    [string]$OutDir
)

$ErrorActionPreference = "Stop"

# Repo root is the parent of this tools\ folder.
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $repoRoot "dist" }

function Write-Step($text, $color = 'Cyan') {
    Write-Host ""
    Write-Host "  $text" -ForegroundColor $color
}

$check = [char]0x2713

# --- Resolve the version from the one place that owns it -------------------
$cliPath = Join-Path $repoRoot "src\lifeboat.ps1"
if (-not (Test-Path $cliPath)) {
    throw "Cannot find src\lifeboat.ps1 (looked in $repoRoot). Run this from the repo's tools\ folder."
}
$cliText = Get-Content $cliPath -Raw
$m = [regex]::Match($cliText, '\$script:LifeboatVersion\s*=\s*"([^"]+)"')
if (-not $m.Success) {
    throw "Could not find `$script:LifeboatVersion in src\lifeboat.ps1 - has the variable been renamed?"
}
$version = $m.Groups[1].Value

Write-Host @"

  ===============================================
    Claude Lifeboat - Release Packager
    Building v$version
  ===============================================
"@ -ForegroundColor Cyan

# --- What ships in the package (everything else is intentionally excluded) --
$includeFiles = @(
    "install.ps1",
    "Install Claude Lifeboat.bat",
    "README.md",
    "LICENSE",
    "CHANGELOG.md"
)
$includeDirs = @(
    "src",
    "assets"
)

# --- Stage a clean tree -----------------------------------------------------
$stageRoot = Join-Path $OutDir "staging"
$stagePkg  = Join-Path $stageRoot "claude-lifeboat"
if (Test-Path $stageRoot) { Remove-Item $stageRoot -Recurse -Force }
New-Item -ItemType Directory -Path $stagePkg -Force | Out-Null

Write-Step "Staging files..."
foreach ($f in $includeFiles) {
    $srcF = Join-Path $repoRoot $f
    if (-not (Test-Path $srcF)) { throw "Expected file is missing: $f" }
    Copy-Item $srcF $stagePkg -Force
    Write-Host "    + $f"
}
foreach ($d in $includeDirs) {
    $srcD = Join-Path $repoRoot $d
    if (-not (Test-Path $srcD)) { throw "Expected folder is missing: $d" }
    Copy-Item $srcD $stagePkg -Recurse -Force
    Write-Host "    + $d\"
}

# --- Zip it -----------------------------------------------------------------
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$zipName = "claude-lifeboat-v$version.zip"
$zipPath = Join-Path $OutDir $zipName
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

Write-Step "Compressing -> $zipName"
# Compress the package folder itself so the archive contains a single
# top-level claude-lifeboat\ folder (installer detects src\ inside it).
Compress-Archive -Path $stagePkg -DestinationPath $zipPath -CompressionLevel Optimal

# --- Checksum so downloads are verifiable -----------------------------------
$hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
$sumPath = "$zipPath.sha256"
# Format mirrors the `sha256sum` convention: "<hash>  <filename>".
"$hash  $zipName" | Set-Content -Path $sumPath -Encoding ASCII

# Tidy the staging tree; the zip is the artifact.
Remove-Item $stageRoot -Recurse -Force

$sizeMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)

Write-Host ""
Write-Host "  $check Built $zipName ($sizeMB MB)" -ForegroundColor Green
Write-Host "    $zipPath"
Write-Host "    SHA256: $hash"

# --- Hand-publish steps (no gh CLI required) --------------------------------
Write-Host @"

  Next steps to publish v${version}:

    1. Tag the commit (if not already):
         git tag v$version
         git push origin v$version

    2. Create the release on GitHub:
         https://github.com/JackBhanded/claude-lifeboat/releases/new?tag=v$version

    3. Drag these two files into the release's "Attach binaries" box:
         $zipPath
         $sumPath

  The one-line installer will then prefer this clean asset automatically.
"@ -ForegroundColor DarkCyan
Write-Host ""
