# found-issues v3 auto-fix — first live failure — Session Handoff
**Date:** 2026-10-04 · **Session:** "v3 release + 3.0.1 sync fix + first live auto-fix"
**Status:** v3.0.0 and v3.0.1 are released and installed. The first live auto-fix run failed because `bats tests/` exits 1 inside the fixer's test run. A strong root-cause lead exists (see TL;DR). It is not yet reproduced. Nothing is fixed yet.
**Re-verification rule (operator's standing feedback):** do NOT act on this doc's claims without re-verifying against the repo / live state first. Ground truth: `./bin/found-issues autofix status` and `git status` in the ledger-301 worktree; `gh pr list -R AltDoug/found-issues --state all --limit 6`.

## TL;DR for the next session

- v3 shipped and works up to the fixer's test step. The fixer made a correct-looking fix, then failed on tests.
- The failure is NOT mysterious. The run logs already name the failing tests. Read them first:
  `~/.cache/found-issues/autofix/AltDoug__found-issues/runs/20261004-155405-15577.btest1.log`
  (btest1 is the run on the unmodified tree: 1202 tests, 6 failures).
- The 6 failures in btest1 (`rg -n '^not ok'`):
  - 819 `session-start (claude): once a day, says the Codex install has no hooks` (tests/codex-wiring.bats:181)
  - 908 `session-start: says once per day that the guards are off without jq` (tests/guard-bypasses.bats:167)
  - 1132 `session-start: nudge fires for cd-only canonical block missing --cwd (hook-sync)` (tests/session-start.bats:145)
  - 1136 `session-start: canonical statusline.sh is never migrated via the target branch` (tests/session-start.bats:251)
  - 1156 `session-start: an interactive cli session still gets the onboarding hint` (tests/session-start.bats:533)
  - 1157 `session-start: a headless session gets no codex-unwired nudge` (tests/session-start.bats:547)
- Lead (read from code, NOT reproduced): all six are session-start nudge/hint tests. `lib/autofix-ship.sh:58-59` runs the test command through `fi_af_child`. `lib/autofix-engine.sh:46` and `:54` set `FOUND_ISSUES_AUTOFIX_CHILD=1` on that child. `hooks/session-start.sh:108-112` (fixed in #190) treats that variable as headless, even when `CLAUDE_CODE_ENTRYPOINT=cli`. Test 1156 exports `CLAUDE_CODE_ENTRYPOINT=cli` and still fails, which fits. `tests/helpers.bash` does not unset `FOUND_ISSUES_AUTOFIX_CHILD`. Only `tests/autofix-helpers.bash:13` and `tests/autofix-queue.bats:11` do. So any bats run started by `autofix test`/`verify`/`ship` inherits the variable and these tests go red. This also means launcher A and the ship step would fail the same way on any repo with a similar suite.
- Likely fix: unset `FOUND_ISSUES_AUTOFIX_CHILD` (and probably `CLAUDECODE`) in `tests/helpers.bash` so every test starts clean. Alternative: scrub it for the test command in `fi_af_run_tests`. Decide with evidence. The first is the smaller change. The second also protects other repos' suites.
- Second finding, also in the logs: btest2/3/4 (after the fixer added a test) fail `docs-consistency: README test-count stat` (README says 1202, actual 1203). The fixer did not bump the README count. Any fix that adds a `@test` must also bump the README count.
- Third finding: btest2 also failed `autofix engine: the watchdog kills the whole process group` (tests/autofix-engine.bats:150, the machine-wide `pgrep -f 'sleep 4711'` flake). btest2 and btest3 finished 2 seconds apart (16:15:15 and 16:15:17), so two bats runs overlapped. btest3 did not hit it.
- Product finding to fix too: `found-issues autofix test` (`fi_af_b_test`, lib/autofix-b.sh:88-100) prints only `tail -n 30` of the log. The failing `not ok` lines were at lines 820-1173 of a 1215-line log, so the fixer never saw them. Print every `not ok` line plus its `#` diagnostics, then the tail. The feedback in lib/autofix.sh:124 uses `tail -n 20` and has the same blind spot (check it).
- Each full `bats tests/` run inside auto-fix took about 10 minutes (15:54 claim, 16:04 first result). Four runs plus a verify used 40 minutes. Worth a look when you fix the above.

## What was done (verify via PR descriptions / commits)

- v3.0.0 released via AltDoug/found-issues#191 (release/v3 into main). Phases were #186 to #190. GitHub release v3.0.0 exists. Verified: `gh pr list` shows #186-#191 MERGED; `gh release list` shows v3.0.0.
- v3.0.1 released via #192 (branch fix/sync-release-branch-prs, commit 19a667a on main). `gh release list` shows v3.0.1 as Latest. Sync now closes an entry whose PR merged into a non-default branch once a later merged PR brings that branch into the default branch. Code: `lib/sync.sh` `_fi_promoted_at` (line 145, called at line 225). One `gh pr list --head <base> --base <default> --state merged` per base per run. A non-ISO answer never counts.
- #193 (docs/ledger-sync-3.0.1) ran the 3.0.1 sync on main. It closed 4 entries (3 from #188, 1 from #190) and logged `hooks/post-bash-dispatch.sh:242`: the `gh pr create` PostToolUse annotator takes only N from `/pull/N` and runs `annotate-pr N` in the cwd repo. A PR made in ANOTHER repo is matched against this repo's PR #N (seen with AltDoug/claude-plugins#42). Merged. Note: origin/main is now `cade9a2` (the squash of #193). The local commit `2c4488d` is the pre-squash commit still checked out in ledger-301.
- Marketplace AltDoug/claude-plugins: #41 (3.0.0) and #42 (3.0.1) are MERGED.
- Installed versions on this Mac: Claude Code plugin `found-issues@altdoug-plugins` 3.0.1 (enabled); Codex plugin `found-issues@altdoug-plugins` 3.0.1 (enabled). `found-issues doctor` says "Codex hooks: wired and trusted".
- Config: `git config --global found-issues.autofix` = true. kingdomtcg has a local `found-issues.autofix` = false (operator choice). tere/site, tere/shop-ops and sayciao read true (inherited global). Throwaway repo AltDoug/fi-v3-e2e is deleted (`gh repo view` cannot resolve it). Its cache dir `~/.cache/found-issues/autofix/AltDoug__fi-v3-e2e` still exists locally.
- First live auto-fix: logging the post-bash-dispatch.sh:242 entry in ledger-301 queued spot item `20261004-155405-15577` and sweep `20261004-155405-28324`. The session started the plugin agents as the hook asked (launcher B).
  - The sweeper stopped correctly: claim rc 4 "another auto-fix run holds this repo". The sweep stays queued.
  - The fixer (found-issues:found-issues-fixer, sonnet) claimed at 15:54:15 into `ledger-301/.claude/worktrees/fi-autofix-20261004-155405-15577` (branch `fi/autofix/hooks-post-bash-dispatch-sh-242-20261004-155405-15577`). Per the session, it changed `hooks/post-bash-dispatch.sh` to read owner/repo from the `/pull/N` URL and skip annotation when it differs from origin (case-insensitive, with a fallback to old behaviour if origin cannot be resolved), plus a bats test in `tests/post-bash-dispatch.bats`.
  - Run log, verbatim: `b test 1: rc=1`, `b test 2: rc=1`, `b test 3: rc=1`, `b test 4: rc=1`, then at 16:35:26 `failed: Fix applied in hooks/post-bash-dispatch.sh (skip annotate when PR URL owner/repo differs from origin) with a new bats test, but bats tests/ exits 1 both before ...` (truncated in the ledger tag).
  - The fixer's worktree and branch are GONE (no `fi-autofix` worktree in `git worktree list`; no local or remote `fi/autofix*` branch; `ledger-301/.claude/worktrees/` is empty). The fix itself is lost. Re-derive it; it is small.

## Remaining work

1. Re-verify state. Run `./bin/found-issues autofix status` and `git status -sb` in ledger-301, and `gh pr list -R AltDoug/found-issues --state all --limit 6`.
2. Diagnose with /diagnose (log evidence first). Start from the btest logs above, which already hold the evidence. Reproduce the lead cheaply and sequentially (never two bats runs at once): for example, run one of the six failing test files (`bats tests/session-start.bats`) with and without `FOUND_ISSUES_AUTOFIX_CHILD=1` exported. Then, if needed, create a nested worktree the same way auto-fix does and run the suite there. Confirm which env var(s) flip the six tests. Check `CLAUDECODE=1` and `CLAUDE_CODE_ENTRYPOINT=cli` (both are set in the current session env).
3. Fix the root cause and the `autofix test` truncation. TDD: write a RED test first (for example, run the test command through `fi_af_run_tests` with the var set and assert the session-start tests pass; and a test that `autofix test` output contains the `not ok` lines). Then GREEN. Run the full suite, then the bash 3.2 subset, sequentially. Bump the README test count for every added `@test` (tests/docs-consistency.bats pins it). Ship as 3.0.2, including the uncommitted autofix-failed ledger tag (or, if the fix resolves it, let auto-fix re-fix the post-bash-dispatch.sh:242 entry; the tag may need clearing through the supported command, never a hand edit).
4. Let queued sweep `20261004-155405-28324` run. It relaunches from the Stop fallback, or via `found-issues autofix run <id>`. Watch its PR.
5. Report every ruling made on the operator's behalf.

3.0.2 release flow (same as 3.0.1):
- Five version places: `bin/found-issues` FI_VERSION, CHANGELOG top, both plugin.json, README Status. Check with `bash scripts/check-version.sh`.
- README test count is pinned by tests/docs-consistency.bats.
- After any `commands/*.md` edit, run `bash scripts/gen-codex-skills.sh`.
- PR to main, watch checks to a terminal state, merge. Watch the main tests and release.yml.
- Marketplace bump PR in `~/Documents/projects/claude-plugins` (`.claude-plugin/marketplace.json`, found-issues version).
- Then `claude plugin marketplace update altdoug-plugins && claude plugin update found-issues@altdoug-plugins`.
- Then `codex plugin marketplace upgrade altdoug-plugins && codex plugin add found-issues@altdoug-plugins`.

## Known live hazards (verify each before relying on it)

- ledger-301 (branch `docs/ledger-sync-3.0.1`, tracking branch gone on origin, already merged) has an UNCOMMITTED change to `docs/found-issues.md`. Verified: `git diff --stat` shows 1 line changed. It is the `(autofix-failed: ...)` tag on the post-bash-dispatch.sh:242 entry. It must reach main via a PR. Never hand-edit the ledger. Never `git checkout` it. Branch off first (the branch is stale), carrying the change.
- The v3-phase5 worktree (branch `v3/phase5-release`, merged, gone on origin) has an uncommitted ledger diff. CORRECTION to the session's claim of "two non-closing suggestions": observed 5 changed entries. One entry (`commands/fix.md:38`) only gained a `(PR-auto: AltDoug/found-issues#191)` token and stays `[open]`. One more (`lib/harness.sh:52`) has both `(PR:` and `(PR-auto:` tokens. Four entries are flipped to `[fixed]` with `(fixed: 2026-10-04)` (ship.sh:116, autofix.sh:150, harness.sh:52, session-start.sh:108). It is residue from sync and is not needed. Do not commit it from there.
- Peer sessions share checkouts. The main checkout `~/Documents/projects/found-issues` is on branch `feat/codex-description-key` (verified). Never switch it. Many other worktrees exist (`git worktree list`).
- Never run the full suite and another bats run at the same time. `tests/autofix-run.bats:179` and `tests/autofix-engine.bats:150` use a machine-wide `pgrep -f 'sleep 4712'` / `'sleep 4711'`. This is already an [open] ledger entry. The btest2/btest3 overlap above hit it.
- After `gh pr merge --auto` on a branch with no required checks, the PR merges instantly before checks. Watch checks to a terminal state first, then merge. AltDoug policy: auto-merge on green, never `--delete-branch`.
- The gh-pr-create verify gate needs the `verify` skill invoked in the session before `gh pr create` on a code diff.
- macOS CI runs bash 3.2. Use ASCII-only `@test` names. Use `! cmd || false` for a mid-test negation (a bare `!` asserts nothing).
- The statusline and SessionStart show the failed auto-fix in the summary line.
- 3 decisions are waiting in this repo's ledger (`found-issues decide`). Verified: `autofix status` prints "Decisions waiting: 3".
- Today's auto-fix budget: 1/5 spot fixes used, 0/1 sweeps. The failed run counts as a spot fix.
- Queue state is outside the repo, in `~/.cache/found-issues/autofix/AltDoug__found-issues/`. Run logs are in its `runs/` dir.
- Open ledger entries about this area (already logged, not new): `lib/autofix-queue.sh:275` (a transient git fetch/worktree failure tags autofix-failed permanently) and `lib/autofix.sh:129` (a verifier outage tags autofix-failed instead of requeueing).

## State snapshot (re-verify)

Taken 2026-10-04 by read-only commands.

- Active gh account: AltDoug (`gh auth status`).
- ledger-301: branch `docs/ledger-sync-3.0.1` at `2c4488d`, tracking branch gone, `M docs/found-issues.md`. origin/main is `cade9a2`.
- `autofix status`: "Auto-fix: on (AltDoug/found-issues)", "Today: 1/5 spot fixes", "Today: 0/1 sweeps", "Running (0)", "Queued (1)" with `20261004-155405-28324  sweep  sweep`, "Decisions waiting: 3". Recent: `20261004-155405-15577 hooks/post-bash-dispatch.sh:242 — failed`. "Spent today: $0.00".
- `gh pr list -R AltDoug/found-issues --state all --limit 3`: #193, #192, #191, all MERGED. Latest release: v3.0.1.
- claude-plugins: #42 and #41 MERGED.
- Plugins on this Mac: Claude Code 3.0.1, Codex 3.0.1. Codex CLI 0.159.0, hooks wired and trusted.
- Fixer worktree `fi-autofix-20261004-155405-15577`: gone. Branch: gone.
- Root-cause lead: unreproduced. Evidence is in the btest logs and the code lines cited in the TL;DR.

## Resume prompt

> Working directory ~/Documents/projects/found-issues/.claude/worktrees/ledger-301 (confirm AltDoug active in `gh auth status`; `git status -sb`). Read docs/handoffs/autofix-v3-first-live-failure-handoff-2026-10-04.md end to end and re-verify it. Then diagnose with /diagnose why `bats tests/` exits 1 inside an auto-fix worktree (nested under .claude/worktrees) while it passes elsewhere, fix it and make `found-issues autofix test` show failing test names to the fixer, TDD, ship as 3.0.2 (PR, watch checks to terminal, merge, release.yml, marketplace bump, update plugins on this Mac), carry the uncommitted ledger change through that PR, then let queued sweep 20261004-155405-28324 run and watch its PR. Report every ruling made on the operator's behalf.
