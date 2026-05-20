# Changelog

All notable changes to Claude Lifeboat are documented here.
Format based on [Keep a Changelog](https://keepachangelog.com/); versioning per [SemVer](https://semver.org/).

## [Unreleased]

- Lean backup mode: skip the regenerable VM disks (`rootfs.vhdx`, `smol-bin.vhdx`) and keep only `sessiondata.vhdx` + configs, to cut backup storage ~90% (pending restore-consistency testing)
- Apply `Advanced.ExcludePatterns` in the robocopy wrapper (currently defined in config but not enforced)
- Real `irm | iex` one-line installer once GitHub releases exist to download from

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

[Unreleased]: https://github.com/JackBhanded/claude-lifeboat/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/JackBhanded/claude-lifeboat/releases/tag/v0.1.0
