---
feature: Branch delete guard and promote
also-called: pre-branch-delete, branch deletion blocked, /found-issues:promote
sources:
  - hooks/pre-branch-delete.sh
  - lib/promote.sh
  - commands/promote.md
  - lib/hook-gate.sh
proven: 2026-11-27
---

## What it is

Stops a branch delete while the branch holds open or deferred entries that the default branch lacks. `promote` carries them over first.

## Parts

| What you see | What it does | Handle |
|---|---|---|
| `found-issues: branch deletion blocked` (exit 2) | The hook's refusal, listing the entries | `hooks/pre-branch-delete.sh` |
| `Entries on feat/x not yet on main:` | `promote` lists them | `cmd_promote` |
| `Applied 1 entry from feat/x.` | `promote --apply --from BRANCH`, run on another branch | `cmd_promote` |
| `FOUND_ISSUES_PROMOTE_GUARD=off git branch -D x` | One-off bypass, read from the command text | `hooks/pre-branch-delete.sh` |

## How to get to it

The hook fires before any Bash call that deletes a branch.

## Driving it

Run the whole block as one shell call:

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new branch-guard)"
$F run "$SB" "mkdir -p docs && printf '# found-issues\n\n' > docs/found-issues.md && git add docs && git commit -qm ledger && git switch -qc feat/x && found-issues log 'src/util.py:6 — only on the branch' && git commit -qam log && git switch -q main"
DEL='{"tool_name":"Bash","cwd":"__REPO__","tool_input":{"command":"git branch -D feat/x"}}'
$F hook "$SB" pre-branch-delete "$DEL" || true                       # exit 2
$F run "$SB" 'git switch -q feat/x && found-issues promote'
$F run "$SB" 'git switch -qc promote/x main && found-issues promote --apply --from feat/x && git commit -qam promote && git switch -q main && git merge -q promote/x'
$F hook "$SB" pre-branch-delete "$DEL"                               # exit 0
$F snap "$SB" after
$F rm "$SB"
```

## What proves it works

- First hook call: exit 2, naming the stranded entry. After the promote branch is merged, the same call exits 0.
- `after.found-issues.md` on `main` holds the entry.

## Gotchas

The guard skips repos whose default branch does not track the ledger, so the drive commits an empty ledger on `main` first. Not driven in the proving run: `gh api` DELETE commands and loop or variable forms.
