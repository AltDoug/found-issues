# Autofix 3.1.4 release and 3.2.0 landing-branch build — Session Handoff
**Date:** 2026-10-05 · **Session:** "autofix 3.1.x verify + 3.2.0 landing branch"
**Status:** v3.1.4 is released and green; the 3.2.0 landing-branch plan is 1 of 8 tasks done (a8263bb) and Task 1 has not been reviewed yet.
**Re-verification rule (operator's standing feedback):** do NOT act on this doc's claims without re-verifying against the repo / live state first. Start with `git -C ~/Documents/projects/found-issues/.claude/worktrees/verify-3.1x-live status -sb && git log --oneline -6` and `gh release list -R AltDoug/found-issues -L 2`.

## TL;DR for the next session

- Work in the worktree `~/Documents/projects/found-issues/.claude/worktrees/verify-3.1x-live` on branch `spec/autofix-landing-branch`. Never touch the main checkout `~/Documents/projects/found-issues`: peer sessions share it and its ledger is dirty on the stale branch `feat/codex-description-key`.
- 3.2.0 makes the auto-fixer start from, and land into, the session's own branch instead of main. The design is in `docs/superpowers/specs/2026-10-05-autofix-landing-branch-design.md`, the 8-task plan in `docs/superpowers/plans/2026-10-05-autofix-landing-branch.md`.
- Execution is subagent-driven (operator's choice). Task 1 is implemented (a8263bb, status DONE_WITH_CONCERNS). Its task review has NOT been dispatched. Next step: generate the review package for 34e9e7b..a8263bb and dispatch a sonnet reviewer, then Tasks 2-8.
- The kh2-midgar watcher is stopped. Restart it (Remaining work, step 2).
- v3.1.4 shipped this session. Nothing about it is pending except live observation after midnight EDT 2026-10-06.

## What was done (verify via PR descriptions / commits)

Re-verified at write time (2026-10-05) with `gh pr view`, `gh release list`, `gh run view`, `git log`:

- Previous handoff `docs/handoffs/autofix-3.1.x-sweeps-live-handoff-2026-10-05.md` (untracked, main checkout only) was checked. Its #205 post-merge main run 37280561911 concluded success; `bats (macos-latest)` completed 2026-10-05T08:26:27Z.
- AltDoug/found-issues PRs, all MERGED:
  - #207: logged 3 found-issues entries (merged 08:04Z).
  - #208: `fi_af_classify` skip logging (09:09Z).
  - #209: sweep test-command precheck, `fi_af_sweep_claim` (09:47Z). The main session merged main into it and pushed the README test count 1244.
  - #210: annotates the classify entry with #208 (09:48Z).
  - #211: release v3.1.4 (14:37Z). `gh release list` shows v3.1.4 as Latest, v3.1.3 before it.
- AltDoug/claude-plugins #50 (marketplace bump to 3.1.4): MERGED 14:38Z.
- v3.1.4 post-merge main run 37326237292: conclusion success, headSha eab7f5a; `bats (macos-latest)` success 14:59:47Z, `bats (ubuntu-latest)` success, shellcheck success.
- dougstation read-only probe (ssh silva@100.98.153.101, scp a .ps1 then `powershell -NoProfile -ExecutionPolicy Bypass -File <f>`): the kh2-midgar sweep `20261005-001847-21946` ended "stale: no test command" because origin/main 361f670 has no `tests/`. The classifier never ran. Five spot fixes were parked decide/manual because the files they cite exist only on unmerged branches. (unverified: probe results are from this session's transcript, not re-run at write time). dougstation self-updated to 3.1.4 at 11:11 EDT (unverified).
- 3.2.0 design: spec commits 3c1b14c, 14b84fc, 34e9e7b; plan commit 378036a; Task 1 commit a8263bb ("feat(autofix): resolve the landing branch from the session's checkout"). `git ls-remote --heads origin spec/autofix-landing-branch` returned a8263bb, so the branch is pushed and current.
- Operator decisions (2026-10-05) for 3.2.0, recorded in the spec:
  1. Fixes start from, and land into, the session's branch, not main.
  2. Unpushed commits: start from the pushed tip, open the PR into the branch, wait until pushed.
  3. Landing rule, approach A: tracked branch; gone upstream means the merged PR's base; never pushed means the nearest pushed ancestor; default or detached means main.
  4. An auto-fix PR closes its entry on merge into the landing branch.
  5. Cited file busy (uncommitted or unpushed changes in the session checkout): the item waits.
  Also approved: cutting 3.1.4; "check once then idle" at work; then "keep watch" for the watcher.
- Peer session "Paseo Deploy" confirmed gh works on dougstation and is logged in as AltDoug (unverified). The "install gh for PR status" footer is cosmetic Claude Code. The statusline's `❓2` on kh2-midgar is 2 decide entries parked by auto-fix (L46 `tools/bin/build.sh`, L55 `tools/verify/scenarios/canary-event66.yml:36`).

## Rulings made on the operator's behalf

1. Logged 3 found-issues entries and merged the ledger PRs #207 and #210 under the AltDoug auto-merge policy.
2. Launched both auto-fixers when the hook asked (cost $0.83 and $0.74). Relaunched 25130 after the repo lock freed.
3. Updated #208's branch from main via gh (no force push).
4. Merged main into #209 and pushed README count 1244.
5. Ran the red-on-old-code checks the fixers skipped for #208 and #209: both red on old code, green on new.
6. Declined the hook's annotate suggestions for entries a commit did not fix (78a3d3e for `:162`/`:168`; the `bin/found-issues` prefix-match entry for #211).
7. Stopped watchers on each "pause" request from the peer session or operator.
8. SDD Ruling 1 and Ruling 2, in `.superpowers/sdd/2026-10-05-autofix-landing-branch/progress.md`:
   - Ruling 1: `_fi_af_entry_file` returns a path only when it exists in the root checkout's working tree. Format-spec topics can contain slashes (`dispatch/shutdown`), so the Task 2 topic test uses that value. Cost if wrong: a file deleted locally but present on origin would not wait, then parks as today.
   - Ruling 2: each task that adds `@test`s also updates the README test count in the same commit, so `tests/docs-consistency.bats` stays green; Task 7 only re-checks it. Cost if wrong: extra README churn.
9. Pushed `spec/autofix-landing-branch` to origin as a backup.

## Remaining work

1. Resume subagent-driven execution from the SDD ledger (`.superpowers/sdd/2026-10-05-autofix-landing-branch/progress.md`, git-ignored, read it end to end). Generate the review package with `bash ~/.claude/plugins/cache/claude-plugins-official/superpowers/6.4.1/skills/subagent-driven-development/scripts/review-package docs/superpowers/plans/2026-10-05-autofix-landing-branch.md 34e9e7b a8263bb` (script path unverified), dispatch the Task 1 reviewer (sonnet), then Tasks 2-8 per the plan. Implementers sonnet; final whole-branch review opus.
2. Task 1 concerns for the reviewer: the implementer rewrote the orphan test (`git rm` on a fresh orphan fails) and added a read-loop guard for `source-guards`. The full suite was NOT re-run after that guard fix (last full run: 1254 tests, 1 failure in source-guards; then focused 28/28). Run the full suite before accepting Task 1.
3. Restart the kh2-midgar watch: `bash <worktree>/.superpowers/watch/fi-watch.sh` in the background (polls dougstation every 15 min, exits on change, 24 h cap). Compare against the last known state: dougstation plugin 3.1.4; kh2-midgar state unchanged since 03:53 EDT 2026-10-05 as of 17:22 EDT (unverified).
4. Check live behaviour: kh2-midgar's first sweep after midnight EDT 2026-10-06 should retire "stale" WITHOUT taking the day's sweep slot (3.1.4 / #209).
5. Retag the two parked kh2-midgar decide entries (L46, L55) only after 3.2.0 ships and only with the operator's OK.
6. PR #171 (sync: hold [!] critical closures, #161) is still OPEN (verified). Mention only; do not act.

## Known live hazards (verify each before relying on it)

- Peer sessions share the main checkout: never `git add -A`, never `git checkout` the ledger there.
- Edit the ledger only via `./bin/found-issues`. Auto-fix PRs ship without a version bump. The README test count is enforced and collides between concurrent PRs.
- Strict branch protection: a BEHIND PR blocks auto-merge. Use `gh pr update-branch` or merge main in; no force push. claude-plugins has no auto-merge and no CI (merge directly).
- The `stop-tests-pass` hook credits only commands starting with `bats`. `pr-verify-gate` fires on the literal text "gh pr create" anywhere in a command, so keep that text out of non-PR commands.
- The operator pauses when leaving home or work (the Mac loses network): stop watchers, resume on "back".
- Leftover worktrees (branch deletion needs an operator checkpoint): `.claude/worktrees/pr209` (pr209-local, pushed, merged), `verify-3.1x-live` (this work), `claude-plugins/.claude/worktrees/fi-3.1.1` (chore/found-issues-3.1.4, merged). `git worktree list` shows many more audit/fix worktrees from earlier sessions; see the previous handoff.
- Probe scripts left in the dougstation home dir: `fi-kh2-probe.ps1`, `fi-kh2-probe2.ps1`, `fi-sig.ps1`, `fi-activity.ps1`, `gh-check.ps1`, `decide-check.ps1`, `survey.ps1` (unverified).
- Untracked handoff docs and `.agents/` in the main checkout belong to peer sessions; leave them.

## State snapshot (re-verify)

- Worktree `~/Documents/projects/found-issues/.claude/worktrees/verify-3.1x-live`, branch `spec/autofix-landing-branch`, tracking origin, in sync at write time. Untracked: `.superpowers/` (git-ignored ledger and watcher).
- Branch tip before this doc: a8263bb. Branch base at the spec start: 34e9e7b. origin/main: eab7f5a (v3.1.4).
- Latest release: v3.1.4 (2026-10-05T14:37:56Z). claude-plugins marketplace at 3.1.4.
- `gh auth status`: AltDoug active.
- Main checkout `~/Documents/projects/found-issues`: branch `feat/codex-description-key` at 045c42b, dirty ledger (per `git worktree list` and the session-start git status).
- 3.2.0 plan progress: Task 1 implemented, not reviewed; Tasks 2-8 not started.

## Resume prompt

> Work in `~/Documents/projects/found-issues/.claude/worktrees/verify-3.1x-live` (branch `spec/autofix-landing-branch`); never touch the main checkout `~/Documents/projects/found-issues`. First confirm AltDoug is active in `gh auth status`, then run `git status -sb` and `git branch --show-current`. Read `docs/handoffs/autofix-3.2.0-landing-branch-handoff-2026-10-05.md` and the SDD ledger `.superpowers/sdd/2026-10-05-autofix-landing-branch/progress.md` end to end, and re-verify every claim against the repo and `gh` before acting. Then resume superpowers subagent-driven-development at the Task 1 review: generate the review package for 34e9e7b..a8263bb, run the full suite first because it was not re-run after the Task 1 guard fix, and dispatch the Task 1 reviewer (sonnet). Continue Tasks 2-8 per `docs/superpowers/plans/2026-10-05-autofix-landing-branch.md` with sonnet implementers and an opus whole-branch review at the end. Restart the kh2-midgar watcher with `bash .superpowers/watch/fi-watch.sh` in the background, and check that the first sweep after midnight EDT 2026-10-06 retires "stale" without taking the day's sweep slot. At the end, report every ruling you made on the operator's behalf.
