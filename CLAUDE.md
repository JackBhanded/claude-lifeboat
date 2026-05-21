# CLAUDE.md — Claude Lifeboat

Context for any Claude (or human) picking up this repo. Keep it current.

## What this is

Claude-aware backup & restore for Windows. Backs up Claude Desktop / Cowork data
(the `Claude_*` MSIX package incl. the Cowork VM `sessiondata.vhdx`,
`ProgramData\Claude`, and Claude Code configs), with versioned snapshots, a safe
undoable restore, Task Scheduler automation, a light HTML dashboard, and a system
tray companion. PowerShell 5+, zero dependencies (ships with Windows).

## Architecture (`src/`)

- `lifeboat.ps1` — CLI dispatcher (`install/status/backup/restore/doctor/
  dashboard/verify/uninstall/tray/version/help`).
- `lifeboat-runner.ps1` — thin wrapper the scheduled tasks invoke (stable path).
- `lifeboat-tray.ps1` — the tray buoy: status light + right-click menu.
- `lib/` — `common.ps1` (robocopy wrappers, **VSS helpers**, logging),
  `config.ps1`, `backup.ps1`, `restore.ps1`, `status.ps1`, `doctor.ps1`,
  `dashboard.ps1`, `verify.ps1`, `install.ps1` (Task Scheduler setup).
- `install.ps1` (root) — one-line/self-downloading installer.
- `Install Claude Lifeboat.bat` — double-click installer (self-elevates).

Two-tier storage (always-on PRIMARY + optional ARCHIVE drive); `latest` mirror +
`daily` snapshots via robocopy `/MIR`; safety snapshot taken before any restore.

## Hard-won PowerShell gotchas

- **No non-ASCII literals in `.ps1`** (PS 5.1 parser). Use `$([char]0x2713)` for
  the checkmark, HTML entities for emoji in generated HTML, ASCII-only console
  strings. (Bit us via em-dash parse errors and a `[char]` 16-bit overflow on an emoji.)
- **`@($null).Count` is 1, not 0** — empty failure lists were miscounted as
  failures. Filter with `| Where-Object { $_ }`.
- **robocopy ERROR 2** on volatile files rewritten mid-copy (cookies, SQLite
  `-journal/-wal/-shm`) — excluded via `/XF` + `/XD` cache dirs.
- **Locked files need VSS.** When Claude Desktop/Cowork is *running*, the live
  `sessiondata.vhdx` is exclusively locked → robocopy exit 9/11 (some files
  skipped). Fix (v0.1.3): take a `Win32_ShadowCopy` snapshot and copy from it
  (`New-VolumeShadowCopy`/`ConvertTo-ShadowPath`/`Remove-VolumeShadowCopy` in
  `common.ps1`), fail-safe fallback to live copy, always released in `finally`.
  Scheduled tasks run at `RunLevel Highest` (S4U, no UAC) so they can snapshot.

## Install & ship

One line (Admin PowerShell): `irm https://github.com/JackBhanded/claude-lifeboat/raw/main/install.ps1 | iex`.
No terminal: download the release zip, double-click `Install Claude Lifeboat.bat`.
Releases are packaged by `tools\Build-Release.ps1` into a clean, versioned
`claude-lifeboat-v<version>.zip` (+ SHA256) under `dist\` — only end-user files,
no `legacy/` or dev notes. The version is read from `src\lifeboat.ps1` (single
source of truth). Publish by hand: tag, create the release, attach the zip +
`.sha256` (the script prints the exact steps). The installer prefers that asset
and falls back to GitHub's source archive for older asset-less releases.

## Roadmap

v0.2 coordination with Lifejacket. (Real release-asset packaging: done — see
`tools\Build-Release.ps1`.) Open follow-up:
make the activity log easier to find from the dashboard/tray (status.json lives on
the backup drive; logs live under `%LOCALAPPDATA%\ClaudeLifeboat\logs`).

## Part of the fleet

- [Claude Meter](https://github.com/JackBhanded/claude-meter) — live usage on your taskbar.
- **Claude Lifeboat** — you are here.
- [Claude Lifejacket](https://github.com/JackBhanded/claude-lifejacket) — keep every session aware of your projects.

_Maintainer's working-style/personal context is kept in private notes, not in this public file._
