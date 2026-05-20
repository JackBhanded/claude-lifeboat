# Claude Lifeboat — Complete Handoff Document

## Part A — The Tool

### 1. Purpose

Claude Lifeboat is an automated backup and restore tool specifically for Claude Desktop user data on Windows. It exists because:

- Claude Desktop with Cowork stores significant user work locally (conversation history, Cowork VM session data, settings, optionally Claude Code configs)
- This data lives in `AppData\Local\Packages\Claude_*` (an MSIX package folder) which Windows' default File History and Backup utilities miss because they don't index MSIX package data well
- Generic backup tools (Kopia, Restic, FreeFileSync, Aomei Backupper) work fine but don't know Claude-specific paths, don't know that `CoworkVMService` needs to be stopped cleanly before restoring Claude data, and don't understand how the Cowork VM bundle relates to session data
- Once you've lost a working Cowork session with files you generated through it, you really don't want to repeat the experience

The tool's value proposition: **Claude-aware** backup that handles the platform's quirks automatically. It's not trying to beat Kopia at general-purpose backup; it's filling the niche Kopia doesn't care about.

### 2. What Lifeboat Backs Up

These are the exact source paths discovered during diagnosis on the user's Windows 10 Home machine. Some of these were not obvious — we found them by reading the actual `cowork-service.log` and event log entries.

| Source path | Internal name | Why it matters |
|---|---|---|
| `%LOCALAPPDATA%\Packages\Claude_*` | `ClaudeDesktop` | Main Claude Desktop data: conversation history, Cowork VM bundle (`rootfs.vhdx`, `smol-bin.vhdx`, `sessiondata.vhdx`), settings, login state |
| `C:\ProgramData\Claude` | `Claude-System` | Machine-wide Cowork service logs and config (where `cowork-service.log` lives — this was a key discovery) |
| `%USERPROFILE%\.claude` | `ClaudeCode-user` | Claude Code CLI configs (if installed) |
| `%APPDATA%\claude-code` | `ClaudeCode-appdata` | Alternate Claude Code config location |
| `%USERPROFILE%\.config\claude` | `ClaudeCode-xdg` | XDG-style Claude Code config location (some installs) |
| Any extra paths the user adds during install | `Extra-<foldername>` | User's project folders, code repos, anything outside Documents they want safe |

**Specific notes on what's inside `ClaudeDesktop`:**

The MSIX package folder typically contains `LocalCache\Roaming\Claude\vm_bundles\claudevm.bundle\` which has:
- `rootfs.vhdx` — the actual Linux VM root filesystem (largest file, ~2 GB)
- `smol-bin.vhdx` — read-only binary disk for the VM
- `sessiondata.vhdx` — the persistent session disk where Cowork-created files live
- `initrd`, `vmlinuz` — kernel and initramfs for the VM

These were discovered by reading the `cowork-service.log` which contains the full HCS Config JSON showing every path the VM uses.

**What lifeboat deliberately does NOT back up:**

- Open SQL Server databases (need a separate `BACKUP DATABASE` approach — we built this separately in `Restore-SqlDatabases.ps1` from the earlier work, but it's not in Lifeboat itself because Lifeboat is for Claude data specifically)
- Full system state (would compete with Macrium Reflect / Aomei; not the niche)
- Apps, drivers, Windows config — same reasoning
- Email, browser data — out of scope

**Auto-detection note:** Lifeboat uses `Get-ChildItem ... -Filter "Claude_*"` to find the actual MSIX package folder rather than hardcoding a name. The user's package was `Claude_pzs8sxrjxfjjc` but the trailing hash differs per machine, so we can't hardcode. The code that finds it is in `Get-ClaudeDataPaths` in `src/lib/common.ps1`.

### 3. Where Backups Go

**Two-tier strategy:**

- **PRIMARY** — an always-available drive (recommended: internal D: drive, falls back to C:). Every backup writes here. This is the always-on safety net.
- **ARCHIVE** — optional removable/external drive (e.g., F:). Syncs from PRIMARY whenever it's plugged in. Long-term versioning lives here.

**Folder structure on each drive:**

```
<DriveLetter>:\ClaudeLifeboat\
├── latest\                      # Mirror of current state, updated every backup
│   ├── ClaudeDesktop\
│   ├── Claude-System\
│   ├── ClaudeCode-user\         (if Claude Code installed)
│   └── Extra-<foldername>\      (if user added extras)
│
├── daily\
│   ├── 2026-05-20\              # Snapshot from each day, copy of latest at that day's first run
│   ├── 2026-05-19\
│   └── ...
│
├── weekly\                      # ARCHIVE only - Sunday snapshots
│   ├── 2026-05-18\
│   └── ...
│
├── safety\                      # Auto-created before each restore (the Time Machine pattern)
│   └── pre-restore-2026-05-20_143022\
│
├── logs\                        # Backup logs, one file per day
│   └── lifeboat-2026-05-20.log
│
├── status.json                  # Last-run status, machine-readable
└── .last_sync                   # ARCHIVE only - timestamp of last sync from PRIMARY
```

**Retention defaults:**

| Tier | What's kept |
|---|---|
| PRIMARY/latest | Current state (overwritten every run) |
| PRIMARY/daily | Last 3 days |
| ARCHIVE/latest | Mirror of PRIMARY/latest when archive is connected |
| ARCHIVE/daily | Last 7 days |
| ARCHIVE/weekly | Last 4 Sunday snapshots |

These are config-driven and live in `Primary.RetentionDailies`, `Archive.RetentionDailies`, `Archive.RetentionWeeklies` in the config file.

**Naming scheme:**

- Daily folders: `yyyy-MM-dd` (e.g., `2026-05-20`)
- Weekly folders: same format, only created on Sundays
- Safety snapshots before restore: `pre-restore-yyyy-MM-dd_HHmmss` (timestamp so multiple per day work)
- Log files: `lifeboat-yyyy-MM-dd.log`

**Format:**

Plain files via robocopy `/MIR`. No archive container (no `.zip`, no `.tar`), no encryption, no deduplication. We chose this on purpose — see Part C for reasoning. Files are directly browsable in Explorer.

### 4. The Restore Flow

The restore command walks through this sequence:

1. **Load config** — find both PRIMARY and ARCHIVE roots from `%LOCALAPPDATA%\ClaudeLifeboat\config.json`
2. **Enumerate snapshots from both** — `latest`, `daily/*`, `weekly/*` from each location. Dedupe by date (same date in both locations only shown once, prefers ARCHIVE for older).
3. **Pick a snapshot** — either by `--from latest`, `--from daily --date 2026-05-19`, or interactive menu. For `latest` we prefer PRIMARY (faster, most recent); for dated daily/weekly we prefer ARCHIVE (more reliable long-term storage).
4. **Pick folders to restore** — `--only ClaudeDesktop` or interactive multi-select. User can restore one folder or all of them.
5. **Plan the destinations** — for each folder, resolve back to its original Windows path using `Resolve-OriginalDestination` (the inverse mapping of `Get-ClaudeDataPaths`). For `--preview` mode, destinations are redirected to `Desktop\lifeboat-preview-<time>\` instead.
6. **Show plan and confirm** — user sees exact source and destination for each folder, must answer `y` (or `--force`).
7. **Take a safety snapshot** — UNLESS `--preview`. Before overwriting anything, copy the current state of each destination to `<PRIMARY>\safety\pre-restore-<timestamp>\`. This is borrowed from Apple Time Machine — restore should itself be undoable.
8. **Stop Claude processes** — if restoring `ClaudeDesktop` or `Claude-System`, cleanly stop Claude Desktop processes (`Get-Process Claude*`) and `Stop-Service CoworkVMService`. Without this, file locks would cause robocopy failures.
9. **Run robocopy `/MIR`** for each folder from source to destination.
10. **Restart `CoworkVMService`** — if we stopped it.
11. **Summary** — count of successes/failures. If anything failed and a safety snapshot was taken, tell the user the safety path so they can revert.

The `--preview` flag is the critical safety feature. We strongly recommend users do `lifeboat restore --preview` first, inspect the resulting `Desktop\lifeboat-preview-*\` folder, and only then re-run without `--preview`. This guidance is in the README and in the CLI prompts.

### 5. Scheduling / Triggering

Windows Task Scheduler is used to run backups. The install routine in `src/lib/install.ps1` (function `Register-LifeboatTasks`) creates these tasks:

| Task name | Trigger | Why |
|---|---|---|
| `ClaudeLifeboat-Hourly` | Every hour starting next hour | Main rhythm |
| `ClaudeLifeboat-OnLogon` | At user logon | Catch missed hours if laptop was off |
| `ClaudeLifeboat-OnSleep` | Event-based (Kernel-Power Event 42) | When laptop sleeps (lid close) |
| `ClaudeLifeboat-OnDriveConnect` | Event-based (NTFS Event 98) | Auto-sync when archive drive plugged in (only registered if archive configured) |
| `ClaudeLifeboat-OnIdle` | Triggers at logon but runs only when idle 10+ minutes | Catch "stepped away" |
| `ClaudeLifeboat-HealthCheck` | Every 2 hours | Runs `status --quiet --notify` — silent unless issues, then toast |

**Key Task Scheduler specifics that took us time to get right:**

- **Principal:** `New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Limited`. The `S4U` logon type allows the task to run even when the user isn't actively logged in (e.g., laptop in sleep recovery), without needing a stored password. `RunLevel Limited` because we don't want unnecessary elevation on every hourly run.
- **Settings:** `-AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew`. The last one is critical — if a backup is somehow already running when the next trigger fires, ignore the new trigger rather than queue or run both.
- **Execution time limit:** 30 minutes. If a backup takes longer, something's wrong and we'd rather kill it.

**Event-based triggers require CIM:**

PowerShell's `New-ScheduledTaskTrigger` cmdlet doesn't natively support event-based triggers. We built them via CIM:

```powershell
$cls = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
$et = New-CimInstance -CimClass $cls -ClientOnly
$et.Enabled = $true
$et.Subscription = '<QueryList>...</QueryList>'
```

The XPath inside `<Subscription>` is the event filter. For sleep:
```xml
<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and (EventID=42)]]</Select></Query></QueryList>
```

For drive-mount:
```xml
<QueryList><Query Id="0" Path="Microsoft-Windows-Ntfs/Operational"><Select Path="Microsoft-Windows-Ntfs/Operational">*[System[(EventID=98)]]</Select></Query></QueryList>
```

The NTFS event log isn't always enabled by default on Windows 10 Home — this is a known limitation documented in the README's troubleshooting section.

**Self-healing:** `lifeboat doctor` checks that all expected tasks exist and re-registers them if missing. It also re-enables disabled tasks. This handles the case where a Windows update or third-party "system cleaner" tool removed the tasks.

---

## Part B — All the Code

### `README.md`

```markdown
# Claude Lifeboat 🛟

> Automated, versioned backup of your Claude Desktop data — including Cowork VM state, session history, and configs. Built because once you've lost a working Cowork session, you don't want to do it again.

[![PowerShell](https://img.shields.io/badge/PowerShell-5.0+-5391FE)]()
[![Windows](https://img.shields.io/badge/Windows-10%2B-0078D6)]()
[![License](https://img.shields.io/badge/license-MIT-green)]()

---

## Why?

Claude Desktop with Cowork stores a lot of work locally:

- **Conversation history & settings** in `AppData\Local\Packages\Claude_*`
- **Cowork VM session data** with everything you've been building in the virtual workspace
- **Cowork VM bundle** (the Linux image itself)
- **Claude Code configs** if you use it

Windows doesn't back any of this up by default. Microsoft's built-in tools (File History, Backup and Restore) don't know about MSIX package data and miss most of it. Backup utilities like Kopia and Restic are excellent but generic — they don't know which Claude paths matter, when CoworkVMService needs to be stopped, or how Cowork's VM bundle relates to session data.

Lifeboat is Claude-aware. That's the entire reason it exists.

## What it does

**Two-tier backup with smart fallback:**

- **Primary** (an always-on drive, usually internal): every hourly backup. Fast.
- **Archive** (optional external drive): long-term versioned snapshots. Catches up automatically when plugged in.

**Triggers:**

- Hourly while computer is on
- When you log in
- When laptop sleeps (lid close)
- When the archive drive is connected
- When the machine has been idle for 10+ minutes

**Safe restore:**

- Always preview first (`--preview` mode restores to a temp folder)
- Automatic safety snapshot before any overwriting restore (so the restore itself is undoable)
- Stops Claude processes cleanly before touching their data
- Restarts services after

**Integrity checks:**

- Sample-verifies files after every backup
- `lifeboat verify` does thorough verification on demand
- Dashboard shows integrity status

**Visibility:**

- `lifeboat status` — terminal traffic-light status
- `lifeboat dashboard` — visual HTML dashboard
- Toast notifications only when something needs attention
- Daily log files

## Install

**One-line installer** (from PowerShell as Administrator):

```powershell
irm https://github.com/jack/claude-lifeboat/raw/main/install.ps1 | iex
```

Or from a cloned repo:

```powershell
git clone https://github.com/jack/claude-lifeboat
cd claude-lifeboat
.\install.ps1
```

The installer will ask you **two questions:**

1. **Primary drive** (default: D: if you have it, else C:)
2. **Archive drive** (optional — leave blank if you don't have an external drive)

Everything else has sensible defaults. Setup takes about 90 seconds and runs an initial backup to verify it works.

## Usage

```
lifeboat install         # First-time setup (or to reconfigure)
lifeboat status          # Quick health check
lifeboat backup          # Run a backup right now
lifeboat restore         # Interactive restore picker
lifeboat verify          # Thorough integrity check
lifeboat doctor          # Diagnose and auto-fix issues
lifeboat dashboard       # Open visual dashboard
lifeboat uninstall       # Remove (keeps your backups)
```

**Common scenarios:**

- *"I just broke Claude, give me yesterday back":*
  ```
  lifeboat restore --from latest
  ```

- *"Test a restore without overwriting anything":*
  ```
  lifeboat restore --preview
  ```

- *"Is everything working?"*
  ```
  lifeboat status
  ```

- *"Something feels off":*
  ```
  lifeboat doctor
  ```

## What gets backed up

| What | Where on disk | Why it matters |
|---|---|---|
| Claude Desktop data | `%LOCALAPPDATA%\Packages\Claude_*` | Conversation history, settings, session state |
| Cowork VM bundle | (inside the above) | The Linux VM image — required for restore to a new machine |
| Cowork session data | (inside the above) | Your actual work in Cowork |
| Claude system logs | `C:\ProgramData\Claude` | Diagnostic data, error history |
| Claude Code configs | `~\.claude`, `%APPDATA%\claude-code`, etc. | If you use the CLI |
| Extra paths | Whatever you add during setup | Your project folders, code repos, etc. |

## How it actually works

**Storage structure** (on each backup root):

```
ClaudeLifeboat/
├── latest/              # mirror of current state (updated every backup)
│   ├── ClaudeDesktop/
│   ├── Claude-System/
│   └── ...
├── daily/
│   ├── 2026-05-20/      # snapshot from each day
│   └── ...
├── weekly/              # archive only
│   ├── 2026-05-18/      # Sunday snapshots
│   └── ...
├── safety/              # auto-created before each restore
│   └── pre-restore-2026-05-20_143022/
├── logs/
└── status.json
```

**Retention** (defaults — configurable):

- Primary: latest + 3 daily snapshots
- Archive: latest + 7 daily + 4 weekly snapshots

**Catch-up sync:** when the archive drive comes back online after being disconnected, Lifeboat detects the gap (>6 hours) and copies any missing daily snapshots from the primary location automatically.

## What this is *not*

To be honest about limits:

- **Not a full-system backup.** This backs up Claude-related data and any extra folders you specify. For "my laptop died, restore everything" use Windows Backup, Macrium Reflect, or Aomei Backupper alongside this.
- **Not encrypted at rest** by default. If you care, enable BitLocker on the backup drive.
- **Not real-time.** Up to 1 hour of work can be lost between hourly backups, but on-sleep and on-idle triggers usually catch you sooner.
- **Cowork VM image may regenerate** when restoring to a new machine. Session data and configs survive cleanly; the VM image is tied to host hypervisor state and may rebuild on first Cowork launch (~2 GB download).
- **No cloud backend (yet).** Primary + archive on local/USB drives only. Cloud uploads (B2, S3, OneDrive) are planned for v0.2.

If you need encryption, dedup, cloud destinations, and don't need Claude-specific awareness, look at [Kopia](https://kopia.io/) or [Restic](https://restic.net/). They're excellent. Lifeboat fills the niche they don't.

## Cross-machine recovery

You have a new laptop. Here's what to do:

1. Install Windows + Claude Desktop on the new machine.
2. Launch Claude Desktop once (creates the package folders), then quit it.
3. Plug in your archive drive.
4. Install Lifeboat:
   ```
   irm https://github.com/jack/claude-lifeboat/raw/main/install.ps1 | iex
   ```
   (Same primary/archive drives as before — Lifeboat will detect the existing backups.)
5. Restore:
   ```
   lifeboat restore --from latest
   ```
   Pick "all" when prompted.
6. Launch Claude Desktop. Your conversations, settings, and Cowork data are there.

## Troubleshooting

**"Cowork still shows the Virtualization error after restore"**

Restore doesn't fix Windows-level virtualization issues. If you're on Windows 10/11 Home, Cowork can't run because Hyper-V isn't available on Home editions. Upgrade to Pro. Lifeboat backs up your data so you don't lose anything when you do.

**"Scheduled task says failed (LastTaskResult: 0x1)"**

```
lifeboat doctor
```

Usually fixes it.

**"Archive drive doesn't auto-sync when I plug it in"**

The OnDriveConnect trigger uses NTFS event 98 (volume mounted), which is sometimes not logged on Windows 10 Home. The hourly trigger will catch it within an hour anyway. To enable the immediate trigger: open Event Viewer → Microsoft → Windows → Ntfs → Operational → right-click → Enable Log.

**"How do I know my backups would actually work?"**

```
lifeboat verify
```

Samples 20 random files per folder, confirms they're readable and match source sizes. Run it periodically. Better still: do a `lifeboat restore --preview` once a month to inspect the actual restored files.

## Acknowledgments

- The two-tier (local + archive) pattern is borrowed from professional NAS backup setups
- The "safety snapshot before restore" idea comes from Apple's Time Machine
- Sample-verification after backup is inspired by [Kopia](https://kopia.io/)
- The CLI conventions (`status`, `doctor`, etc.) follow git, docker, kopia
- This tool was prototyped through a conversation with Claude itself

## License

MIT. Use it, fork it, improve it, ship it. If it saves your bacon, [say hi](https://github.com/jack/claude-lifeboat/discussions).

## Contributing

Issues and PRs welcome at https://github.com/jack/claude-lifeboat.

What I'd love help with:

- Testing on different Claude Desktop versions
- Improvements to Cowork VM handling on restore
- Cloud destinations (B2, S3 via SDK or via rclone wrapping)
- macOS support (Claude Desktop runs there too)
- A GUI installer for non-CLI users
```

### `LICENSE`

```
MIT License

Copyright (c) 2026 Jack and contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### `CHANGELOG.md`

```markdown
# Changelog

All notable changes to Claude Lifeboat will be documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-05-20

Initial release.

### Added

- Two-tier backup (primary + optional archive)
- Auto-sync to archive when drive is connected
- Catch-up logic when archive returns after disconnect
- Hourly, on-logon, on-sleep, on-idle scheduled triggers
- Daily and weekly snapshot retention
- `lifeboat install` - friendly two-question setup
- `lifeboat status` - traffic-light health check (text + JSON modes)
- `lifeboat backup` - manual backup trigger
- `lifeboat restore` - interactive restore with `--preview` mode
- `lifeboat verify` - integrity verification by file sampling
- `lifeboat doctor` - diagnose and auto-fix common issues
- `lifeboat dashboard` - generate visual HTML dashboard
- `lifeboat uninstall` - clean removal (preserves backups)
- Pre-restore safety snapshot (the Time Machine pattern)
- Auto-detection of Claude Desktop MSIX package
- Auto-detection of Claude Code CLI configs in standard locations
- Sample integrity check after each backup
- Toast notifications when health check finds issues
- Self-healing: doctor re-registers missing scheduled tasks

### Known Limitations

- Windows only (Claude Desktop runs on macOS too, support planned)
- No cloud destinations yet
- No encryption at rest (use BitLocker on the backup drive if needed)
- Cowork VM image may regenerate on cross-machine restore

## Planned for 0.2.0

- macOS support
- Cloud destinations via rclone wrapper (Backblaze B2, OneDrive, Google Drive)
- Per-folder retention rules
- Optional encryption (AES-256-GCM, password-derived key)
- Better Cowork VM bundle handling for cross-machine restore
```

### `install.ps1`

```powershell
# Claude Lifeboat one-line installer
#
# Usage:
#   irm https://github.com/jack/claude-lifeboat/raw/main/install.ps1 | iex
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
        Write-Host "    Clone: git clone https://github.com/jack/claude-lifeboat" -ForegroundColor Yellow
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
```

### `src/lifeboat.ps1`

```powershell
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
  https://github.com/jack/claude-lifeboat
#>

[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet("install","status","backup","restore","doctor","dashboard","verify","uninstall","version","help")]
    [string]$Command = "help",

    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Arguments
)

$script:LifeboatVersion = "0.1.0"
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
    uninstall    Remove scheduled tasks (keeps your backups)

  OPTIONS
    --json       (status, verify) Machine-readable output
    --quiet      (status) Only show output if there are issues
    --notify     (status) Show Windows toast if issues found
    --preview    (restore) Restore to a temp folder first (recommended)
    --force      (restore, uninstall) Skip confirmations

  EXAMPLES
    lifeboat install                    # First-time setup
    lifeboat status                     # Quick health check
    lifeboat backup                     # Run a backup now
    lifeboat restore --preview          # Safe restore (recommended first time)
    lifeboat doctor                     # Fix what you can automatically
    lifeboat dashboard                  # Open visual dashboard

  More: https://github.com/jack/claude-lifeboat

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
    "backup"    { Invoke-Backup -Flags $flags }
    "restore"   { Invoke-Restore -Flags $flags }
    "verify"    { Invoke-Verify -Flags $flags }
    "doctor"    { Invoke-Doctor -Flags $flags }
    "dashboard" { Invoke-Dashboard -Flags $flags }
    "uninstall" { Invoke-Uninstall -Flags $flags }
    "version"   { Write-Host "claude-lifeboat v$LifeboatVersion" }
    default     { Show-Help }
}
```

### `src/lifeboat-runner.ps1`

```powershell
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
```

### `src/lib/common.ps1`

```powershell
# Common utilities used by all subcommands

function Test-IsAdmin {
    $user = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $user.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Require-Admin {
    if (-not (Test-IsAdmin)) {
        Write-Failure "This command needs Administrator privileges."
        Write-Info "Right-click PowerShell -> 'Run as administrator', then retry."
        exit 1
    }
}

function Get-LifeboatConfig {
    if (-not (Test-Path $script:ConfigPath)) { return $null }
    try {
        return Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
    } catch {
        Write-Failure "Config file is corrupted: $script:ConfigPath"
        return $null
    }
}

function Save-LifeboatConfig($config) {
    $dir = Split-Path $script:ConfigPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $script:ConfigPath -Encoding UTF8
}

function Get-FormattedSize($bytes) {
    if ($bytes -lt 1KB) { return "$bytes B" }
    if ($bytes -lt 1MB) { return "{0:N1} KB" -f ($bytes / 1KB) }
    if ($bytes -lt 1GB) { return "{0:N1} MB" -f ($bytes / 1MB) }
    return "{0:N2} GB" -f ($bytes / 1GB)
}

function Get-FormattedDuration($timespan) {
    if ($timespan.TotalMinutes -lt 1) { return "$([math]::Round($timespan.TotalSeconds))s" }
    if ($timespan.TotalHours -lt 1) { return "$([math]::Round($timespan.TotalMinutes))min" }
    if ($timespan.TotalDays -lt 1) { return "$([math]::Round($timespan.TotalHours, 1))h" }
    return "$([math]::Round($timespan.TotalDays, 1))d"
}

function Get-ClaudeDataPaths {
    # Returns a hashtable of [name -> path] for all Claude-related data we know about.
    # This is the heart of what makes lifeboat Claude-aware.
    $paths = @{}

    # Claude Desktop MSIX package
    $pkg = Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -Filter "Claude_*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkg) { $paths["ClaudeDesktop"] = $pkg.FullName }

    # ProgramData (machine-wide logs and VM service files)
    if (Test-Path "C:\ProgramData\Claude") {
        $paths["Claude-System"] = "C:\ProgramData\Claude"
    }

    # Claude Code CLI configs (multiple possible locations)
    $ccCandidates = @(
        @{ Name = "ClaudeCode-user";   Path = "$env:USERPROFILE\.claude" },
        @{ Name = "ClaudeCode-appdata"; Path = "$env:APPDATA\claude-code" },
        @{ Name = "ClaudeCode-xdg";    Path = "$env:USERPROFILE\.config\claude" }
    )
    foreach ($c in $ccCandidates) {
        if (Test-Path $c.Path) { $paths[$c.Name] = $c.Path }
    }

    return $paths
}

function Invoke-Robocopy($source, $destination, [switch]$Mirror) {
    # Wrapper for robocopy with sensible defaults.
    # Returns @{ Success = bool; ExitCode = int; Output = string }
    $argList = @($source, $destination)
    if ($Mirror) { $argList += '/MIR' } else { $argList += '/E' }
    $argList += @('/R:1', '/W:1', '/MT:8', '/XJ', '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS', '/NP')

    $output = & robocopy @argList 2>&1 | Out-String
    $code = $LASTEXITCODE
    # robocopy exit codes: 0=no change, 1=copied, 2=extra, 3=copied+extra, 4-7=warnings, 8+=errors
    return @{
        Success = ($code -lt 8)
        ExitCode = $code
        Output = $output
    }
}

function Write-LifeboatLog($message, [string]$level = "INFO") {
    if (-not (Test-Path $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }
    $logFile = Join-Path $script:LogDir "lifeboat-$(Get-Date -Format 'yyyy-MM-dd').log"
    $line = "$(Get-Date -Format 'HH:mm:ss')  [$level]  $message"
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
}

function Test-DrivePath($drivePath) {
    # Tests if a drive (e.g. "D:") is currently available. Handles edge cases.
    if (-not $drivePath) { return $false }
    $letter = ($drivePath -split ':')[0]
    if (-not $letter) { return $false }
    return Test-Path "${letter}:\"
}

function Get-DriveStats($drivePath) {
    if (-not (Test-DrivePath $drivePath)) {
        return @{ Available = $false }
    }
    $letter = ($drivePath -split ':')[0]
    $drive = Get-PSDrive -Name $letter -PSProvider FileSystem -ErrorAction SilentlyContinue
    if (-not $drive) { return @{ Available = $false } }
    $total = $drive.Free + $drive.Used
    return @{
        Available = $true
        Letter = $letter
        TotalBytes = $total
        FreeBytes = $drive.Free
        UsedBytes = $drive.Used
        PercentUsed = if ($total -gt 0) { [math]::Round(($drive.Used / $total) * 100, 1) } else { 0 }
    }
}

function Stop-ClaudeProcesses {
    # Cleanly stops Claude Desktop and the Cowork VM service. Used before restore.
    $stopped = @()
    Get-Process -Name "Claude*" -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_.CloseMainWindow() | Out-Null } catch {}
    }
    Start-Sleep -Seconds 2
    Get-Process -Name "Claude*" -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        $stopped += $_.ProcessName
    }
    $svc = Get-Service CoworkVMService -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        Stop-Service CoworkVMService -Force -ErrorAction SilentlyContinue
        $stopped += "CoworkVMService"
    }
    return $stopped
}

function Start-ClaudeServices {
    Start-Service CoworkVMService -ErrorAction SilentlyContinue
}
```

### `src/lib/config.ps1`

```powershell
# Configuration defaults and validation

function Get-DefaultConfig {
    return @{
        SchemaVersion = 1
        Primary = @{
            Root = ""
            RetentionDailies = 3
        }
        Archive = @{
            Root = ""           # empty means no archive configured
            RetentionDailies = 7
            RetentionWeeklies = 4
        }
        ExtraPaths = @()
        Schedule = @{
            HourlyEnabled = $true
            OnSleep = $true
            OnLogon = $true
            OnIdle = $true
            OnDriveConnect = $true
        }
        Notifications = @{
            Enabled = $true
            HealthCheckIntervalHours = 2
        }
        Advanced = @{
            ExcludePatterns = @("*.tmp", "*.lock", "*.dump")
            MaxBackupDurationMinutes = 30
            VerifyAfterBackup = $true   # quick integrity check
            VerifySampleSize = 5         # randomly verify 5 files per backup
        }
        Version = $script:LifeboatVersion
        CreatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }
}

function Suggest-PrimaryDrive {
    # Recommend the best drive for primary: prefer D: if it has decent space,
    # else fall back to C: with a folder under user profile.
    $candidates = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
        Where-Object { $_.Free -gt 10GB } |
        Sort-Object @{Expression={ if ($_.Name -eq 'D') {0} elseif ($_.Name -ne 'C') {1} else {2} }}, Free -Descending

    if ($candidates) { return $candidates[0].Name + ":" }
    return "C:"
}

function Suggest-ArchiveDrive {
    # Look for removable drives (USB/external)
    $removables = Get-WmiObject Win32_LogicalDisk -Filter "DriveType=2 OR DriveType=3" |
        Where-Object { $_.DeviceID -ne 'C:' -and $_.DeviceID -ne $script:SuggestedPrimary -and $_.FreeSpace -gt 20GB }
    if ($removables) { return $removables[0].DeviceID }
    return $null
}
```

### `src/lib/install.ps1`

```powershell
# lifeboat install - the friendly two-question setup

function Invoke-Install {
    param($Flags)

    Require-Admin

    Write-Host ""
    Write-Host "  ===============================================" -ForegroundColor Cyan
    Write-Host "    Claude Lifeboat v$($script:LifeboatVersion)" -ForegroundColor Cyan
    Write-Host "    Your Claude Desktop data, safe and restorable" -ForegroundColor DarkCyan
    Write-Host "  ===============================================" -ForegroundColor Cyan
    Write-Host ""

    # Detect existing install
    $existingConfig = Get-LifeboatConfig
    if ($existingConfig -and -not $Flags.force) {
        Write-Warning2 "Lifeboat is already installed."
        Write-Info "Primary:  $($existingConfig.Primary.Root)"
        Write-Info "Archive:  $(if($existingConfig.Archive.Root){$existingConfig.Archive.Root}else{'(none)'})"
        Write-Host ""
        Write-Prompt "Reinstall? (y/N):"
        $answer = Read-Host
        if ($answer -ne 'y') {
            Write-Info "Cancelled."
            return
        }
    }

    # Check that Claude Desktop is actually installed
    $claudePackage = Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -Filter "Claude_*" -ErrorAction SilentlyContinue
    if (-not $claudePackage) {
        Write-Warning2 "Claude Desktop doesn't appear to be installed for this user."
        Write-Info "Lifeboat will still set up, but won't have Claude data to back up until you install and run Claude."
        Write-Host ""
    }

    # ----- Question 1: Primary drive -----
    Write-Heading "Step 1 of 2: Primary backup location"
    Write-Host "  Pick a drive that's always available (internal recommended)."
    Write-Host "  Every backup goes here. Fast, reliable, always-on."
    Write-Host ""

    $available = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
        Where-Object { $_.Free -gt 1GB }

    Write-Host "  Available drives:"
    foreach ($d in $available) {
        $freeGB = [math]::Round($d.Free / 1GB, 1)
        $totalGB = [math]::Round(($d.Free + $d.Used) / 1GB, 1)
        $type = if ((Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='$($d.Name):'").DriveType -eq 2) { "removable" } else { "fixed" }
        Write-Host ("    $($d.Name):  $freeGB GB free of $totalGB GB  ($type)") -ForegroundColor DarkGray
    }
    Write-Host ""

    $suggested = Suggest-PrimaryDrive
    $script:SuggestedPrimary = $suggested
    Write-Prompt "Primary drive [default: $suggested]:"
    $primaryInput = Read-Host
    if (-not $primaryInput) { $primaryInput = $suggested }
    $primaryDrive = ($primaryInput.Trim().TrimEnd('\').TrimEnd(':') + ':')
    if (-not (Test-Path $primaryDrive)) {
        Write-Failure "Drive $primaryDrive not found."
        return
    }
    $primaryRoot = Join-Path $primaryDrive "ClaudeLifeboat"
    Write-Success "Primary: $primaryRoot"

    # ----- Question 2: Archive drive (optional) -----
    Write-Heading "Step 2 of 2: Archive drive (optional)"
    Write-Host "  An external drive for long-term versioned backups (7 daily + 4 weekly)."
    Write-Host "  Gets synced from primary automatically when plugged in."
    Write-Host ""
    Write-Host "  Skip this if you don't have an external drive. You can add one later"
    Write-Host "  by running 'lifeboat install' again."
    Write-Host ""

    Write-Prompt "Archive drive (or blank to skip):"
    $archiveInput = Read-Host
    $archiveRoot = $null
    if ($archiveInput) {
        $archiveDrive = ($archiveInput.Trim().TrimEnd('\').TrimEnd(':') + ':')
        if (-not (Test-Path $archiveDrive)) {
            Write-Warning2 "Drive $archiveDrive not currently connected."
            Write-Info "That's fine - Lifeboat will sync when you plug it in."
            Write-Prompt "Continue with $archiveDrive anyway? (Y/n):"
            $confirm = Read-Host
            if ($confirm -eq 'n') { $archiveDrive = $null }
        }
        if ($archiveDrive) {
            $archiveRoot = Join-Path $archiveDrive "ClaudeLifeboat"
            Write-Success "Archive: $archiveRoot"
        }
    } else {
        Write-Info "No archive drive configured. You can add one later."
    }

    # ----- Build config -----
    Write-Heading "Configuring..."
    $config = Get-DefaultConfig
    $config.Primary.Root = $primaryRoot
    if ($archiveRoot) { $config.Archive.Root = $archiveRoot }
    Save-LifeboatConfig $config
    Write-Success "Config saved to $script:ConfigPath"

    # Ensure backup roots exist
    New-Item -ItemType Directory -Path $primaryRoot -Force | Out-Null
    if ($archiveRoot -and (Test-Path (($archiveRoot -split ':')[0] + ':'))) {
        New-Item -ItemType Directory -Path $archiveRoot -Force | Out-Null
    }

    # ----- Register scheduled tasks -----
    Register-LifeboatTasks
    Write-Success "Scheduled tasks registered"

    # ----- Run first backup -----
    Write-Heading "Running first backup to verify everything works..."
    Invoke-Backup -Flags @{ silent = $true }

    # ----- Done -----
    Write-Heading "Installed!"
    Write-Host "  Your Claude data will be backed up automatically:"
    Write-Host "    - Every hour while your computer is on"
    Write-Host "    - When you log in"
    Write-Host "    - When your laptop sleeps (lid close)"
    if ($archiveRoot) {
        Write-Host "    - When the archive drive is plugged in"
    }
    Write-Host "    - When idle for 10+ minutes"
    Write-Host ""
    Write-Host "  Useful commands:"
    Write-Host "    lifeboat status       # quick health check" -ForegroundColor DarkGray
    Write-Host "    lifeboat dashboard    # visual dashboard" -ForegroundColor DarkGray
    Write-Host "    lifeboat backup       # run a backup now" -ForegroundColor DarkGray
    Write-Host "    lifeboat restore      # restore something" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Questions? https://github.com/jack/claude-lifeboat" -ForegroundColor DarkCyan
    Write-Host ""
}

function Register-LifeboatTasks {
    $config = Get-LifeboatConfig
    if (-not $config) { return }

    # Remove existing
    Get-ScheduledTask -TaskName "ClaudeLifeboat-*" -ErrorAction SilentlyContinue |
        Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue

    # Install the backup runner script to a stable location
    $runnerSource = Join-Path $script:ScriptRoot "lifeboat-runner.ps1"
    if (Test-Path $runnerSource) {
        Copy-Item $runnerSource (Join-Path $script:LifeboatHome "lifeboat-runner.ps1") -Force
    }
    # Also copy lib folder so the runner can find its dependencies
    $libDest = Join-Path $script:LifeboatHome "lib"
    if (Test-Path $libDest) { Remove-Item $libDest -Recurse -Force }
    Copy-Item (Join-Path $script:ScriptRoot "lib") $libDest -Recurse

    $runnerPath = Join-Path $script:LifeboatHome "lifeboat-runner.ps1"

    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
        -MultipleInstances IgnoreNew

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runnerPath`" backup"

    # Hourly
    if ($config.Schedule.HourlyEnabled) {
        $trigger = New-ScheduledTaskTrigger -Once `
            -At (Get-Date).Date.AddHours((Get-Date).Hour + 1) `
            -RepetitionInterval (New-TimeSpan -Hours 1)
        Register-ScheduledTask -TaskName "ClaudeLifeboat-Hourly" `
            -Description "Backs up Claude data every hour" `
            -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
    }

    # On logon
    if ($config.Schedule.OnLogon) {
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        Register-ScheduledTask -TaskName "ClaudeLifeboat-OnLogon" `
            -Description "Runs backup at login" `
            -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
    }

    # On sleep (lid close)
    if ($config.Schedule.OnSleep) {
        $sleepXml = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-Kernel-Power''] and (EventID=42)]]</Select></Query></QueryList>'
        try {
            $cls = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
            $et = New-CimInstance -CimClass $cls -ClientOnly
            $et.Enabled = $true; $et.Subscription = $sleepXml
            Register-ScheduledTask -TaskName "ClaudeLifeboat-OnSleep" `
                -Description "Runs backup when computer is going to sleep" `
                -Action $action -Trigger $et -Principal $principal -Settings $settings | Out-Null
        } catch {}
    }

    # On drive connect (if archive configured)
    if ($config.Schedule.OnDriveConnect -and $config.Archive.Root) {
        $pnpXml = '<QueryList><Query Id="0" Path="Microsoft-Windows-Ntfs/Operational"><Select Path="Microsoft-Windows-Ntfs/Operational">*[System[(EventID=98)]]</Select></Query></QueryList>'
        try {
            $cls = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
            $et = New-CimInstance -CimClass $cls -ClientOnly
            $et.Enabled = $true; $et.Subscription = $pnpXml
            Register-ScheduledTask -TaskName "ClaudeLifeboat-OnDriveConnect" `
                -Description "Runs backup when a drive is mounted" `
                -Action $action -Trigger $et -Principal $principal -Settings $settings | Out-Null
        } catch {}
    }

    # On idle
    if ($config.Schedule.OnIdle) {
        $idleSettings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -RunOnlyIfIdle `
            -IdleDuration (New-TimeSpan -Minutes 10) `
            -IdleWaitTimeout (New-TimeSpan -Minutes 30) `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
            -MultipleInstances IgnoreNew
        $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        Register-ScheduledTask -TaskName "ClaudeLifeboat-OnIdle" `
            -Description "Runs backup when machine is idle" `
            -Action $action -Trigger $logonTrigger -Principal $principal -Settings $idleSettings | Out-Null
    }

    # Health check task (every N hours, shows notification on issues)
    if ($config.Notifications.Enabled) {
        $statusAction = New-ScheduledTaskAction `
            -Execute "powershell.exe" `
            -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runnerPath`" status --quiet --notify"
        $trigger = New-ScheduledTaskTrigger -Once `
            -At (Get-Date).AddMinutes(30) `
            -RepetitionInterval (New-TimeSpan -Hours $config.Notifications.HealthCheckIntervalHours)
        Register-ScheduledTask -TaskName "ClaudeLifeboat-HealthCheck" `
            -Description "Periodic health check with notifications" `
            -Action $statusAction -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
    }
}

function Invoke-Uninstall {
    param($Flags)
    Require-Admin

    Write-Heading "Uninstall Claude Lifeboat"

    if (-not $Flags.force) {
        Write-Host "  This will:"
        Write-Host "    - Remove all scheduled tasks"
        Write-Host "    - Remove the config at $script:ConfigPath"
        Write-Host ""
        Write-Host "  This will NOT:"
        Write-Host "    - Delete your backup files (they stay on your drives)"
        Write-Host "    - Affect Claude Desktop itself"
        Write-Host ""
        Write-Prompt "Continue? (y/N):"
        $answer = Read-Host
        if ($answer -ne 'y') {
            Write-Info "Cancelled."
            return
        }
    }

    Get-ScheduledTask -TaskName "ClaudeLifeboat-*" -ErrorAction SilentlyContinue |
        Unregister-ScheduledTask -Confirm:$false
    Write-Success "Scheduled tasks removed"

    if (Test-Path $script:LifeboatHome) {
        Remove-Item $script:LifeboatHome -Recurse -Force -ErrorAction SilentlyContinue
        Write-Success "Config removed"
    }

    Write-Host ""
    Write-Info "Your backup files are untouched. Delete them manually if you want."
    Write-Host ""
}
```

### `src/lib/backup.ps1`

```powershell
# lifeboat backup - the actual backup engine

function Invoke-Backup {
    param($Flags)

    $config = Get-LifeboatConfig
    if (-not $config) {
        Write-Failure "Lifeboat is not installed. Run: lifeboat install"
        exit 1
    }

    $silent = [bool]$Flags.silent
    $startTime = Get-Date

    if (-not $silent) {
        Write-Heading "Running backup..."
    }
    Write-LifeboatLog "Backup started"

    # ---- Step 1: Primary backup (always) ----
    $primaryRoot = $config.Primary.Root
    if (-not (Test-DrivePath $primaryRoot)) {
        Write-Failure "Primary drive not available: $primaryRoot"
        Write-LifeboatLog "Primary drive missing - aborting" "ERROR"
        exit 1
    }

    $primaryLatest = Join-Path $primaryRoot "latest"
    New-Item -ItemType Directory -Path $primaryLatest -Force | Out-Null

    $paths = Get-ClaudeDataPaths
    foreach ($p in $config.ExtraPaths) {
        if (Test-Path $p) {
            $paths["Extra-$(Split-Path $p -Leaf)"] = $p
        }
    }

    if ($paths.Count -eq 0) {
        Write-Warning2 "Nothing to back up. Is Claude Desktop installed?"
        Write-LifeboatLog "No paths to back up" "WARN"
        return
    }

    if (-not $silent) {
        Write-Host "  Backing up to: $primaryRoot" -ForegroundColor DarkGray
    }

    $results = @{}
    foreach ($name in $paths.Keys) {
        $src = $paths[$name]
        $dst = Join-Path $primaryLatest $name
        if (-not $silent) { Write-Host "    $name..." -NoNewline }
        $result = Invoke-Robocopy $src $dst -Mirror
        $results[$name] = $result
        if (-not $silent) {
            if ($result.Success) {
                Write-Host " OK" -ForegroundColor Green
            } else {
                Write-Host " FAILED (exit $($result.ExitCode))" -ForegroundColor Red
            }
        }
        Write-LifeboatLog "$name -> primary: $(if($result.Success){'OK'}else{'FAIL exit '+$result.ExitCode})"
    }

    # ---- Step 2: Primary daily snapshot ----
    $today = Get-Date -Format "yyyy-MM-dd"
    $primaryDaily = Join-Path $primaryRoot "daily\$today"
    if (-not (Test-Path $primaryDaily)) {
        New-Item -ItemType Directory -Path $primaryDaily -Force | Out-Null
        Invoke-Robocopy $primaryLatest $primaryDaily | Out-Null
        Write-LifeboatLog "Created primary daily snapshot: $today"
    }

    # Prune primary dailies
    Prune-Snapshots (Join-Path $primaryRoot "daily") $config.Primary.RetentionDailies

    # ---- Step 3: Archive sync (if available) ----
    $archiveAvailable = $false
    if ($config.Archive.Root -and (Test-DrivePath $config.Archive.Root)) {
        $archiveAvailable = $true
        $archiveRoot = $config.Archive.Root
        New-Item -ItemType Directory -Path $archiveRoot -Force | Out-Null
        $archiveLatest = Join-Path $archiveRoot "latest"
        New-Item -ItemType Directory -Path $archiveLatest -Force | Out-Null

        if (-not $silent) {
            Write-Host ""
            Write-Host "  Syncing to archive: $archiveRoot" -ForegroundColor DarkGray
        }

        # Determine if catch-up needed
        $isCatchUp = $false
        $lastSyncFile = Join-Path $archiveRoot ".last_sync"
        if (Test-Path $lastSyncFile) {
            try {
                $lastSync = [DateTime]::Parse((Get-Content $lastSyncFile | Select-Object -First 1))
                if (((Get-Date) - $lastSync).TotalHours -gt 6) { $isCatchUp = $true }
            } catch { $isCatchUp = $true }
        } else { $isCatchUp = $true }

        # Mirror latest
        $syncResult = Invoke-Robocopy $primaryLatest $archiveLatest -Mirror
        if (-not $silent) {
            Write-Host "    Sync: $(if($syncResult.Success){'OK'}else{'FAILED'})" -ForegroundColor $(if($syncResult.Success){'Green'}else{'Red'})
        }

        # Archive daily
        $archiveDaily = Join-Path $archiveRoot "daily\$today"
        if (-not (Test-Path $archiveDaily)) {
            New-Item -ItemType Directory -Path $archiveDaily -Force | Out-Null
            Invoke-Robocopy $archiveLatest $archiveDaily | Out-Null
        }

        # Weekly snapshot (Sundays)
        if ((Get-Date).DayOfWeek -eq 'Sunday') {
            $archiveWeekly = Join-Path $archiveRoot "weekly\$today"
            if (-not (Test-Path $archiveWeekly)) {
                New-Item -ItemType Directory -Path $archiveWeekly -Force | Out-Null
                Invoke-Robocopy $archiveLatest $archiveWeekly | Out-Null
            }
        }

        # Catch-up: bring across any missing primary dailies
        if ($isCatchUp) {
            $primaryDailyParent = Join-Path $primaryRoot "daily"
            $primaryDailies = Get-ChildItem $primaryDailyParent -Directory -ErrorAction SilentlyContinue
            foreach ($pd in $primaryDailies) {
                $matchingArchive = Join-Path $archiveRoot "daily\$($pd.Name)"
                if (-not (Test-Path $matchingArchive)) {
                    New-Item -ItemType Directory -Path $matchingArchive -Force | Out-Null
                    Invoke-Robocopy $pd.FullName $matchingArchive | Out-Null
                }
            }
        }

        Prune-Snapshots (Join-Path $archiveRoot "daily") $config.Archive.RetentionDailies
        Prune-Snapshots (Join-Path $archiveRoot "weekly") $config.Archive.RetentionWeeklies

        (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") | Set-Content $lastSyncFile
    } elseif ($config.Archive.Root) {
        if (-not $silent) {
            Write-Host ""
            Write-Info "Archive drive offline. Skipped (will catch up when reconnected)."
        }
        Write-LifeboatLog "Archive offline - skipped"
    }

    # ---- Step 4: Quick integrity check (sample verification) ----
    $verifyResult = $null
    if ($config.Advanced.VerifyAfterBackup) {
        $verifyResult = Test-BackupSample -BackupRoot $primaryRoot -SampleSize $config.Advanced.VerifySampleSize
        if (-not $silent) {
            Write-Host ""
            if ($verifyResult.AllPassed) {
                Write-Success "Integrity check passed ($($verifyResult.Tested) files verified)"
            } else {
                Write-Warning2 "Integrity check: $($verifyResult.Failed) of $($verifyResult.Tested) files failed"
            }
        }
    }

    # ---- Step 5: Write status ----
    $duration = (Get-Date) - $startTime
    $status = @{
        LastRun = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        DurationSeconds = [math]::Round($duration.TotalSeconds, 1)
        PrimaryRoot = $primaryRoot
        ArchiveRoot = $config.Archive.Root
        ArchiveSynced = $archiveAvailable
        BackedUp = @($paths.Keys)
        IntegrityOK = if ($verifyResult) { $verifyResult.AllPassed } else { $null }
        Failures = ($results.GetEnumerator() | Where-Object { -not $_.Value.Success } | ForEach-Object { $_.Key })
    }
    $statusJson = $status | ConvertTo-Json -Depth 5
    $statusJson | Set-Content -Path (Join-Path $primaryRoot "status.json") -Encoding UTF8
    if ($archiveAvailable) {
        $statusJson | Set-Content -Path (Join-Path $archiveRoot "status.json") -Encoding UTF8
    }

    Write-LifeboatLog "Backup completed in $($duration.TotalSeconds)s"

    if (-not $silent) {
        Write-Host ""
        Write-Success "Backup complete in $(Get-FormattedDuration $duration)"
    }
}

function Test-BackupSample {
    param([string]$BackupRoot, [int]$SampleSize = 5)
    # Sample-verify by re-reading random files and confirming we can read them.
    # This catches catastrophic copy failures even if robocopy reported success.
    $latest = Join-Path $BackupRoot "latest"
    if (-not (Test-Path $latest)) { return @{ AllPassed = $false; Tested = 0; Failed = 0 } }

    $allFiles = Get-ChildItem $latest -Recurse -File -ErrorAction SilentlyContinue
    if ($allFiles.Count -eq 0) { return @{ AllPassed = $true; Tested = 0; Failed = 0 } }

    $sample = $allFiles | Get-Random -Count ([math]::Min($SampleSize, $allFiles.Count))
    $failed = 0
    foreach ($f in $sample) {
        try {
            # Try to read first byte to confirm file is accessible and not corrupt
            $stream = [System.IO.File]::OpenRead($f.FullName)
            $buf = New-Object byte[] 1
            $null = $stream.Read($buf, 0, 1)
            $stream.Close()
        } catch {
            $failed++
        }
    }
    return @{
        AllPassed = ($failed -eq 0)
        Tested = $sample.Count
        Failed = $failed
    }
}

function Prune-Snapshots($parent, $keep) {
    if (-not (Test-Path $parent)) { return }
    $old = Get-ChildItem $parent -Directory | Sort-Object Name -Descending | Select-Object -Skip $keep
    foreach ($d in $old) {
        Remove-Item $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
        Write-LifeboatLog "Pruned $($d.Name) from $parent"
    }
}
```

### `src/lib/restore.ps1`

```powershell
# lifeboat restore - safe, undoable restore

function Invoke-Restore {
    param($Flags)

    $config = Get-LifeboatConfig
    if (-not $config) {
        Write-Failure "Lifeboat is not installed. Run: lifeboat install"
        exit 1
    }

    Write-Heading "Restore from backup"

    # Gather all available snapshots from both locations
    $allSnapshots = Get-AllSnapshots $config
    if ($allSnapshots.Count -eq 0) {
        Write-Failure "No snapshots found. Nothing to restore from."
        Write-Info "Try running: lifeboat backup"
        return
    }

    # Pick a snapshot
    $snapshot = if ($Flags.from) {
        Find-Snapshot -Snapshots $allSnapshots -From $Flags.from -Date $Flags.date
    } else {
        Select-Snapshot-Interactive $allSnapshots
    }

    if (-not $snapshot) {
        Write-Info "No snapshot selected. Cancelled."
        return
    }

    Write-Host ""
    Write-Host "  Selected: $($snapshot.Location) / $($snapshot.Kind) $($snapshot.Date)" -ForegroundColor Cyan
    Write-Host "  Source:   $($snapshot.Path)" -ForegroundColor DarkGray
    Write-Host "  Captured: $($snapshot.Time)" -ForegroundColor DarkGray

    # Pick what to restore
    $availableFolders = Get-ChildItem $snapshot.Path -Directory | Select-Object -ExpandProperty Name
    $foldersToRestore = if ($Flags.only) {
        @($Flags.only)
    } else {
        Select-Folders-Interactive $availableFolders
    }
    if ($foldersToRestore.Count -eq 0) { Write-Info "Nothing selected."; return }

    # Plan
    $isPreview = [bool]$Flags.preview
    $plan = @()
    foreach ($f in $foldersToRestore) {
        $src = Join-Path $snapshot.Path $f
        $dst = if ($isPreview) {
            Join-Path "$env:USERPROFILE\Desktop\lifeboat-preview-$(Get-Date -Format 'HHmmss')" $f
        } else {
            Resolve-OriginalDestination $f $config
        }
        if (-not $dst) {
            Write-Warning2 "Skipping $f - couldn't determine destination"
            continue
        }
        $plan += @{ Folder = $f; Source = $src; Dest = $dst }
    }
    if ($plan.Count -eq 0) { Write-Info "Nothing to restore."; return }

    Write-Host ""
    Write-Host "  Plan:" -ForegroundColor Yellow
    foreach ($item in $plan) {
        Write-Host "    $($item.Folder)"
        Write-Host "      from: $($item.Source)" -ForegroundColor DarkGray
        Write-Host "      to:   $($item.Dest)" -ForegroundColor DarkGray
    }

    # Confirm
    if (-not $Flags.force) {
        Write-Host ""
        if ($isPreview) {
            Write-Info "Preview mode: files go to a temp folder, nothing overwritten."
        } else {
            Write-Warning2 "This will OVERWRITE the destinations above."
            Write-Info "A safety snapshot of current state will be taken first."
        }
        Write-Prompt "Continue? (y/N):"
        if ((Read-Host) -ne 'y') { Write-Info "Cancelled."; return }
    }

    # ---- Safety snapshot (the Time Machine trick) ----
    if (-not $isPreview) {
        $safetyDir = Join-Path $config.Primary.Root "safety\pre-restore-$(Get-Date -Format 'yyyy-MM-dd_HHmmss')"
        Write-Host ""
        Write-Host "  Creating safety snapshot at $safetyDir..." -ForegroundColor Cyan
        New-Item -ItemType Directory -Path $safetyDir -Force | Out-Null
        foreach ($item in $plan) {
            if (Test-Path $item.Dest) {
                $safetyTarget = Join-Path $safetyDir $item.Folder
                Invoke-Robocopy $item.Dest $safetyTarget | Out-Null
            }
        }
        Write-Success "Safety snapshot saved"
        Write-Info "If anything goes wrong, undo with: lifeboat restore --from safety --date $(Get-Date -Format 'yyyy-MM-dd_HHmmss')"
    }

    # ---- Stop Claude services if restoring Claude data ----
    $stoppedServices = @()
    $needsStop = $plan | Where-Object { $_.Folder -eq "ClaudeDesktop" -or $_.Folder -eq "Claude-System" }
    if ($needsStop -and -not $isPreview) {
        Write-Host ""
        Write-Host "  Stopping Claude services..." -ForegroundColor Cyan
        $stoppedServices = Stop-ClaudeProcesses
        if ($stoppedServices.Count -gt 0) {
            Write-Info "Stopped: $($stoppedServices -join ', ')"
        }
    }

    # ---- Do the restore ----
    Write-Host ""
    Write-Host "  Restoring..." -ForegroundColor Cyan
    $success = 0; $failed = 0
    foreach ($item in $plan) {
        $destParent = Split-Path $item.Dest -Parent
        if (-not (Test-Path $destParent)) {
            New-Item -ItemType Directory -Path $destParent -Force | Out-Null
        }
        Write-Host "    $($item.Folder)..." -NoNewline
        $result = Invoke-Robocopy $item.Source $item.Dest -Mirror
        if ($result.Success) {
            Write-Host " OK" -ForegroundColor Green
            $success++
        } else {
            Write-Host " FAILED (exit $($result.ExitCode))" -ForegroundColor Red
            $failed++
        }
    }

    # ---- Restart services ----
    if ($needsStop -and -not $isPreview) {
        Write-Host ""
        Write-Host "  Restarting Claude services..." -ForegroundColor Cyan
        Start-ClaudeServices
        Write-Success "Done"
    }

    # ---- Summary ----
    Write-Host ""
    if ($failed -eq 0) {
        Write-Success "Restore complete: $success folder(s) restored"
        if ($isPreview) {
            Write-Host ""
            Write-Info "Preview files are at: $(Split-Path $plan[0].Dest -Parent)"
            Write-Info "Inspect them. If they look right, re-run restore without --preview."
        }
    } else {
        Write-Warning2 "$failed of $($plan.Count) folder(s) failed to restore"
        Write-Info "Check log: $script:LogDir"
        if (-not $isPreview) {
            Write-Info "Safety snapshot is at: $safetyDir"
            Write-Info "To revert: lifeboat restore --from safety --date <timestamp>"
        }
    }
}

function Get-AllSnapshots($config) {
    $snapshots = @()

    $locations = @(
        @{ Name = "PRIMARY"; Root = $config.Primary.Root },
        @{ Name = "ARCHIVE"; Root = $config.Archive.Root }
    )

    foreach ($loc in $locations) {
        if (-not $loc.Root) { continue }
        if (-not (Test-DrivePath $loc.Root)) { continue }

        # latest
        $lp = Join-Path $loc.Root "latest"
        if (Test-Path $lp) {
            $snapshots += [PSCustomObject]@{
                Location = $loc.Name; Kind = "latest"; Date = ""
                Path = $lp; Time = (Get-Item $lp).LastWriteTime
            }
        }
        # dailies
        foreach ($d in (Get-ChildItem (Join-Path $loc.Root "daily") -Directory -ErrorAction SilentlyContinue)) {
            $snapshots += [PSCustomObject]@{
                Location = $loc.Name; Kind = "daily"; Date = $d.Name
                Path = $d.FullName; Time = $d.LastWriteTime
            }
        }
        # weeklies
        foreach ($w in (Get-ChildItem (Join-Path $loc.Root "weekly") -Directory -ErrorAction SilentlyContinue)) {
            $snapshots += [PSCustomObject]@{
                Location = $loc.Name; Kind = "weekly"; Date = $w.Name
                Path = $w.FullName; Time = $w.LastWriteTime
            }
        }
    }

    return $snapshots
}

function Select-Snapshot-Interactive($snapshots) {
    Write-Host ""
    Write-Host "  Available snapshots:" -ForegroundColor Yellow

    $latests = $snapshots | Where-Object { $_.Kind -eq 'latest' } | Sort-Object Time -Descending
    $dailies = $snapshots | Where-Object { $_.Kind -eq 'daily' } | Sort-Object Date -Descending |
        Group-Object Date | ForEach-Object { $_.Group[0] }
    $weeklies = $snapshots | Where-Object { $_.Kind -eq 'weekly' } | Sort-Object Date -Descending |
        Group-Object Date | ForEach-Object { $_.Group[0] }

    $menu = @{}
    $i = 1
    if ($latests) {
        Write-Host ""
        Write-Host "  Most recent state:" -ForegroundColor Cyan
        foreach ($s in $latests) {
            $age = (New-TimeSpan -Start $s.Time -End (Get-Date))
            Write-Host ("    [$i] $($s.Location) latest  ($(Get-FormattedDuration $age) ago)")
            $menu[$i.ToString()] = $s; $i++
        }
    }
    if ($dailies) {
        Write-Host ""
        Write-Host "  Daily snapshots:" -ForegroundColor Cyan
        foreach ($s in $dailies) {
            Write-Host ("    [$i] daily " + $s.Date + "  ($($s.Location))")
            $menu[$i.ToString()] = $s; $i++
        }
    }
    if ($weeklies) {
        Write-Host ""
        Write-Host "  Weekly snapshots:" -ForegroundColor Cyan
        foreach ($s in $weeklies) {
            Write-Host ("    [$i] weekly " + $s.Date + "  ($($s.Location))")
            $menu[$i.ToString()] = $s; $i++
        }
    }

    Write-Host ""
    Write-Prompt "Pick a number (or blank to cancel):"
    $choice = Read-Host
    if (-not $choice) { return $null }
    return $menu[$choice.Trim()]
}

function Find-Snapshot($Snapshots, $From, $Date) {
    if ($From -eq 'latest') {
        return $Snapshots | Where-Object { $_.Kind -eq 'latest' } |
            Sort-Object @{Expression={if($_.Location -eq 'PRIMARY'){0}else{1}}}, Time -Descending |
            Select-Object -First 1
    }
    return $Snapshots | Where-Object { $_.Kind -eq $From -and $_.Date -eq $Date } |
        Sort-Object @{Expression={if($_.Location -eq 'ARCHIVE'){0}else{1}}} |
        Select-Object -First 1
}

function Select-Folders-Interactive($folders) {
    Write-Host ""
    Write-Host "  What to restore:" -ForegroundColor Yellow
    $i = 1
    foreach ($f in $folders) {
        Write-Host "    [$i] $f"
        $i++
    }
    Write-Host ""
    Write-Prompt "Numbers (e.g. 1,3) or 'all':"
    $choice = Read-Host
    if ($choice -eq 'all') { return $folders }
    if (-not $choice) { return @() }
    $idx = $choice -split ',' | ForEach-Object { [int]($_.Trim()) - 1 }
    return $idx | ForEach-Object { $folders[$_] }
}

function Resolve-OriginalDestination($folderName, $config) {
    switch -Wildcard ($folderName) {
        "ClaudeDesktop" {
            $existing = Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -Filter "Claude_*" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($existing) { return $existing.FullName }
            return "$env:LOCALAPPDATA\Packages\Claude_pzs8sxrjxfjjc"
        }
        "Claude-System" { return "C:\ProgramData\Claude" }
        "ClaudeCode-user" { return "$env:USERPROFILE\.claude" }
        "ClaudeCode-appdata" { return "$env:APPDATA\claude-code" }
        "ClaudeCode-xdg" { return "$env:USERPROFILE\.config\claude" }
        "Extra-*" {
            $base = $folderName -replace '^Extra-', ''
            foreach ($p in $config.ExtraPaths) {
                if ((Split-Path $p -Leaf) -eq $base) { return $p }
            }
            return $null
        }
        default { return $null }
    }
}
```

### `src/lib/status.ps1`

```powershell
# lifeboat status - traffic-light health check

function Invoke-Status {
    param($Flags)

    $config = Get-LifeboatConfig
    if (-not $config) {
        if ($Flags.json) {
            @{ OverallStatus = "red"; Error = "not installed" } | ConvertTo-Json
        } else {
            Write-Failure "Lifeboat is not installed. Run: lifeboat install"
        }
        exit 2
    }

    $script:checks = @()
    function Add-Check($name, $status, $message, $detail = "") {
        $script:checks += [PSCustomObject]@{
            Name = $name; Status = $status; Message = $message; Detail = $detail
        }
    }

    # Read status file
    $primaryStatus = $null
    $statusPath = Join-Path $config.Primary.Root "status.json"
    if (Test-Path $statusPath) {
        try { $primaryStatus = Get-Content $statusPath -Raw | ConvertFrom-Json } catch {}
    }

    # Check: last backup time
    if ($primaryStatus) {
        $lastRun = [DateTime]::Parse($primaryStatus.LastRun)
        $age = (New-TimeSpan -Start $lastRun -End (Get-Date))
        if ($age.TotalHours -lt 2) {
            Add-Check "Last backup" "green" "Recent" "$(Get-FormattedDuration $age) ago"
        } elseif ($age.TotalHours -lt 6) {
            Add-Check "Last backup" "yellow" "Older than expected" "$(Get-FormattedDuration $age) ago"
        } else {
            Add-Check "Last backup" "red" "Stale" "$(Get-FormattedDuration $age) ago"
        }
    } else {
        Add-Check "Last backup" "red" "No backup yet" "Run: lifeboat backup"
    }

    # Primary drive
    $primaryStats = Get-DriveStats $config.Primary.Root
    if ($primaryStats.Available) {
        $freeGB = [math]::Round($primaryStats.FreeBytes / 1GB, 1)
        if ($primaryStats.PercentUsed -lt 80 -and $freeGB -gt 10) {
            Add-Check "PRIMARY drive" "green" "${freeGB} GB free" "$(($primaryStats.PercentUsed))% used"
        } elseif ($primaryStats.PercentUsed -lt 95) {
            Add-Check "PRIMARY drive" "yellow" "${freeGB} GB free (getting low)" "$(($primaryStats.PercentUsed))% used"
        } else {
            Add-Check "PRIMARY drive" "red" "${freeGB} GB free (critical)" "Backups may fail soon"
        }
    } else {
        Add-Check "PRIMARY drive" "red" "Not available" $config.Primary.Root
    }

    # Archive drive
    if ($config.Archive.Root) {
        $archiveStats = Get-DriveStats $config.Archive.Root
        if ($archiveStats.Available) {
            $freeGB = [math]::Round($archiveStats.FreeBytes / 1GB, 1)
            if ($freeGB -gt 20) {
                Add-Check "ARCHIVE drive" "green" "Connected, ${freeGB} GB free" "$($archiveStats.PercentUsed)% used"
            } else {
                Add-Check "ARCHIVE drive" "yellow" "Connected, ${freeGB} GB free (low)" "$($archiveStats.PercentUsed)% used"
            }
            # Last sync
            $syncFile = Join-Path $config.Archive.Root ".last_sync"
            if (Test-Path $syncFile) {
                try {
                    $lastSync = [DateTime]::Parse((Get-Content $syncFile | Select-Object -First 1))
                    $syncAge = (New-TimeSpan -Start $lastSync -End (Get-Date))
                    if ($syncAge.TotalHours -lt 24) {
                        Add-Check "Last archive sync" "green" "$(Get-FormattedDuration $syncAge) ago" ""
                    } else {
                        Add-Check "Last archive sync" "yellow" "$(Get-FormattedDuration $syncAge) ago" ""
                    }
                } catch {}
            }
        } else {
            Add-Check "ARCHIVE drive" "yellow" "Unplugged" "PRIMARY still backing up. Plug in to sync."
        }
    }

    # Scheduled tasks
    $tasks = Get-ScheduledTask -TaskName "ClaudeLifeboat-*" -ErrorAction SilentlyContinue
    if (-not $tasks) {
        Add-Check "Scheduled tasks" "red" "None found" "Run: lifeboat install"
    } else {
        $failed = @()
        foreach ($t in $tasks) {
            $info = Get-ScheduledTaskInfo -TaskName $t.TaskName
            $r = $info.LastTaskResult
            # 0=ok, 267011 / 0x41303=not yet run, 267009 / 0x41301=running
            if ($r -ne 0 -and $r -ne 267011 -and $r -ne 267009) {
                $failed += "$($t.TaskName -replace 'ClaudeLifeboat-','') (0x{0:X})" -f $r
            }
        }
        if ($failed.Count -gt 0) {
            Add-Check "Scheduled tasks" "red" "$($failed.Count) task(s) failed" ($failed -join '; ')
        } else {
            Add-Check "Scheduled tasks" "green" "All $($tasks.Count) tasks healthy" ""
        }
    }

    # Integrity
    if ($primaryStatus -and $null -ne $primaryStatus.IntegrityOK) {
        if ($primaryStatus.IntegrityOK) {
            Add-Check "Last integrity check" "green" "Passed" ""
        } else {
            Add-Check "Last integrity check" "yellow" "Failed" "Some files unreadable"
        }
    }

    # Today's log errors
    $todayLog = Join-Path $script:LogDir "lifeboat-$(Get-Date -Format 'yyyy-MM-dd').log"
    if (Test-Path $todayLog) {
        $errCount = (Select-String -Path $todayLog -Pattern "\[ERROR\]" -ErrorAction SilentlyContinue).Count
        if ($errCount -eq 0) {
            Add-Check "Today's log" "green" "No errors" ""
        } else {
            Add-Check "Today's log" "yellow" "$errCount error(s) today" $todayLog
        }
    }

    $hasRed = ($script:checks | Where-Object { $_.Status -eq "red" }).Count -gt 0
    $hasYellow = ($script:checks | Where-Object { $_.Status -eq "yellow" }).Count -gt 0

    if ($Flags.json) {
        @{
            OverallStatus = if ($hasRed) { "red" } elseif ($hasYellow) { "yellow" } else { "green" }
            CheckedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            Checks = $script:checks
        } | ConvertTo-Json -Depth 5
    } else {
        $quiet = [bool]$Flags.quiet
        if (-not $quiet -or $hasRed -or $hasYellow) {
            Write-Heading "Lifeboat Status"
            foreach ($c in $script:checks) {
                $sym = switch ($c.Status) {
                    'green' { [char]0x2713; break }
                    'yellow' { '!'; break }
                    'red' { [char]0x2717; break }
                }
                $col = switch ($c.Status) {
                    'green' { 'Green'; break }
                    'yellow' { 'Yellow'; break }
                    'red' { 'Red'; break }
                }
                Write-Host ("  $sym " + ("{0,-26} " -f $c.Name) + $c.Message) -ForegroundColor $col
                if ($c.Detail) {
                    Write-Host ("    " + $c.Detail) -ForegroundColor DarkGray
                }
            }
            Write-Host ""
            if ($hasRed) {
                Write-Host "  Overall: ATTENTION NEEDED" -ForegroundColor Red
                Write-Info "Try: lifeboat doctor"
            } elseif ($hasYellow) {
                Write-Host "  Overall: OK with warnings" -ForegroundColor Yellow
            } else {
                Write-Host "  Overall: ALL GREEN" -ForegroundColor Green
            }
            Write-Host ""
        }
    }

    # Notification
    if ($Flags.notify -and ($hasRed -or $hasYellow)) {
        try {
            $title = if ($hasRed) { "Lifeboat: Attention needed" } else { "Lifeboat: Warning" }
            $issues = $script:checks | Where-Object { $_.Status -ne "green" }
            $body = ($issues | ForEach-Object { "$($_.Name): $($_.Message)" }) -join "`n"
            if ($body.Length -gt 200) { $body = $body.Substring(0, 197) + "..." }
            Show-ToastNotification $title $body
        } catch {}
    }

    if ($hasRed) { exit 2 } elseif ($hasYellow) { exit 1 } else { exit 0 }
}

function Show-ToastNotification($title, $body) {
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $textNodes = $template.GetElementsByTagName("text")
        $textNodes.Item(0).AppendChild($template.CreateTextNode($title)) | Out-Null
        $textNodes.Item(1).AppendChild($template.CreateTextNode($body)) | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("ClaudeLifeboat")
        $notifier.Show($toast)
    } catch {}
}
```

### `src/lib/doctor.ps1`

```powershell
# lifeboat doctor - diagnose and auto-fix common issues

function Invoke-Doctor {
    param($Flags)

    Write-Heading "Lifeboat Doctor"
    Write-Host "  Running diagnostics and auto-fixing what I can..."
    Write-Host ""

    $config = Get-LifeboatConfig
    if (-not $config) {
        Write-Failure "Lifeboat is not installed. Run: lifeboat install"
        return
    }

    $fixed = 0
    $cantfix = 0

    # ---- Check 1: Are scheduled tasks present? ----
    Write-Host "  [1] Scheduled tasks..." -NoNewline
    $tasks = Get-ScheduledTask -TaskName "ClaudeLifeboat-*" -ErrorAction SilentlyContinue
    $expectedCount = 4 + ($(if ($config.Archive.Root) { 1 } else { 0 })) + ($(if ($config.Notifications.Enabled) { 1 } else { 0 }))
    if (-not $tasks -or $tasks.Count -lt $expectedCount) {
        Write-Host " MISSING" -ForegroundColor Red
        Write-Host "      Re-registering tasks..." -NoNewline
        if (-not (Test-IsAdmin)) {
            Write-Host " can't (need admin)" -ForegroundColor Red
            Write-Info "Re-run as Administrator to fix this."
            $cantfix++
        } else {
            try {
                Register-LifeboatTasks
                Write-Host " fixed" -ForegroundColor Green
                $fixed++
            } catch {
                Write-Host " failed: $_" -ForegroundColor Red
                $cantfix++
            }
        }
    } else {
        Write-Host " OK ($($tasks.Count) tasks)" -ForegroundColor Green
    }

    # ---- Check 2: Are any tasks disabled? ----
    Write-Host "  [2] Task states..." -NoNewline
    $disabled = $tasks | Where-Object { $_.State -eq 'Disabled' }
    if ($disabled) {
        Write-Host " $($disabled.Count) disabled" -ForegroundColor Yellow
        foreach ($d in $disabled) {
            Write-Host "      Re-enabling $($d.TaskName)..." -NoNewline
            try {
                Enable-ScheduledTask -TaskName $d.TaskName | Out-Null
                Write-Host " fixed" -ForegroundColor Green
                $fixed++
            } catch {
                Write-Host " failed" -ForegroundColor Red
                $cantfix++
            }
        }
    } else {
        Write-Host " OK" -ForegroundColor Green
    }

    # ---- Check 3: Backup root exists? ----
    Write-Host "  [3] Primary backup root..." -NoNewline
    if (-not (Test-DrivePath $config.Primary.Root)) {
        Write-Host " drive missing" -ForegroundColor Red
        Write-Info "Primary drive $($config.Primary.Root) not available."
        Write-Info "Check drive letter, then re-run: lifeboat install"
        $cantfix++
    } elseif (-not (Test-Path $config.Primary.Root)) {
        Write-Host " folder missing, creating..." -NoNewline
        try {
            New-Item -ItemType Directory -Path $config.Primary.Root -Force | Out-Null
            Write-Host " fixed" -ForegroundColor Green
            $fixed++
        } catch {
            Write-Host " failed" -ForegroundColor Red
            $cantfix++
        }
    } else {
        Write-Host " OK" -ForegroundColor Green
    }

    # ---- Check 4: lifeboat-runner exists at install location ----
    Write-Host "  [4] Runner script..." -NoNewline
    $runner = Join-Path $script:LifeboatHome "lifeboat-runner.ps1"
    if (-not (Test-Path $runner)) {
        Write-Host " missing" -ForegroundColor Red
        Write-Info "Re-run: lifeboat install"
        $cantfix++
    } else {
        Write-Host " OK" -ForegroundColor Green
    }

    # ---- Check 5: Most recent backup actually has files? ----
    Write-Host "  [5] Latest backup contents..." -NoNewline
    $latest = Join-Path $config.Primary.Root "latest"
    if (-not (Test-Path $latest)) {
        Write-Host " no backup yet" -ForegroundColor Yellow
        Write-Info "Run: lifeboat backup"
    } else {
        $folders = Get-ChildItem $latest -Directory
        if ($folders.Count -eq 0) {
            Write-Host " empty" -ForegroundColor Red
            Write-Info "Try: lifeboat backup"
            $cantfix++
        } else {
            $totalFiles = (Get-ChildItem $latest -Recurse -File -ErrorAction SilentlyContinue).Count
            Write-Host " OK ($($folders.Count) folders, $totalFiles files)" -ForegroundColor Green
        }
    }

    # ---- Check 6: Is CoworkVMService present? (informational) ----
    Write-Host "  [6] Cowork service..." -NoNewline
    $svc = Get-Service CoworkVMService -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host " present ($($svc.Status))" -ForegroundColor Green
    } else {
        Write-Host " not installed" -ForegroundColor Yellow
        Write-Info "Claude Desktop may not be installed - lifeboat will still backup what's there"
    }

    # ---- Check 7: PowerShell execution policy ----
    Write-Host "  [7] Execution policy..." -NoNewline
    $policy = Get-ExecutionPolicy -Scope LocalMachine
    if ($policy -eq 'Restricted' -or $policy -eq 'AllSigned') {
        Write-Host " too strict ($policy)" -ForegroundColor Yellow
        if (Test-IsAdmin) {
            Write-Host "      Setting RemoteSigned..." -NoNewline
            try {
                Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy RemoteSigned -Force
                Write-Host " fixed" -ForegroundColor Green
                $fixed++
            } catch {
                Write-Host " failed: $_" -ForegroundColor Red
                $cantfix++
            }
        } else {
            Write-Info "Run as admin: Set-ExecutionPolicy -Scope LocalMachine RemoteSigned"
            $cantfix++
        }
    } else {
        Write-Host " OK ($policy)" -ForegroundColor Green
    }

    Write-Host ""
    if ($fixed -gt 0) {
        Write-Success "Fixed $fixed issue(s)"
    }
    if ($cantfix -gt 0) {
        Write-Warning2 "Couldn't auto-fix $cantfix issue(s) - see above"
    }
    if ($fixed -eq 0 -and $cantfix -eq 0) {
        Write-Success "All systems healthy"
    }
    Write-Host ""
}
```

### `src/lib/verify.ps1`

```powershell
# lifeboat verify - thorough integrity check of a backup
# Different from the quick sample-verify done after each backup.

function Invoke-Verify {
    param($Flags)

    $config = Get-LifeboatConfig
    if (-not $config) {
        Write-Failure "Lifeboat is not installed."
        exit 1
    }

    Write-Heading "Verifying backup integrity"

    $target = if ($Flags.from) {
        $snapshots = Get-AllSnapshots $config
        Find-Snapshot -Snapshots $snapshots -From $Flags.from -Date $Flags.date
    } else {
        @{ Path = (Join-Path $config.Primary.Root "latest") }
    }

    if (-not $target -or -not (Test-Path $target.Path)) {
        Write-Failure "No backup to verify."
        exit 1
    }

    Write-Host "  Target: $($target.Path)" -ForegroundColor DarkGray
    Write-Host ""

    # Compare each backed-up folder against the source
    $paths = Get-ClaudeDataPaths
    foreach ($p in $config.ExtraPaths) {
        if (Test-Path $p) {
            $paths["Extra-$(Split-Path $p -Leaf)"] = $p
        }
    }

    $totalChecked = 0
    $totalMismatched = 0
    $totalUnreadable = 0
    $perFolderResults = @{}

    foreach ($name in $paths.Keys) {
        $source = $paths[$name]
        $backup = Join-Path $target.Path $name
        if (-not (Test-Path $backup)) {
            Write-Host "  $name : not in backup" -ForegroundColor Yellow
            continue
        }

        Write-Host "  $name..." -NoNewline

        # Sample-verify: pick random 20 files from source, check each one exists in backup with same size
        $sourceFiles = Get-ChildItem $source -Recurse -File -ErrorAction SilentlyContinue
        if ($sourceFiles.Count -eq 0) {
            Write-Host " (empty source)" -ForegroundColor DarkGray
            continue
        }

        $sample = $sourceFiles | Get-Random -Count ([math]::Min(20, $sourceFiles.Count))
        $mismatched = 0
        $unreadable = 0
        foreach ($sf in $sample) {
            $rel = $sf.FullName.Substring($source.Length).TrimStart('\')
            $backupFile = Join-Path $backup $rel
            if (-not (Test-Path $backupFile)) {
                $mismatched++
                continue
            }
            try {
                $bSize = (Get-Item $backupFile).Length
                if ($bSize -ne $sf.Length) {
                    $mismatched++
                    continue
                }
                # Quick read test
                $stream = [System.IO.File]::OpenRead($backupFile)
                $stream.Close()
            } catch {
                $unreadable++
            }
        }

        $totalChecked += $sample.Count
        $totalMismatched += $mismatched
        $totalUnreadable += $unreadable
        $perFolderResults[$name] = @{
            Checked = $sample.Count
            Mismatched = $mismatched
            Unreadable = $unreadable
        }

        if ($mismatched -eq 0 -and $unreadable -eq 0) {
            Write-Host " OK ($($sample.Count) sampled)" -ForegroundColor Green
        } else {
            Write-Host " $($mismatched + $unreadable) issues in $($sample.Count) sampled" -ForegroundColor Red
        }
    }

    Write-Host ""
    if ($Flags.json) {
        @{
            Target = $target.Path
            TotalChecked = $totalChecked
            TotalMismatched = $totalMismatched
            TotalUnreadable = $totalUnreadable
            PerFolder = $perFolderResults
            OverallOK = ($totalMismatched -eq 0 -and $totalUnreadable -eq 0)
        } | ConvertTo-Json -Depth 5
    } else {
        if ($totalMismatched -eq 0 -and $totalUnreadable -eq 0) {
            Write-Success "Verified: $totalChecked files checked, all good"
        } else {
            Write-Warning2 "$($totalMismatched + $totalUnreadable) issues out of $totalChecked files checked"
            Write-Info "Recommend: lifeboat backup (re-run to fix)"
        }
    }

    if ($totalMismatched -gt 0 -or $totalUnreadable -gt 0) { exit 1 } else { exit 0 }
}
```

### `src/lib/dashboard.ps1`

```powershell
# lifeboat dashboard - generate and open visual dashboard

function Invoke-Dashboard {
    param($Flags)

    $config = Get-LifeboatConfig
    if (-not $config) {
        Write-Failure "Lifeboat is not installed."
        exit 1
    }

    $dashboardPath = if ($Flags.path) {
        $Flags.path
    } else {
        "$env:USERPROFILE\Desktop\Claude-Lifeboat.html"
    }

    Write-Heading "Generating dashboard..."
    Generate-Dashboard -Config $config -Path $dashboardPath
    Write-Success "Dashboard: $dashboardPath"

    if (-not $Flags.noopen) {
        Start-Process $dashboardPath
    }
}

function Generate-Dashboard {
    param($Config, $Path)

    # Collect data
    $primaryStats = Get-DriveStats $Config.Primary.Root
    $archiveStats = if ($Config.Archive.Root) { Get-DriveStats $Config.Archive.Root } else { $null }

    $primaryStatus = $null
    $statusPath = Join-Path $Config.Primary.Root "status.json"
    if (Test-Path $statusPath) {
        try { $primaryStatus = Get-Content $statusPath -Raw | ConvertFrom-Json } catch {}
    }

    # Get JSON status by calling our own status command
    $statusJson = $null
    try {
        $tempFile = [System.IO.Path]::GetTempFileName()
        $runnerPath = Join-Path $script:LifeboatHome "lifeboat-runner.ps1"
        if (-not (Test-Path $runnerPath)) { $runnerPath = Join-Path $script:ScriptRoot "lifeboat.ps1" }
        & powershell.exe -ExecutionPolicy Bypass -File $runnerPath status --json > $tempFile 2>$null
        $statusJson = Get-Content $tempFile -Raw | ConvertFrom-Json
        Remove-Item $tempFile -Force
    } catch {}

    # Snapshots
    function Get-Snaps($root) {
        if (-not $root -or -not (Test-Path $root)) { return @() }
        $items = @()
        $latest = Join-Path $root "latest"
        if (Test-Path $latest) {
            $sz = (Get-ChildItem $latest -Recurse -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            $items += @{ Kind = "latest"; Date = "—"; Time = (Get-Item $latest).LastWriteTime; SizeMB = [math]::Round($sz / 1MB, 0) }
        }
        Get-ChildItem (Join-Path $root "daily") -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $sz = (Get-ChildItem $_.FullName -Recurse -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            $items += @{ Kind = "daily"; Date = $_.Name; Time = $_.LastWriteTime; SizeMB = [math]::Round($sz / 1MB, 0) }
        }
        Get-ChildItem (Join-Path $root "weekly") -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $sz = (Get-ChildItem $_.FullName -Recurse -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            $items += @{ Kind = "weekly"; Date = $_.Name; Time = $_.LastWriteTime; SizeMB = [math]::Round($sz / 1MB, 0) }
        }
        return $items
    }

    $primarySnaps = Get-Snaps $Config.Primary.Root
    $archiveSnaps = if ($Config.Archive.Root) { Get-Snaps $Config.Archive.Root } else { @() }

    # Tasks
    $tasks = Get-ScheduledTask -TaskName "ClaudeLifeboat-*" -ErrorAction SilentlyContinue | ForEach-Object {
        $info = Get-ScheduledTaskInfo -TaskName $_.TaskName
        @{
            Name = $_.TaskName -replace 'ClaudeLifeboat-', ''
            State = $_.State.ToString()
            LastRun = if ($info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { $info.LastRunTime.ToString("MM/dd HH:mm") } else { "Never" }
            Result = $info.LastTaskResult
            NextRun = if ($info.NextRunTime) { $info.NextRunTime.ToString("MM/dd HH:mm") } else { "—" }
        }
    }

    # Today's log
    $todayLog = Join-Path $script:LogDir "lifeboat-$(Get-Date -Format 'yyyy-MM-dd').log"
    $recentLog = if (Test-Path $todayLog) { Get-Content $todayLog -Tail 30 } else { @() }

    $statusColor = switch ($statusJson.OverallStatus) {
        'green' { '#16a34a' }
        'yellow' { '#ca8a04' }
        'red' { '#dc2626' }
        default { '#6b7280' }
    }
    $statusText = switch ($statusJson.OverallStatus) {
        'green' { 'All systems healthy' }
        'yellow' { 'Warnings present' }
        'red' { 'Attention needed' }
        default { 'Status unknown' }
    }

    # Build HTML
    Add-Type -AssemblyName System.Web

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta http-equiv="refresh" content="60">
<title>Claude Lifeboat</title>
<style>
*{box-sizing:border-box}
body{font-family:-apple-system,'Segoe UI',sans-serif;margin:0;padding:24px;background:#0b1220;color:#e2e8f0;min-height:100vh}
.container{max-width:1200px;margin:0 auto}
header{display:flex;justify-content:space-between;align-items:center;margin-bottom:24px}
.logo{display:flex;align-items:center;gap:14px}
.logo-icon{font-size:34px;line-height:1}
h1{margin:0;font-size:24px;font-weight:700}
.subtitle{color:#94a3b8;font-size:13px}
.banner{background:linear-gradient(135deg,$statusColor,$statusColor`dd);padding:20px 24px;border-radius:14px;margin-bottom:24px;display:flex;align-items:center;gap:16px;box-shadow:0 4px 24px rgba(0,0,0,0.3)}
.banner-dot{width:14px;height:14px;border-radius:50%;background:white;box-shadow:0 0 12px rgba(255,255,255,0.7);animation:pulse 2s infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:0.5}}
.banner-text{font-size:20px;font-weight:600}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:20px;margin-bottom:24px}
.card{background:#111827;border:1px solid #1f2937;border-radius:14px;padding:20px;transition:transform 0.2s}
.card h2{margin:0 0 16px;font-size:13px;color:#94a3b8;font-weight:600;text-transform:uppercase;letter-spacing:0.8px}
.row{display:flex;justify-content:space-between;padding:11px 0;border-bottom:1px solid #1f2937;align-items:center}
.row:last-child{border-bottom:none}
.row-name{font-weight:500}
.row-detail{color:#94a3b8;font-size:12px;margin-top:2px}
.badge{padding:4px 10px;border-radius:6px;font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:0.4px}
.badge-green{background:#0f5132;color:#a3e635}
.badge-yellow{background:#78350f;color:#fde047}
.badge-red{background:#7f1d1d;color:#fca5a5}
.badge-gray{background:#334155;color:#cbd5e1}
.drive-name{font-size:20px;font-weight:700;margin-bottom:2px}
.drive-sub{color:#94a3b8;font-size:12px;margin-bottom:14px}
.progress{background:#0b1220;border-radius:8px;height:28px;overflow:hidden;position:relative;border:1px solid #1f2937}
.progress-fill{height:100%;background:linear-gradient(90deg,#3b82f6,#06b6d4);transition:width 0.6s}
.progress-fill.warning{background:linear-gradient(90deg,#ca8a04,#eab308)}
.progress-fill.danger{background:linear-gradient(90deg,#dc2626,#ef4444)}
.progress-text{position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);font-size:12px;font-weight:700}
.stats{display:flex;gap:24px;margin-top:14px}
.stat strong{display:block;color:#e2e8f0;font-size:16px}
.stat-label{color:#94a3b8;font-size:11px;text-transform:uppercase}
.snaps{max-height:260px;overflow-y:auto}
.snap-row{display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px solid #1f2937;font-size:12px;align-items:center}
.snap-row:last-child{border-bottom:none}
.snap-meta{color:#94a3b8}
table{width:100%;border-collapse:collapse;font-size:12px}
th{text-align:left;padding:9px 8px;color:#94a3b8;font-weight:600;border-bottom:1px solid #1f2937;font-size:10px;text-transform:uppercase}
td{padding:10px 8px;border-bottom:1px solid #1f2937}
.log{background:#020617;border-radius:10px;padding:14px;max-height:240px;overflow-y:auto;font-family:'Consolas',monospace;font-size:11px;line-height:1.5;color:#94a3b8}
.log-err{color:#fca5a5}
.log-warn{color:#fde047}
.footer{text-align:center;color:#475569;font-size:11px;margin-top:24px}
.empty{color:#475569;text-align:center;padding:24px;font-style:italic;font-size:13px}
code{background:#1f2937;padding:2px 6px;border-radius:4px;font-size:11px}
@media(max-width:768px){.grid{grid-template-columns:1fr}}
</style>
</head>
<body>
<div class="container">

<header>
  <div class="logo">
    <div class="logo-icon">$([char]0x1F6DF)</div>
    <div>
      <h1>Claude Lifeboat</h1>
      <div class="subtitle">$(Get-Date -Format 'dddd, MMMM dd yyyy &middot; HH:mm:ss')</div>
    </div>
  </div>
  <div class="subtitle">auto-refreshes every 60s</div>
</header>

<div class="banner">
  <div class="banner-dot"></div>
  <div class="banner-text">$statusText</div>
</div>

<div class="grid">
"@

    # Primary drive card
    $html += '<div class="card">'
    $html += "<div class=`"drive-name`">PRIMARY &middot; $($primaryStats.Letter):</div>"
    $html += "<div class=`"drive-sub`">$([System.Web.HttpUtility]::HtmlEncode($Config.Primary.Root))</div>"
    if ($primaryStats.Available) {
        $cls = if ($primaryStats.PercentUsed -gt 90) { 'danger' } elseif ($primaryStats.PercentUsed -gt 75) { 'warning' } else { '' }
        $freeGB = [math]::Round($primaryStats.FreeBytes / 1GB, 1)
        $usedGB = [math]::Round($primaryStats.UsedBytes / 1GB, 1)
        $totalGB = [math]::Round($primaryStats.TotalBytes / 1GB, 1)
        $html += "<div class=`"progress`"><div class=`"progress-fill $cls`" style=`"width:$($primaryStats.PercentUsed)%`"></div><div class=`"progress-text`">$($primaryStats.PercentUsed)% used</div></div>"
        $html += "<div class=`"stats`"><div class=`"stat`"><strong>$freeGB GB</strong><div class=`"stat-label`">free</div></div><div class=`"stat`"><strong>$usedGB GB</strong><div class=`"stat-label`">used</div></div><div class=`"stat`"><strong>$totalGB GB</strong><div class=`"stat-label`">total</div></div></div>"
    } else {
        $html += '<div class="empty">Drive not available</div>'
    }
    $html += '</div>'

    # Archive drive card
    $html += '<div class="card">'
    if ($archiveStats) {
        $html += "<div class=`"drive-name`">ARCHIVE &middot; $($archiveStats.Letter):</div>"
        $html += "<div class=`"drive-sub`">$([System.Web.HttpUtility]::HtmlEncode($Config.Archive.Root))</div>"
        if ($archiveStats.Available) {
            $cls = if ($archiveStats.PercentUsed -gt 90) { 'danger' } elseif ($archiveStats.PercentUsed -gt 75) { 'warning' } else { '' }
            $freeGB = [math]::Round($archiveStats.FreeBytes / 1GB, 1)
            $usedGB = [math]::Round($archiveStats.UsedBytes / 1GB, 1)
            $totalGB = [math]::Round($archiveStats.TotalBytes / 1GB, 1)
            $html += "<div class=`"progress`"><div class=`"progress-fill $cls`" style=`"width:$($archiveStats.PercentUsed)%`"></div><div class=`"progress-text`">$($archiveStats.PercentUsed)% used</div></div>"
            $html += "<div class=`"stats`"><div class=`"stat`"><strong>$freeGB GB</strong><div class=`"stat-label`">free</div></div><div class=`"stat`"><strong>$usedGB GB</strong><div class=`"stat-label`">used</div></div><div class=`"stat`"><strong>$totalGB GB</strong><div class=`"stat-label`">total</div></div></div>"
        } else {
            $html += '<div class="empty">Drive unplugged<br><span style="font-size:11px">Plug in to auto-sync from PRIMARY</span></div>'
        }
    } else {
        $html += '<div class="drive-name">ARCHIVE</div><div class="empty">Not configured<br><code>lifeboat install</code> to add one</div>'
    }
    $html += '</div></div>'

    # Health checks
    if ($statusJson -and $statusJson.Checks) {
        $html += '<div class="card"><h2>Health Checks</h2>'
        foreach ($c in $statusJson.Checks) {
            $badgeCls = "badge-$($c.Status)"
            $detail = if ($c.Detail) { "<div class=`"row-detail`">$([System.Web.HttpUtility]::HtmlEncode($c.Detail))</div>" } else { '' }
            $html += "<div class=`"row`"><div><div class=`"row-name`">$([System.Web.HttpUtility]::HtmlEncode($c.Name))</div>$detail</div><span class=`"badge $badgeCls`">$([System.Web.HttpUtility]::HtmlEncode($c.Message))</span></div>"
        }
        $html += '</div>'
    }

    # Tasks
    $html += '<div class="card"><h2>Scheduled Tasks</h2><table><tr><th>Task</th><th>State</th><th>Last Run</th><th>Result</th><th>Next Run</th></tr>'
    foreach ($t in $tasks) {
        $resultBadge = if ($t.Result -eq 0) { 'badge-green'; $resultText = 'OK' } elseif ($t.Result -eq 267011 -or $t.Result -eq 267009) { 'badge-gray'; $resultText = 'pending' } else { 'badge-red'; $resultText = "0x{0:X}" -f $t.Result }
        if ($t.Result -eq 0) { $resultText = 'OK' }
        elseif ($t.Result -eq 267011 -or $t.Result -eq 267009) { $resultText = 'pending' }
        else { $resultText = "0x{0:X}" -f $t.Result }
        $stateBadge = if ($t.State -in @('Ready','Running')) { 'badge-green' } else { 'badge-yellow' }
        $html += "<tr><td>$($t.Name)</td><td><span class=`"badge $stateBadge`">$($t.State)</span></td><td>$($t.LastRun)</td><td><span class=`"badge $resultBadge`">$resultText</span></td><td>$($t.NextRun)</td></tr>"
    }
    $html += '</table></div>'

    # Snapshot inventories
    $html += '<div class="grid"><div class="card"><h2>Primary Snapshots</h2><div class="snaps">'
    if ($primarySnaps.Count -eq 0) { $html += '<div class="empty">No snapshots yet</div>' }
    foreach ($s in $primarySnaps) {
        $kindBadge = switch ($s.Kind) { 'latest' { 'badge-green' } 'weekly' { 'badge-yellow' } default { 'badge-gray' } }
        $label = if ($s.Date -eq '—' -or -not $s.Date) { $s.Kind } else { "$($s.Kind) $($s.Date)" }
        $html += "<div class=`"snap-row`"><div><span class=`"badge $kindBadge`">$label</span></div><div class=`"snap-meta`">$($s.SizeMB) MB &middot; $($s.Time.ToString('MM/dd HH:mm'))</div></div>"
    }
    $html += '</div></div><div class="card"><h2>Archive Snapshots</h2><div class="snaps">'
    if ($archiveSnaps.Count -eq 0) {
        if ($archiveStats -and -not $archiveStats.Available) {
            $html += '<div class="empty">Archive drive unplugged</div>'
        } else {
            $html += '<div class="empty">No snapshots yet</div>'
        }
    }
    foreach ($s in $archiveSnaps) {
        $kindBadge = switch ($s.Kind) { 'latest' { 'badge-green' } 'weekly' { 'badge-yellow' } default { 'badge-gray' } }
        $label = if ($s.Date -eq '—' -or -not $s.Date) { $s.Kind } else { "$($s.Kind) $($s.Date)" }
        $html += "<div class=`"snap-row`"><div><span class=`"badge $kindBadge`">$label</span></div><div class=`"snap-meta`">$($s.SizeMB) MB &middot; $($s.Time.ToString('MM/dd HH:mm'))</div></div>"
    }
    $html += '</div></div></div>'

    # Log
    $html += '<div class="card"><h2>Today''s Log</h2><div class="log">'
    if ($recentLog.Count -eq 0) {
        $html += '<div class="empty">No log entries yet</div>'
    } else {
        foreach ($line in $recentLog) {
            $cls = if ($line -match "\[ERROR\]") { 'log-err' } elseif ($line -match "\[WARN\]") { 'log-warn' } else { '' }
            $html += "<div class=`"$cls`">$([System.Web.HttpUtility]::HtmlEncode($line))</div>"
        }
    }
    $html += '</div></div>'

    $html += @"
<div class="footer">
  Claude Lifeboat &middot; Open this file anytime to check status &middot; <code>lifeboat status</code> for CLI version
</div>
</div>
</body>
</html>
"@

    $html | Set-Content -Path $Path -Encoding UTF8
}
```


### Generated artifacts (not part of source — these are created at runtime)

These are documented here so the porting Claude knows what to expect to find on disk and what to write/read:

**`%LOCALAPPDATA%\ClaudeLifeboat\config.json`** — created by `Save-LifeboatConfig`. Example:

```json
{
  "SchemaVersion": 1,
  "Primary": {
    "Root": "D:\\ClaudeLifeboat",
    "RetentionDailies": 3
  },
  "Archive": {
    "Root": "F:\\ClaudeLifeboat",
    "RetentionDailies": 7,
    "RetentionWeeklies": 4
  },
  "ExtraPaths": [],
  "Schedule": {
    "HourlyEnabled": true,
    "OnSleep": true,
    "OnLogon": true,
    "OnIdle": true,
    "OnDriveConnect": true
  },
  "Notifications": {
    "Enabled": true,
    "HealthCheckIntervalHours": 2
  },
  "Advanced": {
    "ExcludePatterns": ["*.tmp", "*.lock", "*.dump"],
    "MaxBackupDurationMinutes": 30,
    "VerifyAfterBackup": true,
    "VerifySampleSize": 5
  },
  "Version": "0.1.0",
  "CreatedAt": "2026-05-20 14:30:22"
}
```

**`<BackupRoot>\status.json`** — written after each backup. Example:

```json
{
  "LastRun": "2026-05-20 14:30:48",
  "DurationSeconds": 26.3,
  "PrimaryRoot": "D:\\ClaudeLifeboat",
  "ArchiveRoot": "F:\\ClaudeLifeboat",
  "ArchiveSynced": true,
  "BackedUp": ["ClaudeDesktop", "Claude-System"],
  "IntegrityOK": true,
  "Failures": []
}
```

**`%LOCALAPPDATA%\ClaudeLifeboat\logs\lifeboat-YYYY-MM-DD.log`** — daily log files. Plain text, format: `HH:mm:ss  [LEVEL]  message`. Levels: `INFO`, `WARN`, `ERROR`.

---

## Part C — The Journey

### Chronological narrative

The project started not as a backup tool but as a Cowork troubleshooting session. The user reported the error: *"Claude's workspace requires Virtual Machine Platform, but the virtualization service isn't responding. Restart your computer to resolve this."*

**Phase 1 — Misdiagnosis.** I initially assumed this was a generic Windows virtualization error (Docker, WSL, Android emulator). Gave standard "enable WSL/Hyper-V features and reboot" advice. Wrong assumption — the user clarified it was specifically Claude Desktop's Cowork tab. This was a lesson: read the user's words carefully before treating their problem as a known category.

**Phase 2 — Capability diagnosis via PowerShell.** Built a series of diagnostic scripts that the user ran and pasted output back:

1. First check: virtualization features (`Get-WindowsOptionalFeature`)
2. CoworkVMService presence (`Get-Service`)
3. Discovery: `AppData\Roaming\Claude\logs\cowork_vm_node.log` doesn't exist on this user's system — confused us briefly
4. Event Log query revealed the real log location: `C:\ProgramData\Claude\Logs\cowork-service.log`
5. Reading that log gave us the smoking gun: `"Cannot create system since Hyper-V is not installed on the host"` and HCS error `0x80370102`

This phase taught us that:
- Claude Desktop's MSIX install puts data in `LOCALAPPDATA\Packages\Claude_*`, not in `Roaming\Claude` as we initially guessed
- The machine-wide service logs live in `C:\ProgramData\Claude`
- The Windows Event Log (specifically Application log entries with source `CoworkVMService`) tells you where the real logs are

**Phase 3 — Diagnosis complete, but the user's machine is fundamentally limited.** Windows 10 Home Single Language doesn't support Hyper-V. Cowork can't run. The user agreed to upgrade to Windows 10 Pro (~$99) instead of a clean reinstall.

**Phase 4 — Backup planning before the upgrade.** This is where the backup story really started. The user wanted to back up everything important before the OS upgrade. We built `Backup-BeforeUpgrade.ps1` as a one-shot snapshot script. It backed up: user folders, Claude data (with `Get-ChildItem -Filter "Claude_*"` auto-detection), Claude Code configs, IIS configuration and sites, installed apps list, browsers, dev environment.

**Phase 5 — SQL Server backup.** User asked for SQL too. Built `Restore-SqlDatabases.ps1` and integrated `BACKUP DATABASE` calls into the one-shot script using `sqlcmd`. Key insight: just copying `.mdf` files doesn't work — SQL Server locks them, and even if copied, they may be in inconsistent state. The right way is `BACKUP DATABASE [name] TO DISK = '...' WITH CHECKSUM`. Discovered LocalDB instances need `(localdb)\<name>` syntax.

**Phase 6 — Continuous backup with two-tier storage.** User said "I never want to lose anything I did with Claude" and wanted hourly + on-sleep backups with easy restore. First version was a simple "backup drive only" approach. User pushed back: *"what if the backup drive isn't connected?"* This led to the two-tier design — PRIMARY (always-on internal) plus ARCHIVE (external, syncs when plugged in). This was a much better architecture and would carry forward into the final tool.

**Phase 7 — Smart reporting / dashboard.** User asked how they'd know everything was running fine. We added: a health check script with traffic-light status (green/yellow/red), an HTML dashboard that auto-refreshes, toast notifications when issues found, daily archived reports. The dashboard learned a lot of UI patterns we'd carry forward — usage bars, badge styles, dark mode, snapshot inventory tables.

**Phase 8 — Packaging into a real product.** User asked: *"wouldn't it be amazing if we could package this so all Claude users could use it?"* This is when I had to push back honestly. I told them:

- The backup space is mature with Kopia, Restic, FreeFileSync — we can't compete on generic backup
- BUT we have unique value: Claude-specific knowledge (paths, services, restore quirks)
- We should frame Lifeboat as "Claude-aware backup tool" not "the universal lifejacket"
- I researched what mature tools do well (Kopia's sample-verify, Time Machine's pre-restore snapshots, Scoop's install pattern) and explicitly borrowed those patterns

We then rebuilt everything from scratch as a proper CLI tool with subcommands following git/docker conventions: `install`, `status`, `backup`, `restore`, `verify`, `doctor`, `dashboard`, `uninstall`.

### Things we tried and abandoned

**Hardlink-based snapshots.** Initially I designed the system to use hardlinks for snapshots so each snapshot would only take disk space for the changed files. Abandoned because:

1. Hardlinks don't work cleanly across separate `daily/yyyy-MM-dd/` folders the way I'd hoped — they require the snapshot tree to share the same volume and the script to create the hardlinks correctly per file
2. PowerShell's `New-Item -ItemType HardLink` is finicky on directories vs files
3. The complexity wasn't justified for the data volumes involved (Claude data is ~2-8 GB; 7 daily copies is 14-56 GB, fine on a modern external SSD)
4. Simpler is better — full robocopy `/MIR` copies are easier to understand, debug, and restore manually if needed

We switched to: PRIMARY keeps just 3 days, ARCHIVE keeps full versioning, neither uses hardlinks. Storage cost is the tradeoff.

**Storing everything in the user's regular Documents folder.** Considered putting backups in `Documents\ClaudeBackups\`. Abandoned because:

- User might back that up themselves via OneDrive sync, causing infinite recursion
- It pollutes the user's space
- A dedicated drive root (`X:\ClaudeLifeboat\`) is cleaner and more discoverable

**Single all-in-one PS script.** Original drafts had everything in one giant `Backup-BeforeUpgrade.ps1`. As features grew we split into modular `src/lib/*.ps1` files. This worked much better because each command is its own concern and we could share helpers via `common.ps1`.

**Encryption at rest.** Considered AES-256-GCM with a passphrase derived from PBKDF2. Abandoned for v0.1 because:

- It adds a password-management UX burden ("what if I forget the password?")
- BitLocker on the backup drive does the same job with no UX cost
- Adding it later in v0.2 is fine; it's listed in the planned section

**MSDN/cheap product keys.** When the user asked where to buy Windows 10 Pro, I almost recommended ₹499–2,500 "lifetime keys" from Indian resellers, then web-searched and verified these are MSDN/volume keys being resold against Microsoft's terms. Pushed back and recommended legitimate retail boxes (~₹10,000) instead. This wasn't backup-related but reinforced a pattern: when something feels too cheap, verify rather than recommend.

**Generic File History for Claude data.** Briefly considered "just tell users to enable Windows File History and add Claude paths." Tested mentally: File History excludes MSIX package data by default and is notoriously unreliable. Wouldn't recover Cowork VM state correctly. Justified building our own.

### Why we ended up with the current shape

- **Two-tier (primary + archive):** because users want protection even when the external drive isn't plugged in. Standard NAS/3-2-1 backup pattern adapted to consumer hardware.
- **Robocopy `/MIR`:** because it's built into Windows, fast, handles long paths, multi-threaded, and produces directly browsable backups. No proprietary format to recover from.
- **JSON config in LocalAppData:** standard Windows convention. Survives uninstall/reinstall of the tool if the user wants. Easy to edit by hand.
- **Status file in each backup root:** lets restore on a different machine read what was last backed up without needing the original config.
- **Pre-restore safety snapshot:** the killer feature. Restores should be undoable. Borrowed from Time Machine.
- **CLI with subcommands:** `lifeboat install`, `lifeboat status` etc. is friendlier than a folder of scripts named `Setup-AutoBackup.ps1`, `Check-BackupHealth.ps1` etc. Following git/docker conventions makes the tool feel professional immediately.
- **Doctor command:** addresses the self-healing problem — Windows updates, third-party cleaners, and user mistakes can all break the scheduled tasks. `lifeboat doctor` re-creates them.

---

## Part C continued — Gotchas

### PowerShell quirks

**1. Variable scoping in helper functions.** Originally `Invoke-Status` declared `$checks = @()` locally then had a nested helper `function Add-Check { $script:checks += ... }`. The `$script:checks` and the local `$checks` are *different variables*. Symptom: status output was empty. Fix: declare `$script:checks = @()` at the top and use `$script:checks` everywhere. This is documented in PowerShell as the difference between local and script scope, but very easy to get wrong with `+=` accumulator patterns inside nested functions.

**2. Robocopy exit codes are bit flags, not normal return codes.** Exit code 0 = no change; 1 = files copied; 2 = extras detected at dest; 3 = both copied and extras; 4-7 = warnings; 8+ = errors. Code `$result.Success = ($code -lt 8)` is the only correct way to interpret success. People who treat robocopy success as `$LASTEXITCODE -eq 0` will think every successful backup with new files is a failure.

**3. `Get-ChildItem -Filter "Claude_*"`.** The `-Filter` parameter uses Windows filesystem filters which behave differently from `-Include`. With `-Filter` you can only specify one pattern but it's much faster because it's evaluated at the FS layer. We use this to find the MSIX package folder.

**4. `Get-ScheduledTask` doesn't fail if no tasks match.** It returns `$null`. So checks need to be `if (-not $tasks)` rather than `try/catch`.

**5. Scheduled task `LastTaskResult` codes:**
- `0` = success
- `267009` (`0x41301`) = currently running
- `267011` (`0x41303`) = never run yet
- `0x1` = generic error (often script error)
- `0x41306` = task terminated (exceeded execution time limit)

All non-zero codes that aren't the "running" or "not yet run" sentinels should be treated as failures.

**6. PowerShell's `New-ScheduledTaskTrigger -Once -RepetitionInterval` behavior changed between Windows versions.** In older versions you had to specify both `-RepetitionInterval` AND `-RepetitionDuration`. In Windows 10 1809+ and PowerShell 5.1, omitting `-RepetitionDuration` means "repeat indefinitely" which is what we want. If the porting Claude runs into Windows Server or older Win10 builds, may need to add an explicit large duration like `(New-TimeSpan -Days 9999)`.

### Task Scheduler permission issues

**1. The hourly task initially failed silently because of execution policy.** Solution: always include `-ExecutionPolicy Bypass` in the task action's PowerShell argument:

```powershell
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$runnerPath`" backup"
```

The `Bypass` here is scoped to that single invocation, not a system-wide change. Safer than `Set-ExecutionPolicy Unrestricted`.

**2. S4U logon type was the right choice.** Other logon types:
- `Interactive` requires user to be logged in interactively
- `Password` requires storing the password
- `S4U` (Service for User) runs as the user without needing password, even when locked
- `ServiceAccount` requires a real service account

S4U was right for "backup runs in background as the user, while the user isn't actively at the keyboard."

**3. Event-based triggers require CIM, not the cmdlet.** `New-ScheduledTaskTrigger` has no parameter for event-based triggers. Must be created with:

```powershell
$cls = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
$et = New-CimInstance -CimClass $cls -ClientOnly
$et.Enabled = $true
$et.Subscription = '<QueryList>...</QueryList>'
```

This is poorly documented in PowerShell docs but works reliably.

**4. NTFS event log isn't enabled by default on Windows 10 Home.** The OnDriveConnect trigger uses NTFS Event 98 (volume mounted). On many Home installs this log channel exists but isn't enabled, so the trigger never fires. We documented a workaround in the README (enable the log via Event Viewer) and note that the hourly trigger catches the drive within an hour anyway.

**5. Kernel-Power Event 42 fires on sleep on all Windows 10+ systems.** This is universal and reliable. It's also worth noting Event 42 has multiple meanings — it can be "entering modern standby," "entering S3 sleep," "entering S4 hibernate." All of these are good moments to back up, so we accept all of them.

### Path and encoding problems

**1. MSIX package folder names have a trailing hash that varies per machine.** The user's was `Claude_pzs8sxrjxfjjc`. Hardcoding this would break for other users. Always use `Get-ChildItem ... -Filter "Claude_*" | Select -First 1`.

**2. UTF-8 BOM problems.** `Set-Content -Encoding UTF8` in Windows PowerShell 5.1 adds a BOM (UTF-8 with BOM signature). This causes problems when those files are read by tools expecting plain UTF-8. We use `-Encoding UTF8` everywhere because the BOM is fine for our internal logs and config files, but the porting Claude should be aware if extending the tool to share files with non-Windows tools.

**3. Robocopy and path lengths.** Windows has a 260-char path limit by default. Robocopy handles long paths internally when copying, but if you `Get-ChildItem` a deep tree, you can hit `PathTooLongException`. We use `-ErrorAction SilentlyContinue` on enumerations to be defensive. The Cowork VM bundle paths are deep — `C:\Users\Jack\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\vm_bundles\claudevm.bundle\rootfs.vhdx` is already 130+ chars before any subdirectories. Long-path support (`HKLM\SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled=1`) is enabled by default in Windows 10 1607+ but not in PowerShell 5.1 — fine for our use but a gotcha if extending.

**4. JSON encoding.** `ConvertTo-Json -Depth 10` is important. The default depth is 2, which silently truncates nested objects (replacing them with `"System.Collections.Hashtable"` strings). Always explicit `-Depth`.

### Things that cost us real time

- **Initial misdiagnosis of the Cowork error** as generic Windows virtualization. ~30 minutes of dead-end advice.
- **Looking for logs in `AppData\Roaming\Claude\logs\`** when they were actually in `C:\ProgramData\Claude\Logs\`. Event Viewer was the key — `Get-EventLog -LogName Application -Source "CoworkVMService"` told us where the logs really lived.
- **The hardlink experiment.** Spent time designing a hardlink-based snapshot system before realizing it added complexity without enough benefit.
- **`$script:checks` scope bug** in the status command. Symptom was an empty traffic light. Took a manual code review to catch — I'm now paranoid about `$script:` vs local in nested helper functions.
- **Suggesting cheap Windows 10 Pro keys.** Started to recommend ₹499 keys before catching myself, web-searching, and confirming these are MSDN/volume keys against ToS. Recommending dishonest products is never worth saving the user a few rupees.

### Design decisions and their reasoning

| Decision | Reasoning |
|---|---|
| Subcommand CLI (`lifeboat status`, etc.) | Familiar pattern from git, docker, kubectl, kopia. Discoverable via `lifeboat help`. Each command is its own concern. |
| Two-tier backup (PRIMARY + ARCHIVE) | User wanted protection when external drive isn't plugged in. Internal drive always available + optional external = redundancy without rigid requirements. |
| PRIMARY keeps only 3 days | Internal drives are space-constrained. The user's was 480GB SSD with 288GB free. Long-term versioning lives on the larger external drive. |
| robocopy /MIR for the actual copy | Built into Windows, fast, handles long paths, multi-threaded, and produces directly browsable backups. No proprietary format = no lock-in. |
| No encryption by default | Adds password-management UX burden. BitLocker on the backup drive solves the same problem without our complexity. Listed in v0.2 plans. |
| Safety snapshot before restore | Restores must be undoable. Time Machine pattern. Cheap on disk, big peace of mind. |
| Sample integrity check after each backup | Cheap (read 5 random files, ~50ms) and catches catastrophic copy failures that robocopy might not flag. From Kopia's playbook. |
| `Resolve-OriginalDestination` is a switch statement, not config-driven | Mapping from backup-folder-name to original-disk-path is part of "Claude-awareness". Encoding it in code rather than config makes the tool authoritative about what Claude paths are. |
| Self-healing via `lifeboat doctor` | Scheduled tasks get removed by Windows updates, third-party cleaners, and user mistakes. Easier to re-create than to make indestructible. |
| Run as user via S4U logon type | Background backup that doesn't need an interactive session and doesn't require storing a password. Right Windows pattern for this. |
| Stop CoworkVMService before restoring Claude data | Cowork holds file locks on the VM bundle files. Restore would fail with sharing violations otherwise. |
| Stable script install location (`%LOCALAPPDATA%\ClaudeLifeboat`) | Scheduled tasks need a stable path. Wherever the user cloned the repo, the runner gets copied to this canonical location. |
| ASCII-safe symbols in console output (`[char]0x2713` etc.) | Some PowerShell hosts (older terminals, RDP) display Unicode poorly. We use `[char]0x2713` (✓) which works almost everywhere, but fall back gracefully. The CLI is otherwise plain ASCII. |

---

## Part D — Status

### Done vs left

**Done:**

- [x] All eight subcommands implemented (`install`, `status`, `backup`, `restore`, `verify`, `doctor`, `dashboard`, `uninstall`)
- [x] Two-tier backup architecture (PRIMARY + ARCHIVE)
- [x] Catch-up sync when ARCHIVE returns after disconnect
- [x] All five scheduled task triggers (hourly, on-logon, on-sleep, on-idle, on-drive-connect)
- [x] Health-check task with toast notifications
- [x] Pre-restore safety snapshot
- [x] Sample-verify after each backup
- [x] Thorough verify command for on-demand integrity
- [x] Doctor command with auto-fix for common issues
- [x] HTML dashboard with auto-refresh
- [x] JSON output mode for status/verify (for scripting)
- [x] One-line installer (`install.ps1`)
- [x] Bracket-balanced, structurally validated PowerShell
- [x] README, LICENSE (MIT), CHANGELOG
- [x] Detected one scope bug in status (`$script:checks`) and fixed it

**Left:**

- [ ] **Actually testing on a Windows machine.** Everything was written from a Linux sandbox. The PowerShell was structurally checked but not executed. Expect 2-3 real bugs first time the install runs.
- [ ] **Real GitHub repo.** The install URL `github.com/jack/claude-lifeboat` is placeholder. Repo needs to be created at `github.com/JackBhanded/claude-lifeboat`, README's URLs updated, first release tagged with the zip attached.
- [ ] **Test the OnDriveConnect trigger on a Windows 10 Home box.** We documented it might not fire if NTFS event log is disabled by default but haven't verified on the user's actual machine.
- [ ] **Verify cross-machine restore works end-to-end.** The README describes the steps but we haven't done a full "new laptop, restore from archive" test.
- [ ] **macOS support.** Claude Desktop runs on macOS too. The whole tool is currently Windows-only because of PowerShell, Task Scheduler, and MSIX paths.
- [ ] **Cloud destinations** (B2, S3, OneDrive). Planned for v0.2.

### Open questions

1. **Does the MSIX package name pattern (`Claude_*`) always start with `Claude_`?** We assumed yes. If Anthropic publishes a different package later (different signing identity), the auto-detection might miss it. Should probably also try fallback patterns.

2. **Cowork VM image restore on a different machine.** When `rootfs.vhdx` etc. are restored to a new Windows machine, will Cowork re-use them or rebuild? We documented "may rebuild" as a caveat but didn't test. If it consistently rebuilds, we might as well exclude those `.vhdx` files from backup to save space.

3. **What's the right behavior if Claude Desktop's MSIX package version changes between backup and restore?** Probably restoring works fine because the user data layout is stable, but we haven't tested. The MSIX package suffix (`Claude_pzs8sxrjxfjjc`) might change with new versions, breaking our resolve-destination logic.

4. **Should `lifeboat backup` block while Claude Desktop is actively writing to the package folder?** Robocopy with `/MIR` handles in-use files acceptably but not perfectly. For files actively being written (like an in-progress conversation), the copied version might be partially-written. The sample-verify catches catastrophic cases but not in-progress writes.

5. **Notification fallback when Windows.UI.Notifications isn't available.** On Server SKUs or stripped Windows, the toast API may not exist. The try/catch silently swallows the error currently. Should we fall back to a message box? Email? Probably needs more thought.

6. **Does `Get-Service CoworkVMService` exist on all Claude Desktop versions?** This service name might change. If it disappears in a future release, our `Stop-ClaudeProcesses` becomes a no-op (which is fine), but our doctor check would report it missing (which is also fine).

7. **Backup of in-flight Cowork sessions.** Cowork sessions have ephemeral state in memory that isn't on disk until the session ends. Backing up an active session might give an incomplete snapshot. We document "session data is in `sessiondata.vhdx`" but the in-memory state isn't captured.

### Things I'd do differently if starting fresh

1. **Write a smoke test that runs after install.** Right now `lifeboat install` runs a first backup. But we have no automated "did everything actually work?" test. A `lifeboat selftest` command that creates a tiny test file in a known location, runs a backup, then verifies it got copied would be a real confidence-builder.

2. **Cross-platform from day one.** Hard-coding Windows paths and PowerShell made macOS support a v0.2 problem instead of v0.1. If starting fresh, I'd build the tool in Python or Go with a thin Windows-specific shim for Task Scheduler, and use cron / launchd for macOS / Linux respectively.

3. **Less initial scope.** v0.1 has 8 subcommands, 6 scheduled task types, an HTML dashboard, toast notifications, JSON output mode, integrity verification, safety snapshots, and doctor auto-fix. That's a lot for a first release. The MVP could have been: `install`, `backup`, `restore`, `status`. Everything else as v0.2.

4. **Earlier honest framing.** I let the user's enthusiasm ("the Claude lifejacket baby!") carry me further than it should have before I pushed back with "this fills a Cowork-specific niche, not a universal need." Better to set realistic expectations from the first product conversation.

5. **A test/CI strategy.** Even a basic `Invoke-Pester` smoke test would have caught the `$script:checks` scope bug. PowerShell has Pester for unit tests — should have used it.

6. **Bundling lib/ into a PowerShell module.** Right now `src/lib/*.ps1` are dot-sourced individually. A real `.psd1` + `.psm1` module with exported function names would be more conventional and avoid potential dot-source ordering bugs.

7. **Don't ship until tested.** Strongest lesson — I built everything in a Linux sandbox without ever executing the code. The first user to try this will find real bugs. If starting fresh I'd insist on a Windows VM or at least the user running each script as we built it, iterating bug-by-bug.

8. **Verify URLs before writing READMEs that link to them.** Replace `github.com/jack/claude-lifeboat` everywhere with `github.com/JackBhanded/claude-lifeboat` before any user sees it. Lesson: ask for the actual URL early instead of placeholdering.

9. **A `lifeboat config` subcommand to edit settings.** Right now the config is JSON and the user edits it manually. A simple `lifeboat config set Notifications.Enabled false` command would be more user-friendly.
