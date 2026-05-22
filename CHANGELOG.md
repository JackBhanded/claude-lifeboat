# Changelog

All notable changes to Claude Lifeboat are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/); versioning per [SemVer](https://semver.org/).

## [Unreleased]

### Added
- **Real release packaging** (`tools\Build-Release.ps1`). Builds a clean,
  versioned `claude-lifeboat-v<version>.zip` plus a SHA256 checksum, containing
  only what an end user needs (no `legacy/`, no dev notes). Version is read from
  `src\lifeboat.ps1` so there's a single source of truth.

### Changed
- The one-line installer now **prefers a packaged release asset** when one is
  attached to the release, falling back to GitHub's source archive for older
  asset-less releases (and to `main` if there's no release at all).
- The tray icon is now a proper **life-ring** glyph (outer ring + coral hub + four
  lashings) instead of a plain ring-with-dot, so Lifeboat is easy to tell apart
  from the other fleet tools at a glance. It still doubles as a status light: the
  ring and lashings carry the green/amber/red/grey health colour, with the hub in
  Claude coral.
- README: added an honest **"How it differs from the alternatives"** section.

## [0.1.4] — 2026-05-21

### Added
- **On-demand backup to any drive.** Plug in a USB/removable drive and back up
  to it right now — from the tray ("Back up to a drive..." lists what's
  connected) or the CLI (`lifeboat backup --to=E:`). Uses VSS, and leaves your
  configured archive untouched.

### Changed
- The tray's "Exit & stop automatic backups" now asks for confirmation first
  (so a stray click can't silently turn off your backups), and its message
  points you to "Resume automatic backups" in the tray instead of a CLI command
  that may not be on PATH.

## [0.1.3] — 2026-05-21

### Added
- **Open-file backups via VSS.** Backups now take a Volume Shadow Copy snapshot
  and copy from it, so files a running app holds locked — chiefly the live
  Cowork `sessiondata.vhdx` — back up cleanly instead of being skipped
  (the `ClaudeDesktop -> primary: FAIL exit 11` lines). If VSS isn't available
  it safely falls back to a live copy, and the snapshot is always released.
- The installer now **launches the tray immediately** after setup (it still
  also auto-starts at each logon).

### Changed
- Scheduled backup tasks now run at `RunLevel Highest` (still no UAC prompt via
  S4U) so the automatic backups can use VSS for locked files.

## [0.1.2] — 2026-05-21

### Added
- **Easy install.** The one-line installer now actually downloads and installs
  itself: `irm https://github.com/JackBhanded/claude-lifeboat/raw/main/install.ps1 | iex`
  (resolves the latest release, falls back to the latest code, TLS 1.2).
- **Double-click installer** — `Install Claude Lifeboat.bat` self-elevates
  (asks for the admin rights needed to schedule backups) and runs the installer,
  so no PowerShell or execution-policy wrangling is required.

## [0.1.1] — 2026-05-21

### Added
- **System tray companion** (`lifeboat tray`): a lifebuoy status-light (green/amber/red) with a right-click control panel — open dashboard, back up now, restore, view logs, open the backup folder, pause/resume the schedule, and two exits (close the tray vs. close it *and* stop automatic backups). Backups run via Task Scheduler independently of the tray.
- **Lean vs Full backup mode**, chosen at install. Lean (default) skips the regenerable VM OS image (`rootfs.vhdx` / `smol-bin.vhdx`, often 8+ GB) and keeps your actual work (`sessiondata.vhdx`); Full keeps everything for a self-contained restore.
- **Live progress spinners** (elapsed time + copied-so-far size) on backup and restore, with warm stage-by-stage narration and gentle, recoverable failure messages.
- Backups skip the redundant daily snapshot when nothing has changed.

### Changed
- Dashboard reskinned to the light Claude theme (warm cream, Claude coral, soft cards) with the official Claude logo, and moved off the Desktop to `%LOCALAPPDATA%\ClaudeLifeboat\dashboard.html`.

### Fixed
- Robocopy now excludes volatile cache/cookie/journal files that change mid-copy — the real cause of spurious "ERROR 2" backup failures.
- The safety-snapshot undo now actually works (the `safety/` folder is enumerated and the timestamp is captured once so the undo command matches).
- Tray no longer reports phantom failures (an empty failure list serialized to JSON null was being miscounted).
- Several dashboard rendering bugs: lifeboat emoji exceeding the 16-bit `[char]` range, an em-dash parsed as date-format codes, and a literal em-dash parse error.
- Restore previews go to a temp folder (auto-opened in Explorer) instead of cluttering the Desktop.

## [0.1.0] — 2026-05-21

Initial release. Claude-aware automated backup & restore for Windows.

### Added
- `lifeboat` CLI: `install`, `status`, `backup`, `restore`, `verify`, `doctor`, `dashboard`, `uninstall`
- Two-tier backup (always-on PRIMARY + optional ARCHIVE drive) with `latest` / `daily` / `weekly` snapshots
- Auto-detection of Claude Desktop MSIX package, `ProgramData\Claude`, and Claude Code configs
- Safety snapshot before every restore (undoable restores) + `--preview` mode that restores to a temp folder first
- Clean `CoworkVMService` stop/start around restores so file locks don't corrupt the copy
- Windows Task Scheduler integration: hourly, on-logon, on-sleep, on-idle, on-drive-connect, plus a periodic health check with toast notifications
- `lifeboat doctor` self-healing for missing/disabled scheduled tasks

### Fixed during port (from the original chat-built prototype)
- **Safety-snapshot undo now actually works** — `Get-AllSnapshots` now enumerates the `safety/` folder, and the restore flow captures the timestamp once so the folder name and the printed undo command always match
- Reduced default retention to 2 primary / 5 archive dailies to keep backup storage reasonable given full VM-bundle copies
- Corrected repository URLs to `github.com/JackBhanded/claude-lifeboat`

[Unreleased]: https://github.com/JackBhanded/claude-lifeboat/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/JackBhanded/claude-lifeboat/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/JackBhanded/claude-lifeboat/releases/tag/v0.1.0
