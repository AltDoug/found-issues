---
feature: Auto-fix runs and the fix batch
also-called: auto-fix, sweep, /found-issues:fix, fi-fix
sources:
  - lib/autofix.sh
  - lib/autofix-queue.sh
  - lib/autofix-engine.sh
  - lib/autofix-ship.sh
  - lib/autofix-sweep.sh
  - lib/autofix-b.sh
  - lib/autofix-classify.sh
  - lib/autofix-hook.sh
  - lib/fix-plumbing.sh
  - commands/fix.md
  - codex-skills/fi-fix/
  - agents/
proven: never
---

## What it is

Two ways of having entries fixed for you. Auto-fix is opt-in and in the background: a `(fix: small)` entry is fixed in its own worktree, tested, checked by a reviewer model and shipped as a PR that merges itself. `/found-issues:fix` works through open entries in one go, with the user approving: re-check, sort, fix on a branch, ship one PR with precise annotations.

## Gotchas

Not driven: an auto-fix run needs a paid engine and a real GitHub repo, its PR merges itself, and verification keeps `FOUND_ISSUES_AUTOFIX=off`. The fix batch has no kit drive: the sandbox has no `origin` it can fetch, and its triage and approval steps are a model following `commands/fix.md`.

- What a test run covers instead (a test result, not a proof of the feature): `tests/autofix-*.bats` drive auto-fix with stand-in engines, a bare local remote and the `gh` mock (`tests/autofix-helpers.bash`); `tests/cli-fix.bats` builds the fetchable origin the batch needs (network git is blocked, so a bare repo inside the sandbox would serve).
- Auto-fix starts from hooks, once `found-issues config autofix true` is set in a GitHub repo with a test command. Its commands: `autofix run ID` (headless), `claim`, `brief`, `next`, `search`, `test`, `verify`, `diff`, `ship`, `release` (an in-session fixer) and `cancel ID`. Runs in progress show as `🔧N` in the statusline.
- The batch's commands: `fix workspace` (a worktree from `origin`'s default branch on its own fix branch), `fix test WORKTREE`, and `fix ship WORKTREE --title T --body-file F --pick LOC` (push, open the PR, annotate the picks; it never merges).
- What a real proof would show: a queued item finishing in `autofix status`, a fix branch, a merged PR and the entry closed by sync; for the batch, the worktree and branch, the test output and exit code, and `(PR: ...)` on the picked entries only. Earlier live runs are written up in `docs/e2e/`.
