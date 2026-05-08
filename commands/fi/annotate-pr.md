---
description: Annotate matching [open] entries with a (PR: org/repo#N) reference
argument-hint: <PR-number>
allowed-tools: Bash(found-issues:*)
---

After running `gh pr create` (or noticing a PR was opened), annotate any
`[open]` entries the PR addresses with `(PR: org/repo#N)`. The sync hook
will then auto-flip those entries to `[fixed]` when the PR merges.

## What to do

```bash
found-issues annotate-pr $ARGUMENTS
```

The CLI:
1. Verifies the PR exists via `gh pr view`
2. Fetches the list of files touched by the PR
3. Scans `docs/found-issues.md` for `[open]` entries whose paths match those files
4. Appends `(PR: org/repo#N)` to each match (skipping entries already annotated for this PR)

Pass the result through to the user. The CLI prints either:

- `Annotated N entries with (PR: org/repo#N)` — happy path
- `annotate-pr: no [open] entries match files touched by PR #N. No changes.` — edge case (PR addresses code with no logged entries)

## When to invoke

The `post-pr-create` hook should surface relevant entries automatically
right after `gh pr create` runs. That output includes the suggested
command line. **Run the suggested `/fi annotate-pr <N>` immediately** —
do not defer.

If the hook didn't fire (e.g., user opened the PR via the GitHub web UI
or via a non-Bash tool), the user can invoke this command manually with
the PR number.

## Multi-PR entries

A single entry can be addressed by multiple PRs (e.g., partial fix → revert
→ re-fix). Running `/fi annotate-pr` multiple times with different PR
numbers is safe — both annotations get appended:

```
- [open] 2026-05-06 src/foo.py:42 — leak (PR: org/repo#5) (PR: org/repo#7)
```

Sync checks each PR independently; the entry flips to `[fixed]` when any
one merges to the default branch.
