---
name: fi-uninstall
description: Wipe plugin-private state — statusline segment, onboarding marker, mode cache, fi alias — BEFORE removing the found-issues plugin itself. The ledger (docs/found-issues.md) is repo data and stays untouched. Run only when actually removing the plugin, not for troubleshooting (that is $fi-doctor).
---
<!-- loc-override: generated 1:1 from commands/uninstall.md by scripts/gen-codex-skills.sh; length is owned by the source command file -->

The user wants to uninstall `found-issues`. Claude Code's `/plugin uninstall`
removes the plugin itself, but plugin-private state under `~/.claude/` and
`~/.cache/` is not touched by the platform — that's our problem to clean up.

**Order matters — surface this to the user before running anything.** The
canonical sequence is:

1. `$fi-uninstall` (this command — runs `found-issues uninstall`)
2. `/plugin uninstall found-issues` (Claude Code platform command)
3. `/plugin marketplace remove altdoug-plugins` (only if also removing the marketplace)

If the user already ran `/plugin uninstall found-issues` first (the common
mistake), our CLI may not be on PATH anymore. Tell them to either:
- Reinstall the plugin temporarily (`/plugin install found-issues`), then
  re-run this skill in the right order; or
- Manually `rm -rf ~/.claude/found-issues ~/.cache/found-issues` and edit
  `~/.claude/statusline.sh` to remove the marker-bracketed block (between
  `# === found-issues plugin segment ===` and `# === end ...`).

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
