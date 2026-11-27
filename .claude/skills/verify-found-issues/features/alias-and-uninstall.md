---
feature: The /fi shortcut and uninstall
also-called: /fi, install-fi-alias, uninstall, /found-issues:uninstall
sources:
  - lib/fi-alias.sh
  - lib/uninstall.sh
  - commands/uninstall.md
proven: 2026-11-27
---

## What it is

`/fi` is a short alias for the slash commands. `uninstall` removes the plugin's private state and leaves each repo's ledger alone.

## Parts

| What you see | What it does | Handle |
|---|---|---|
| `install-fi-alias: created .../.claude/commands/fi.md` | Writes the alias file | `cmd_install_fi_alias` |
| `uninstall-fi-alias: removed ...` | Removes it only if it is ours | `cmd_uninstall_fi_alias` |
| `✓ removed onboarding state`, `✓ removed mode-detection cache` | `uninstall` | `cmd_uninstall` |

## How to get to it

Setup offers the alias; uninstall runs before `/plugin uninstall`.

## Driving it

Run the whole block as one shell call:

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new alias-uninstall)"
$F run "$SB" 'found-issues install-fi-alias && cat "$HOME/.claude/commands/fi.md" && found-issues uninstall-fi-alias'
$F run "$SB" 'found-issues log "src/util.py:2 — survives uninstall" >/dev/null; found-issues install-fi-alias >/dev/null; mkdir -p "$HOME/.claude/found-issues" "$HOME/.cache/found-issues"; found-issues uninstall; ls -a "$HOME/.claude" "$HOME/.cache"; tail -1 docs/found-issues.md'
$F rm "$SB"
```

## What proves it works

- The alias file appears and is removed.
- After `uninstall` the two state folders and `fi.md` are gone and the ledger line is still there.

## Gotchas

**Only ever in a sandbox:** `uninstall` deletes `~/.claude/found-issues` and `~/.cache/found-issues` under `HOME`. Not driven in the proving run: leaving a foreign `fi.md` in place, and statusline removal by `uninstall`.
