---
feature: Codex hook wiring
also-called: install-codex-hooks, uninstall-codex-hooks
sources:
  - lib/codex-hooks.sh
  - lib/codex-rewrite.sh
  - scripts/gen-codex-skills.sh
proven-with: no Codex; the generated shim is run by hand
proven: 2026-11-27
---

## What it is

Writes the plugin's hooks into Codex's user-level `hooks.json`, through small shims that find the current plugin version at run time.

## Parts

| What you see | What it does | Drive it by |
|---|---|---|
| Entries in `hooks.json`, shims under `found-issues/hooks/` | Installs | `install-codex-hooks --codex-home DIR` |
| `env FOUND_ISSUES_HARNESS=codex '.../NAME.sh'` | The command in each entry | read `hooks.json` with `jq` |
| `removed hook entries ... and the shims` | Removes only its own | `uninstall-codex-hooks --codex-home DIR` |

## How to get to it

A Codex user runs it once after `codex plugin add`.

## Driving it

Install next to somebody else's hook, run the SessionStart shim, uninstall, and check the other hook survived.

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new codex-wiring)"; trap '$F rm "$SB"' EXIT
H="$SB/home/.codex"
$F run "$SB" 'mkdir -p "$HOME/.codex" && echo "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"/usr/bin/true foreign\"}]}]}}" > "$HOME/.codex/hooks.json" && found-issues install-codex-hooks --codex-home "$HOME/.codex"'
cp "$H/hooks.json" "$EVIDENCE/hooks.json"
$F run "$SB" 'jq "[.hooks[][].hooks[]] | length" "$HOME/.codex/hooks.json"'
$F is "$SB" '7'
for n in session-start format-enforcer pre-branch-delete post-bash-dispatch first-touch stop-reminder; do
  $F has "$SB" "env FOUND_ISSUES_HARNESS=codex '$H/found-issues/hooks/$n.sh'" "$H/hooks.json"
  $F executable "$SB" "$H/found-issues/hooks/$n.sh"
done
$F run "$SB" 'printf "{\"session_id\":\"c1\",\"source\":\"startup\",\"cwd\":\"%s\"}" "$REPO" | FOUND_ISSUES_HARNESS=codex "$HOME/.codex/found-issues/hooks/session-start.sh" | jq -r ".hookSpecificOutput.hookEventName"'
$F is "$SB" 'SessionStart'
$F run "$SB" 'found-issues uninstall-codex-hooks --codex-home "$HOME/.codex" && jq -c . "$HOME/.codex/hooks.json"'
$F has "$SB" '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/bin/true foreign"}]}]}}'
$F gone "$SB" "$H/found-issues/hooks/session-start.sh"
```

## What proves it works

- Six entries of its own are added beside the foreign one (SessionStart, two PreToolUse, two PostToolUse, Stop), each naming a shim that exists.
- The SessionStart shim answers in JSON with `SessionStart`.
- After uninstall only the foreign entry is left and the shims are gone.

## Gotchas

- Proven against a stand-in: no Codex ran, so loading, the `/hooks` trust review and payloads from a real Codex are unproven.
- Editing a command in `commands/` requires regenerating `codex-skills/` (`bash scripts/gen-codex-skills.sh`; `tests/codex-skills-drift.bats` checks).
- Not driven: `FOUND_ISSUES_CODEX_HOME`, a second install over the first, and the other five shims being run.
