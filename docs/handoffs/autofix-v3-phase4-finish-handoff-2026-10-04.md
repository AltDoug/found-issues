# found-issues v3.0.0 auto-fix — Phase 4 Finish Handoff

**Date:** 2026-10-04 · **Session:** "v3 phase 3 finish + phase 4 build (operator asleep)"
**Status:** Phase 3 is MERGED (PR #188, post-merge run green). Phase 4 is built on `v3/phase4-sweep` (Tasks 1-10 done, pushed, HEAD 88c9b34). Task 11 is partial: the opus whole-branch review is DONE and found 6 Important or conditional issues; the fix pass, the final suites, the PR, the merge and the post-merge watch are still to do.
**Re-verification rule (operator's standing feedback):** do NOT act on this doc's claims without re-verifying against the repo / live state first. Ground truth: `git -C ~/Documents/projects/found-issues/.claude/worktrees/v3-phase4 fetch && git log --oneline 907cdd9..HEAD`, `gh pr list -R AltDoug/found-issues --state all -L 5`, and the git-ignored ledger `.superpowers/sdd/2026-10-04-autofix-v3-phase4-sweep/progress.md` (its `Final:` lines are the findings to fix).

## TL;DR for the next session

1. Work in `~/Documents/projects/found-issues/.claude/worktrees/v3-phase4`, branch `v3/phase4-sweep`, pushed. Read the plan `docs/superpowers/plans/2026-10-04-autofix-v3-phase4-sweep.md` (Rulings, Global Constraints, Review Focus, Task 11) and the ledger.
2. Do the review fix pass: I1, I2, I3, I5 are Important; I4 and I6 are conditional, but each has a cheap fix, so fix them too. Each fix gets a RED→GREEN test. Log the 7 deferred minors with `./bin/found-issues log --fix small …`, re-deriving every line number with `rg -n` AFTER the fixes.
3. Then: full suite, bash 3.2 subset, re-run the E2E script, PR into `release/v3`, merge, watch the post-merge run to a terminal state, write the Phase 5 plan handoff.
4. #1 hazard: the operator was ASLEEP for all of Phase 4. The plan's 10 rulings and the Task 8/9/11 rulings were made on his behalf. Surface them in the PR body and in your final report, under "Rulings made while you were away".

## What was done (verify via commits)

**Phase 3 finish (merged).** PR #188 squash-merged into `release/v3` as `907cdd9`. Post-merge run 37179465772 finished `success` on every job, including `bats (macos-latest)`. Review fixes I1-I4 are in 54dff6e. The ledger was annotated with `--pick`, and `lib/autofix-queue.sh:263` was resolved as verified: ai. The 7 Phase 3 review minors are logged in the ledger.

**Phase 4 commits** (`git log --oneline 907cdd9..HEAD`):

| Commit | What it did |
|---|---|
| f6ba031 | Phase 4 plan handoff |
| ea555f7 | The plan |
| d657d17 | T1: `_fi_af_fix_loop` extracted |
| f0b62a0 | T2: candidates and the `AUTOFIX-SWEEP-DUE` trigger from log, tag, decide and sync |
| 582ca6a | T3: sweep claim and per-entry commit/settle |
| 5c1eaea | T4: classify/wake pass and stand-in support |
| 91d1bb7 | T5: sweep run on launcher A, and `_fi_af_publish` shared with the spot ship |
| 60090b6 | T6: launcher B for sweeps (`next`, sweep-aware verify, release and ship) and `agents/found-issues-sweeper.md` |
| 53423d9 | T7: hook marker and the sweeper nudge |
| 5275afa | T8: `found-issues fix workspace\|test\|ship` and the `commands/fix.md` rewrite (prompt-8..10) |
| e10a4f9 | T9: SessionStart headless guard (prompt-11, extended to the jq and codex notices) |
| f2a12c1 | T10: docs |
| 88c9b34 | E2E-found fix: sweep annotations by dedup key, not by location |

**Verification so far:**
- Full suite at f2a12c1: `bats tests/` exit=0, 1133 ok, 0 not ok. That run predates 88c9b34, which added 1 test (README now says 1134).
- The bash 3.2 subset was stopped unfinished (15 ok, 0 not ok).
- The E2E script `e2e-sweep.sh` is in this session's scratchpad (`/private/tmp/claude-501/-Users-diogosilvasena-Documents-projects-found-issues--claude-worktrees-v3-phase3/94716ef4-a95f-4769-a75d-eeb10f1f1408/scratchpad/`; it may vanish). It drives the B path in bypassPermissions mode (claim+classify, next/test/verify/release/ship) and the A path in default mode (hook, detached run) through the real CLI and hooks, with `claude` and `gh` stand-ins. Both shipped one PR. Recreate the script from the plan's Task 11 step 2 if it is gone.

**Rulings made while the operator was away:** plan Rulings 1-10, plus the ledger's Task 8, Task 9 and Task 11 lines. The main ones:
- A sweep is a queue item with `kind=sweep`.
- Classify and wake run inside the claim.
- One commit per approved entry.
- New setting `sweepBudget`, default $10 (this is plan usage, not billing).
- Branch name `fi/sweep/<date>-<id5>`.
- `fix ship` never merges.
- The prompt-11 guard was extended to the jq and codex notices.

## Remaining work

1. **Fix pass** — exact findings in the ledger's `Final:` lines, from the opus review at 88c9b34:
   - **I1 (B sweep loses committed work).** Verify exits 2/3/6/7 leave a dirty tree. Ship then fails, and `fi_af_worktree_remove` deletes the branch along with its approved commits. Fix: hard reset plus `clean -fd` to `AFI_head` at the start of `fi_af_sweep_ship`. In the sweep brief, say that exit 3 means "fix the tests and verify again".
   - **I2 (A sweep ships after `autofix off`).** `fi_af_enabled || break` falls through into the ship. Fix: requeue, or end stale, when switched off.
   - **I3 (a requeued sweep blocks spot fixes all day).**
     - The sweep cap is taken at claim, so a same-day re-claim gets rc 3.
     - `_fi_af_run` then writes `day/<date>.capped`, which also stops spot drains and the Stop fallback.
     - Fix: don't re-take the cap for a requeued sweep, or keep a sweep's rc 3 from writing `.capped`.
     - Also fix claim's rc 3 message, which says "spot-fix cap" for sweeps.
   - **I4 (conditional).** A fixer child's SessionStart sync can call `fi_af_sweep_check` with root set to the fixer worktree. Fix: skip it when `FOUND_ISSUES_AUTOFIX_CHILD=1`.
   - **I5 (`fix ship` hits the wrong ledger).** It derives root from the git common dir, which is the main checkout. From a linked-worktree session it annotates the wrong ledger. Fix: add `--source <root>` (default `--show-toplevel` of the cwd) and pass it from `commands/fix.md`; regenerate the codex skill.
   - **I6 (forged item state).** Validate that `AFI_wt` lies under `$AFI_root/.claude/worktrees/fi-` before any reset, `add -A` or remove.
2. **Minors** (deferred, log them): A verifier outage counts as a reject; classify cost carries over between items; no per-entry eligibility re-check; `read` without `-r` in classify apply; the headless guard should also honour `FOUND_ISSUES_AUTOFIX_CHILD`; mid-test `[[ ]]` inside loops doesn't fail on bash 3.2 (use `|| false`); the stale sweep claim prints an empty reason.
3. **Task 11 steps 1-6** of the plan: suites, E2E, PR (pr-verify-gate dry-run probe, then the skip-reason file), merge, post-merge watch, Phase 5 handoff. The SDD workspace dir is git-ignored; delete it after a clean review, as the plan says.
4. **Phase 5** (spec §11): statusline, status, SessionStart summary, setup disclosure, doctor, docs (`docs/versioning.md`), the 3.0.0 bump, a live E2E in a real AUTO-mode session (check the classifier allows `autofix ship`, and check whether `.claude/worktrees` writes prompt), the release PR and the marketplace bump. **Then ENABLE auto-fix on this Mac:** `git config --global found-issues.autofix true`, verify with `found-issues doctor`, give the disclosure that fix PRs always auto-merge, and ask once (picker) which client repos to exclude.

## Known live hazards (verify each before relying on it)

1. Subagents must never trigger permission prompts. Reviews are read-only opus Agents; never use the forked `/code-review`.
2. **pr-verify-gate:** probe `gh pr create --dry-run` in its own call, then write the reason into the printed `.pr-verify-skipped` path, after the final commit.
3. **Merging into `release/v3`:** `GH_PR_MERGE_BASE_GUARD=off gh pr merge <N> --auto --squash`. It merges at once (no required checks). macOS bats runs only on the post-merge push run, so watch that run to a terminal state.
4. **Shell gotchas:**
   - This session's shell cwd resets to `v3-phase3` on every call, so prefix every command with `cd <v3-phase4>`.
   - zsh does not word-split `$files`, so pass test files literally.
   - A bats glob that matches nothing aborts the whole run.
   - bats `-f` goes before the file and must not contain spaces.
5. **bash 3.2:** `${VAR:-{\"a\"\}}` keeps a stray backslash, so use a variable default. A mid-test `[[ ]]` asserts nothing on 3.2.
6. **README count:** recount after adding tests (command in the Phase 3 handoff hazard 5).
7. **`found-issues log` line numbers:** re-derive them with `rg -n` after any edit. Phase 3 had to re-log 5 entries whose lines came from a pre-edit review.
8. Never write `docs/found-issues.md` by hand. The shared main checkout is peer-used; the `v3-docs` and `v3-phase3` worktrees are not yours.
9. **Peer session in this worktree:** the SessionStart claim-conflict hook reported a peer session (278c8f3e, the previous v3 session) on this worktree. Check `git status` and `git branch --show-current` before every commit.
10. **Stand-ins:**
    - The stand-in `claude` exports `FI_STANDIN_PROMPT` (its last argument) for `FI_STANDIN_EDIT`, and answers any prompt containing "found-issues classifier" with `FI_STANDIN_CLASSIFY`.
    - The stand-in cost is $0.25 per call. Sweep budget tests depend on that.

## State snapshot (re-verify)

- `v3-phase4`: branch `v3/phase4-sweep`, in sync with origin, clean, HEAD 88c9b34.
- `origin/release/v3` = 907cdd9. No Phase 4 PR is open. The latest tag is v2.10.4.
- The SDD ledger records Tasks 1-10 complete, Task 11 partial, and 6 `Final:` findings plus 7 `Final: minor (deferred)` lines.
- gh: AltDoug is the active account.

## Resume prompt

Working directory ~/Documents/projects/found-issues/.claude/worktrees/v3-phase4 (branch v3/phase4-sweep, pushed; `git fetch`, confirm the tree is clean and `gh auth status` shows AltDoug active). Read docs/handoffs/autofix-v3-phase4-finish-handoff-2026-10-04.md end to end and re-verify its claims first (`git log --oneline 907cdd9..HEAD`, `gh pr list -R AltDoug/found-issues --state all -L 5`, the SDD ledger .superpowers/sdd/2026-10-04-autofix-v3-phase4-sweep/progress.md and its `Final:` lines). Then finish Task 11 of docs/superpowers/plans/2026-10-04-autofix-v3-phase4-sweep.md with superpowers:executing-plans: fix review findings I1-I6 each with a RED->GREEN test, log the 7 deferred minors with `./bin/found-issues log --fix small` (line numbers re-derived after the fixes), run the full suite and the bash 3.2 subset in the background, re-run the E2E, open the PR into release/v3 (state the evidence and list every ruling made while the operator was asleep), merge with GH_PR_MERGE_BASE_GUARD=off, watch the post-merge release/v3 run to a terminal state, delete the SDD workspace, then write the Phase 5 plan handoff. The operator is asleep: do everything possible without him and never trigger permission prompts from subagents. Remember the end-of-Phase-5 task: once 3.0.0 is released and the plugins are updated on this Mac, enable auto-fix here (`git config --global found-issues.autofix true`, verify with `found-issues doctor`, give the disclosure that fix PRs always auto-merge, ask once via picker which client repos to exclude).
