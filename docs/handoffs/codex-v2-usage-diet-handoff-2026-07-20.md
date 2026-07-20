# found-issues v2.0.0 (Codex + Usage Diet) — Session Handoff

**Date:** 2026-07-20 · **Session:** "codex-compat + usage-diet build-out"
**Status:** All build + review work is DONE on `feat/codex-compat-usage-diet` (pushed, 659/659 bats). Shipping tail (2 small ledger fixes → PR → CI → merge → marketplace PR) is NOT started.
**Re-verification rule (operator's standing feedback):** do NOT act on this
doc's claims without re-verifying against the repo / live state first.
Ground truth: `git -C ~/Documents/projects/found-issues log --oneline origin/main..HEAD`, `bats tests/` (expect 659 ok), `.superpowers/sdd/progress.md` (per-task ledger), `bin/found-issues list`.

## TL;DR for the next session

1. Read this doc, then `.superpowers/sdd/progress.md` (full task-by-task record) and the spec `docs/superpowers/specs/2026-07-19-codex-compat-usage-diet-design.md`.
2. Nothing is merged. Branch `feat/codex-compat-usage-diet` (HEAD `22ed39e`) holds ~40 commits: v1.7.1 → v2.0.0.
3. Next: fix the last 2 unannotated ledger entries, sync-flip the versioning entry, `gh pr create`, auto-merge + full CI matrix, post-merge sync (zero open), marketplace PR.
4. #1 hazard: **do not squash-merge blindly without checking the ledger flip path** — most `[open]` entries carry `(commit: <sha>)` annotations from branch commits; squash-merge rewrites SHAs, but every fixed entry ALSO relies on `sync`'s PR-annotation path… actually only 4 entries have `(commit:)` only, no `(PR:)`. The PR-create dispatcher hook should add `(PR: AltDoug/found-issues#N)` annotations at PR time — VERIFY it does (dogfood moment); any entry left with only a `(commit:)` ref will demote to `commit-stale` under squash-merge.

## What was done (verify via commits)

All on `feat/codex-compat-usage-diet`, executed as subagent-driven tasks 1–12 with per-task review (details + review verdicts in `.superpowers/sdd/progress.md`):

- **Usage diet:** single PostToolUse dispatcher `hooks/post-bash-dispatch.sh` replaces 3 per-Bash hooks; hook-side auto-annotation `--hook-auto` (line-matched via `fi_diff_old_ranges` removal-run parsing, mass-touch cap 3, exit 3 = candidates for model judgment); rules skill compressed 8.6KB→3.7KB (`28e122b`); session-start injection cap (criticals always, `FOUND_ISSUES_SESSION_INJECT_MAX`=15) (`c4058ca`).
- **Codex support:** `.codex-plugin/plugin.json` (`9a65429`); generated `codex-skills/` + drift test (`444100a`); session-start Codex rules injection + Claude-only guards (`df09dc6`); stop-reminder fail-open on Codex (`da6755a`); **`found-issues install-codex-hooks`/`uninstall-codex-hooks`** — user-level `$CODEX_HOME/hooks.json` merge, needed because **Codex 0.144.5 removed plugin-bundled hooks** (`08eacba`, hardened `e33f6b4`); JSON envelope shapes in `lib/harness.sh` (`4c8b711`, PostToolUse + SessionStart `hookSpecificOutput`).
- **Docs/release:** AGENTS.md/README dual-harness rewrite, CHANGELOG 2.0.0 + BREAKING, version 2.0.0 in `bin/found-issues` + both manifests, `check-version.sh` five-place lockstep (`57a33ef`, `45e9998`).
- **Adversarial review (71 agents):** 13 confirmed findings incl. 1 CRITICAL (hunk parser matched diff *context* lines → false-`[fixed]` path) — all fixed (`0d78334`, `a85c13b`, `45e9998`), fix verified airtight by independent 16-probe re-review.
- **E2E:** Claude-side hook flow verified against a real scratch repo; Codex-side skills install + marketplace syntax verified live; evidence in `.superpowers/sdd/task-11-report.md` (feeds the PR description). NOT verified live (Codex hook-trust wall): SessionStart envelope acceptance + hook env vars — 2-min manual repros in that report §8.
- Deliberately NOT done: Codex statusline (no surface), Stop-marker on Codex (deferred ledger entry), Codex `agents/openai.yaml` polish.

## Remaining work

1. **Fix + annotate the 2 unannotated `[open]` entries** (small): `bin/found-issues:3733` doctor `grep -c` "0\n0" arithmetic noise; `tests/session-start.bats` six vacuous `!` negations (pre-existing on main). TDD, then `bin/found-issues annotate-commit HEAD --pick <loc>` each.
2. **Sync-flip the `docs/versioning.md:10,85` entry** under sync authority: its fix is verified in `0c0514c` but the entry's comma line-spec makes it unreachable by annotate tooling (that bug itself fixed in `769cc01`). Flip to `[fixed] (verified: ai) (fixed: <date>)` during `/found-issues:sync` after re-verifying `docs/versioning.md` no longer references "Status & roadmap".
3. **`gh pr create`** — title `feat: dual-harness Codex support + usage diet (v2.0.0)`; body from `.superpowers/sdd/task-11-report.md` evidence + spec link + known Codex v1 limitations; standard footer. The dispatcher hook fires on PR create (dogfood): verify its auto-annotation output; run any printed `--pick` yourself.
4. **Arm auto-merge, then `/loop`** the CI watch (full matrix incl. Windows bats 7–15 min — never declare green on Linux/Mac alone).
5. **Post-merge:** `bin/found-issues sync` on main → all annotated entries flip → confirm **zero `[open]`**; cut of the GitHub release is automated on version-bump merge (ci/auto-release workflow, #113).
6. **Marketplace PR** in `~/Documents/projects/…/claude-plugins` checkout (or clone `AltDoug/claude-plugins`): bump found-issues to 2.0.0 in `.claude-plugin/marketplace.json` AND add Codex-native `.agents/plugins/marketplace.json` (working local schema recorded in `.superpowers/sdd/task-11-report.md` §3 — hosted equivalent uses `source: git-subdir`-style; consult `codex plugin marketplace --help`). Source PR merges FIRST.

## Known live hazards (verify each before relying on it)

1. **Codex 0.144.5 `plugin_hooks` = removed** — the manifest `hooks` pointer is inert; user-level installer is the only hook path. Re-check `codex features list` — if `plugin_hooks` returned, docs/design may need a follow-up.
2. **Squash-merge vs `(commit:)` annotations** (see TL;DR #4): confirm the PR-create hook adds `(PR: …#N)` refs; if not, run `bin/found-issues annotate-pr <N> --pick …` for the commit-only-annotated entries before merge.
3. **The operator's `loc-validator` hook** blocks commits/PRs when generated `codex-skills/*.md` exceed length targets — the generator now emits a `loc-override` marker line (commit `008b891`); if the hook still trips, the marker text must contain `loc-override:` + ≥10-char reason.
4. **found-issues Stop hook** blocks turns missing the `<!-- found-issues-checked: … -->` marker — include it in every substantive turn.
5. **Windows bats teardown flake**: bounded-retry already in helpers; if CI shows "Device or resource busy", it's the known flake — re-run the job, don't chase it.
6. **`bats tests/` locally takes ~10 min** (659 tests); the count guard test fails honestly if tests are added without updating README's stat strip — follow its printed fix message.

## State snapshot (re-verify)

- Branch `feat/codex-compat-usage-diet` @ `22ed39e`, pushed, working tree clean, no PR open yet.
- `bats tests/`: 659/659 (last full run in the airtight re-review). `scripts/check-version.sh`: OK, MAJOR 1.7.1→2.0.0.
- Ledger: 13 `[open]` (9 annotated → flip on merge; 1 unparseable-versioning → sync-flip; 2 unannotated → step 1; 1 critical `.codex-plugin` entry annotated `08eacba`), 1 `[deferred]` (Codex stop-marker, intentional).
- `.superpowers/sdd/` holds all briefs/reports/review packages (gitignored scratch — survives locally only).

## Resume prompt (also placed on clipboard)

> Read docs/handoffs/codex-v2-usage-diet-handoff-2026-07-20.md end to end, then re-verify its claims per the re-verification rule (git log origin/main..HEAD, bats tests/ expecting 659 ok, bin/found-issues list). Working dir: ~/Documents/projects/found-issues, branch feat/codex-compat-usage-diet. Then continue the v2.0.0 ship tail in order: (1) fix + annotate the two small open ledger entries (doctor grep -c noise at bin/found-issues:3733; vacuous negations in tests/session-start.bats), (2) sync-flip the docs/versioning.md entry after re-verifying its fix, (3) gh pr create for v2.0.0 (verify the dispatcher's dogfood annotation output, add (PR:) refs to commit-only-annotated entries if the hook doesn't), (4) arm auto-merge and /loop the full CI matrix including Windows bats, (5) after merge: sync to zero open entries, then the marketplace PR in AltDoug/claude-plugins (claude marketplace bump to 2.0.0 + Codex-native .agents/plugins/marketplace.json), source repo first. Stop and report if CI fails or the ledger flip path misbehaves; or stop after 40 turns.
