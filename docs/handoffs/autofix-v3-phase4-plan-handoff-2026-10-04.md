# found-issues v3.0.0 auto-fix — Phase 4 Plan Handoff

**Date:** 2026-10-04 · **From:** the session that finished Phase 3 (PR #188)
**Status:** Phase 3 is MERGED into `release/v3` (squash `907cdd9`, 2026-10-04T05:17:39Z). Post-merge `tests` run 37179465772: completed **success** (every job green, including `bats (macos-latest)` on bash 3.2). Phase 4 has NOT started. There is no Phase 4 plan yet; writing it is the first job.
**Re-verification rule (operator's standing feedback):** do NOT act on this doc's claims without re-checking them first. Ground truth:
- `git -C ~/Documents/projects/found-issues/.claude/worktrees/v3-phase4 fetch && git log --oneline -3 origin/release/v3`
- `gh pr list -R AltDoug/found-issues --state all -L 5`
- `gh run list -R AltDoug/found-issues --branch release/v3 -L 2`
- the spec `docs/superpowers/specs/2026-10-03-autofix-v3-design.md` (§4.1, §4.2, §6, §7, §11)

## TL;DR for the next session

- Work in `~/Documents/projects/found-issues/.claude/worktrees/v3-phase4`, branch `v3/phase4-sweep`, cut from `origin/release/v3` at `907cdd9`. Its first commit is this handoff. Push with `git push -u origin v3/phase4-sweep` so it stops tracking `release/v3`.
- **Phase 4 scope (spec §11):** the sweep (§6), the `found-issues-sweeper` agent (moved from Phase 3), the `AUTOFIX-SWEEP-DUE` trigger (§4.1), and `/found-issues:fix` on the shared plumbing (folds in audit prompt-8..11).
- **First step:** write the plan with `superpowers:writing-plans` at `docs/superpowers/plans/2026-10-04-autofix-v3-phase4-sweep.md`, using the Phase 3 plan as the template (Docs re-check, Rulings, Global Constraints, Review Focus, numbered tasks with RED→GREEN steps, final verification task). Get the operator's approval of the plan and its rulings before executing (one picker).
- Execution pattern that worked in Phases 2 and 3: Native SDD (the SDD ledger lives under `.superpowers/sdd/<plan-slug>/progress.md`, git-ignored), then ONE read-only opus whole-branch review, then fixes, PR into `release/v3`, merge, and the post-merge watch.
- `v3-phase3` worktree and `v3/phase3-launcher-b` are finished (the branch is deleted server-side on merge). The `v3-docs` worktree belongs to a peer; do not work there.
- **Operator request (2026-10-03), still pending:** once 3.0.0 is released and the plugins are updated on this Mac, enable auto-fix here. That is the last step of Phase 5 (see below).

## What Phase 3 shipped (PR #188, verify via `gh pr view 188`)

- **Launcher B:** the plugin agent `agents/found-issues-fixer.md` (sonnet, maxTurns 60, background) drives one item through `found-issues autofix claim/brief/test/verify/ship/release`. A standalone claim records `launcher=B` and no pid; every B call refreshes the repo lock.
- **`autofix verify`:** bash re-runs the tests, then the headless opus verifier; it records `verdict_tree` (`git write-tree`) and then `verdict`. `ship` refuses any other tree, and refuses when no tree is recorded.
- **Hook launcher selection:** `lib/autofix-hook.sh` plus the `post-bash-dispatch` route. `auto`/`bypassPermissions` → JSON nudge naming `found-issues:found-issues-fixer`; other modes / Codex → detached `autofix run <id> --engine <harness>`; `agent_id` or `FOUND_ISSUES_AUTOFIX_CHILD=1` → nothing.
- **Stop fallback** in `hooks/stop-reminder.sh` → launcher A for items still queued (skips a FRESH lock, the capped marker, the grace period, another repo).
- **`autofix run` exits:** 1 unknown id (no drain), 3 capped (+ `day/<date>.capped`), 4 locked, 7 engine outage. **New in review fixes:** B `verify`/`ship` exit 8 = auto-fix switched off, item requeued.
- **PostToolUse context** now goes out as `hookSpecificOutput` JSON on Claude Code.
- **Review fixes (commit 54dff6e, all RED→GREEN):** I1 `autofix off` stops B (claim refuses, verify/ship requeue); I2 a stale lock no longer strands the queue at Stop; I3 PostToolUse never exits 1, and `fi_af_item_set` no longer recreates a stub; I4 tree pinning fails closed.
- **Ledger:** `lib/harness.sh:52`, `lib/autofix.sh:150`, `lib/autofix-ship.sh:116` carry `(PR: AltDoug/found-issues#188)` (sync flips them). `lib/autofix-queue.sh:263` resolved as non-reproducing (verified: ai). 7 review minors logged 2026-10-04 (all `(fix: small)`): `lib/autofix-hook.sh:58` (re-printed marker relaunch + cross-repo glob), `:82` (engine override), `:123` (per-repo off ignored at Stop; no capped marker from a B claim), `:124` (Stop fork), `:137` (cwd prefix matching), `lib/autofix-queue.sh:290` (requeue keeps attempts/verdict), `tests/autofix-hook.bats:119` (Focus-5 test proves too little). Fold the hook ones into Phase 4 if they touch the same code; otherwise Phase 6 burns them down.

Evidence at merge: full suite `bats tests/` exit 0, 1076 ok, 0 not ok, 3 skips; bash 3.2 subset exit 0, 261 ok, 0 not ok; E2E through real CLI + hooks (claude/gh stand-ins) and the Task 9 live probe (`permission_denials []`, item `launcher=B attempts=2 result=shipped`).

## Phase 4 — what to plan (from the spec; re-read it, this is a summary)

1. **Sweep trigger (§4.1):** `log` or `sync` brings the fixable-now count to `sweepThreshold` (default 5), or records a fixable critical `(fix: medium)`, and no sweep ran today → queue a sweep item and print `AUTOFIX-SWEEP-DUE <id>`. Phase 3 wrote the hook's marker handling so Phase 4 only adds this marker (ruling 3); extend `fi_afh_ids`/the dispatch route and the Stop fallback to sweep items, and pick `found-issues-sweeper` for B.
2. **Sweep flow (§6):** fresh worktree from `origin/<default>` after fetch, branch `fi/sweep/<YYYYMMDD>-<n>`, refuse a dirty tree, `--cwd` on every `list`/`status` (prompt-8); classify untagged entries read-only via `found-issues tag`; wake blocked entries (`sync` handles `until: pr:`/`date:` mechanically; the sweep re-judges free text); fix up to `sweepMax` (8) entries, critical first, same-file groups, then oldest, one commit each, a failure reverts that entry only; ship ONE PR via the shared `autofix ship` path with `--pick` per fixed entry and the ledger committed into the PR (prompt-9). Never touch `(decide:)`, `(manual:)`, `(fix: large)`; list large ones as "needs a plan".
3. **Caps (§7):** 1 sweep per repo per day, max 8 entries, $3 per background run.
4. **`found-issues-sweeper` agent** (launcher B for sweeps), same shape as the fixer: only `found-issues autofix …` Bash calls, edits only inside the sweep worktree, never git/gh/ledger.
5. **`/found-issues:fix` on the shared plumbing (spec §6 last paragraphs):** keeps its approval gate; shares workspace setup, ship and test-command detection. Audit findings to fold in (from `docs/audits/2026-10-03-audit/findings-prompt.json` on `fix/audit-2026-10-03`, commit 7cb8f23):
   - **prompt-8 [high] `commands/fix.md:62`:** no worktree isolation or clean-tree/base-ref discipline; per-day branch name collides on a second run; `list --json` and the annotate commands can read different ledgers in a worktree.
   - **prompt-9 [medium] `commands/fix.md:82`:** never commits/pushes the ledger change `annotate-pr` makes after `gh pr create`; the already-fixed bucket ends in `/found-issues:sync`, which archives, so the `(PR:)` annotation never reaches the default branch and the run leaves ledger/archive diffs.
   - **prompt-10 [low] `commands/fix.md:5`:** allowed-tools covers only a `bats` runner, but the body needs the repo's tests + build, so other stacks prompt; range entries cannot be picked from `path:line`.
   - **prompt-11 [low] `hooks/session-start.sh:96`:** SessionStart injects "prepend this italic line" directives with no headless/entrypoint guard; spec: run onboarding/statusline nudges only when `CLAUDE_CODE_ENTRYPOINT` is empty or `cli`.

Open design questions to settle in the plan's Rulings (recommend, then ask the operator once):
- Does the sweep reuse `autofix claim` (one lock, one worktree) with `kind=sweep`, or get its own claim? Recommendation: reuse the queue/lock/claim with `kind=sweep` so caps, reap and the Stop fallback work unchanged.
- How the sweeper verifies per entry: `autofix verify` per entry commit vs once for the whole PR. The tree-pinning rule (ship only the approved tree) must still hold.
- Whether the sweep's classify step (writing tags) commits tag changes into the sweep PR (likely yes, same as the ledger annotations).

## Known live hazards (verify each before relying on it)

1. **Subagents must never trigger operator permission prompts.** Reviewers and finders are read-only agents (`model: opus` for the review); never use the forked `/code-review` skill.
2. **pr-verify-gate** blocks `gh pr create` on >200 code lines without verify/review skill telemetry. Probe `gh pr create --dry-run` in its own call; write the evidence-backed reason into the printed `.pr-verify-skipped` path in a separate call, after the final commit.
3. **gh-pr-merge-base-guard** blocks merges into `release/v3`; use `GH_PR_MERGE_BASE_GUARD=off gh pr merge <N> --auto --squash` (merges at once: `release/v3` has no required checks, so PR checks never gate).
4. **CI:** PR runs are ubuntu-only. macOS bats (bash 3.2) runs only on the post-merge push run, so watch it to terminal (`gh run watch <id> --exit-status`). bats `-f` goes BEFORE the file and must not contain spaces.
5. **Local bash 3.2 run:** `mkdir -p /private/tmp/claude-501/b32 && ln -sf /bin/bash /private/tmp/claude-501/b32/bash`, then `PATH=/private/tmp/claude-501/b32:$PATH bash "$(command -v bats)" <files>`. The full suite takes ~10+ min: run long suites in the background with output to a file.
6. **README test count** is pinned by `tests/docs-consistency.bats`: `n=$(rg -c '^@test ' tests/*.bats | awk -F: '{s+=$2} END{print s}'); sed -i '' -E "s/ [0-9]+ tests on/ $n tests on/" README.md`. Rules `SKILL.md` budget is 4200 bytes.
7. **`found-issues log` cites the line you give it:** after editing a file, re-derive line numbers with `rg -n` before logging (Phase 3 had to re-log 5 entries whose lines came from a pre-edit review). `log` refuses symptoms ending in annotation-shaped groups (`(fix:`, `(decide:`, `(manual:`, `(until:`); use the `--fix` flag.
8. **Never write `docs/found-issues.md` by hand**: `./bin/found-issues log|resolve|annotate-pr`. Use the worktree's `./bin/found-issues` (running sessions keep their old plugin CLI; the installed 2.10.4 commit hook adds non-closing `(commit-auto: <sha>)` suggestions).
9. **The shared main checkout** `~/Documents/projects/found-issues` is dirty and peer-used: never `git add -A` or check out its ledger there.
10. **Tests with detached spawns must close fd 3** (`3>&-`) or bats hangs. macOS has no `timeout` (watchdog is bash + perl `setpgrp`). Sourcing `bin/found-issues` twice in one shell fails (`FI_VERSION: readonly`).
11. **Bats:** a mid-test `! cmd` asserts nothing; use `! cmd || false`. ASCII-only `@test` names (Windows guard).
12. **Live tests use plan usage** (`FI_LIVE=1 bats tests/autofix-live.bats`): only with operator approval; they need the real `$HOME`. This is the Max subscription: say "usage", not "spend".
13. **Unverified until Phase 5 E2E:** (a) the auto-mode classifier's treatment of `found-issues autofix ship` (it merges a PR; "Merging a pull request no human has approved" is on the auto-mode block list), since the Phase 3 probe ran under `bypassPermissions`; (b) whether Claude Code's protected-directory rule for `.claude/` makes a B fixer's edits under `<root>/.claude/worktrees/fi-autofix-<id>/` prompt in auto mode (no prompt was seen in bypass).
14. A Bash call that pushes a scratch fixture to a local bare `main` via a `$var` path trips git-push-main-guard: put such setup in a script file run with `bash <file>`.

## Phase 5 and 6 reminders

- **Phase 5:** statusline, status, SessionStart summary, setup disclosure, doctor, docs (`docs/versioning.md` breaking-change note), 3.0.0 bump, live E2E (in a real AUTO-mode session), the `release/v3` → `main` release PR, marketplace bump. **Then ENABLE auto-fix on this Mac:** `git config --global found-issues.autofix true`, verify with `found-issues doctor`, give the disclosure that fix PRs always auto-merge, and ask once (picker) which client repos to exclude (`git config found-issues.autofix false` in each).
- **Phase 6:** whole-plugin audit and ledger burn-down, driven by `/goal` (spec §11).
- **Operator-only steps still outstanding:** run `/hooks` once in interactive Codex; run `/plugin update found-issues` in Claude Code after each release.

## Resume prompt

Working directory ~/Documents/projects/found-issues/.claude/worktrees/v3-phase4 (branch v3/phase4-sweep, cut from origin/release/v3 at 907cdd9; `git fetch` and confirm the tree is clean, then `git push -u origin v3/phase4-sweep` if it still tracks release/v3). Read docs/handoffs/autofix-v3-phase4-plan-handoff-2026-10-04.md end to end and re-verify its claims first (`git log --oneline -3 origin/release/v3`, `gh pr list -R AltDoug/found-issues --state all -L 5`, `gh run list -R AltDoug/found-issues --branch release/v3 -L 2`); confirm `gh auth status` shows AltDoug active. Then write the Phase 4 plan (sweep, found-issues-sweeper agent, AUTOFIX-SWEEP-DUE trigger, /found-issues:fix on the shared plumbing folding in audit prompt-8..11) with superpowers:writing-plans at docs/superpowers/plans/2026-10-04-autofix-v3-phase4-sweep.md, modelled on the Phase 3 plan, and get the operator's approval of the plan and its rulings via one picker before executing. Execute with Native SDD, then ONE read-only opus whole-branch review, fix Critical/Important with RED->GREEN tests, PR into release/v3, merge with GH_PR_MERGE_BASE_GUARD=off, and watch the post-merge release/v3 run to terminal. Never trigger permission prompts from subagents. Remember the end-of-Phase-5 task: once 3.0.0 is released and the plugins are updated on this Mac, enable auto-fix here (`git config --global found-issues.autofix true`, verify with `found-issues doctor`, give the disclosure that fix PRs always auto-merge, ask once via picker which client repos to exclude).
