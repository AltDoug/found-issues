# Auto-fix 3.3.0 release — Session Handoff

**Date:** 2026-10-06 · **Session:** "Release 330"
**Status:** v3.2.1 is fully shipped (claude-plugins #52 merged, post-merge run green). 3.3.0 SDD Tasks 1-7 and Task 3 are built and reviewed; Task 8 steps 1-3 are done (684fc68, full suite 1..1342, 0 not ok). Next is Task 8 step 5: the workflow-backed `/code-review` at xhigh, then the release PR, merge, release, marketplace bump and sync.
**Re-verification rule (operator's standing feedback):** do NOT act on this
doc's claims without re-verifying against the repo / live state first.
Ground truth: in the worktree `git status --short`, `git log --oneline origin/main..HEAD` (expect 10 commits, f8c3c73..684fc68), the SDD ledger `.superpowers/sdd/2026-10-06-autofix-codex-models/progress.md`; and `gh release list -R AltDoug/found-issues -L 2`, `gh pr view 52 -R AltDoug/claude-plugins --json state`.

## TL;DR for the next session
1. Work ONLY in the worktree `/Users/diogosilvasena/Documents/projects/found-issues/.claude/worktrees/release-3-3-0` (branch release/v3.3.0, base 2a1e82b). Never touch the main checkout. `gh auth status` must show AltDoug active.
2. Read the SDD ledger end to end: it holds every ruling R1-R15 and every deferred minor. Plan: `docs/superpowers/plans/2026-10-06-autofix-codex-models.md`; spec: `docs/superpowers/specs/2026-10-06-autofix-codex-models-design.md` (section 9, sweep batches, is binding).
3. Tasks 1-7, Task 3 and Task 8 steps 1-3 are complete and reviewed. Never re-dispatch them.
4. Next: Task 8 step 5, `/code-review` at xhigh on the branch (ruling R15 makes it the final whole-branch review). The workflow variant may check out main mid-run: re-check `git branch --show-current` afterwards.
5. #1 hazard: `docs/found-issues.md` is modified and uncommitted in the worktree on purpose (see Dirty state). Never `git checkout` it, never `git add -A`.
6. Report every ruling you make on the operator's behalf, and collect every `Ruling:` line from the ledger for the final report.

## What was done (verify via PR descriptions / commits)
**v3.2.1 tail (AltDoug/found-issues + AltDoug/claude-plugins)**
- Post-merge run 37505263276 on main concluded success (all 8 jobs).
- AltDoug/claude-plugins **#52** (found-issues 3.2.0 -> 3.2.1, marketplace.json) squash-merged as cc7327e at 2026-10-06T18:08:46Z. claude-plugins has no CI workflows (prior bumps #49-#51 also merged with 0 checks); the gate was the found-issues post-merge run being green. `gh release list -L 2` shows v3.2.1 Latest, v3.2.0.

**3.3.0 build on branch release/v3.3.0 (10 commits ahead of origin/main bb2e836; branch pushed)**
- Task 1 f8c3c73: per-role Codex models, `inherit` as the opt-out. (7698813 is the previous handoff doc.)
- Task 2 c73cfdb: a failed Codex turn (`turn.failed`) is an outage that requeues, also on the verifier; `FI_AF_CHILD_TOKENS`. Fixes ledger entry `lib/autofix.sh:129` (annotate on the release PR, ruling R6).
- Task 4 015a849: opt-in token caps `autofix.codexRunTokens` / `autofix.codexSweepTokens`; `fi_af_run_budget_left`, `fi_af_spent_text`, `fi_af_token_cap`, `fi_af_cap_int`.
- Task 5 5f6f329: `runBudget` / `sweepBudget` opt-in with no default; no `--max-budget-usd` when unset; doctor says "no dollar cap".
- Task 6 0dd8eb6 + dcb394f (fix round 1): `sweepMax` -> `sweepBatch` (default 8); sweeps take every fixable entry and ship one PR per batch at a file boundary; continuation items (cont, cap_day, skip_files, engine, chain_cost/chain_tokens); launcher B batches too (R9); per-item cost is the batch's own spend (R10); retry-ship queues no continuation.
- Task 7 dff8ced: run log "codex <role>: model ..., N tokens, run total X[/cap]"; status "<n>/<cap> tokens" or "<n> tokens" (R8); doctor "Codex models:" line plus model-error warning; PR body lists models; `_fi_af_end` records the engine that actually ran.
- Task 3 df448e1 (controller-run, operator approved via picker): `docs/e2e/v3.3-codex-tokens-2026-10-06.md`, 8 live Codex runs, all shipped (pinned spots 236626 / 236658 / 202186 tokens, pinned sweep 779824 tokens for 3 entries; inherit similar); suggested caps RUN_CAP 800000 / SWEEP_CAP 2400000 (R11). Usage is reported only on `turn.completed` (no streaming). The operator chose via picker to delete AltDoug/fi-v3-e2e; it was deleted and confirmed.
- Task 8 steps 1-3 684fc68: `docs/configuration.md`, README, CHANGELOG `[3.3.0] - 2026-10-06`, `FI_VERSION` and both `plugin.json` at 3.3.0. Full bare `bats tests/`: `1..1342`, 0 not ok (saved at `.superpowers/sdd/2026-10-06-autofix-codex-models/full-suite.txt`); `scripts/check-version.sh` OK (3.2.1 -> 3.3.0 MINOR); README count 1342 matches.
- Task 8 step 4 (R14): e2e evidence reuses Task 3's live runs plus a fresh `autofix status` / `doctor` on the kept local fixture clone with codexRunTokens=800000. Quotes are in the ledger's Task 8 lines: status "237138/800000 tokens", "674908/2400000 tokens"; doctor "Codex models: fixer gpt-6.1-sol (medium), verifier gpt-6-astra (high), classifier gpt-6.1-sol (low)". The raw captures were in the predecessor's scratchpad (may be gone); re-capture from the run logs under `~/.cache/found-issues/autofix/AltDoug__fi-v3-e2e/runs/` (state in `~/.claude/found-issues/autofix/AltDoug__fi-v3-e2e/`) if needed.
- New ledger entry (logged with `--decide`) at `lib/autofix-ship.sh:231`: merge-when-green gives up on a conflicting PR. A launcher-A drain of 3 spot fixes produced conflicting PR #3 (adjacent ledger lines + test.sh); resolved by hand in the e2e (R12). Deliberately NOT fixed in 3.3.0.

**Rulings made on the operator's behalf this session (all also in the ledger)**
- Merged claude-plugins #52 with no checks (repo has no CI; gate = found-issues post-merge run green).
- R4 Task 3 runs after Task 7; R5 stand-in fails before edits; R6 annotate `lib/autofix.sh:129` on the release PR; R7 `sweepMax` key refused by `config`; R8 status shows tokens without a cap; R9 launcher B batch close; R10 chain_cost/chain_tokens; R11 suggested caps from the formula (800000 / 2400000); R12 hand-resolved e2e PR #3 and serialized the inherit spots; R13 Task 8 split (implementer steps 1-3, controller 4-6); R14 e2e evidence reuse; R15 `/code-review` xhigh serves as the final review.

## Remaining work
In order:
1. **Re-verify**: `gh auth status` (AltDoug), `git status --short` (only `docs/found-issues.md` modified), `git branch --show-current` (release/v3.3.0), `git log --oneline origin/main..HEAD` (10 commits), ledger tail.
2. **Task 8 step 5: `/code-review` at xhigh** on the branch (R15; memory feedback-adversarial-review-release-branches: v1.6.0's review caught 10 confirmed defects). Re-check `git branch --show-current` after it (the workflow variant can check out main). Triage the ledger's deferred minors against its findings. Notable ones: Task 1 leading-dash model value accepted at runtime (seen live: a raw `git config ... --unset` typo set the model to "--unset" and doctor printed "fixer --unset (medium)"; `found-issues config` itself refuses it); Task 2 `fromjson` on a non-object `error.message`; Task 2 verifier crash without `turn.failed` reads as reject; Task 4 vacuous asserts; Task 5 doctor raw runBudget; Task 6 `skip_files` ':' paths and `FE_path` not reset (`lib/autofix-sweep.sh:381`, `:493-495`); Task 7 "model" substring heuristic (`lib/autofix-engine.sh:229`). Fix confirmed findings through an implementer dispatch (`sonnet`) in new commits, then re-run full bare `bats tests/` (about 20 min, background) and re-check the README test count.
3. **Merge origin/main into the branch** (bb2e836, the #225 ledger sync; its flip lines are identical to the hook's, so they merge clean), then **commit `docs/found-issues.md`** so the new `lib/autofix-ship.sh:231` entry lands with the release PR.
4. **Release PR** titled "release: v3.3.0 — Codex auto-fix: pinned models and a token cap" with the full-suite `1..N` line, e2e quotes and the rulings list. pr-verify-gate needs verify/review telemetry or a skip file (hazard 4). Then `found-issues annotate-pr <N> --pick lib/autofix.sh:129` plus any other entry the branch honestly fixes (review the hook candidates). AltDoug policy: `gh pr merge <N> --auto --squash` (no --delete-branch), watch every check to a terminal state (Windows bats about 20-31 min), then the post-merge `tests` run and `release.yml` to success; `gh release list -R AltDoug/found-issues -L 1` must show v3.3.0 Latest.
5. **Task 8 step 6: claude-plugins marketplace bump** found-issues 3.2.1 -> 3.3.0 (same shape as #52, worktree under `~/Documents/projects/claude-plugins/.claude/worktrees/`), PR, merge after the found-issues post-merge run is green.
6. **`/found-issues:sync`**; collect every `Ruling:` line from the ledger into the final report ("Rulings I made"); then delete the SDD workspace (`rm -rf "${SDD:?}"` with SDD set to `.superpowers/sdd/2026-10-06-autofix-codex-models`) and use `superpowers:finishing-a-development-branch`.
7. **Still open from earlier**: ask the operator (picker) which release takes the 14 decided ledger entries (recommend a batch after 3.3.0, `lib/autofix-engine.sh:120` safety item first); the kh2 `tools/bin/build.sh` retag is an operator checkpoint; the operator runs `/plugin update found-issues` to get 3.2.1/3.3.0 locally (installed CLI/hooks are still 3.2.0).

## Known live hazards (verify each before relying on it)
1. Shell cwd resets after every Bash call: `cd` into the worktree inside the same command.
2. The installed plugin hook is 3.2.0: running `found-issues log` with autofix on prints AUTOFIX-QUEUED / AUTOFIX-SWEEP-DUE markers that the PostToolUse hook turns into a detached `autofix run` with the OLD CLI. Redirect log output to a file when exercising the branch CLI on a real repo.
3. Subagents can die on transient network errors (ENOTFOUND hit Task 7 once): check the worktree for uncommitted partial work and resume the same agent via SendMessage.
4. pr-verify-gate needs verify/review telemetry or a skip file at `~/.claude/.session-tracker/<session>.<cksum of repo root>.pr-verify-skipped`, written in its own Bash call; it expires at the next commit. Keep literal PR-create text out of non-PR commands. stop-tests-pass credits only a bare `bats tests/`.
5. Full `bats tests/` takes about 20 minutes locally: run in background. macOS CI runs bash 3.2 (guard empty-array expansions under `set -u`); ASCII-only `@test` names; use `! cmd || false`, never a bare `!`.
6. `docs/found-issues.md` hook flips: a hook rewrites ledger entries in whatever checkout runs it. Never `git checkout` the file; never `git add -A`. Auto-fix is on globally: log design questions with `--decide`, not `--fix`.
7. The rm-target-guard hook blocks `rm -rf "$VAR"`; write `"${VAR:?}"`.
8. `git config <key> --unset` is the wrong order (it sets the literal value "--unset"); use `git config --unset <key>`.
9. `gh pr checks --watch` started right after PR creation exits with "no checks reported": wait for the run to register, then `gh run watch <id>`. Foreground `sleep N && cmd` chains are blocked; use `run_in_background` or Monitor.
10. Read-first hook: Edit/Write on a file needs a prior Read in the session. The SDD workspace is git-ignored and lives only in this worktree: do not remove the worktree.

## State snapshot (re-verify)
- Checked at write time (2026-10-06): branch release/v3.3.0, up to date with origin/release/v3.3.0, HEAD 684fc68 (then this handoff doc on top); `git log --oneline origin/main..HEAD` = 10 commits (f8c3c73, 7698813, c73cfdb, 015a849, 5f6f329, 0dd8eb6, dcb394f, dff8ced, df448e1, 684fc68). origin/main is bb2e836 (#225), NOT yet merged into the branch.
- Dirty state (explain, do not lose): `docs/found-issues.md` modified and uncommitted: (a) a hook flipped 3 entries to [fixed] (`hooks/stop-reminder.sh:87`, `lib/autofix.sh:127`, `lib/autofix-sweep.sh:387`), identical to what #225 already put on main; (b) the NEW decide entry `lib/autofix-ship.sh:231`. Plan: merge origin/main, then commit the ledger with the release PR.
- `gh release list -R AltDoug/found-issues -L 2`: v3.2.1 Latest (2026-10-06T17:39:47Z), v3.2.0. `gh pr view 52 -R AltDoug/claude-plugins --json state`: MERGED.
- Open PRs expected: found-issues #171 (external, unrelated). None of ours.
- SDD ledger last line: "NEXT: Step 5 = /code-review xhigh on the branch (R15) ...".

## Resume prompt
> Work in the existing worktree /Users/diogosilvasena/Documents/projects/found-issues/.claude/worktrees/release-3-3-0 (branch release/v3.3.0; never touch the main checkout). Run `gh auth status` and confirm AltDoug is active. Read docs/handoffs/autofix-3.3.0-release-handoff-2026-10-06.md end to end and the SDD ledger .superpowers/sdd/2026-10-06-autofix-codex-models/progress.md, then re-verify against live state (git status --short, git log --oneline origin/main..HEAD, gh release list -R AltDoug/found-issues -L 2, gh pr view 52 -R AltDoug/claude-plugins --json state). Then continue Task 8 step 5, the workflow-backed /code-review at xhigh, per superpowers:subagent-driven-development (Tasks 1-7 and Task 3 are complete and Task 8 steps 1-3 are done; never re-dispatch them): triage the ledger's deferred minors against its findings, fix confirmed ones via an implementer dispatch, merge origin/main and commit the ledger, then the release PR, merge on green, release, claude-plugins marketplace bump, and /found-issues:sync. Never `git add -A`; never `git checkout` docs/found-issues.md. Report every ruling you make on the operator's behalf.
