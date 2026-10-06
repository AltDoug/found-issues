# Auto-fix 3.3.0 build — Session Handoff

**Date:** 2026-10-06 · **Session:** "Release 321"
**Status:** v3.2.1 is released (v3.2.1 Latest, #223) but its post-merge `tests` run and the claude-plugins marketplace bump (#52) are still open; 3.3.0 Task 1 of 8 is built and reviewed on branch release/v3.3.0 (f8c3c73); next is Task 2.
**Re-verification rule (operator's standing feedback):** do NOT act on this
doc's claims without re-verifying against the repo / live state first.
Ground truth: `gh run view 37505263276 -R AltDoug/found-issues --json status,conclusion,jobs`, `gh pr view 52 -R AltDoug/claude-plugins --json state`, `gh release list -R AltDoug/found-issues -L 2`, and in the worktree `git log --oneline origin/main..HEAD` plus the SDD ledger `.superpowers/sdd/2026-10-06-autofix-codex-models/progress.md`.

## TL;DR for the next session
1. Work ONLY in the worktree `/Users/diogosilvasena/Documents/projects/found-issues/.claude/worktrees/release-3-3-0` (branch release/v3.3.0, base origin/main 2a1e82b). Never touch the main checkout.
2. v3.2.1 is merged (#223, squash 5757d95) and released. Checked at write time: post-merge push run 37505263276 on main was still `in_progress` (macOS + ubuntu bats); claude-plugins #52 (marketplace bump 3.2.0 -> 3.2.1) was `OPEN`. Finish that tail first: watch the run to a terminal state, then merge #52 only if it is green. If it is red, diagnose (3.2.2) before anything else.
3. Then resume `superpowers:subagent-driven-development` from the SDD ledger at Task 2. Task 1 (per-role Codex models, f8c3c73) is complete and reviewed; never re-dispatch it.
4. #1 hazard: shell cwd resets to a different worktree after every Bash call; always `cd` into the intended worktree inside the same command.
5. Report every ruling you make on the operator's behalf.

## What was done (verify via PR descriptions / commits)
**v3.2.1 release (AltDoug/found-issues)**
- **#223** `release: v3.2.1` merged (squash 5757d95). PR checks all passed (bats ubuntu about 15 min). `release.yml` run 37505263487 succeeded and `gh release list -L 2` shows v3.2.1 Latest (2026-10-06T17:39:47Z). Evidence: full bare `bats tests/` on the final tree: `1..1310`, 1310 ok, 0 not ok, exit 0.
- `found-issues annotate-pr 223 --pick` of exactly `lib/autofix.sh:127`, `hooks/stop-reminder.sh:87`, `lib/autofix-sweep.sh:387` (out of 24 hook candidates); the annotation was committed to the PR branch (1b35647) so the closing refs land on main with the merge.
- **#224** docs(3.3.0) plan/spec amendments merged (opt-in caps, sweep batches).
- **#225** docs(found-issues) sync merged: closes the 3 entries. Sync phase 1: Closed 3 (3 PR). Phase 2 (sonnet triager): 64 eligible, 0 fixed, 60 still present, 4 unclear; about 20 entries cite drifted line numbers but their symptoms are still present.
- #171 (external, jbelmana) is still open and unrelated.

**claude-plugins marketplace bump**
- Worktree `~/Documents/projects/claude-plugins/.claude/worktrees/fi-3.2.1`, branch chore/found-issues-3.2.1, pushed; PR **AltDoug/claude-plugins#52** changes marketplace.json found-issues 3.2.0 -> 3.2.1. State at write time: OPEN, deliberately not merged until the v3.2.1 post-merge run is green.

**3.3.0 Task 1 (branch release/v3.3.0, pushed)**
- Commit **f8c3c73** `feat(autofix): pin Codex models per role, with inherit as the opt-out`. Implementer: 76/76 on 5 files. Task review (sonnet): Spec pass, Approved, 3 minors deferred in the ledger. README test count is now 1315.
- SDD workspace (git-ignored) at `.superpowers/sdd/2026-10-06-autofix-codex-models/`: `progress.md` (ledger: preflight table, rulings R1-R3, Task 1 complete plus 3 deferred minors), `global-constraints.md`, `reviewer-instructions.md`, `re-reviewer-instructions.md`, `task-1-brief.md`, `task-1-report.md`, the review diff.

**Rulings made on the operator's behalf (with why)**
1. pr-verify-gate skip file used for #223 (verify + /code-review ran in the predecessor build session; this session ran the full suite) and for claude-plugins #52 (one-line version bump).
2. Only the three intended entries annotated on #223, out of 24 hook candidates.
3. Ledger annotation committed to the release PR branch so closing refs land on main with the merge.
4. claude-plugins #52's post-create annotator listed found-issues entries against a claude-plugins PR: the known cross-repo bug (ledger `hooks/post-bash-dispatch.sh:242`); nothing annotated.
5. 3.3.0 batch design (spec section 9): a continuation sweep item (cont=n, cap_day=today, carried cost/tokens, base, skip_files); a batch closes at sweepBatch fixes at the next file boundary; later batches skip files earlier batch PRs changed; a failed batch ship, budget stop or outage queues no continuation.
6. `sweepMax` renamed `sweepBatch` (default 8); a set `sweepMax` is still read when `sweepBatch` is unset.
7. Unset dollar cap = no `--max-budget-usd` at all; doctor/setup say "no dollar cap" plainly.
8. Plan Task 3 (live Codex measurement) now only yields a suggested cap for docs; the controller runs it, not a subagent; it needs an AskUserQuestion before deleting AltDoug/fi-v3-e2e.
9. SDD preflight rulings: R1 (renumbering artifact), R2 (each task updates the `lib/autofix.sh` Settings help for the keys it adds: Task 4 token keys, Task 6 sweepMax -> sweepBatch), R3 (the continuation carries engine=$AFI_engine).
10. Sync triager: entry `lib/autofix-ship.sh:180` was wrongly excluded as "PR-annotated" (its "(PR: ...)" is symptom text); it is a decided, unimplemented design entry and stays open.

## Remaining work
In order:
1. **v3.2.1 tail.** `gh auth status` (AltDoug active). `gh run view 37505263276 -R AltDoug/found-issues --json status,conclusion,jobs`; if still in progress, watch it with `gh run watch 37505263276` (run it in the background; macOS + ubuntu bats take 20-30 min). Terminal green: `gh pr checks 52 -R AltDoug/claude-plugins`, then `gh pr merge 52 -R AltDoug/claude-plugins --squash` (no --delete-branch), watch to MERGED. Red: stop and diagnose as 3.2.2 before 3.3.0 work.
2. **Resume SDD at Task 2** of `docs/superpowers/plans/2026-10-06-autofix-codex-models.md` (spec: `docs/superpowers/specs/2026-10-06-autofix-codex-models-design.md`). Read the ledger first and `git log --oneline origin/main..HEAD`. Run order: 2, 3, 4, 5, 6, 7, 8. Reuse `reviewer-instructions.md`, `re-reviewer-instructions.md`, `global-constraints.md` from the workspace for dispatches. Pass an explicit model on every dispatch (implementers `sonnet`, judgment reviewers `opus`).
3. **Task 3 is controller-run**: live Codex measurement by the controller, not a subagent; it recreates `AltDoug/fi-v3-e2e` and needs an AskUserQuestion picker before deleting the old repo (`gh-repo-delete-guard` needs `GH_REPO_DELETE_GUARD=off` after the operator's yes). It only informs docs (a suggested cap); caps stay opt-in.
4. Per ruling R2, each task that adds or renames a setting updates the `lib/autofix.sh` Settings help text.
5. After all tasks: full bare `bats tests/` on the final tree, release PR for 3.3.0 (CHANGELOG, version bumps in bin FI_VERSION and both plugin.json, `scripts/check-version.sh`), annotate-pr, merge on green per AltDoug policy, verify the release and the post-merge run, marketplace bump in claude-plugins, `/found-issues:sync`.
6. Still open from the predecessor: ask the operator (picker) which release takes the 14 decided ledger entries (recommend a batch after 3.3.0; the `lib/autofix-engine.sh:120` safety item first). The kh2 `tools/bin/build.sh` retag waited for 3.2.1 to ship and is now unblocked; it is an operator checkpoint.
7. The installed plugin CLI on this Mac is still 3.2.0 until the marketplace bump merges and the operator runs `/plugin update found-issues` (operator surface, not done).

## Known live hazards (verify each before relying on it)
1. `gh pr checks --watch` started right after PR creation exits immediately with "no checks reported". Wait for the run to register, then `gh run watch <id>`.
2. Foreground `sleep N && cmd` chains are blocked by the harness; use `run_in_background` or Monitor.
3. Shell cwd resets to the release-3-2-1 worktree after every Bash call: always `cd` into the intended worktree in the same command.
4. pr-verify-gate needs verify/review telemetry or a skip file at `~/.claude/.session-tracker/<session>.<cksum of repo root>.pr-verify-skipped`, written in its own Bash call; it expires at the next commit. Keep literal PR-create text out of non-PR commands. stop-tests-pass credits only a bare `bats tests/`.
5. A hook auto-flips ledger entries in whatever checkout runs it after a merge (it dirtied release-3-2-1's `docs/found-issues.md`; that flip is already on main via #225, so leave that file alone and never `git checkout` it; the release-3-2-1 worktree is reaper fodder). Check `git status` before any ledger commit.
6. Implementers' bats runs can exceed the 2-minute tool timeout when other sessions load the machine; tell them to run long suites with `run_in_background` or a longer timeout.
7. Read-first hook: Edit/Write on a file requires a prior Read in the session (even scratchpad copies).
8. Auto-fix is on globally: log design questions as `--decide`, not `--fix`.
9. Never `git add -A`; never `git checkout` the ledger; macOS CI runs bash 3.2 (guard empty-array expansions under `set -u`); ASCII-only `@test` names; use `! cmd || false` in bats.
10. A PATCH release cannot have "### Added" in its CHANGELOG section (`scripts/check-version.sh`); 3.3.0 is a MINOR so it can.
11. The SDD workspace is git-ignored and lives only in the release-3-3-0 worktree: do not remove that worktree.

## State snapshot (re-verify)
- Checked at write time (2026-10-06): post-merge run 37505263276 `in_progress`; claude-plugins #52 `OPEN`; `gh release list -L 2` = v3.2.1 Latest (2026-10-06T17:39:47Z), v3.2.0.
- release-3-3-0 worktree: branch release/v3.3.0 pushed, `git log --oneline -3` = f8c3c73 (Task 1), 2a1e82b (#224), 5757d95 (#223). This handoff doc is committed on top.
- Other worktrees under `.../found-issues/.claude/worktrees/`: release-3-2-1 (merged #223; ledger dirty with a redundant hook flip, leave it), sync-3-2-1 (merged #225, clean), plan-3-3-0 (merged #224, clean).
- Open PRs expected: found-issues #171 (external); claude-plugins #52.

## Resume prompt
> Work in the existing worktree /Users/diogosilvasena/Documents/projects/found-issues/.claude/worktrees/release-3-3-0 (branch release/v3.3.0; never touch the main checkout). Run `gh auth status` and confirm AltDoug is active. Read docs/handoffs/autofix-3.3.0-build-handoff-2026-10-06.md end to end and re-verify against live state (gh run view 37505263276, gh pr view 52 -R AltDoug/claude-plugins, gh release list -L 2, git log --oneline origin/main..HEAD, the SDD ledger .superpowers/sdd/2026-10-06-autofix-codex-models/progress.md), then finish the v3.2.1 tail (watch the post-merge run to a terminal state, merge claude-plugins #52 only if green), then resume superpowers:subagent-driven-development from the SDD ledger at Task 2 (Task 1 is complete; never re-dispatch it). Never `git add -A`; never `git checkout` the ledger. Report every ruling you make on the operator's behalf.
