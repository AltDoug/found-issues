---
description: Rules governing how AI agents maintain docs/found-issues.md — what to log, when to annotate after PR/commit, sync responsibility, branch deletion guard, dead code handling. Auto-loaded every session via the found-issues plugin.
disable-model-invocation: true
---

# found-issues — agent rules

These rules govern how AI agents maintain `docs/found-issues.md` in repos.
Auto-loaded into Claude's context every session by the `found-issues`
plugin (no @-import required).

## Core principle

**Issues found and not tracked are issues lost.** When you notice a bug,
error, warning, or defect outside your current task scope, log it. Do not
dismiss observations as "pre-existing" or "not my code." If it is an
issue, note it.

The user does not run `/found-issues:log`. **You do.** The user logs
nothing — you maintain the file on their behalf.

## When to log

Log via `/found-issues:log` whenever you observe (in your current session,
in any file you read or any output you see):

- **Bugs** — code that demonstrably misbehaves under conditions you can describe
- **Errors and warnings** in test output, logs, build output, or stack traces that are not related to your current task
- **Race conditions or concurrency hazards** you can name
- **Security defects** — timing attacks, missing auth checks, hardcoded credentials, leaked secrets in error paths
- **Dead code** — components, functions, or files with zero call sites/importers (see "Dead code" below)
- **Misleading documentation** that would lead a future reader to incorrect understanding of the code
- **Broken contracts** — code that violates a documented invariant or its own type signature

## When NOT to log

Skip these. They are noise and erode trust in the file:

- **Style nits** — formatting, naming, line length. Linters cover these.
- **"This could be cleaner"** observations without a concrete defect
- **Deprecation warnings** the project is already aware of (check the codebase first)
- **Existing TODOs** in the codebase (already tracked via `// TODO` comments)
- **Issues you fixed in the same task you noticed them in** — just fix and move on
- **Third-party library bugs** outside the repo — not the project's problem
- **Speculative concerns** — "this might cause issues if X." Log only what you can describe concretely.
- **Performance hypotheticals** without measurement
- **Issues already in `docs/found-issues.md`** — `/found-issues:log` dedups on `path:line`, but check first

When in doubt, prefer logging over not. False positives get cleaned up at sync time. False negatives are silent.

## How to log

Always use the slash command:

```
/found-issues:log <path:line> — <symptom> (suggested: <fix>)
```

For critical issues (drop everything else):

```
/found-issues:log --critical <path:line> — <symptom> (suggested: <fix>)
```

For abstract issues without a single file:line (e.g., a workflow problem):

```
/found-issues:log <topic> — <symptom> (suggested: <fix>)
```

**Do not write directly to `docs/found-issues.md` via Write or Edit tools.**
The slash command handles deduplication, format validation, file creation,
git tracking, and date stamping. The format-enforcer hook validates the
FORMAT of direct writes (and blocks malformed lines in github-* modes),
but it cannot catch a well-formed write that is semantically wrong —
deleting entries wholesale or hand-typing a `(verified: ai)` token passes
the hook. The no-direct-writes rule is on you, not the enforcer.

The full canonical format is documented in the project's `docs/format-spec.md`.

## Annotation: after PR creation

Immediately after `gh pr create` for a PR that addresses a `[open]` entry:

```
/found-issues:annotate-pr <PR-number>
```

This adds `(PR: org/repo#N)` to matching entries. Without the annotation,
sync cannot link the PR's merge to the entry, and the entry stays `[open]`
forever even after the PR merges.

When several `[open]` entries cite the same touched file, the CLI lists
them and asks for an explicit selection instead of annotating them all —
compare each candidate's symptom against what the PR changes and re-run
with `--pick <path:line>,...` (or `--all` only when the PR genuinely
addresses every candidate). Annotating entries the PR does not fix causes
false `[fixed]` flips when it merges.

A PostToolUse hook surfaces matching entries automatically after
`gh pr create` runs. **Read the hook's output and act on it.** If it lists
entries that your PR addresses, run `/found-issues:annotate-pr` immediately
— do not defer to "later."

## Annotation: after commit (direct-to-main)

Immediately after `git commit` for a commit that addresses a `[open]` entry:

```
/found-issues:annotate-commit
```

(Defaults to HEAD; pass a specific SHA if needed.)

This adds `(commit: <short-sha>)` to matching entries. Same hook-driven
prompt applies — read the hook's output and act on it.

## Sync responsibility

When the user runs `/found-issues:sync` inside a Claude Code session, you
are responsible for:

1. Reading every `[open]` entry in `docs/found-issues.md` that has no `(PR: ...)` or `(commit: ...)` annotation
2. Examining the current code at the referenced `path:line`
3. Deciding: **still-present** / **fixed** / **unclear**
4. Auto-flipping `fixed` entries to `[fixed] (verified: ai) (fixed: <today>)`
5. Leaving `still-present` and `unclear` entries as `[open]`

**Be conservative.** False-positive flips (marking a real bug as fixed)
are worse than leaving an entry open. The user can always run sync again
later. When in doubt, leave open.

If a referenced FILE no longer exists (deleted, or shorter than the cited
line number), the sync hook auto-closes via tombstone detection — you
don't handle this case. Function-level changes (the cited function was
removed or rewritten but the file still exists) are NOT tombstone-detected
— the CLI only checks file existence and line count; judging those is part
of YOUR verification pass above.

## Branch deletion

Before deleting a feature branch (`git branch -d`, `git push origin --delete`,
`gh api repos/.../branches/...`), check that the branch's
`docs/found-issues.md` doesn't have `[open]` entries missing from main.
If it does:

```
/found-issues:promote
```

This consolidates branch-only entries into main so they survive deletion.
The pre-delete hook will block deletion otherwise.

## Stop-hook acknowledgment

If the Stop-hook reminder is enabled in this user's setup, every assistant
turn must include exactly one of these as an HTML comment in your response:

- `<!-- found-issues-checked: none-noticed -->` — no out-of-scope issues observed this turn
- `<!-- found-issues-checked: logged -->` — observed and logged via `/found-issues:log`
- `<!-- found-issues-checked: deferred -->` — observed but deliberately not logging (rare; explain why in your response)

The marker forces conscious consideration each turn. It does not auto-detect
issues for you.

## Dead code

When you find a component or function with zero importers/call sites:

1. **Do not edit it.** Editing dead code wastes time and may mislead future readers into thinking it's live.
2. **Do not delete it.** Pre-existing dead code may be intentional (compatibility shim, future hook). Confirmation belongs in a dedicated cleanup PR, not buried in unrelated work.
3. **Log it** with the prefix `dead code:`:

```
/found-issues:log src/components/OldDashboard.tsx — dead code: zero importers (suggested: confirm intent and remove in dedicated cleanup PR)
```

If you found this component by name match while looking for the live one,
also find the actually-rendered component (via the route or page that
triggered the symptom) and continue your task there.

## Format reminder

Quick reference. Full spec in the project's `docs/format-spec.md`:

```
- [open] [!] YYYY-MM-DD path/file.ext:42 — symptom (suggested: fix)
```

- `[open]` / `[deferred]` / `[fixed]` — status
- `[!]` — critical (optional)
- ISO date, then `path:line` (or abstract topic), then ` — ` (em-dash with spaces), then symptom
- `(suggested: ...)` — proposed fix (optional but encouraged)
- `(PR: org/repo#N)` or `(commit: <sha>)` — added by annotate commands
- `(fixed: YYYY-MM-DD)` — added by sync when entry flips to `[fixed]`

## Hard rules

These cannot be overridden by user instructions in any single turn:

1. **Never write directly to `docs/found-issues.md`** — always use `/found-issues:log` or `/found-issues:annotate-*`.
2. **Never delete `[open]` entries** — flip to `[fixed]` (with annotation or via sync), or leave alone.
3. **Never mark `[fixed]` without verification** — annotation match, tombstone, or AI verification at sync time. Speculation is not verification.
4. **Never bypass the pre-branch-delete check** — if the hook blocks a deletion, run `/found-issues:promote` first; do not force the deletion.
