---
feature: Codex hook wiring
also-called: install-codex-hooks, Codex support, stable shims
sources:
  - lib/codex-hooks.sh
  - lib/codex-rewrite.sh
  - lib/harness.sh
  - scripts/gen-codex-skills.sh
  - codex-skills/
proven: 2026-11-27
---

## What it is

Writes the plugin's hooks into Codex's user-level `hooks.json`, through small shims that find the current plugin version at run time.

## Parts

| What you see | What it does | Handle |
|---|---|---|
| `install-codex-hooks --codex-home DIR` | Writes `hooks.json` entries and the shims | `cmd_install_codex_hooks` |
| `env FOUND_ISSUES_HARNESS=codex '.../found-issues/hooks/NAME.sh'` | The command in each entry | `lib/codex-hooks.sh` |
| `uninstall-codex-hooks` | Removes only its own entries and the shims | `cmd_uninstall_codex_hooks` |

## How to get to it

A Codex user runs it once after `codex plugin add`.

## Driving it

Run the whole block as one shell call:

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new codex-wiring)"
$F run "$SB" 'found-issues install-codex-hooks --codex-home "$HOME/.codex" && jq -r ".hooks | to_entries[] | .key as \$k | .value[] | .hooks[] | \"\(\$k): \(.command)\"" "$HOME/.codex/hooks.json" && cp "$HOME/.codex/hooks.json" "$EVIDENCE/hooks.json"'
$F run "$SB" 'printf "{\"session_id\":\"c1\",\"source\":\"startup\",\"cwd\":\"%s\"}" "$REPO" | FOUND_ISSUES_HARNESS=codex "$HOME/.codex/found-issues/hooks/session-start.sh" | jq -r ".hookSpecificOutput.hookEventName"'
$F run "$SB" 'found-issues uninstall-codex-hooks --codex-home "$HOME/.codex" && cat "$HOME/.codex/hooks.json"'
$F rm "$SB"
```

## What proves it works

- Six entries (SessionStart, two PreToolUse, two PostToolUse, Stop), each running a shim under the sandbox's Codex folder.
- The SessionStart shim answers with `SessionStart` in JSON; after uninstall `hooks.json` is `{"hooks": {}}`.

## Gotchas

Proven against a stand-in: no Codex ran, so loading, the `/hooks` trust review and payloads from real Codex are unproven. Editing a command in `commands/` requires regenerating `codex-skills/` (`bash scripts/gen-codex-skills.sh`; `tests/codex-skills-drift.bats` checks).
