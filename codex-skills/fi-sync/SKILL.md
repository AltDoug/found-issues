---
name: fi-sync
description: "Reconcile the ledger with reality: flip [open] entries whose annotated PR merged or whose annotated commit landed on the default branch to [fixed], tombstone entries whose cited file git confirms was removed, and surface stale in-PR work. Run after merges land or when the ledger looks out of date. Mutating and not reversible — no command reopens a closure, so use --dry-run first when unsure. Do NOT use it to link a PR or commit to an entry: $fi-annotate-pr and $fi-annotate-commit write those references; sync only reads what they wrote."
---
<!-- loc-override: generated 1:1 from commands/sync.md by scripts/gen-codex-skills.sh; length is owned by the source command file -->

Reconcile `docs/found-issues.md` against the current state of the code
and the PR/commit history. Two phases — the CLI does mechanical phase 1,
you do AI verification in phase 2.

## Phase 1 — Mechanical sync (delegated to CLI)

Run:

```bash
found-issues sync <the user-provided arguments>
```

(`--dry-run` reports what would change and writes nothing — use it first
when unsure; closures are not reversible.)

This handles three closure mechanisms automatically:

- **PR merge** — `[open]` entries with `(PR: org/repo#N)` get checked via `gh pr view`. A PR merged into the default branch flips the entry to `[fixed]`. A PR merged into another branch (a release branch, a stacked PR) flips it once a later merged PR brings that branch into the default branch.
- **Commit on default branch** — entries with `(commit: <sha>)` get checked via `git merge-base --is-ancestor`. A commit on main flips the entry to `[fixed]` only when that commit touched the file the entry cites (a cited directory matches any file under it; the pre-rename path counts; entries with no usable path keep the old behaviour). A landed commit that never touched the cited file leaves the entry `[open]` and sync prints one line naming the entry and the sha, with the undo command: `found-issues unannotate '<loc>' <sha>`.
- **Tombstone** — the entry auto-flips with `(closure: tombstone)` only when **git confirms the file was removed**: absent from the current `HEAD` tree AND present somewhere in git history. Everything else stays `[open]`, and you must not close those yourself in Phase 2 either:
  - a file that merely got **SHORTER** than the cited line — that is line drift, not a fix;
  - a path git **never tracked** — an abstract location (`workflow/release-process`), a typo, or a gitignored path;
  - a file deleted only in the **dirty worktree** — an uncommitted `rm` is not a closure;
  - anything at all when there is **no git repo or no commits**.

  A path being absent says nothing about whether the issue was fixed, and no supported command reopens a `[fixed]` entry — so when in doubt, leave it `[open]`.

The CLI output, section by section, and what each one asks of you:

- `Synced. Closed: N (P PR + C commit + T tombstone).` (plus `Demoted:` /
  `Renamed:` counts), `Synced. Nothing to close.`, or with `--dry-run`
  `Dry run — nothing written.` — report it.
- The status line (`3 issues · 1 in PR`) — pass it through.
- `N hook-suggested annotation(s) awaiting confirmation (NOT closed)` — a
  `(PR-auto:)`/`(commit-auto:)` suggestion whose ref has landed. Each item is
  followed by two ready-to-run lines with the real number, sha and location
  filled in:

  ```
  - src/foo.py:1 — suggested (commit-auto: ab12cd3) has landed
      confirm: found-issues annotate-commit ab12cd3 --force --pick 'src/foo.py:1'
      reject:  found-issues unannotate 'src/foo.py:1' ab12cd3
  ```

  A PR suggestion prints `found-issues annotate-pr <N> --pick '<loc>'` (an
  `org/repo#N` ref when the PR lives in another repo); a landed commit prints
  `annotate-commit <sha> --force --pick '<loc>'` (`--force` because a commit
  already on the default branch is otherwise refused from a feature branch).
  Compare each entry against what that change did; run **confirm** for the
  ones it fixed (it rewrites the suggestion to the closing form, which the next
  sync acts on), run **reject** for the ones it did not (it strips that one
  marker), and leave the rest alone. Never confirm on the suggestion alone, and
  never edit the ledger by hand to remove a suggestion.
- `sync: commit <sha> is on <branch> but did not touch <path> — left [open] …`
  — an annotated commit landed but is unrelated to the file the entry cites, so
  it did not close the entry. If the annotation is wrong, run the printed
  `found-issues unannotate '<loc>' <sha>`; if the commit really is the fix,
  leave it and verify the entry in Phase 2.
- `Warning: N entry(ies) carry (PR: ...) annotations but the GitHub repo cannot
  be resolved (mode: git)` (stderr) — the remote is not github.com or `gh` is
  not authenticated, so PR merges cannot close those entries. Fix the remote or
  `gh auth status`; nothing was changed.
- `archive: moved N entries …` — old `[fixed]` entries moved to
  `found-issues-archive.md`; both files changed and need committing.
- `Warning: N PR annotation(s) could not be fetched via gh` — check
  `gh auth status`; nothing was demoted.

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
   - If **fixed** — close it through the CLI:

     ```bash
     found-issues resolve "<distinctive text from the entry>" --verified ai
     ```

     This flips `[open]` → `[fixed]` and appends `(verified: ai) (fixed: <today>)`.
     **Never edit `docs/found-issues.md` directly.** The ledger is a shared
     file that concurrent sessions also write; a direct `Edit` loses writes,
     drifts the format, and bypasses the guards. `resolve` is the serialized
     path. If the match is ambiguous it exits 2 and prints the candidates —
     re-run with a longer, more distinctive fragment rather than reaching for
     `Edit`. If it exits 4, the entry has an active `(PR: ...)` and is not
     yours to close; leave it.
   - If **unclear** — leave as `[open]`. Don't guess.

## Phase 3 — Deferred review

A `[deferred]` entry with no `(until: ...)` never comes back on its own,
so the parking lot only grows. Review it here.

Eligible: every `[deferred]` entry with no `(until: ...)`, whose
`(mute-until: ...)` date (if any) has passed, and whose own date is more
than 30 days old. Work through at most 20 per run, oldest first.

For each eligible entry:

1. Read the code or file at its location, and the entry's `(reason: ...)`.
2. Decide which case it is:
   - **Gone** — the symptom is no longer present (the same evidence bar as
     Phase 2), or what the entry is about no longer exists: the file,
     feature, service, tool or machine it describes was removed or
     replaced. Close it:

     ```bash
     found-issues resolve "<distinctive text from the entry>" --deferred --verified ai
     ```

   - **Ready** — the issue is still present, and the reason it was
     deferred no longer holds: the blocker merged, the phase it waited for
     shipped, the dependency it needed is in place. Bring it back:

     ```bash
     found-issues promote-deferred "<distinctive text from the entry>"
     ```

   - **Still parked** — still present and still blocked, or unclear. Leave
     it as it is.

The Phase 2 conservative bias applies to the "Gone" case: close only on
clear evidence. "Ready" only puts the entry back in the open list, where it
is fixed, deferred again, or auto-fixed like any other.

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
your verdict. `found-issues resolve` appends `(verified: ai) (fixed: ...)`
without touching what is already on the line, so the demoted annotation
survives on its own. Do not try to strip it.

## Reporting

After both phases, report concisely:

- Phase 1 closures (from CLI output)
- Phase 2 closures: which entries you flipped and why (one sentence each)
- Phase 2 deferred: count of entries you left as `[open]` because the
  judgment was unclear (don't list them all — just the count)
- Phase 3: how many deferred entries you closed, brought back, and left
  parked, plus how many eligible ones remain for the next run
- Final status: run `found-issues status --format=plain` and pass it
  through

## Example phase 2 reasoning

> Entry: `- [open] 2026-04-15 src/auth.ts:88 — race on session refresh, two concurrent calls can clobber the token`
>
> Read `src/auth.ts:80-100`. The `refreshSession` function now has a
> mutex via `Promise.withResolvers`; concurrent calls await the same
> promise. The race described in the symptom is no longer possible.
>
> → `found-issues resolve "race on session refresh" --verified ai`

> Entry: `- [open] 2026-04-20 src/queue.py:42 — possible memory leak when worker pool exhausted`
>
> Read `src/queue.py:35-60`. The pool exhaustion handling looks similar
> to the original code — I can't tell from inspection whether the leak
> is fixed without actually running under load.
>
> → Leave as `[open]`. Cannot verify by inspection.
