---
feature: Setup, the /fi shortcut and uninstall
also-called: /found-issues:setup, fi-setup, /fi, install-fi-alias, /found-issues:uninstall, fi-uninstall
sources:
  - lib/fi-alias.sh
  - lib/uninstall.sh
  - commands/setup.md
  - commands/uninstall.md
  - codex-skills/fi-setup/
  - codex-skills/fi-uninstall/
proven: 2026-11-27
proven-hash: 2dcf8163f01f
---

## What it is

Getting the plugin set up and taking it off. `/found-issues:setup` is a guided walkthrough with optional statusline, git pre-commit hook, `/fi` shortcut and auto-fix opt-in. `/fi` is a short alias for the slash commands. `uninstall` removes the plugin's private state and leaves each repo's ledger alone.

## Parts

| What you see | What it does | Drive it by |
|---|---|---|
| `install-fi-alias: created .../.claude/commands/fi.md` | Writes the alias file | `found-issues install-fi-alias` |
| `uninstall-fi-alias: removed ...` | Removes it only if it is ours | `uninstall-fi-alias` |
| `is not the found-issues alias` | Somebody's own `/fi` is left alone (install exits 1) | write your own `fi.md` first |
| `✓ removed onboarding state`, `✓ removed mode-detection cache` | Takes the private state off | `found-issues uninstall` |
| `found-issues is now active.`, four optional steps | The walkthrough | `/found-issues:setup` in a real session |

## How to get to it

`/found-issues:setup` after installing (`$fi-setup` in Codex); uninstall runs before `/plugin uninstall`.

## Driving it

The alias: install, read, remove; then somebody's own `/fi` is left alone by both.

```bash
set -eo pipefail
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new alias)"; trap '$F rm "$SB"' EXIT
FI_MD="$SB/home/.claude/commands/fi.md"
$F run "$SB" 'found-issues install-fi-alias'
$F has "$SB" 'install-fi-alias: created'
$F has "$SB" 'Run /found-issues:$ARGUMENTS' "$FI_MD"
$F run "$SB" 'found-issues uninstall-fi-alias'
$F has "$SB" 'uninstall-fi-alias: removed'
$F gone "$SB" "$FI_MD"
$F run "$SB" 'echo mine > "$HOME/.claude/commands/fi.md" && found-issues uninstall-fi-alias'
$F has "$SB" 'is not the found-issues alias'
$F has "$SB" 'mine' "$FI_MD"
$F run "$SB" 'found-issues install-fi-alias' || true
$F rc "$SB" 1
$F has "$SB" 'Not overwriting your /fi command'
$F has "$SB" 'mine' "$FI_MD"
```

Uninstall: the two state folders and our alias go, the ledger stays.

```bash
set -eo pipefail
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new uninstall)"; trap '$F rm "$SB"' EXIT
H="$SB/home"
$F run "$SB" 'found-issues log "src/util.py:2 — survives uninstall" && found-issues install-fi-alias && mkdir -p "$HOME/.claude/found-issues" "$HOME/.cache/found-issues"'
$F exists "$SB" "$H/.claude/found-issues"
$F exists "$SB" "$H/.cache/found-issues"
$F exists "$SB" "$H/.claude/commands/fi.md"
$F run "$SB" 'found-issues uninstall'
$F has "$SB" '✓ removed onboarding state'
$F has "$SB" '✓ removed mode-detection cache'
$F gone "$SB" "$H/.claude/found-issues"
$F gone "$SB" "$H/.cache/found-issues"
$F gone "$SB" "$H/.claude/commands/fi.md"
$F has "$SB" 'survives uninstall' docs/found-issues.md
```

## What proves it works

- The alias file appears and is removed; a foreign `fi.md` keeps its content through uninstall and install.
- After `uninstall` the two state folders and `fi.md` are gone and the ledger line is still there.

## Gotchas

- **Only ever in a sandbox:** `uninstall` deletes `~/.claude/found-issues` and `~/.cache/found-issues` under `HOME`.
- Not driven: the setup walkthrough. It is prose a model follows with a person answering (`commands/setup.md`), so it needs Claude Code or Codex with the plugin loaded. Drive the CLI calls it offers through statusline.md, format-guard.md, this file and autofix-settings.md; after editing the prose run `bats tests/setup-autofix-disclosure.bats tests/setup-custom-statusline-flow.bats`. In a real session each offered option ends in the state its own feature file describes.
- Not driven: statusline removal by `uninstall`.
