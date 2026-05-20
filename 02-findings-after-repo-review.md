# Findings After Seeing claude-meter Repo

**Repo:** https://github.com/JackBhanded/claude-meter
**Reviewed:** 2026-05-21
**Reviewer:** Claude (prior context, web_fetch only — no clone, no file reads)

## What I actually found

The repo is essentially empty. As of review:

- 1 commit total
- Only file in tree: `.gitattributes`
- No README, no source, no LICENSE
- 0 stars, 0 releases, no description
- GitHub username: `JackBhanded` (so the canonical install URL for Lifeboat is `github.com/JackBhanded/claude-lifeboat`, not `github.com/jack/claude-lifeboat` as I had placeholdered)

This means there are no existing conventions, README style, install patterns, or coding patterns from Jack's prior shipped work that I can learn from and mirror in Lifeboat. The "Claude usage on taskbar" project the user referenced verbally has not actually been published as code yet — only as a repo placeholder.

## What this changes for the porting Claude

**1. Update every URL in Lifeboat from `jack/claude-lifeboat` to `JackBhanded/claude-lifeboat`.** This affects:
- `README.md` (multiple places — install one-liner, contributing link, discussions link, troubleshooting links)
- `install.ps1` (the comment block at the top)
- `CHANGELOG.md` (no URLs but worth a scan)
- Anywhere else the placeholder snuck in

**2. Don't assume Jack has a prior public README pattern to match.** Use Lifeboat's README as-is. It's clean and follows standard open-source conventions (badges, table of contents, install/usage/troubleshooting, honest "what this is not", contributing section).

**3. Don't assume Jack has a prior install pattern.** The `irm ... | iex` one-liner pattern in Lifeboat's installer follows scoop/oh-my-posh conventions and is the right default.

**4. There's likely no `claude-meter` Windows tool to interoperate with.** I had speculated maybe Lifeboat could read claude-meter's status or share a tray icon. With no claude-meter code existing, treat that as a v0.3+ thought, not a v0.1 design constraint.

## What we don't know about claude-meter

The user described it verbally as showing "Claude usage on taskbar." This sounds like a tray icon / system tray app that displays usage limits. We don't know:

- Whether it was finished and they just didn't push, or they only got as far as creating the repo
- The language (could be C#, Python, Electron, Rust — anything)
- Whether it talked to a Claude API or scraped the desktop app
- If there's local state we'd want Lifeboat to back up alongside Claude Desktop

If the porting Claude finds claude-meter code added later, two paths to consider:

- **If claude-meter stores config in `%LOCALAPPDATA%\ClaudeMeter\` or similar:** add it to `Get-ClaudeDataPaths` in `src/lib/common.ps1` as another auto-detected path (similar to how Claude Code is detected in three possible locations).
- **If claude-meter has a tray icon framework already:** Lifeboat could potentially share it instead of relying on Windows toast notifications. Toasts are limited (no persistent indicator). But this is a v0.2+ idea.

## Recommendation to the porting Claude

Treat the claude-meter repo as a separate, unrelated project for now. Don't try to merge or interoperate. Ship Lifeboat at `github.com/JackBhanded/claude-lifeboat` on its own. If claude-meter ships later and there's actual integration value, do it as a v0.2 follow-up.

## Honest note about my prior advice

In the handoff document I wrote (Part D, item "Things I'd do differently"):

> *"Pinning down the user's existing Claude-meter project first. They published a project together with Claude before. Reading that project's README, install pattern, and naming would have informed Lifeboat's conventions and likely saved iterations. Worth getting that URL early."*

That advice was based on the user saying they had "published" their first git project. The reality is they created a repo but haven't pushed code yet. So:

- The iteration cost I worried about ("not matching Jack's existing conventions") was lower than I thought
- But the lesson stands: ask for the actual URL before assuming what's there
- And: "I published it" can mean anything from "I have a private prototype" to "it's on the homepage of HN." Verify before optimizing for compatibility.

The porting Claude can take this as a small case study in not over-indexing on what users describe verbally vs. what's actually shipped.
