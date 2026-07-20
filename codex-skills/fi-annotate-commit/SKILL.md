---
name: fi-annotate-commit
description: Annotate matching [open] entries with a (commit: <sha>) reference
---

After a `git commit` that addresses an `[open]` entry — typically in
`github-direct` mode (push-to-main without PRs) or for fixes that don't
warrant a PR — annotate the entry with the commit's short SHA. Sync will
auto-flip when the commit lands on the default branch.

## What to do

```bash
found-issues annotate-commit <the user-provided arguments>
```

If the user provided no argument, the CLI defaults to `HEAD` — the most
recent commit. This is the 90% case ("I just committed the fix, mark it").

Pass through the CLI's output:

- `Annotated N entries with (commit: <short>)` — happy path
- `annotate-commit: no [open] entries match files touched by commit <sha>. No changes.` — commit didn't touch any logged paths
- A candidate list ending in a `--pick` instruction — several entries cite
  one touched file, so the CLI annotates none of them (auto-tagging all
  would false-flip the unfixed ones when the commit lands). Compare each
  candidate's symptom against what the commit actually changes, then
  re-run with `--pick <path:line>,...` for the entries it genuinely
  addresses (or `--all` when it addresses every candidate). For two
  entries at the SAME path:line, use the extended pick form
  `--pick "<path:line> — <symptom fragment>"`.

## When to invoke

The `post-bash-dispatch` hook surfaces relevant entries automatically right
after `git commit` succeeds. **Run `$fi-annotate-commit` immediately** —
do not defer.

For fixes spread across multiple commits, run `$fi-annotate-commit <sha>`
once per relevant commit. The CLI is idempotent — running it twice with
the same SHA is safe (the second pass detects the existing annotation
and skips).

## Combined with PR workflow

If you opened a PR for a fix AND want to annotate a specific commit
within it, both annotations are valid:

```
- [open] 2026-05-06 src/foo.py:42 — leak (PR: org/repo#5) (commit: a1b2c3d)
```

Sync checks both — closure happens whichever resolves first (PR merge
or commit landing on main).
