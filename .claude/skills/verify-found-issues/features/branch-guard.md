---
feature: Branch delete guard and promote
also-called: pre-branch-delete, branch deletion blocked, promote, /found-issues:promote
sources:
  - hooks/pre-branch-delete.sh
  - lib/promote.sh
  - commands/promote.md
  - codex-skills/fi-promote/
proven-with: hand-built hook payloads (no Claude Code or Codex)
proven: 2026-11-27
proven-hash: 0f39d6f80c96
---

## What it is

Stops a branch delete while the branch holds open or deferred entries that the default branch lacks. `promote` carries them over first.

## Parts

| What you see | What it does | Drive it by |
|---|---|---|
| `found-issues: branch deletion blocked` (exit 2) | The refusal, listing the entries | a Bash payload whose command is `git branch -D NAME` |
| `Entries on feat/x not yet on main:` | Lists what would move | `found-issues promote` on that branch |
| `Applied 1 entry from feat/x.` | Copies them over | `promote --apply --from BRANCH`, on another branch |
| Silence, exit 0 | One-off bypass, read from the command text | `FOUND_ISSUES_PROMOTE_GUARD=off git branch -D x` as the command |

## How to get to it

The hook fires before any Bash call that deletes a branch.

## Driving it

```bash
set -eo pipefail
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new branch-guard)"; trap '$F rm "$SB"' EXIT
$F registered "$SB" PreToolUse pre-branch-delete Bash
$F run "$SB" "mkdir -p docs && printf '# found-issues\n\n' > docs/found-issues.md && git add docs && git commit -qm ledger && git switch -qc feat/x && found-issues log 'src/util.py:6 — only on the branch' && git commit -qam log && git switch -q main"
DEL='{"tool_name":"Bash","cwd":"__REPO__","tool_input":{"command":"git branch -D feat/x"}}'
$F hook "$SB" pre-branch-delete "$DEL" || true
$F rc "$SB" 2
$F has "$SB" 'found-issues: branch deletion blocked'
$F has "$SB" 'src/util.py:6 — only on the branch'
$F hook "$SB" pre-branch-delete '{"tool_name":"Bash","cwd":"__REPO__","tool_input":{"command":"FOUND_ISSUES_PROMOTE_GUARD=off git branch -D feat/x"}}'
$F rc "$SB" 0
$F lacks "$SB" 'branch deletion blocked'
$F run "$SB" 'git switch -q feat/x && found-issues promote'
$F has "$SB" 'Entries on feat/x not yet on main:'
$F run "$SB" 'git switch -qc promote/x main && found-issues promote --apply --from feat/x && git commit -qam promote && git switch -q main && git merge -q promote/x'
$F has "$SB" 'Applied 1 entry from feat/x.'
$F has "$SB" 'src/util.py:6 — only on the branch' docs/found-issues.md
$F hook "$SB" pre-branch-delete "$DEL"
$F silent "$SB"
$F snap "$SB" after
```

## What proves it works

- The first delete payload exits 2 and names the stranded entry. The bypass form passes.
- After the promote branch is merged, `main`'s ledger holds the entry and the same payload passes silently.

## Gotchas

- The guard skips repos whose default branch does not track the ledger, so the drive commits an empty ledger on `main` first.
- Delete by literal name: a `$variable` or a loop cannot be checked.
- Not driven: `gh api` DELETE commands, `git push --delete`, and loop or variable forms. The `hooks.json` line is read, not fired.
