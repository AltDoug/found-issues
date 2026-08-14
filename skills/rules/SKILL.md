---
description: Rules for how AI agents maintain docs/found-issues.md — logging, annotation after PR/commit, sync, branch-deletion guard, dead code. Auto-loaded every session by the found-issues plugin.
disable-model-invocation: true
---

# found-issues — agent rules

<!-- loc-override: single auto-loaded ruleset; splitting changes per-session injection -->

**Issues found and not tracked are issues lost.** When you notice a defect outside your current task scope, log it — never dismiss it as "pre-existing" or "not my code." The user logs nothing; you maintain `docs/found-issues.md` on their behalf — via the commands below, never direct Write/Edit.

## Logging

`/found-issues:log <path:line> — <symptom> (suggested: <fix>)` — `--critical` for urgent items; an abstract topic may replace `path:line`.

- **Log:** demonstrable bugs; off-task errors/warnings in test/build/log output; nameable race conditions; security defects; dead code (zero call sites); misleading docs; broken contracts.
- **Don't log:** style nits; "could be cleaner"; known deprecations; existing TODOs; things you fixed in-task; third-party bugs; speculation without a concrete symptom; unmeasured perf hypotheticals; duplicates (the command dedups on path:line).
- When in doubt, log — false positives get cleaned at sync; false negatives are silent.

## Annotation after PR / commit

A hook auto-runs annotation after `gh pr create` and `git commit`: entries whose cited line the diff modifies are annotated automatically and reported in one line. Your job is ONLY the judgment cases the hook surfaces — a candidate list means the CLI could not decide. Compare each candidate's symptom against what the PR/commit actually changes, then run the printed `found-issues annotate-pr <N> --pick <loc>,...` (`--all` only when it genuinely addresses every candidate). Never annotate entries the PR does not fix — they false-flip to `[fixed]` on merge. Do not defer; unannotated entries can never auto-close. Hook didn't fire (web-UI PR)? Run `/found-issues:annotate-pr <N>` manually. The same flow covers `git commit`; manual fallback `/found-issues:annotate-commit [sha]` (default HEAD).

## Sync

On `/found-issues:sync`, for each unannotated `[open]` entry: read the code at `path:line`; decide still-present / fixed / unclear; flip only fixed → `[fixed] (verified: ai) (fixed: <today>)`. Be conservative — a false flip is worse than a stale open. Only git-confirmed removals auto-close; absence alone never does. Judging still-present code is YOUR pass.

## Branch deletion

Before deleting any branch, consolidate its `[open]` entries missing from main: `/found-issues:promote`. The pre-delete hook blocks otherwise.

## Stop-hook marker (if enabled)

Every substantive turn includes exactly one HTML comment:
`<!-- found-issues-checked: none-noticed -->` | `logged` | `deferred` (rare; say why).

## Dead code

Zero importers → do not edit, do not delete. Log with prefix `dead code:`, then find the actually-live component via the route/page that triggered the symptom and continue there.

## Format (full spec: docs/format-spec.md)

`- [open] [!] YYYY-MM-DD path/file.ext:42 — symptom (suggested: fix)`
Statuses `[open]`/`[deferred]`/`[fixed]`; `[!]` = critical; ` — ` em-dash with spaces; `(PR: org/repo#N)` / `(commit: <sha>)` added by annotation; `(fixed: YYYY-MM-DD)` added by sync.

## Hard rules (no single-turn override)

1. Never write `docs/found-issues.md` directly — commands only.
2. Never delete `[open]` entries.
3. Never mark `[fixed]` without verification (annotation, tombstone, or AI-verified sync).
4. Never bypass the pre-branch-delete check — run promote first.
