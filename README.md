# Claude Lifeboat 🛟

> Claude-aware backup for your Windows machine. Automatically backs up your Claude Desktop / Cowork data — conversation history, the Cowork VM session disk, settings, and Claude Code configs — so a lost session or a bad upgrade doesn't take your work with it.

[![PowerShell](https://img.shields.io/badge/PowerShell-5.0+-5391FE)]()
[![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6)]()
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

## Why this exists

Claude Desktop with Cowork stores real work locally — conversation history, the Cowork VM's `sessiondata.vhdx` (everything you've built in the virtual workspace), settings, and login state — inside an `AppData\Local\Packages\Claude_*` MSIX folder. Windows' built-in File History and Backup tools don't index MSIX package data well, so most of it goes unprotected. General backup tools (Kopia, Restic, Aomei) work fine but don't know the Claude-specific paths, don't know that `CoworkVMService` must be stopped cleanly before restoring, and don't understand how the VM bundle relates to your session data.

Lifeboat is **Claude-aware**. That's the whole point. It's not trying to beat Kopia at general backup — it fills the niche Kopia doesn't care about.

> **Honest scope:** This is backup *insurance* for Claude data, not a full-system imaging tool and not a cure for Cowork problems. If Cowork itself won't start, fixing that (e.g. enabling virtualization) is the real solution — Lifeboat just makes sure your data survives the troubleshooting.

## What it backs up

| Source | Why it matters |
|---|---|
| `%LOCALAPPDATA%\Packages\Claude_*` | Claude Desktop data: conversation history, the Cowork VM bundle (`sessiondata.vhdx` holds your actual work), settings, login state |
| `C:\ProgramData\Claude` | Machine-wide Cowork service logs/config |
| `%USERPROFILE%\.claude` + alternates | Claude Code CLI configs (if installed) |
| Folders you add at install time | Your project folders, repos, anything else you want safe |

Backups are plain files (robocopy `/MIR`) — directly browsable in Explorer, no proprietary container, no lock-in.

## How it works

- **Two-tier storage** — a always-on PRIMARY drive (every backup lands here) + an optional ARCHIVE drive (external, syncs when plugged in, keeps longer history).
- **Versioned snapshots** — `latest/` mirror + dated `daily/` + Sunday `weekly/` folders.
- **Safety snapshot before every restore** — restore is itself undoable (the Time Machine pattern). If a restore goes wrong: `lifeboat restore --from safety --date <timestamp>`.
- **Stops `CoworkVMService` cleanly before restoring** so file locks don't corrupt the copy.
- **Scheduled via Windows Task Scheduler** — hourly, at logon, on sleep, on idle, and when the archive drive connects.

## Install

PowerShell 5+ (ships with Windows 10/11). **Run as Administrator** (Task Scheduler registration needs it).

1. Download the latest release zip from the [Releases page](../../releases) and extract it.
2. Open an **elevated** PowerShell in the extracted folder.
3. Run:
   ```powershell
   .\install.ps1
   ```
4. Answer two questions (primary drive, optional archive drive). It registers the scheduled tasks and runs a first backup to verify everything works.

That's it. Your Claude data is now backed up automatically.

## Usage

```powershell
lifeboat status               # quick health check
lifeboat backup               # run a backup right now
lifeboat restore --preview    # SAFE restore: copies to a temp folder first
lifeboat restore              # interactive restore (with safety snapshot)
lifeboat dashboard            # open the visual HTML dashboard
lifeboat doctor               # diagnose & auto-fix scheduled-task issues
lifeboat verify               # confirm a backup is restorable
lifeboat uninstall            # remove scheduled tasks (keeps your backups)
```

**Always `lifeboat restore --preview` first.** It restores into a temp folder and opens it in Explorer so you can inspect the files before overwriting anything real — nothing in your Claude folders (or on your Desktop) is touched.

## Disk usage — read this

Backups are full copies (no dedup). Your Claude data includes the Cowork VM bundle, and the Linux image (`rootfs.vhdx`) is ~2 GB. With the default retention (2 primary + 5 archive dailies + 4 weeklies), expect roughly **15–25 GB** of backup storage to protect ~2 GB of live data, because the regenerable VM image is copied into each snapshot. A leaner mode that skips the regenerable disks and keeps only `sessiondata.vhdx` is planned for v0.2 (pending restore-consistency testing). For now, point PRIMARY at a drive with room to spare.

## Troubleshooting

- **"Running scripts is disabled on this system"** — PowerShell's execution policy. The installer and scheduled tasks already use `-ExecutionPolicy Bypass`; if you hit this running `lifeboat` directly, use `powershell -ExecutionPolicy Bypass -File .\src\lifeboat.ps1 <command>`.
- **Drive-connect trigger doesn't fire** — the NTFS operational event log isn't enabled by default on some Windows editions. Hourly + logon backups still cover you.
- **A scheduled task went missing** — `lifeboat doctor` re-registers anything that disappeared.

## Project layout

```
install.ps1            bootstrap installer (copies src/ to %LOCALAPPDATA%\Programs)
src/
├── lifeboat.ps1       the CLI dispatcher
├── lifeboat-runner.ps1  what scheduled tasks invoke
└── lib/
    ├── common.ps1   config.ps1   backup.ps1   restore.ps1
    ├── status.ps1   doctor.ps1   dashboard.ps1  verify.ps1
    └── install.ps1  (Task Scheduler setup + uninstall)
legacy/               first-generation scripts, archived for reference
```

## About

Built by **[Jack Bhanded](https://www.sawyouatsinai.com/jewish-dating-team.aspx)**, Lead developer and architect at [SawYouAtSinai](https://www.sawyouatsinai.com). Part of a small suite of Claude utilities alongside [Claude Meter](https://github.com/JackBhanded/claude-meter).

## License

[MIT](LICENSE).
