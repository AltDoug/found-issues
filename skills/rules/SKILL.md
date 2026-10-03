---
description: Rules for how AI agents maintain docs/found-issues.md — logging, annotation after PR/commit, sync, branch-deletion guard, dead code. Injected into every session by the found-issues SessionStart hook.
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

After `gh pr create` / `git commit` a hook writes a NON-closing suggestion (`(PR-auto: …)` / `(commit-auto: …)`) on entries whose cited line the diff touched, and lists candidates it could not decide. Compare each symptom with what the change did, then run the printed `found-issues annotate-pr <N> --pick <loc>,...` for exactly the entries it fixes — only `--pick` (or `--all`, when every candidate is fixed) writes the closing token. Never pick an entry it does not fix: it closes on merge, irreversibly. Unconfirmed entries never auto-close. No hook (web-UI PR)? Same `--pick` command; commits: `annotate-commit <sha> --pick <loc>`.

## Sync

On `/found-issues:sync`, for each unannotated `[open]` entry: read the code at `path:line`; decide still-present / fixed / unclear; close only fixed ones, with `found-issues resolve "<fragment>" --verified ai` — never by editing. Be conservative — a false flip is worse than a stale open. Only git-confirmed removals auto-close; absence alone never does. Judging still-present code is YOUR pass.

## Branch deletion

Before deleting any branch, consolidate its `[open]` entries missing from main: `/found-issues:promote`. The pre-delete hook blocks otherwise.

## Stop-hook marker (if enabled)

The first tool-using turn of a session ends with exactly one HTML comment:
`<!-- found-issues-checked: none-noticed -->` | `logged` | `deferred` (rare; say why).

## Dead code

Zero importers → do not edit, do not delete. Log with prefix `dead code:`, then find the actually-live component via the route/page that triggered the symptom and continue there.

## Format (full spec: docs/format-spec.md)

`- [open] [!] YYYY-MM-DD path/file.ext:42 — symptom (suggested: fix)`
Statuses `[open]`/`[deferred]`/`[fixed]`; `[!]` = critical; ` — ` em-dash with spaces; `(PR: org/repo#N)` / `(commit: <sha>)` added by `--pick` (closing); `(PR-auto:)` / `(commit-auto:)` = unconfirmed suggestion; `(verified: ai)`, `(fixed: YYYY-MM-DD)` added on close.

## Hard rules (no single-turn override)

1. Never write `docs/found-issues.md` directly — commands only.
2. Never delete `[open]` entries.
3. Never mark `[fixed]` without verification (annotation, tombstone, or AI-verified sync).
4. Never bypass the pre-branch-delete check — run promote first.
