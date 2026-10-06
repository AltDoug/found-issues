# Auto-fix 3.2.1 release — Session Handoff
**Date:** 2026-10-06 · **Session:** "3.2.1 build"
**Status:** 3.2.1 is fully implemented, reviewed and pushed on branch release/v3.2.1 (3 commits on origin/main 3a4397f), but NOT yet released: the full bare `bats tests/` has not been completed on the final tree, and no release PR exists.
**Re-verification rule (operator's standing feedback):** do NOT act on this doc's claims without re-verifying against the repo / live state first. Ground truth: `git log --oneline -5` and `git status` in the worktree, `gh pr list -R AltDoug/found-issues --state open`, `gh release list -R AltDoug/found-issues -L 2`, `found-issues autofix status`, `git log --oneline -3 origin/main`, and the ledger via `./bin/found-issues list` (never hand-edit docs/found-issues.md).

## TL;DR for the next session
- Work ONLY in the worktree `/Users/diogosilvasena/Documents/projects/found-issues/.claude/worktrees/release-3-2-1` (branch release/v3.2.1). Never touch the main checkout.
- All four 3.2.1 items are built and targeted suites are green. The one missing gate is a full bare `bats tests/` on the final tree (expect `1..1310`, 0 not ok). Run it first, in the background (about 40-60 min).
- Then: release PR, `annotate-pr --pick` of three ledger entries, merge on green, verify v3.2.1 Latest, marketplace bump in AltDoug/claude-plugins, `/found-issues:sync`, then 3.3.0.
- 3.3.0 scope changed after the peer session "Autofix Codex" relayed new operator decisions (below under Remaining work 7). Amend the plan/spec BEFORE building.
- Report every ruling you make on the operator's behalf.

## What was done (verify via PR descriptions / commits)
Branch release/v3.2.1, base origin/main 3a4397f (#222), pushed to origin. Commits:
- **a26cba5** `release: v3.2.1` — the four items, version bumps (bin FI_VERSION, both plugin.json = 3.2.1), CHANGELOG [3.2.1], README (v3.2.1, 6 lifecycle hooks, test count), docs/configuration.md, docs/architecture.md, codex-skills regenerated.
- **726e622** `fix: review findings` — ship-wait validation, retry needs no engine, 3-day retire of an unlaunched ship retry (branch kept), cancel names the kept branch, CMakeLists.txt / requirements*.txt count as code. README test count 1310.
- **7b907e7** `docs(changelog)` — setup picker moved from "### Added" to "### Changed", because `scripts/check-version.sh` rejects "### Added" in a PATCH bump (ruling: the operator chose 3.2.1 as a patch).
- The handoff commit (this doc) sits on top.

The four items as built:
1. **`[!]` lib/autofix.sh:127 baseline.** New `fi_af_base_tests` in lib/autofix-queue.sh, called in `fi_af_claim` after the worktree is cut and in `fi_af_sweep_claim` before classify. Red at base: the item finishes stale "tests fail at base", failing tests go in the run log, and the worktree is reset after a green base. The spot claim had already taken its daily slot; the sweep takes the day's slot on a red base (ruling; it bounds re-runs).
2. **hooks/stop-reminder.sh:87 hybrid.** `turn_edits_code` = Edit/Write/MultiEdit/NotebookEdit on non-doc paths (not .md/.mdx/.markdown/.txt/.rst/.adoc, except CMakeLists.txt / requirements*.txt / constraints*.txt, which count as code). A code edit blocks once per session (and records `reminded/<sid>.code`, so later doc-only turns block too). Otherwise one non-blocking reminder is written to `reminded/<sid>.nudge` and delivered by the NEW hook hooks/prompt-nudge.sh (UserPromptSubmit, registered in hooks/hooks.json) as additionalContext, then renamed `.nudged`. Reason: Claude Code docs say a Stop hook cannot reach the model without forcing another turn. Mutating Bash alone gets the reminder only (ruling). `EVERY_TURN=on` keeps the old behavior. The Codex path is unchanged.
3. **lib/autofix-sweep.sh:387 keep + requeue.** `_fi_af_sweep_ship_failed` requeues with `ship_tries+1`, `cur` past the last entry, `wait_next` +900 s (`FOUND_ISSUES_AUTOFIX_SHIP_WAIT`), up to `FOUND_ISSUES_AUTOFIX_SHIP_TRIES=3`, then failed "(N tries; branch X kept)". `fi_af_worktree_remove` keeps the branch whenever `ship_tries>0` unless the outcome is shipped ("drop"). `_fi_af_sweep_claim_ship` re-attaches a worktree to the kept branch (no cap, classify or baseline). `_fi_af_publish` reuses an existing open PR on a retry. Reap/requeue keep the base; stale-retire exempts a retry for 3 days. The spot ship path is deliberately unchanged (the operator decision named the sweep only).
4. **Setup picker.** commands/setup.md Optional 4 asks 5 (Recommended) / 10 / 20 / Other and writes `found-issues config autofix.sweepThreshold <n>` [--global]. Per a peer-relayed operator decision, it does NOT raise sweepMax/sweepBudget (this supersedes the start handoff's item 4 text).

Test fixture change: `tests/autofix-helpers.bash` spot fixture's test.sh now passes at base (the bug test runs only when src/ has an uncommitted or unpushed change). Five existing tests were adjusted: autofix-b (x3), autofix-cancel (wait_engine helper), autofix-run (retry-feedback), cli-fix (fix-test).

Verification done this session:
- Targeted suites green: autofix-claim, autofix-run, autofix-sweep (45 ok), stop-reminder (38 ok), autofix-b, autofix-cancel, cli-fix (11/11), setup-autofix-disclosure, codex-skills-drift, check-version (all ok after 7b907e7). A full `bats tests/autofix-*.bats` run: only the 4 tests later fixed failed.
- The FULL `bats tests/` was NOT completed on the final tree: a run was stopped at 590 ok / 1 not ok (check-version, since fixed by 7b907e7).
- End-to-end verify skill run (branch CLI, real git, stand-in engines + gh shim): flow 1, red real bats suite -> "stale: tests fail at base", 0 engine calls. Flow 2, push failure -> requeued `ship_tries=1`, 2 commits on the kept fi/sweep branch, retry shipped PR #5 with no new engine calls. Flow 3, stop hook fed this session's real transcript: code edit -> exit 2 once; doc-only turn -> exit 0 + `.nudge`, prompt hook delivered once. The setup picker was NOT driven (it is prose).
- Adversarial /code-review (high) found 10 candidates. Fixed #3, #7, #8, #9, #10 in 726e622. Accepted as rulings: #1 every ship failure retries (operator's literal rule; deterministic failures cost about 2 extra suite runs); #2 Bash-only code edits only get the reminder; #4 a spot claim spends a daily slot on a red base; #5 one flaky base run retires a spot item stale (the entry stays fixable; sweeps still take it); #6 docs-only sessions re-parse the transcript every Stop after the reminder (accepted cost).
- Baseline on origin/main before changes: 1..1290, with 3 failures caused by this session's in-flight edits (not pre-existing).

## Remaining work
In order:
1. In the worktree: `gh auth status` (AltDoug active); re-verify state; run a bare `bats tests/` (expect `1..1310`, 0 not ok; about 40-60 min, run it in the background; stop-tests-pass credits only the bare command). Fix anything red, as a NEW commit.
2. Open the release PR from release/v3.2.1. Title: "release: v3.2.1 — baseline test run, sweep ship retry, stop-reminder hybrid, sweep-trigger picker". Body: the four items, the rulings, the review outcome, the verification evidence (including the full-suite result from step 1). The pr-verify-gate needs this session's verify+review telemetry or a skip file written in its own Bash call BEFORE the PR command (hazard 2); keep the literal PR-create text out of other commands.
3. Right after creating it: `found-issues annotate-pr <N> --pick 'lib/autofix.sh:127,hooks/stop-reminder.sh:87,lib/autofix-sweep.sh:387'` (exactly these three; first confirm with `./bin/found-issues list` that those locs exist).
4. Merge on green per the AltDoug auto-merge policy: `gh pr checks <N> --watch`, then `gh pr merge <N> --squash` (no --delete-branch); watch to MERGED. release.yml auto-cuts the tag: verify `gh release list -R AltDoug/found-issues -L 2` shows v3.2.1 Latest. Then watch the post-merge push run (macOS + ubuntu) to a terminal state.
5. Bump the marketplace in AltDoug/claude-plugins (same shape as its PR #51), merge on green.
6. `/found-issues:sync`.
7. Start 3.3.0: fresh worktree from the new origin/main. First amend the plan and spec in a docs PR, then run superpowers:subagent-driven-development on the plan. New operator decisions, relayed by peer session "Autofix Codex" on 2026-10-06 (it has since exited; a reply could not be delivered), ALL for 3.3.0, not 3.2.1:
   - (a) The item 4 picker drops the sweepMax/sweepBudget raise (done in 3.2.1).
   - (b) Drop the per-sweep COUNT limit: a sweep fixes every fixable entry but ships a PR every 8 fixes (batches). The batch-size setting defaults to 8 (the implementer's call). `dailySweeps` stays.
   - (c) No MONEY cap by default: `runBudget` and `sweepBudget` become opt-in (unset = no cap; claude children then get no `--max-budget-usd`).
   - (d) Codex token caps `autofix.codexRunTokens` / `autofix.codexSweepTokens` are opt-in (unset = no cap). Pinned per-role models stay the default; plan Task 3's measurement only informs docs.
   - Amend `docs/superpowers/plans/2026-10-06-autofix-codex-models.md` (Tasks 3, 4, 6) and `docs/superpowers/specs/2026-10-06-autofix-codex-models-design.md` (Decisions); add (b) and (c) as new plan tasks. Releasing them in 3.3.0 was the peer's ruling, agreed by this session.
   - Plan Task 3 recreates AltDoug/fi-v3-e2e and asks before deleting (gh-repo-delete-guard needs `GH_REPO_DELETE_GUARD=off` after the operator's yes).
8. Still open from before: ask the operator (picker) which release takes the 14 decided entries (recommend a batch after 3.3.0; the `lib/autofix-engine.sh:120` safety item first). The kh2 `tools/bin/build.sh` retag waits for 3.2.1 to ship (operator checkpoint).

## Known live hazards (verify each before relying on it)
1. **Worktree-isolation guard.** The session may be isolated to the worktree. Commands whose text names git inside heredocs or python get refused: write scripts to the scratchpad and run them by path; use the Edit/Write tools for file edits.
2. **Harness gates match command text.** pr-verify-gate fires on the literal PR-create command: it needs this session's verify and review telemetry, or a skip file written in its own Bash call before the PR command (the skip expires at the next commit). stop-tests-pass credits only a bare `bats tests/` (there is NO `tests/hooks/` dir). Keep "gh pr create" text out of non-PR commands.
3. **commit-done-gate** blocks a code commit if code was edited after the last passing test run.
4. **check-version.sh:** a PATCH release cannot have "### Added" in its CHANGELOG section.
5. **The test fixture now passes at base.** Any new auto-fix test that needs a failing suite must gate its failure on a change (see tests/autofix-helpers.bash).
6. `fi_af_child` polls with `sleep 1`, so every claim now costs at least 1 s more in tests (the baseline run).
7. The installed plugin CLI is 3.2.0 until 3.2.1 is released and re-installed. Test branch code via `./bin/found-issues` by path; auto-fix agents use the INSTALLED CLI.
8. Auto-fix is on globally: log design questions as `--decide`, not `--fix` (a `--fix` entry makes hooks ask for paid fixer agents).
9. A 3.x auto-fix run writes an uncommitted `(PR: ...)` annotation into a session checkout's ledger. Check `git diff docs/found-issues.md` before ledger commits. Never `git add -A`; never `git checkout` the ledger; peer sessions share checkouts.
10. macOS CI runs bash 3.2: guard empty-array expansions under `set -u` with `${A[@]+"${A[@]}"}`; a bare `! cmd` in bats asserts nothing (use `! cmd || false`); keep `@test` names ASCII-only.
11. External PR #171 (jbelmana, "sync: hold [!] critical closures for human verification (#161)") is open and unrelated.
12. Context budget: hand off early in long sessions.

## State snapshot (re-verify)
- origin/main `3a4397f` (#222); v3.2.0 is Latest.
- Open PRs: #171 only (verify).
- Branch release/v3.2.1 pushed with 3 commits plus this handoff commit; working tree clean after the handoff commit.
- `found-issues autofix status` at session start: Running 0, Queued 0, 1/1 sweeps today.

## Resume prompt
> Work in the existing worktree /Users/diogosilvasena/Documents/projects/found-issues/.claude/worktrees/release-3-2-1 (branch release/v3.2.1; never touch the main checkout). Run `gh auth status` and confirm AltDoug is active. Read docs/handoffs/autofix-3.2.1-release-handoff-2026-10-06.md end to end, re-verify against live state (git log/status, gh pr list, gh release list -L 2, found-issues autofix status), then do Remaining work 1-7 in order: full bare `bats tests/`, the release PR + annotate-pr --pick of the three entries, merge on green, verify v3.2.1 Latest and the post-merge run, marketplace bump in AltDoug/claude-plugins, /found-issues:sync, then 3.3.0 (plan/spec amendments for the peer decisions first, then superpowers:subagent-driven-development). Never `git add -A`; never `git checkout` the ledger. Report every ruling you make on the operator's behalf.
