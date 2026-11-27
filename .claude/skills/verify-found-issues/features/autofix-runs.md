---
feature: Auto-fix runs and sweeps
also-called: auto-fix, spot fix, sweep, the fixer, merge when green
sources:
  - lib/autofix.sh
  - lib/autofix-queue.sh
  - lib/autofix-engine.sh
  - lib/autofix-ship.sh
  - lib/autofix-sweep.sh
  - lib/autofix-b.sh
  - lib/autofix-classify.sh
  - lib/autofix-hook.sh
  - agents/
proven: never
---

## What it is

Opt-in background fixing: a `(fix: small)` entry is fixed in its own worktree, tested, checked by a reviewer model, and shipped as a PR that merges itself.

## Parts

| What you see | What it does | Handle |
|---|---|---|
| `autofix run ID` | Headless fix or sweep | `cmd_autofix` |
| `autofix claim, brief, next, search, test, verify, diff, ship, release` | The steps for an in-session fixer | `lib/autofix.sh`, `lib/autofix-b.sh` |
| `autofix cancel ID` | Stop an item | `cmd_autofix` |
| `🔧N` in the statusline | Runs in progress | `fi_segment_af_suffix` |

## How to get to it

It starts from hooks once `found-issues config autofix true` is set in a GitHub repo with a test command.

## Driving it

Not by this kit. The repo's own tests drive it with stand-in engines, a bare local remote and the `gh` mock (`tests/autofix-helpers.bash`): run the one that matches the change, for example `bats tests/autofix-run.bats`. That is a test result, not a proof of the feature.

## What proves it works

A real run would show a queued item finishing in `autofix status`, a fix branch, a merged PR, and the entry closed by sync.

## Gotchas

Never driven: a real run needs a paid engine and a real GitHub repo, its PR merges itself, and verification keeps `FOUND_ISSUES_AUTOFIX=off`. Earlier live runs are written up in `docs/e2e/`.
