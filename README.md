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

## The problem, in one breath

Claude Desktop (and Cowork) keeps your real work on your computer — your
conversation history, everything you've built in the Cowork workspace, your
settings and logins. But it's tucked away in a hidden Windows folder that normal
backup tools don't know to look in. So if something breaks or an update goes
sideways, that work can vanish.

**Claude Lifeboat** is like Time Machine, but it knows exactly where Claude hides
your data. It backs it all up automatically, and gives you a one-click way to get
it back.

> **Where it fits:** Lifeboat is *insurance* for your Claude data — not a
> whole-computer backup, and not a fix for Cowork itself. If Cowork won't start,
> that's a separate fix; Lifeboat just makes sure your work survives the
> troubleshooting.

## What it backs up

| What | Why it matters |
|---|---|
| Your Claude Desktop data | Your conversation history, everything you've built in the Cowork workspace, your settings and login |
| Claude's shared system files | The behind-the-scenes Cowork logs and config |
| Your Claude Code settings | If you use the Claude Code command-line tool |
| Any folders you add | Your projects, repos, or anything else you want kept safe |

Your backups are just ordinary files in ordinary folders — open them in File
Explorer anytime. No special app needed to read them, no lock-in.

## How it works

- **Two places to keep your backups** — a main drive that's always on (every
  backup goes here) and, if you like, an extra drive (e.g. an external one) that
  catches up whenever you plug it in and keeps a longer history.
- **Dated versions** — a "latest" copy plus dated daily and weekly folders, so you
  can go back to a good day, not just the most recent backup.
- **Restoring is undoable** — before it puts anything back, it saves where you are
  first. If a restore isn't what you wanted, you can reverse it.
- **It handles the tricky locked files** — it pauses the Cowork background service
  cleanly so your work copies over safely instead of getting corrupted.
- **It runs itself** — backups happen on a schedule in the background: hourly, when
  you log in, and when you plug your extra drive in.

## Install

Windows 10/11 (PowerShell 5+ ships built in). Pick whichever's easiest:

**Easiest — one line.** Open PowerShell **as Administrator** and paste:

```powershell
irm https://github.com/JackBhanded/claude-lifeboat/raw/main/install.ps1 | iex
```

It downloads itself, installs, and walks you through two quick questions
(primary drive, optional archive drive).

**No terminal — double-click.** Download the latest release zip from the
[Releases page](https://github.com/JackBhanded/claude-lifeboat/releases/latest),
extract it, and double-click **`Install Claude Lifeboat.bat`**. It asks Windows
for permission (needed to schedule your backups), then installs itself.

Either way, when it finishes your Claude data is backed up automatically — and
you'll have the `lifeboat` command for everything below.

## Usage

```powershell
lifeboat status               # quick health check
lifeboat backup               # run a backup right now
lifeboat backup --to=E:       # one-time backup to a USB / removable drive
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

## How it differs from the alternatives

Honestly? There isn't much that does this. When we went looking, Lifeboat turned
out to be nearly one-of-a-kind — so here's a fair map of the neighbourhood.

The one tool that *also* knows where Claude hides its data is
**[claude-cowork-migration](https://github.com/Hiroto-Kozuki/claude-cowork-migration)**.
It's good at what it does, but it's built for a different job: **moving** your
Cowork data to another drive (say, to free up space on `C:`), not keeping safe,
dated copies over time. It's a manual copy you run yourself — no schedule, no
version history, and it needs Claude fully closed while it runs. If your goal is
literally *"get this giant VM file off my system drive,"* it's the better fit.

Anthropic's own **[Export Data](https://support.claude.com)** (Settings → Privacy)
is worth knowing about too — but it only gives you your *conversations* as a JSON
file from the server. It doesn't touch your local Cowork workspace, your logins,
or your Claude Code setup. Good for a chat archive; not a backup of your machine.

Then there are the excellent **general-purpose** Windows backup tools —
[Restic](https://restic.net), [Duplicati](https://www.duplicati.com),
[Kopia](https://kopia.io), Macrium, AOMEI. They're more powerful than Lifeboat in
the big-picture sense (whole-disk images, encryption, cloud targets, block-level
dedup), and if you want to back up your *entire computer*, use one of them. What
they don't do is *know about Claude* — you'd have to find the hidden folders and
the live VM disk yourself, and several rely on a Windows snapshot component that a
2026 update is known to have broken on some machines.

That's the gap Lifeboat fills: the only **automatic, versioned, Claude- and
Cowork-aware** backup, that copies the *live* VM safely, and works on Windows Home
too. Use a full-disk tool for your whole PC; let Lifeboat look after the Claude
corner of it.

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

Part of a small suite of Claude utilities alongside [Claude Meter](https://github.com/JackBhanded/claude-meter) (live usage on your taskbar), [Claude Lifejacket](https://github.com/JackBhanded/claude-lifejacket) (keep every Claude session aware of your projects), [Claude Compass](https://github.com/JackBhanded/claude-compass) (keep every session attuned to how you like to work), and [Claude Parachute](https://github.com/JackBhanded/claude-parachute) (a safety net for the Bash changes Claude Code's /rewind can't see).

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for the version-by-version list of changes.

## License

[MIT](LICENSE) — do whatever you want, just keep the copyright notice.
