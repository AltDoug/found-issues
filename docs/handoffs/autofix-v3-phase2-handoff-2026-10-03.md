# found-issues v3.0.0 auto-fix — Session Handoff

**Date:** 2026-10-03 · **Session:** "audit batches 1-5 + Codex wiring + v3 design and phase 1"
**Status:** 2026-10-03 audit batches 1-5 shipped to main (v2.9.2 to v2.10.4, latest tag v2.10.4); v3.0.0 spec approved and Phase 1 (fix tags + decision queue) merged into `release/v3`; Phase 2 (queue/claim/lock/caps/launchers) not started.
**Re-verification rule (operator's standing feedback):** do NOT act on this doc's claims without re-verifying against the repo / live state first. Ground truth: `git -C ~/Documents/projects/found-issues fetch && git log --oneline -5 origin/main origin/release/v3`, `gh pr list -R AltDoug/found-issues --state all -L 12`, and the spec `docs/superpowers/specs/2026-10-03-autofix-v3-design.md` on `release/v3`.

## TL;DR for the next session

- Main is at the v2.10.4 audit-fix line; nothing of ours is open on GitHub. `release/v3` is the integration branch for v3.0.0 (phase PRs target it; ONE final PR `release/v3` -> `main` ships 3.0.0; `release.yml` only fires on main).
- Next job: write the **Phase 2 plan** (superpowers:writing-plans) from spec §4-§5, §7, §9, §11 against Phase 1's shipped interfaces, get the operator's review + execution-method pick, execute with TDD, PR into `release/v3`, watch to terminal.
- Phase 2 scope: work queue, claim, lock (`mkdir`, 60-min stale), caps, release, ship, merge-when-green, launcher A for the Claude and Codex engines, allowlist-syntax pinning, cost measurement, stand-in `claude`/`codex` binaries for zero-cost CI.
- **Operator request (2026-10-03): once v3 is live on this Mac, ENABLE the v3 auto-fix features here** ("once v3 is active on here please enable those settings, I want them on"). This is the last step of Phase 5 (see Remaining work). Memory file: `enable-autofix-after-v3.md`.
- Operator-only steps still outstanding: run `/hooks` once in interactive Codex (trust the found-issues hooks); run `/plugin update found-issues` in Claude Code (this Mac's Claude plugin cache holds 2.8.0/2.9.0/2.9.1 only — `doctor` shows it).

## What was done (verify via PR descriptions / commits)

Shipped to main (each: TDD, full bats, `verify` skill, auto-merge, PR checks plus the post-merge macOS `tests` run watched to success, release auto-cut by `release.yml`):

- #178 v2.9.2 audit batch 1: data-loss and false-close fixes.
- #179 v2.9.3 batch 2: guard bypasses (branch-delete, format guard), Codex lib lookup.
- #180 v2.10.0 Codex wiring: Stop nudge from `last_assistant_message`, `apply_patch` enforcement, `doctor` Codex section, daily Claude SessionStart notice.
- #181 v2.10.1 batch 3: rules reach Claude, prompt accuracy, Codex YAML.
- #182 v2.10.2 batch 4: resource/process counts (builtin parser and keys, gh memo, hook gates).
- #183 v2.10.3: stable Codex hook shims under `$CODEX_HOME/found-issues/hooks/` (hook trust survives plugin updates).
- #184 v2.10.4 batch 5 CLI hygiene: unknown flags refused, log newline/escalation, dedup keys via parser, subdir ledger, default-branch fallback main/master/trunk, promote dedup vs main+archive, deferred touch exact refind, statusline uninstall (literal strip / unbalanced-marker refusal / backup / symlink write-through), last-LINE1 splice. Deviation: spaced paths kept supported (3 sync tests pin them) instead of refused.
- #185 docs: logged 34 leftover 2026-10-03 audit lows to `docs/found-issues.md` (tagged `[2026-10-03 audit <id>, <sev>]`); sync closed 5 merged-PR entries (#157, #177, #179, #180, #184). Not logged (fixed by batches): cli-14/15/16, hook-15, ledger-4; prompt-8..11 are folded into v3 phase 4.
- Marketplace: AltDoug/claude-plugins #40 merged -> found-issues 2.10.4 (that repo has no CI and no auto-merge: merge with `gh pr merge --squash`).
- Mac Codex: plugin updated to 2.10.4, `install-codex-hooks` re-run; all 5 `hooks.json` entries point at the shims; hooks are still UNTRUSTED until the operator runs `/hooks` once in interactive Codex. Memory file `codex-wiring-state-mac.md` updated.

v3.0.0 (opt-in auto-fix / auto-sweep):

- **Spec approved:** `docs/superpowers/specs/2026-10-03-autofix-v3-design.md` (commit 6f1f8a2; phase 6 added in 7e0bc3e). Key operator decisions:
  - 4-question classification (decision needed? fixable now? provable by tests? size) -> one tag: `fix: small|medium|large` | `decide:` | `manual:` | `deferred` + `until:`. Severity = priority, not a gate.
  - Decision queue. Small = spot fix in its own worktree + own PR. Medium counts toward a sweep at 5 fixable-now (a critical medium triggers immediately).
  - Fix PRs ALWAYS auto-merge (setup must disclose it).
  - HYBRID launchers: a Claude session in auto/bypass mode -> in-session plugin subagent; Claude default/acceptEdits/plan and ALL Codex -> detached headless `claude -p --permission-mode dontAsk --permission-prompts none --allowedTools ...` / `codex exec --sandbox workspace-write`. The bash CLI does all git/push/PR/annotate/merge.
  - An opus read-only verifier gates every diff.
  - Caps: 5 spot fixes + 1 sweep (max 8) per repo per day, $2 per background run.
  - Settings live in git config `found-issues.autofix` (global + per-repo override). GitHub PR mode only for v3.0.0.
- **Spike findings (spec §4.5):** `claude -p --bare` fails under OAuth ("Not logged in"), so headless children load the user's CLAUDE.md/hooks (the operator's git-boundaries rule refused a commit on main in the spike, so fixers must run on `fi/autofix/*` branches); off-allowlist Bash is denied with no prompt (`permission_denials`); one haiku turn is about $0.09; allowlist pattern `Bash(cat:*)` seemed not to apply, so pin syntax by test in phase 2; `codex exec` edited without prompting in 69s.
- **Phase 1** plan `docs/superpowers/plans/2026-10-03-autofix-v3-phase1-tags.md` (commit 064a28e) executed natively; PR #186 merged into `release/v3` (squash 54a4214); PR checks plus the post-merge `release/v3` tests run, including bats (macos-latest), all success. Adds:
  - parser tags + `list --json` fields (`fix_tag`, `decide`, `decided`, `manual`, `until`, `autofix_failed`);
  - `lib/autofix-tags.sh` (`fi_offlimits_category/check`, `fi_tag_text`, `fi_tag_resolve`, `fi_entry_retag`, `fi_until_due`); `lib/tag.sh` (`fi_tag_apply`, `cmd_tag`); `lib/decide.sh`; `commands/decide.md` + `codex-skills/fi-decide`;
  - `log --fix|--decide|--manual` (incl. `--fix=`, refuses flags after the entry, tags on escalation/deferred match); `defer --until pr:|date:|text`; sync wakes due deferred entries ("Woke: N");
  - SessionStart "N decisions waiting"; the gate runs sync for until-triggers; rules budget 3700 -> 4200 bytes (rules now 4101); version 3.0.0 (unreleased) with CHANGELOG `## [3.0.0] - unreleased`; CI on `release/v3`. 939 bats pass.
  - Final opus review: 2 Important fixed; 7 Minors logged (tagged) in `release/v3` `docs/found-issues.md`: M3 pre-sync decision count, M4 decide matching all open entries, M5 legacy "(fix: free text)" now parsed as tag [decide], M6 "PR #N" in tag text vs pre-commit hook, M7 case-sensitive off-limits [decide], M8 gate syncs for free-text until, M9 lexical date compare.
- **Phase 6 added to spec §11** (operator request): after the 3.0.0 release, a whole-plugin audit (same method as `docs/audits/2026-10-03-audit`), log every finding tagged, then burn found-issues' own ledger to zero (or every remaining open is decide/manual-with-reason), driven by a user-typed `/goal` (draft via prompt-handoff at phase 6 start, with a turn cap); fixes ship as 3.0.x/3.1.0 with marketplace bumps.

## Remaining work

In order:

1. **Phase 2 plan** (superpowers:writing-plans, against Phase 1's shipped interfaces): queue / claim / lock (`mkdir`, 60-min stale) / caps / release / ship / merge-when-green + launcher A for Claude and Codex engines, allowlist-syntax pinning, cost measurement, stand-in `claude`/`codex` binaries for zero-cost CI.
2. **Execute.** The operator chose Native execution plus one fresh opus read-only whole-branch review for phase 1; ask again per phase (picker, recommendation first).
3. **PR into `release/v3`.** `GH_PR_MERGE_BASE_GUARD=off` is needed for `gh pr merge --auto --squash` because base is not main (intentional integration branch). Watch the PR checks, then the post-merge `release/v3` run to terminal.
4. **Phases 3, 4, 5.** Phase 4 folds in prompt-8..11. Phase 5 includes:
   - live E2E on a private throwaway GitHub repo;
   - the setup disclosure (fix PRs always auto-merge);
   - the 3.0.0 release PR `release/v3` -> `main`;
   - the claude-plugins marketplace bump (merge with `gh pr merge --squash`);
   - the operator updates the Claude Code and Codex plugins on this Mac;
   - **then ENABLE the v3 features on the operator's machine** (operator request 2026-10-03, memory file `enable-autofix-after-v3.md`). Steps:
     1. `git config --global found-issues.autofix true` (spec §8; auto-merge of fix PRs is always on by design). Keep the default caps.
     2. Verify with `found-issues doctor`, auto-fix section (run the freshly updated 3.0.0 CLI, not a stale one).
     3. Give him the setup disclosure.
     4. Ask once (picker) whether any client repos should be excluded; exclude with `git config found-issues.autofix false` in those repos.
5. **Phase 6** whole-plugin audit + ledger burn-down (see above).
6. Optional quick fixes: the 7 phase-1 minors (two are `(decide:)` entries for the operator via `found-issues decide`).

## Known live hazards (verify each before relying on it)

1. **Subagents must never trigger operator permission prompts.** Finders/verifiers are read-only; do code review inline or via a read-only opus Agent, never the forked `/code-review` skill.
2. **pr-verify-gate** blocks `gh pr create` (and the WHOLE bash command it sits in, so a combined commit+push+create silently skips the commit) on >200 code lines without a review skill. Probe with `gh pr create --dry-run ...` in its own call, then write the reason into the printed `.pr-verify-skipped` path in a separate call (the path hash changes per commit).
3. **gh-pr-merge-base-guard** blocks merges into `release/v3`; use `GH_PR_MERGE_BASE_GUARD=off` for that one command (intentional).
4. **CI:** PR runs are ubuntu-only; macOS bats (bash 3.2) runs only on the post-merge push run (main or `release/v3`), so watch it to terminal. Local bash 3.2: `PATH=/private/tmp/claude-501/b32:$PATH bash "$(command -v bats)" <files>` (recreate with `mkdir -p /private/tmp/claude-501/b32 && ln -sf /bin/bash /private/tmp/claude-501/b32/bash`). bats `-f` must come BEFORE the file and must not contain spaces.
5. **README test count** is pinned by `tests/docs-consistency.bats`; after adding tests run `n=$(rg -c '^@test ' tests/*.bats | awk -F: '{s+=$2} END{print s}'); sed -i '' -E "s/ [0-9]+ tests on/ $n tests on/" README.md`. Rules `SKILL.md` budget is 4200 bytes (4101 used).
6. **`log` refuses** symptoms ending in annotation-shaped groups, now including `(fix:` / `(decide:` / `(manual:` / `(until: text`; reword.
7. **The shared main checkout** `~/Documents/projects/found-issues` is dirty and peer-used (currently on `feat/codex-description-key`, with a modified ledger and untracked `.agents/` + handoff/audit docs): never `git add -A` there, never checkout its ledger. Worktree `audit-2026-10-03` has unrelated peer ledger/archive diffs (left alone). Stale worktrees (audit-b1..b5, codex-shims, audit-lows, etc.) are reaper-safe once merged.
8. **Running sessions use their old plugin CLI**; verify with the worktree's `./bin/found-issues`.
9. **Spec facts the in-session launcher (B) relies on are dated 2026-10-03 docs:** plugin agents ignore `permissionMode`; a subagent inherits auto/acceptEdits/bypass; background subagents surface prompts in default mode; auto mode allows push+PR in the working repo but 3 consecutive classifier blocks resume prompting; hooks receive `permission_mode` on PostToolUse/Stop/UserPromptSubmit (not SessionStart). Re-check against current docs before building on them.
10. **agent-config** has uncommitted ledger changes from the Codex investigation: `docs/found-issues.md` lines 91-92 (duplicate gsd agent roles in `~/.codex/agents`; "Exceeded skills context budget" in `~/.codex/skills`) plus other peer ledger/archive diffs and 3 untracked `docs/research/*.html` files. Verify with `git -C ~/Documents/projects/agent-config status`.

## State snapshot (re-verify)

Verified 2026-10-03 (read-only commands; the GitHub clock showed the v2.10.4 release at 2026-10-04T00:05Z):

- `origin/main` = b6018b9 (#185). `origin/release/v3` = 7e0bc3e (spec phase 6 on top of #186 squash 54a4214).
- Latest release/tag: v2.10.4 (v2.10.3, v2.10.2 before it). Marketplace: AltDoug/claude-plugins #40 merged.
- Open PRs of ours: none (last 12 in AltDoug/found-issues are all MERGED, #175 to #186).
- gh account: AltDoug active (dsilvaSOS also logged in).
- Dirty files per repo:
  - found-issues worktree `v3`: branch `v3/phase1-tags` at 11a8ccf (merged), clean.
  - found-issues worktree `v3-docs`: branch `release/v3` at 7e0bc3e, clean apart from this handoff doc until committed.
  - found-issues worktree `audit-2026-10-03`: branch `fix/audit-2026-10-03`, modified `docs/found-issues.md` and `docs/found-issues-archive.md` (peer diffs, untouched).
  - found-issues main checkout: branch `feat/codex-description-key` at 045c42b, modified `docs/found-issues.md`, untracked `.agents/`, `docs/audits/prompt-audit-2026-08-12.md`, two `docs/handoffs/` docs.
  - claude-plugins: `main`, clean.
  - agent-config: `main`, modified `docs/found-issues.md` + `docs/found-issues-archive.md`, 3 untracked `docs/research/*.html`.

## Resume prompt

Working directory: ~/Documents/projects/found-issues/.claude/worktrees/v3-docs (branch release/v3; run `git pull` first — the `v3` worktree cannot check out release/v3 while this one holds it, so do the Phase 2 work here or on a new `v3/phase2-*` branch cut from it). Read docs/handoffs/autofix-v3-phase2-handoff-2026-10-03.md end to end. Re-verify its claims against live state first (git fetch; gh pr list; the v3 spec). Confirm gh account AltDoug with `gh auth status`. Then use superpowers:writing-plans to write the Phase 2 plan (spec §4-§5, §7, §9, §11 phase 2) against Phase 1's shipped interfaces, ask the operator to review it and pick an execution method (picker, recommendation first), execute with TDD, PR into release/v3, watch to terminal. Never trigger permission prompts from subagents; review inline or with a read-only opus agent. Remember the end-of-phase-5 task: once 3.0.0 is released and the plugins are updated on this Mac, enable auto-fix here (`git config --global found-issues.autofix true`, verify with `found-issues doctor`, give the disclosure, ask once which client repos to exclude).
