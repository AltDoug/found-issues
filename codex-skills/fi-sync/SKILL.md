---
name: fi-sync
description: Sync found-issues — flip merged PRs/commits to [fixed], verify unannotated entries, surface stale work
---
<!-- loc-override: generated 1:1 from commands/sync.md by scripts/gen-codex-skills.sh; length is owned by the source command file -->

Reconcile `docs/found-issues.md` against the current state of the code
and the PR/commit history. Two phases — the CLI does mechanical phase 1,
you do AI verification in phase 2.

## Phase 1 — Mechanical sync (delegated to CLI)

Run:

```bash
found-issues sync
```

This handles three closure mechanisms automatically:

- **PR merge** — `[open]` entries with `(PR: org/repo#N)` get checked via `gh pr view`. Merged PRs flip the entry to `[fixed]`.
- **Commit on default branch** — entries with `(commit: <sha>)` get checked via `git merge-base --is-ancestor`. Commits on main flip the entry to `[fixed]`.
- **Tombstone** — if an entry's `path:line` no longer exists (file deleted, file shorter than line N), the entry auto-flips with `(closure: tombstone)`.

The CLI prints a one-line summary: `Synced. Closed: N (P PR + C commit + T tombstone).`

## Phase 2 — AI verification of unannotated entries

This is your job — the CLI cannot do it without invoking you.

After phase 1, read the issues file and find every `[open]` entry eligible
for AI verification. An entry is eligible when it has:

- **No annotations** (unannotated path:line entries), OR
- Only demoted annotations: `(PR-closed: ...)` and/or `(commit-stale: ...)`.

Entries with an active `(PR: ...)` or `(commit: ...)` annotation are NOT
eligible — those represent in-flight work and should be left alone.

For each eligible entry:

1. **Read the code at `path:line`** (use the `Read` tool, with appropriate offset/limit around the referenced line).
2. **Re-read the entry's symptom and suggested fix** — they describe what the bug was.
3. **Decide**: is the issue *still present*, *fixed*, or *unclear*?
4. **Act**:
   - If **still-present** — leave the entry as `[open]`. Do not touch it.
   - If **fixed** — edit the file: change `[open]` → `[fixed]` and append `(verified: ai) (fixed: YYYY-MM-DD)` (today's date).
   - If **unclear** — leave as `[open]`. Don't guess.

## Conservative bias is mandatory

False-positive closures (marking a real bug as fixed) are worse than
stale opens. The user can always run `$fi-sync` again later. When in
doubt, leave the entry alone.

Do **not** flip on:
- Code that "looks different" but you can't tell if the symptom is gone
- Entries whose `path:line` no longer makes sense (the CLI's tombstone check
  already handled file-not-found / line-out-of-range — if it didn't fire,
  the location is intact and you should examine it)
- Entries with vague symptoms ("this could break" / "might be slow") —
  these can't be verified by reading code, only by running it
- Symptoms describing intermittent or load-dependent behavior — reading
  code can't disprove a race condition

Do flip on:
- The exact null-check / type-check / bounds-check the symptom describes is
  now visibly present in the code
- The function or call referenced in the symptom no longer exists
  (different from tombstone — this is when the file is there but the
  callsite or function was renamed/removed)
- The symptom describes a missing feature/field that is now clearly in
  place at the referenced location

## Reading demoted annotations as hints

When an entry has `(PR-closed: ...)` or `(commit-stale: ...)`, treat the
annotation as **weak evidence that someone tried to fix this**, not proof
the bug is gone. Apply the same conservative bias as for unannotated
entries: verify by reading the code at `path:line`; flip only on clear
evidence the symptom is no longer present.

The demoted annotation stays on the line as audit trail regardless of
your verdict — if you flip the entry, append `(verified: ai) (fixed: ...)`
in addition to the existing demoted annotation. Do not strip the demoted
annotation.

## Reporting

After both phases, report concisely:

- Phase 1 closures (from CLI output)
- Phase 2 closures: which entries you flipped and why (one sentence each)
- Phase 2 deferred: count of entries you left as `[open]` because the
  judgment was unclear (don't list them all — just the count)
- Final status: run `found-issues status --format=plain` and pass it
  through

## Example phase 2 reasoning

> Entry: `- [open] 2026-04-15 src/auth.ts:88 — race on session refresh, two concurrent calls can clobber the token`
>
> Read `src/auth.ts:80-100`. The `refreshSession` function now has a
> mutex via `Promise.withResolvers`; concurrent calls await the same
> promise. The race described in the symptom is no longer possible.
>
> → Flip to `[fixed] (verified: ai) (fixed: 2026-05-07)`.

> Entry: `- [open] 2026-04-20 src/queue.py:42 — possible memory leak when worker pool exhausted`
>
> Read `src/queue.py:35-60`. The pool exhaustion handling looks similar
> to the original code — I can't tell from inspection whether the leak
> is fixed without actually running under load.
>
> → Leave as `[open]`. Cannot verify by inspection.
