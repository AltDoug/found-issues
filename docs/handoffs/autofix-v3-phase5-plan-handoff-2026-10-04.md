# found-issues v3.0.0 auto-fix — Phase 5 Plan Handoff

**Date:** 2026-10-04 · **Session:** "v3 phase 4 finish (operator asleep)"
**Status:** Phase 4 is MERGED into `release/v3` as PR #189 (ca747ec). Phase 5 has not started: no plan, no code. This doc is the first commit on `v3/phase5-release`. After Phase 5 come the `release/v3` → `main` release PR for 3.0.0 and the marketplace bump.
**Re-verification rule (operator's standing feedback):** do NOT act on this doc's claims without re-verifying against the repo / live state first. Ground truth: `git -C ~/Documents/projects/found-issues/.claude/worktrees/v3-phase5 fetch && git log --oneline -3 origin/release/v3`, `gh pr view 189 -R AltDoug/found-issues --json state,mergeCommit`, `gh run view 37184138843 -R AltDoug/found-issues --json status,conclusion`, `git rev-list --count origin/release/v3..origin/main`.

## TL;DR for the next session

1. Work in `~/Documents/projects/found-issues/.claude/worktrees/v3-phase5`, branch `v3/phase5-release`, cut from `origin/release/v3` at ca747ec.
2. Write the Phase 5 plan first (`superpowers:writing-plans` into `docs/superpowers/plans/2026-10-0X-autofix-v3-phase5-release.md`), then execute it (`superpowers:executing-plans`), the same way phases 2-4 were done. Read spec §11 (Delivery), §8 (Settings, setup, visibility, safety), §4.1 and the Rulings and Global Constraints at the top of `docs/superpowers/plans/2026-10-04-autofix-v3-phase4-sweep.md` first.
3. Phase 5 scope (spec §11 item 5): statusline, `autofix status`, SessionStart summary, setup disclosure, doctor, docs (`docs/versioning.md` breaking-change note), the 3.0.0 bump, and a live E2E.
4. Then the final step: one PR `release/v3` → `main` for 3.0.0, then the marketplace bump PR in `AltDoug/claude-plugins` (only after the source release merges).
5. Last: enable auto-fix on this Mac (see "Remaining work", item 8).
6. The operator may be asleep again. Do everything possible without him, list every ruling made on his behalf in the PR bodies and in the final report ("Rulings made while you were away"), and never let a subagent trigger a permission prompt.

## What was done (verify via PR descriptions / commits)

**Phase 4 review fix pass** (commit 1ef9f0c on `v3/phase4-sweep`, from the opus whole-branch review findings I1-I6):
- **I1:** sweep ship resets to the last approved commit first, so a half-done entry no longer fails the ship and deletes the approved branch. The sweep brief now says verify exit 3 means "fix the tests and verify again".
- **I2:** `autofix off` mid-sweep requeues on launcher A instead of shipping.
- **I3:** a sweep requeued the same day keeps the cap it already took (`cap_day` item field). A sweep over the cap retires stale (rc 5) instead of rc 3, so it never writes `day/<date>.capped`.
- **I4:** no sweep check inside a fixer child (`FOUND_ISSUES_AUTOFIX_CHILD=1`).
- **I5:** `found-issues fix ship --source <root>` (default: the checkout the worktree was made under). `commands/fix.md` passes it and the Codex skill was regenerated.
- **I6:** `fi_af_item_read` refuses an item whose `wt` is outside `"$AFI_root"/.claude/worktrees/fi-*` or contains `..`; the reaper retires such items untouched.
- 11 new tests and 1 rewritten test. README test count is now 1145 (`cat tests/*.bats | rg -c '^@test'` printed 1145 on this branch).

**Review minors.** Six are logged in `docs/found-issues.md` as `(fix: small)`, at `lib/autofix.sh:129`, `lib/autofix-classify.sh:121`, `lib/autofix-sweep.sh:168`, `hooks/session-start.sh:108`, `tests/autofix-sweep-b.bats:30` and `lib/autofix-sweep.sh:162` (line numbers as logged; re-derive before relying on them). The seventh ("classify apply reads rows without -r") was dropped as non-reproducible: both reads use `read -r`. A separate entry logs `tests/autofix-run.bats:179`: the TERM test uses a machine-wide `pgrep` and failed once when the full suite and the bash 3.2 subset ran in parallel.

**Evidence before merge:**
- Full suite `bats tests/`: 1144 ok, 1 not ok (the TERM collision above). Re-run alone, `bats tests/autofix-run.bats` exit=0, 22/22.
- bash 3.2 subset: exit=0, 356 ok, 0 not ok.
- E2E with the real CLI and hooks, stand-in `claude`/`gh`: B path (bypassPermissions) did claim+classify, verify exit 3 then fixed, a half-done edit was dropped at ship, 5 fix commits plus 1 annotation commit, one PR, auto-merge armed. A path (default mode) ended `result=shipped`: PR #9, 6 fixed, merge auto, $3.2500.

**Merge.** PR #189 "feat(v3) phase 4: sweep, sweeper agent, /found-issues:fix on shared plumbing" merged into `release/v3` at 2026-10-04T06:53:36Z as ca747ec. Post-merge push run 37184138843: `success` on every job (detect changes, shellcheck, json validation, version check, test name ASCII guard, bats ubuntu-latest, bats macos-latest, ci).

**Rulings made while the operator was asleep** (all listed in PR #189's body; the operator must review them): plan Rulings 1-10; the Task 8 ruling (`fix ship` annotates the worktree ledger only when it has its own); the Task 9 ruling (the jq and codex SessionStart notices are also headless-guarded); the I3, I4, I5 and I6 rulings (for I5 the default source is the path prefix of the worktree, not `--show-toplevel` as the reviewer suggested); and dropping the seventh minor.

The git-ignored SDD scratch workspace `.superpowers/sdd/2026-10-04-autofix-v3-phase4-sweep/` was deleted after the CI run. It lives in the `v3-phase4` worktree, not this one.

## Remaining work

1. **Plan.** Write the Phase 5 plan (see TL;DR). The plan carries its own Rulings and Global Constraints sections like the phase 4 plan, and a "Docs re-check" section for any Claude Code facts it relies on.
2. **Visibility pieces (spec §8).**
   - Statusline: `🔧N` (running) and `❓N` (decisions waiting), read from a state file by the existing builtin segment path, no new forks. Relevant code: `lib/statusline-core.sh`, `lib/list-status.sh`.
   - `found-issues autofix status`: queue, running, today's counts against caps, and recent results with PR links and cost (from `total_cost_usd`). A first `status` subcommand already exists (`lib/autofix.sh`, `_fi_af_status`); check it against the spec before adding to it.
   - SessionStart summary, interactive sessions only (`CLAUDE_CODE_ENTRYPOINT` empty or `cli`; Phase 4 prompt-11 guard in `hooks/session-start.sh`): "Since last session: fixed N (PR ...), M failed (reason), K decisions waiting".
   - `/found-issues:setup`: new auto-fix step that states, before enabling, that fix PRs merge themselves, that runs bill the user's account including in the background, the default caps, and how to turn it off. The wording must say plainly that fix PRs auto-merge.
   - `doctor`: an auto-fix section showing enabled state, test command, `gh` auth, `claude`/`codex` on PATH, and caps (`lib/doctor.sh`).
3. **Docs.** `docs/versioning.md` gets a breaking-change note for 3.0.0. Date the CHANGELOG `## [3.0.0] - unreleased` section, which has grown with each phase. Update the README Status header. Re-count the README test count after adding tests.
4. **Version check.** `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json` and `FI_VERSION` in `bin/found-issues` are already `3.0.0` on `release/v3` (since phase 1, 54a4214). `docs/versioning.md` requires five places in lockstep: `FI_VERSION`, the CHANGELOG section, both `plugin.json` files and the README Status header. `scripts/check-version.sh` enforces it; run it. The marketplace manifest (`AltDoug/claude-plugins/.claude-plugin/marketplace.json`) is the sixth place and is bumped only after the source release merges.
5. **Live E2E in a REAL auto-mode Claude Code session** (not stand-ins). Check (a) that the auto-mode classifier lets `found-issues autofix ship <id>` through (spec §4.1 and §12; it may treat the self-merge as "merging a pull request no human has approved") and (b) whether writes under `.claude/worktrees` prompt. If either blocks, record the finding and the ruling in the plan and PR.
6. **Review and merge.** Read-only opus whole-branch review (Agent with `model: opus`, never the forked `/code-review`), fix pass with RED to GREEN tests, full suite and the bash 3.2 subset run one after the other, PR into `release/v3`, merge, watch the post-merge push run to a terminal state (macOS bats only runs there).
7. **Release.** One PR `release/v3` → `main` for 3.0.0 (date the CHANGELOG, run `scripts/check-version.sh`). `.github/workflows/release.yml` auto-cuts the tag and GitHub release when `.claude-plugin/plugin.json`'s version changes on `main`. Watch its runs to a terminal state; AltDoug repos auto-merge per github.md, never past a red check. Check `git rev-list --count origin/release/v3..origin/main` first (it was 0 at handoff) and merge `main` into `release/v3` if `main` moved. Then open the marketplace bump PR in `AltDoug/claude-plugins`.
8. **Enable auto-fix on this Mac** (operator request 2026-10-03, memory "Enable auto-fix after v3"), only after 3.0.0 is released AND the plugins are updated on this Mac: `git config --global found-issues.autofix true`, verify with `found-issues doctor`, give the disclosure that fix PRs always auto-merge, and ask once via an AskUserQuestion picker which client repos to exclude.
9. **Phase 6** (spec §11, after 3.0.0 is on `main`; not part of this handoff's work): whole-plugin audit and ledger burn-down, driven by `/goal`.

## Known live hazards (verify each before relying on it)

1. The operator is asleep or away: work autonomously. Subagents must never trigger permission prompts. Reviews are read-only opus Agents; never use the forked `/code-review`.
2. **pr-verify-gate:** probe `gh pr create --dry-run` in its own call. It asks for verify and review skill telemetry. Write the skip reason into the printed `.pr-verify-skipped` path after the final commit.
3. **Merging into `release/v3`:** `GH_PR_MERGE_BASE_GUARD=off gh pr merge <N> --auto --squash` merges at once (no required checks). macOS bats runs only on the post-merge push run, so watch it to a terminal state. The release PR into `main` is the real release: AltDoug repos auto-merge per github.md, never past a red check.
4. **Never run the full suite and the bash 3.2 subset in parallel.** The TERM test in `tests/autofix-run.bats:179` uses a machine-wide `pgrep` and collides. Run them one after the other, or accept the failure and re-run that file alone.
5. **bash 3.2:** a mid-test `[[ ]]` and a bare `!` assert nothing, so use `|| false`. `${VAR:-{\"a\"\}}` keeps a stray backslash, so use a variable default.
6. **README test count** is pinned by `tests/docs-consistency.bats`: recount with `cat tests/*.bats | rg -c '^@test'` after adding tests.
7. **`found-issues log` line numbers:** re-derive them with `rg -n` after any edit.
8. Never write `docs/found-issues.md` by hand (use `./bin/found-issues log|resolve|annotate-pr`). The main checkout is peer-used. The other worktrees (`v3-docs`, `v3-phase3`, `v3-phase4`) are not yours.
9. **Shell:** zsh does not word-split `$files`, so pass test files literally. A bats glob that matches nothing aborts the whole run. `bats -f` goes before the file and must not contain spaces. Use ASCII-only `@test` names.
10. **Stand-ins:** `tests/standins/claude` exports `FI_STANDIN_PROMPT` for `FI_STANDIN_EDIT`, answers prompts containing "found-issues classifier" with `FI_STANDIN_CLASSIFY`, and costs $0.25 per call (sweep budget tests depend on that).
11. **`main` vs `release/v3`:** `main` was 0 commits ahead of `release/v3` at handoff. The spec says to merge `main` into `release/v3` whenever `main` moves.
12. **Terminal text:** Phase 5 touches the statusline and SessionStart output. Everything that renders in a terminal is text, so no screenshot pass applies, but the setup disclosure must state plainly that fix PRs auto-merge.

## State snapshot (re-verify)

- `origin/release/v3` = ca747ec (PR #189 squash-merge); PR #189 state MERGED.
- This worktree: `~/Documents/projects/found-issues/.claude/worktrees/v3-phase5`, branch `v3/phase5-release`, cut from ca747ec; this handoff is its first commit (pushed by the orchestrator).
- `origin/main` is 0 commits ahead of `release/v3` at handoff.
- Latest tag: v2.10.4. Plugin manifests and `FI_VERSION` already say 3.0.0 on `release/v3`; CHANGELOG still says `## [3.0.0] - unreleased`.
- README test count 1145.
- gh: AltDoug is the active account.

## Resume prompt

> Working directory ~/Documents/projects/found-issues/.claude/worktrees/v3-phase5 (branch v3/phase5-release; `git fetch`, confirm the tree is clean and `gh auth status` shows AltDoug active). Read docs/handoffs/autofix-v3-phase5-plan-handoff-2026-10-04.md end to end and re-verify its claims first (`git log --oneline -3 origin/release/v3`, `gh pr view 189 --json state,mergeCommit`, `gh run view 37184138843 --json conclusion`). Then write the Phase 5 plan with superpowers:writing-plans from spec §11 item 5 and the final release step, and execute it with superpowers:executing-plans: statusline, status, SessionStart summary, setup disclosure, doctor, docs/versioning.md breaking-change note, date the 3.0.0 CHANGELOG section, live E2E in a real auto-mode session, a read-only opus whole-branch review, PR into release/v3, merge, watch the post-merge run, then the release/v3 → main release PR, watch its runs, then the marketplace bump in AltDoug/claude-plugins. The operator may be asleep: do everything possible without him, list every ruling made on his behalf in the PRs and the final report, and never trigger permission prompts from subagents. After 3.0.0 is released and the plugins are updated on this Mac, enable auto-fix (`git config --global found-issues.autofix true`), verify with `found-issues doctor`, disclose that fix PRs always auto-merge, and ask once via picker which client repos to exclude.
