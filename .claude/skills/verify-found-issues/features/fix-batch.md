---
feature: Fix the open entries as a batch
also-called: /found-issues:fix, fi-fix, fix workspace, fix test, fix ship
sources:
  - lib/fix-plumbing.sh
  - commands/fix.md
proven: never
---

## What it is

Works through open entries in one go: re-check each, sort them, get approval, fix on a branch, ship one PR with precise annotations.

## Parts

| What you see | What it does | Handle |
|---|---|---|
| `fix workspace` | A fresh worktree from `origin`'s default branch on its own fix branch | `_fi_fix_workspace` |
| `fix test WORKTREE` | Runs the repo's detected test command there | `lib/fix-plumbing.sh` |
| `fix ship WORKTREE --title T --body-file F --pick LOC` | Push, open the PR, annotate the picks; never merges | `lib/fix-plumbing.sh` |

## How to get to it

`/found-issues:fix` in a session.

## Driving it

No kit drive yet. `workspace` needs an `origin` it can fetch: a bare repo inside the sandbox as `origin` would allow it (network git is blocked), and `ship` also needs the `gh` mock. `tests/cli-fix.bats` builds exactly that.

## What proves it works

The new worktree and branch, the test command's output and exit code, and for `ship` the `pr create` call in the mock's log plus `(PR: ...)` on the picked entries only.

## Gotchas

Not driven yet: the sandbox has no fetchable origin, and the triage and approval steps are a model following `commands/fix.md`.
