---
description: Clean up plugin-private state (statusline segment, onboarding marker, mode cache, /fi alias) before /plugin uninstall
argument-hint: (no arguments)
allowed-tools: Bash(found-issues:*)
---

The user wants to uninstall `found-issues`. Claude Code's `/plugin uninstall`
removes the plugin itself, but plugin-private state under `~/.claude/` and
`~/.cache/` is not touched by the platform — that's our problem to clean up.

Run the deterministic cleanup command:

```bash
found-issues uninstall
```

This removes (only what was actually installed):

1. **Statusline segment** — the marker-bracketed block in `~/.claude/statusline.sh`
   (preserves the rest of the file and the executable permission)
2. **Onboarding marker** — `~/.claude/found-issues/` directory
3. **Mode-detection cache** — `~/.cache/found-issues/` directory
4. **`/fi` alias** — `~/.claude/commands/fi.md` *only if* it contains
   `Run /found-issues:` (won't touch a user's own `/fi` command)

What it does **not** touch:

- Per-repo `docs/found-issues.md` and `docs/found-issues-archive.md` files —
  those are the user's project data, intentionally preserved.

After the cleanup runs, remind the user to complete removal from Claude Code:

```
/plugin uninstall found-issues
/plugin marketplace remove altdoug-plugins   (if installed via aggregator)
```

Those are slash commands — they only work from inside Claude Code, which is
why the CLI prints them as next-steps rather than running them itself.
