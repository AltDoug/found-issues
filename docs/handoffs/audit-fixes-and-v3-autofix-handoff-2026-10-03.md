# found-issues audit fixes + v3.0.0 auto-fix feature — Session Handoff

**Date:** 2026-10-03 · **Session:** "v2.9.1 archive fix + full audit"
**Status:** v2.9.1 shipped; full audit verified (112 findings, 95 confirmed) and committed on `fix/audit-2026-10-03`; NEXT = fix batches 1–5, then task 3 (auto-fix feature → v3.0.0).
**Re-verification rule (operator's standing feedback):** do NOT act on this
doc's claims without re-verifying against the repo / live state first.
Ground truth: `git -C ~/Documents/projects/found-issues fetch && git log --oneline -3 origin/main`, `gh pr list --state all --limit 5`, and `docs/audits/2026-10-03-audit/{SUMMARY.md,runtime-evidence.md,all-verdicts.json}` on branch `fix/audit-2026-10-03`.

## TL;DR for the next session

1. Work in the existing worktree `~/Documents/projects/found-issues/.claude/worktrees/audit-2026-10-03` (branch `fix/audit-2026-10-03`, pushed, no PR yet). Cut each fix batch as its OWN branch off `origin/main` (new worktree per batch is fine), or rebase this branch — the audit artifacts can ship as a docs-only PR first.
2. Read `docs/audits/2026-10-03-audit/SUMMARY.md` (fix plan, 5 batches) and `runtime-evidence.md` (verbatim repro output). Per-finding verdicts + minimal fixes: `all-verdicts.json` (`jq '.[] | select(.id=="ledger-1")'`).
3. Order: batch 1 (data loss / false close) → 2 (guard bypasses) → 3 (rules reach Claude + prompt accuracy + Codex YAML) → 4 (resource) → 5 (CLI hygiene). Each: TDD, full `bats tests/` (serial, ~3 min), PR, `gh pr merge --auto --squash`, watch PR checks AND the post-merge `tests` push run (only place macOS bats / bash 3.2 runs) to a terminal state.
4. Then task 3: `superpowers:brainstorming` → opt-in auto-fix/auto-sweep feature, released as **v3.0.0** (operator decision 2026-10-03; memory `autofix-feature-ships-as-v3`).
5. #1 hazard: subagents must NOT raise permission prompts for the operator. This session's finders/verifiers were told "Read/Grep/Glob only, no writes" and did not prompt. A forked `/code-review` skill launch was stopped for this reason — do code review inline (read the diff yourself) instead of the forked skill.

## What was done (verify via PR descriptions / commits)

- **Task 1 — v2.9.1, PR #177 (merged, squash 3844477):** unattended syncs (SessionStart `hooks/session-start.sh`, segment autosync `lib/list-status.sh`, post-merge route `hooks/post-bash-dispatch.sh`) now run `FOUND_ISSUES_AUTO_ARCHIVE=off … sync`; explicit sync still archives. Env var (not a new flag) because SessionStart resolves the CLI via PATH and an older CLI rejects unknown flags (verified: a v2.2.9 CLI honors the env var). 3 new e2e tests. Post-merge run 37155267366: `run: success`, `bats (macos-latest): success`. Release v2.9.1 published 21:29Z. Ledger entry `lib/sync.sh:427` annotated `(PR: AltDoug/found-issues#177)` — still shows [open] on main until an explicit sync flips it.
- **Stray archive diffs discarded** (operator approved): `.claude/worktrees/bash-hook-perf` is clean. The main checkout `~/Documents/projects/found-issues` was restored EXCEPT one peer-logged entry (`- [open] 2026-08-23 bin/found-issues (annotate-pr) — … 100-file cap`) that existed nowhere else — it is re-inserted there as a 1-line uncommitted diff AND committed on `fix/audit-2026-10-03`. Evidence diffs: session scratchpad (ephemeral).
- **Task 2 — audit (commit 7cb8f23 on `fix/audit-2026-10-03`):** operator picked "Thorough + fix". 6 sonnet finders → 6 opus adversarial verifiers → orchestrator runtime repros in docker `hookfork:latest`. 112 findings: 95 CONFIRMED, 17 PLAUSIBLE, 0 REFUTED. Unique (non-dup): 8 high · 31 medium · 56 low. All highs confirmed at runtime.
- **NOT done:** any audit fix; logging the low-severity leftovers to the ledger; task 3; closing dougstation `docs/found-issues.md:137` (the archive bug from that repo's side) — 2.9.1 has shipped, so annotate/close it there.

## Remaining work

### Fix batches (details + exact minimal fixes in SUMMARY.md / all-verdicts.json)
1. **Data loss / false close (v2.9.2):** ledger-1 (= status-4, annot-6) lost-update race — `cmp -s` skip of no-op mv + cksum optimistic check before mv + same-dir tmp (fixes ledger-2/cli-23); ledger-3+15 archive delete-by-NR in awk (no grep binary mode); cli-4 reject annotation-shaped symptom tail in `log`; prompt-2 no-flag `annotate-pr/commit` writes the `-auto` suggestion form (only `--pick`/`--all` write canonical) + fix SessionStart text `hooks/session-start.sh:464-467`; annot-10 rerun cmd uses resolved sha not `HEAD`; ledger-12 `core.quotepath=off`; ledger-11 no commit-stale demotion in shallow clones; ledger-17 skip sync/archive on conflict markers; hook-8 `|| true` at `hooks/stop-reminder.sh:115`.
2. **Guard bypasses:** hook-2 (`git -C`), hook-3 (`-df`), hook-4 (quoted operand), hook-5 (sub-line Edit flip — reconstruct full lines), hook-14 (use `${BASH_SOURCE[0]%/*}/../lib` in pre-branch-delete + format-enforcer; currently dead on Codex), prompt-6 (drop agent-visible `FOUND_ISSUES_PROMOTE_GUARD=off` hint), hook-18 (say when jq is missing).
3. **Rules reach Claude:** prompt-17 — `skills/rules/SKILL.md` has `disable-model-invocation: true`, which per code.claude.com/docs/en/skills *prevents* loading; the rules have never reached Claude sessions. Emit the rules body from SessionStart for Claude too (lift the codex-only gate near `hooks/session-start.sh:58`, flip `tests/session-start.bats:405`), keep within the 3.7 KB budget, fix `docs/architecture.md`/`AGENTS.md`/`README.md`. Plus prompt-1/12/13/14/15/16/19 text fixes, and cli-19: quote the Codex `description:` YAML in `scripts/gen-codex-skills.sh:71` (PyYAML rejects fi-sync, fi-log, fi-fix, fi-annotate-pr, fi-annotate-commit) + add a strict-parse drift test.
4. **Resource:** ledger-5/6/7/8, hook-6/7/11/12/20, annot-1/2/13, cli-10/11/12, status-1/2/3/14/15. Re-measure with `docs/audits/2026-10-03-audit/repro-scripts/run.sh` / `run2.sh` before/after (baseline: sync ≈ 65 forks per open entry; SessionStart 517; Stop 22; Edit hook 7).
5. **CLI hygiene:** cli-5 (`uninstall --help` is destructive!), cli-6, the open `*) shift ;;` ledger entry (shared `fi_reject_unknown_flag`), cli-1/2/3/13(=ledger-10)/14/15/16, status-5/6/7/8/11/17, prompt-7 (= cli-8, promote dedup keys).
Leftover lows → log to `docs/found-issues.md` with `found-issues log` (worktree bin), don't fix.
After each PR: `/found-issues:annotate-pr <N>` with `--pick` for the ledger entries it fixes (the open `lib/archive.sh:36` catch-all entry is batch 5).

### Task 3 — opt-in auto-fix / auto-sweep (v3.0.0)
- Operator's words: "if toggled on, sessions will auto spawn a subagent to handle issues that are easy fixes when coming across them instead of logging easy things and leaving it for later, and spawn a bigger found-issues sweep once the issues total to a certain number".
- Run `superpowers:brainstorming` first; offer `grill-me` once. Open questions (pickers): what counts as "easy"; trigger surface (rules text vs hook vs CLI); default N; sweep in worktree + PR; Codex support.
- Depends on batch 1 + the `commands/fix.md` gaps the audit found: prompt-8 (no worktree / per-day branch collides / list vs annotate read different ledgers), prompt-9 (annotation never committed; closing sync archives), prompt-10 (allowed-tools only bats), prompt-11 (SessionStart directives fire in headless runs).
- Constraints: spawned agents must not prompt the operator (check how subagent permission modes behave before designing on them); any new hook keeps the zero-fork early-exit contract of `lib/hook-gate.sh`; workers `sonnet`, verifiers `opus`.
- Release: `FI_VERSION`, both `plugin.json`, CHANGELOG → `3.0.0`; `scripts/check-version.sh` accepts MAJOR and reminds to document breaking changes in `docs/versioning.md`.

## Known live hazards (verify each before relying on it)

1. **Explicit sync archives.** Running `found-issues sync` (no env var) in any checkout moves 20+ old `[fixed]` entries into the archive — fine in a deliberate PR, noise otherwise. Use `FOUND_ISSUES_AUTO_ARCHIVE=off found-issues sync` or `--dry-run` unless archiving is the point.
2. **Running sessions use their old plugin CLI** (this session's hooks were 2.8.0). Verify fixes with the worktree's `./bin/found-issues` / `FOUND_ISSUES_BIN=<worktree>/bin/found-issues`, never bare `found-issues`.
3. **CI shape:** PR runs are ubuntu-only; macOS bats (bash 3.2) runs only on the post-merge push. Watch that run to a terminal state every time. Local check: symlink `/bin/bash` first on PATH and run `bash "$(command -v bats)" <file>`.
4. **Full suite is fast now:** `bats tests/` serial took 2:58 (815 tests). `bats -j` silently runs 0 tests (no GNU parallel).
5. **`gh-pr-create-verify-gate` hook** blocks `gh pr create` until the `verify` skill ran this session (it did for #177). Drive the changed flow end-to-end (docker `hookfork` repros work well), then retry.
6. **Docker harness:** `hookfork:latest` (bash 5.2, strace, jq, git, gawk+mawk). Mount the worktree at `/src:ro`; hooks need `CLAUDE_PLUGIN_ROOT=/w` to mimic Claude Code (without it you are testing the Codex path — see hook-14). Clones made from the local checkout get a STALE `origin/main` (local `main` ref = v2.2.9) — fetch first if the ledger version matters.
7. **Main checkout is shared and dirty:** on stale branch `feat/codex-description-key`; holds the peer's 1-line ledger entry + untracked handoff/audit docs. Never `git add -A` / `git checkout` the ledger there.
8. **Open external PR #171** (jbelmana, hold critical closures) — not ours; leave it.

## State snapshot (re-verify)

- `origin/main` = 3844477 (#177, v2.9.1). Release v2.9.1 tagged.
- `fix/audit-2026-10-03` = 7cb8f23 (pushed): audit artifacts + peer ledger entry; plus this handoff doc (commit it if not yet).
- `fix/background-sync-no-archive` worktree `.claude/worktrees/v291-no-archive` — merged; safe for the reaper.
- Open ledger entries on main: `scripts/gen-codex-skills.sh:49` (annotated, PR merged — flips on next explicit sync), `lib/archive.sh:36`, `lib/sync.sh:147`, two `bin/found-issues` parser entries (2026-09-14), `lib/sync.sh:427` (annotated #177), `hooks/pre-branch-delete.sh:92`; + the 2026-08-23 annotate-pr entry on the audit branch.

## Resume prompt
> Read `~/Documents/projects/found-issues/.claude/worktrees/audit-2026-10-03/docs/handoffs/audit-fixes-and-v3-autofix-handoff-2026-10-03.md` end to end. Re-verify its claims against live state first (`git fetch`, `gh pr list`, `docs/audits/2026-10-03-audit/SUMMARY.md` and `runtime-evidence.md` on branch `fix/audit-2026-10-03`); do not act on it unverified. Working directory `~/Documents/projects/found-issues/.claude/worktrees/audit-2026-10-03`; the main checkout is shared and dirty — don't touch its ledger. GitHub account AltDoug; confirm with `gh auth status`. Then: ship the audit fix batches 1–5 from SUMMARY.md in order, each as its own PR off origin/main with TDD, full `bats tests/`, the `verify` skill, auto-merge, and a watch of both the PR checks and the post-merge main `tests` run (macOS bats) to a terminal state; log the leftover lows. After that, run `superpowers:brainstorming` for the opt-in auto-fix/auto-sweep feature and build it as v3.0.0. Any subagent you dispatch must not trigger permission prompts for the operator (read-only tool instructions for finders/verifiers; review diffs inline instead of the forked /code-review skill).
