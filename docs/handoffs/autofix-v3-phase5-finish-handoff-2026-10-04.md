# found-issues v3.0.0 auto-fix — Phase 5 Finish Handoff

**Date:** 2026-10-04 · **Session:** "v3 phase 5 build + live E2E (operator asleep)"
**Status:** Tasks 1-9 of the Phase 5 plan are built and live-E2E proven; the final review's 6 Important findings (I1-I6) are not yet fixed, the branch is pushed (this handoff commit is its tip), and Tasks 11-14 (PR, release, marketplace bump, local enable) are not started.
**Re-verification rule (operator's standing feedback):** do NOT act on this doc's claims without re-verifying against the repo / live state first. Ground truth: `git -C <worktree> log --oneline ca747ec..HEAD`, `.superpowers/sdd/2026-10-04-autofix-v3-phase5-release/progress.md` (git-ignored ledger in the worktree), `gh pr list -R AltDoug/found-issues --base release/v3 --state all --limit 5`.

## TL;DR for the next session

- Worktree `~/Documents/projects/found-issues/.claude/worktrees/v3-phase5`, branch `v3/phase5-release`, cut from `origin/release/v3` at `ca747ec` (PR #189). Plan: `docs/superpowers/plans/2026-10-04-autofix-v3-phase5-release.md` (Rulings 1-12, Global Constraints, Review Focus, Tasks 1-14), executed with `superpowers:executing-plans`.
- Built and committed: config, cancel, full status, statusline/json segments, SessionStart summary, doctor section, setup disclosure, 3.0.0 docs, live E2E evidence. Final read-only opus review verdict: "with fixes" (0 Critical, 6 Important, 9 Minor deferred).
- Next move: fix I1-I6 RED->GREEN (one commit each), re-run the full suite then the bash 3.2 subset (sequentially), then Task 11 (push + PR into `release/v3`), Task 12 (release PR to `main`), Task 13 (marketplace bump), Task 14 (enable on this Mac).
- The operator may be asleep: work autonomously, list every ruling made on his behalf in the PRs and the final report, subagents must never trigger permission prompts, reviews stay read-only.

## What was done (verify via PR descriptions / commits)

The branch was pushed together with this handoff doc (`origin/v3/phase5-release` = the handoff commit; before that push it was `ahead 13` of `2cee403`). No PR is open yet. Tree clean except git-ignored `.superpowers/`. Ledger has `Task N: complete` lines for Tasks 1-9, every `Ruling:` line, 6 `Final: TODO` (I1-I6) and 9 `Final: minor (deferred)` lines.

Commits on top of `ca747ec` (newest first, `git log --oneline ca747ec..HEAD`):

```
3e11713 docs(v3) phase 5: live E2E evidence (7 self-merged PRs, A and B, Claude and Codex)
8a0267a fix(v3) phase 5: the launcher B nudge names the agent's model
64817c2 fix(v3) phase 5: guard the status read loop's final partial line (source-guards)
8737bc0 fix(v3) phase 5: status prints spend as dollars and cents
d107289 docs(v3) phase 5: 3.0.0 breaking-change note, changelog, README status, config docs
39c98f4 feat(v3) phase 5: setup discloses auto-merge and billing before enabling auto-fix
6b23b16 feat(v3) phase 5: doctor shows auto-fix readiness and caps
bf2c49c feat(v3) phase 5: SessionStart summary of auto-fix results; fixer children are headless
747c2d8 feat(v3) phase 5: statusline shows runs in progress and decisions waiting
e89000e feat(v3) phase 5: autofix status shows PR links, cost, decisions and spend
6530d45 feat(v3) phase 5: autofix cancel stops a run and its engine process group
4148db4 feat(v3) phase 5: found-issues config wraps the auto-fix settings
82e5ec2 docs(v3) phase 5 plan: visibility, settings, live E2E and the 3.0.0 release
2cee403 docs(handoff): v3 phase 5 plan handoff
```

By task:

- **`found-issues config`** (`lib/autofix-config.sh`, `cmd_config`) wraps the auto-fix settings.
- **`autofix cancel`** (new `lib/autofix-status.sh`; item fields `cpgid`, `finished` in `lib/autofix-queue.sh`).
- **Full `autofix status`:** PR links, cost, "Spent today", decisions waiting, newest-first by `finished`. Status spend prints as dollars and cents (`$0.00`).
- **Statusline:** `🔧N` (runs in progress) and `❓N` (decisions waiting).
  - `🔧N` reads a state file `<state>/autofix/seg/<sanitized physical root>`, written on claim/retire/requeue/reap, read builtin-only after the cache (`lib/segment-cache.sh` `fi_segment_af_suffix` / `fi_segment_join`). Cache key bumped `seg1` -> `seg2`.
  - `❓N` is ledger-derived (`fi_count_decide`).
  - json output gains `decisions` / `running` fields. Contract doc gains a "v3 additive buckets" section plus 2 snapshot tests in `tests/contract-segment.bats`.
- **Autofix summary + SessionStart block:** interactive sessions only, gated by a builtin `-d` on `<state>/autofix`. Plus a `FOUND_ISSUES_AUTOFIX_CHILD` headless guard (fixes ledger entry `hooks/session-start.sh:108`).
- **Doctor:** Auto-fix section (`fi_af_doctor`).
- **Setup:** "Optional 4" disclosure in `commands/setup.md`, `codex-skills/fi-setup` regenerated.
- **Docs:** `docs/versioning.md` "3.0.0 — breaking changes", CHANGELOG `## [3.0.0] - 2026-10-04` (Breaking/Added/Fixed), README Status v3.0.0 + Auto-fix section + decide row, `docs/configuration.md` auto-fix settings. README test count 1188. `scripts/check-version.sh` OK.
- **Extra fixes:**
  - Status "$0.00" formatting.
  - Source-guards fix: read-loop guard for a final partial line in `lib/autofix-status.sh`.
  - Launcher B nudge now says "with model sonnet (its own setting)" (8a0267a). This was a live finding: the operator's subagent-model-guard hook blocked the model-less dispatch.
- **Live E2E (Task 9)** on private throwaway repo `AltDoug/fi-v3-e2e` (left in place; deleting is the operator's call). Evidence doc: `docs/e2e/v3-live-e2e-2026-10-04.md`. 7 PRs, all self-merged via merge-when-green (no branch protection on a free private repo, so auto-merge cannot arm):
  - A claude spot PR#1 ($0.97, 83s); A codex spot PR#2 (63s).
  - Hook-spawned A from a real `claude -p` manual-mode session PR#3 ($0.78).
  - B spot in a REAL interactive `claude --permission-mode auto` session PR#4. Run in detached tmux because the Orca app was not running.
  - A claude sweep PR#5 ($1.48); A codex sweep PR#6; B sweep PR#7 ($0.98).
  - Sync closed 10/10 entries, ledger 0 open. Total about $4.81 Claude estimate.
  - Answers: the auto-mode classifier allowed `found-issues autofix ship`; writes under `.claude/worktrees` did not prompt. The SessionStart summary was seen live.
- **Tests at write time:** full `bats tests/` was 1187 ok / 1 not ok (source-guards, fixed afterwards in 64817c2 and re-run alone green). The full suite has NOT been re-run since those last commits. The bash 3.2 subset (command in plan Task 9 Step 1) gave exit=0, 447 ok.
- **Final review:** ONE read-only opus agent, verdict "with fixes": 0 Critical, 6 Important (all re-graded as standing), 9 Minor deferred. The 6 Important (full text in the ledger `Final: TODO` lines):
  - **I1:** json `running` regex matches the `35` in the `\033[35m` color code (`lib/list-status.sh`). Fix: use plain `FI_SEG_AF_N`.
  - **I2:** a SIGKILLed A run keeps the lock for 3600s, so status/claim cannot reap it: the 🔧 sticks and claims return 4. Fix in `fi_af_lock`: owner is a running item with a dead pid => stale. Also remove the manual lock `rm` in the reaped-crash test of `tests/cli-status-autofix.bats`.
  - **I3:** cancel signals the pid before checking that the lock owner == id (the drain may be on another item).
  - **I4:** cancel during publish can leave an opened/armed PR while the item says cancelled. Fix: record `pr=` right after `gh pr create`; cancel refuses or records it.
  - **I5:** B fixer free text via `autofix release --failed` can reach the SessionStart directive. Fix: use an allowlist of bash phrases.
  - **I6:** cancel of a queued item races a claim and can unlock a live run. Fix: a single `mv` queue->done, never running-first `fi_af_retire`.
- **Rulings made on the operator's behalf** (list all in the PRs and the final report): plan Rulings 1-12 in the plan file; ledger rulings: Task 3 test fixes + BSD midnight; Task 4 additive-bucket contract ruling + vacuous-test fix; Task 5 test location; Task 7 grep instead of rg; Task 9 tmux instead of Orca + trust dialog accepted + `sweepThreshold` 2 + hook-path probe.

## Remaining work

In order:

1. **Fix pass for I1-I6**, each RED->GREEN with the test watched failing, one commit each. Optionally the cheap minors (stamp read `|| true`; summary early-return when `$FI_AF_ST` is absent). Otherwise log the minors with `./bin/found-issues log --fix small '<path:line> — <symptom> (suggested: …)'` after re-deriving lines with `rg -n`. Recount README tests.
2. **Full suite, then the bash 3.2 subset, sequentially** (never in parallel).
3. **Plan Task 11:** push; `gh pr create --dry-run` probe; PR into `release/v3` with rulings + E2E evidence; `./bin/found-issues annotate-pr <N> --pick hooks/session-start.sh:108`; `GH_PR_MERGE_BASE_GUARD=off gh pr merge <N> --auto --squash`; watch the post-merge `release/v3` push run to a terminal state (macOS bats only runs there).
4. **Task 12:** release PR `release/v3` -> `main`. Check `git rev-list --count origin/release/v3..origin/main` first; re-date the CHANGELOG if the day changed; watch every check; merge on green; no `--delete-branch`; watch `release.yml`; `gh release list --limit 1` shows v3.0.0.
5. **Task 13:** marketplace bump in `~/Documents/projects/claude-plugins` (`.claude-plugin/marketplace.json`, found-issues version 3.0.0) via PR, merge.
6. **Task 14:**
   - Update plugins on this Mac (`claude plugin --help` for syntax); in a new shell `found-issues --version` = 3.0.0.
   - `git config --global found-issues.autofix true`; run `found-issues doctor`.
   - Disclose plainly that fix PRs always auto-merge and runs bill the account.
   - Ask ONCE via AskUserQuestion multiSelect which client repos to exclude (tere site, tere-shop-ops, kingdomtcg, sayciao; set `git -C <repo> config found-issues.autofix false`).
   - Update memory `enable-autofix-after-v3.md` + its MEMORY.md line.
   - Then delete the `.superpowers/sdd/2026-10-04-autofix-v3-phase5-release` workspace and use `superpowers:finishing-a-development-branch`.

## Known live hazards (verify each before relying on it)

- The operator may be asleep: work autonomously, list every ruling, subagents must never trigger permission prompts, reviews read-only.
- Never run the full suite and the bash 3.2 subset in parallel (`tests/autofix-run.bats:179` uses a machine-wide `pgrep`).
- The pr-verify-gate: probe `gh pr create --dry-run`, and write the skip reason to the printed `.pr-verify-skipped`.
- `ps` truncates argv without `-ww` (cost a false alarm this session).
- bats quirks: glob / `-f` handling; ASCII-only test names; bash 3.2 `[[ ]]` and `!` mid-test need `|| false` (a bare `!` asserts nothing).
- Never write `docs/found-issues.md` by hand; use the `found-issues` CLI.
- `~/.claude/found-issues/autofix` now exists on this Mac (E2E state for `AltDoug/fi-v3-e2e`), so the SessionStart summary block will run once v3 is installed.
- The Orca app was not running this session (E2E used detached tmux).
- The context-budget nudge fired at about 424K tokens.
- Confirm `AltDoug` is the active account in `gh auth status` before any `gh` write.

## State snapshot (re-verify)

- Worktree: `~/Documents/projects/found-issues/.claude/worktrees/v3-phase5`; branch `v3/phase5-release`, 13 commits ahead of `origin/v3/phase5-release` (`2cee403`); HEAD `3e11713`; tree clean (git-ignored `.superpowers/` only).
- Ledger: `.superpowers/sdd/2026-10-04-autofix-v3-phase5-release/progress.md` (9 `Task N: complete`, 6 `Final: TODO`, 9 `Final: minor` at write time). Sibling files: `full.log`, `b32.log`, `review-ca747ec..3e11713.diff`, per-task test logs.
- Throwaway E2E repo `AltDoug/fi-v3-e2e` still exists (private); delete only on operator say-so.
- No PR for Phase 5 exists yet (verify with `gh pr list -R AltDoug/found-issues --base release/v3 --state all --limit 5`). `release/v3` was last known at `ca747ec` (PR #189).
- Version in tree is 3.0.0 prep (CHANGELOG dated 2026-10-04); no tag/release cut; claude-plugins marketplace not yet bumped; v3 not yet installed on this Mac.

## Resume prompt

> Working directory ~/Documents/projects/found-issues/.claude/worktrees/v3-phase5 (branch v3/phase5-release; `git status -sb`, confirm AltDoug active in `gh auth status`). Read docs/handoffs/autofix-v3-phase5-finish-handoff-2026-10-04.md end to end and re-verify it (git log ca747ec..HEAD, the ledger .superpowers/sdd/2026-10-04-autofix-v3-phase5-release/progress.md). Then continue the plan docs/superpowers/plans/2026-10-04-autofix-v3-phase5-release.md with superpowers:executing-plans from the final-review fix pass: fix review findings I1-I6 RED->GREEN, run the full suite then the bash 3.2 subset, then Tasks 11-14 (PR into release/v3, merge, watch post-merge run; release/v3 -> main 3.0.0 PR, watch runs and release.yml; marketplace bump in AltDoug/claude-plugins; update plugins on this Mac, enable auto-fix globally, doctor, disclose that fix PRs always auto-merge, ask once via picker which client repos to exclude). The operator may be asleep: do everything possible without him, list every ruling made on his behalf in the PRs and the final report, never trigger permission prompts from subagents.
