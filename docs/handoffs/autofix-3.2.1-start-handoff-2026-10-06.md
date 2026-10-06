# Auto-fix 3.2.1 start — Session Handoff
**Date:** 2026-10-06 · **Session:** "3.2.0 follow-through"
**Status:** 3.2.0 is released and its follow-through PRs (#216-#221) are all merged; 3.2.1 (three operator-decided fixes) is scoped but not started, and no spec or plan doc exists for it yet.
**Re-verification rule (operator's standing feedback):** do NOT act on this doc's claims without re-verifying against the repo / live state first. Ground truth: `gh release list -R AltDoug/found-issues -L 2`, `gh pr list -R AltDoug/found-issues --state open`, `found-issues autofix status`, `git log --oneline -5 origin/main`, and the ledger via `./bin/found-issues list` (never hand-edit docs/found-issues.md).

## TL;DR for the next session
- Build **found-issues 3.2.1** from a fresh branch off origin/main, in a fresh worktree. Three fixes, one PR, then release:
  1. `[!]` lib/autofix.sh:127 — run the test command once right after `fi_af_worktree_add`. If it fails, retire the run as stale with "tests fail at base" and stop before any fixer attempt.
  2. hooks/stop-reminder.sh:87 — hybrid. Block once per session only when the session edited code; otherwise send a non-blocking reminder.
  3. lib/autofix-sweep.sh:387 — on ship failure, keep the branch and requeue the item so the next run retries ship.
- After 3.2.1 ships: bump the marketplace in AltDoug/claude-plugins, run `/found-issues:sync`, then start 3.3.0 from `docs/superpowers/plans/2026-10-06-autofix-codex-models.md` (subagent-driven).
- Re-verify the live state first. Report every ruling you make on the operator's behalf.

## What was done (verify via PR descriptions / commits)
All in AltDoug/found-issues, all MERGED (squash). PR states were re-checked with `gh pr view` while writing this doc.
- **#216** — handoff doc for 3.2.0 (`docs/handoffs/autofix-3.2.0-shipped-handoff-2026-10-06.md`).
- **#217** — recorded the operator's decide answers:
  - `[!]` lib/autofix.sh:127: retire the run as stale up front with "tests fail at base" (see TL;DR item 1). Ships as 3.2.1.
  - hooks/stop-reminder.sh:87: hybrid, relayed from peer session "Dougstation Sessions". "Edited code" must come from the plugin's own signal: a transcript `tool_use` on non-doc paths, or the plugin's own PostToolUse marker. Never agent-config's `~/.claude/.session-tracker` file.
- **#218** — the 3.3.0 plan, `docs/superpowers/plans/2026-10-06-autofix-codex-models.md` (6 tasks). Operator chose subagent-driven execution. Measured while planning (codex-cli 0.160.1):
  - `gpt-6.1-sol` and `gpt-6-astra` are both listed by `codex debug models`.
  - An unknown model makes `codex exec --json` exit 1 with a `turn.failed` event. Its last stderr line is "Reading additional input from stdin...", so today's outage text is useless.
  - A verifier on a bad model counts as a reject. Plan Task 2 fixes both.
- **Sweep 20261006-004139-14852 recovery.** Launcher B ran the stale 3.1.4 CLI from the old session's PATH. It fixed and verifier-approved 8 entries. Then ship's `git push` failed at 03:09:39 with "Could not resolve host: github.com" (transient DNS via the Tailscale resolver). The failure path (lib/autofix-sweep.sh:387 -> `fi_af_finish` -> `fi_af_worktree_remove`, with `git branch -D` at lib/autofix-queue.sh:289) deleted the branch.
  - Peer session "Landing Branch" re-pinned the commits. This session rebased them onto main and ran `bats tests/` (1..1290, 0 not ok).
  - **#219** opened, `annotate-pr --pick` run for the 8 entries, merged as 85bb9ee. Post-merge tests run 37430882546 passed on macos-latest and ubuntu-latest.
  - The pr-verify-gate skip file was recorded with provenance (auto-fix verifier approvals plus the full suite).
  - #219 also logged the decide entry lib/autofix-sweep.sh:387.
- **#220** — sync closing the 8 entries ("Synced. Closed: 8 (8 PR + 0 commit + 0 tombstone)"). Phase-2 AI verification of 67 eligible entries closed 0 (51 still present, about 26 of them by default rather than full reads; 16 unclear).
- **#221** — recorded the operator's answer on lib/autofix-sweep.sh:387: keep the branch and requeue the item so the next run retries ship. The operator then added it to 3.2.1 scope.
- Local rescue branch `fi/sweep/20261006-14852` was deleted with operator approval.
- Memory: new `release-3-2-1-scope.md` (the 3.2.1 scope); `codex-autofix-models-3-3-0.md` updated.

## Remaining work
**3.2.1 (operator scope, 2026-10-06).** No spec or plan doc exists. Write a short spec+plan or go straight to TDD (your call). One PR, then release.
1. `[!]` lib/autofix.sh:127 baseline test run -> stale "tests fail at base".
   - Evidence: kh2-midgar sweep 20261006-000038-07073 burned $4.88; the found-issues self-run 20261005-222204-26051 failed the same way.
   - It probably explains the ledger entry tests/cli-list.bats:28.
   - Hook point: right after `fi_af_worktree_add` (lib/autofix-queue.sh:261; called from lib/autofix-sweep.sh:201 and lib/autofix-queue.sh:432).
2. hooks/stop-reminder.sh:87 hybrid (details in "What was done" above). The current code asks once per session with a blocking `decision: block`.
3. lib/autofix-sweep.sh:387 keep the branch and requeue on ship failure.
   - Also consider the spot path: lib/autofix.sh:179 `_fi_af_end "$id" failed "ship: $FI_AF_WHY"`. It reaches the same deletion through `fi_af_worktree_remove`.
   - Related existing entry: lib/autofix-queue.sh:275 (transient fetch/worktree failures tag permanently).

**Release mechanics (from #212):**
- Bump `bin/found-issues` FI_VERSION, `.claude-plugin/plugin.json` and `.codex-plugin/plugin.json`.
- Update CHANGELOG, plus the README version line and test count.
- PR title "release: v3.2.1 — ...". `release.yml` auto-cuts the tag on merge.
- Then bump the marketplace in AltDoug/claude-plugins (same shape as #51).
- An adversarial `/code-review` before the release PR is standing practice.

**After 3.2.1:**
- 3.3.0 per plan #218 (subagent-driven). Task 3 recreates AltDoug/fi-v3-e2e and asks before deleting; `gh-repo-delete-guard` needs `GH_REPO_DELETE_GUARD=off` after the operator's yes.
- kh2 `tools/bin/build.sh` retag waits until 3.2.1 ships (operator checkpoint).
- Box-side `/found-issues:sync` on dougstation mod repos only when those sessions are idle.
- The 14 other decide entries were ALL answered by the operator on 2026-10-06 (each now carries `(decided: ...)` in the ledger; landed in this handoff's PR). They are buildable work but NOT assigned to a release. Ask the operator (picker) which release takes them; recommend a batch after 3.3.0. Flag `lib/autofix-engine.sh:120` (lock the unattended Claude fixer: worktree-scoped Edit/Write, Bash sandbox, `--strict-mcp-config`, each proven live) as the safety item worth doing first. Questions 6/7 (`lib/sync.sh:403`, `commands/defer.md:29`) share ONE new `unannotate` verb.

## Known live hazards (verify each before relying on it)
1. Long-lived sessions keep the plugin CLI version from their start PATH (that sweep ran 3.1.4 after 3.2.0 was installed). Test branch code with `./bin/found-issues` by path. Auto-fix agents use the INSTALLED plugin CLI.
2. Harness gates match command text.
   - pr-verify-gate fires on the literal PR-create command. It needs this session's verify and review telemetry, or a skip file written in its own Bash call before the PR command. The skip expires at the next commit.
   - stop-tests-pass credits only a bare `bats tests/`. There is NO `tests/hooks/` dir, so `bats tests/ tests/hooks/` errors.
   - Keep "gh pr create" text out of non-PR commands.
3. Auto-fix is on globally. Logging a `--fix` tagged entry in this repo makes hooks ask the main session to launch fixer/sweeper agents (paid). Log design questions as `--decide`.
4. A 3.x auto-fix run writes an uncommitted `(PR: ...)` annotation into the session checkout's ledger. Check `git diff docs/found-issues.md` before ledger commits. Never `git add -A`; never `git checkout` the ledger; peer sessions share checkouts.
5. Worktree layout. Work happens in `/Users/diogosilvasena/Documents/projects/found-issues/.claude/worktrees/verify-3.1x-live`, with nested `.claude/worktrees/` under it (`decide-3-2-1`, `recover-sweep-14852`; the reaper cleans them). Never touch the main checkout `/Users/diogosilvasena/Documents/projects/found-issues`. Create a fresh branch from origin/main in a worktree for 3.2.1.
6. macOS CI runs bash 3.2. Guard empty-array expansions under `set -u` with `${A[@]+"${A[@]}"}`. A bare `! cmd` in bats asserts nothing; use `! cmd || false`. Keep `@test` names ASCII-only.
7. External PR #171 (jbelmana, "sync: hold [!] critical closures for human verification (#161)") is open and unrelated.
8. Context budget: hand off early in long sessions.

## State snapshot (re-verify)
- origin/main `4ea9143` (#221) at handoff.
- v3.2.0 is Latest (2026-10-06T02:21:25Z).
- Open PRs: #171 only, plus this handoff doc's PR, which the predecessor merges before spawning.
- `found-issues autofix status`: Running 0, Queued 0, 1/1 sweeps today. Last result: sweep 20261006-004139-14852 "failed: ship: git push failed".
- Ledger: 1 critical · 67 other · 1 stale. Decisions waiting: 0 (`found-issues decide --count`).

## Resume prompt
> Work in a fresh git worktree of /Users/diogosilvasena/Documents/projects/found-issues (branch from origin/main; never touch the main checkout itself). First run `gh auth status` and confirm the active account is AltDoug. Read `docs/handoffs/autofix-3.2.1-start-handoff-2026-10-06.md` end to end and the memory file release-3-2-1-scope.md, then re-verify against live state (`gh release list -R AltDoug/found-issues -L 2`, `gh pr list -R AltDoug/found-issues --state open`, `found-issues autofix status`, `git log --oneline -5 origin/main`). Then build found-issues 3.2.1 with its three operator-decided fixes ([!] lib/autofix.sh:127 baseline test run, hooks/stop-reminder.sh:87 hybrid, lib/autofix-sweep.sh:387 keep+requeue on ship failure): TDD, full `bats tests/`, adversarial /code-review, one release PR merged on green, verify v3.2.1 Latest, bump the marketplace in AltDoug/claude-plugins, then /found-issues:sync. After that, start 3.3.0 from plan docs/superpowers/plans/2026-10-06-autofix-codex-models.md with superpowers:subagent-driven-development. Never `git add -A`; never `git checkout` the ledger. Report every ruling you make on the operator's behalf.
