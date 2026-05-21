<div align="center">

<img src="assets/claude-logo.svg" width="72" alt="Claude Lifeboat">

# Claude Lifeboat 🛟

**Claude-aware backup for your Windows machine.** Automatically backs up your Claude Desktop / Cowork data — conversation history, the Cowork VM session disk, settings, and Claude Code configs — so a lost session or a bad upgrade doesn't take your work with it.

[![PowerShell](https://img.shields.io/badge/PowerShell-5.0+-5391FE)]()
[![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6)]()
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

Part of a small suite of Claude utilities, alongside **[Claude Meter](https://github.com/JackBhanded/claude-meter)**.

</div>

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

## Backup size — lean vs full

At install you choose a backup mode:

- **Lean (recommended)** — skips the big, regenerable Cowork VM OS image (`rootfs.vhdx` + `smol-bin.vhdx`, often 8+ GB that Claude rebuilds on its own) and keeps your actual work (`sessiondata.vhdx`), conversations, settings, and Claude Code configs. Tiny and fast.
- **Full** — backs up everything, including the OS image, for a completely self-contained restore. Larger; point PRIMARY at a drive with room to spare.

Change your mind anytime by re-running `lifeboat install`. Either way, volatile cache/cookie files are always excluded — they're regenerable and were the source of spurious copy errors.

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

## About the author

<table>
<tr>
<td width="120" valign="top">
<img src="https://www.SawYouAtSinai.com/_layouts/images/team/jackbio.jpg" width="100" alt="Jack Bhanded">
</td>
<td valign="top">

Built by **[Jack Bhanded](https://www.sawyouatsinai.com/jewish-dating-team.aspx)**, Lead developer and architect at [SawYouAtSinai](https://www.sawyouatsinai.com). Devotee of innovative technologies and gadgets. Built this because he wanted his Claude Desktop and Cowork data backed up safely and automatically — with a one-click restore for when something goes wrong.

</td>
</tr>
</table>

Part of a small suite of Claude utilities alongside [Claude Meter](https://github.com/JackBhanded/claude-meter) (live usage on your taskbar) and [Claude Lifejacket](https://github.com/JackBhanded/claude-lifejacket) (keep every Claude session aware of your projects).

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for the version-by-version list of changes.

## License

[MIT](LICENSE) — do whatever you want, just keep the copyright notice.
