---
description: Annotate matching [open] entries with a (PR: org/repo#N) reference
codex-description: After opening a PR that addresses an [open] entry, attach the canonical (PR: org/repo#N) reference so sync auto-flips the entry when the PR merges — bare text like 'PR #N' in an entry is invisible to sync; this command writes the only format that closes the loop. When several entries cite one touched file a candidate list appears: re-run with --pick path:line for exactly the entries the PR addresses, never --all as a shortcut. Use /found-issues:annotate-commit instead when the fix is a direct commit with no PR.
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
4. Auto-annotates only UNAMBIGUOUS matches — entries that are the sole `[open]`
   entry citing their touched file. When several entries share one touched
   file, the CLI annotates none of them and prints the candidate list instead
   (file-level matching alone would tag every entry on a hot file, and sync
   would false-flip them all to `[fixed]` on merge).

Possible outputs:

- `Annotated N entries with (PR: org/repo#N)` — happy path
- `annotate-pr: no [open] entries match files touched by PR #N. No changes.` — edge case (PR addresses code with no logged entries)
- A candidate list ending in a `--pick` instruction — ambiguous matches that
  need YOUR judgment. **Do not skip this step.** Compare each candidate's
  symptom against what the PR actually changes, then re-run with only the
  entries the PR genuinely addresses:

  ```bash
  found-issues annotate-pr <N> --pick path/file.py:42,path/other.py:7
  ```

  Locations are exactly as printed in the candidate list (`path:line`, or a
  bare path for line-less entries). If the PR really does address every
  listed candidate (e.g. a release PR sweeping all open issues), use
  `found-issues annotate-pr <N> --all` instead. Never use `--all` to save
  yourself the symptom comparison.

  When TWO entries share the same `path:line`, a bare location pick is
  refused (it cannot select between them) — use the extended form with a
  symptom fragment:

  ```bash
  found-issues annotate-pr <N> --pick "src/hot.py:2 — null deref"
  ```

Pass the result through to the user.

## When to invoke

The post-bash dispatcher hook normally handles this automatically
(`--hook-auto`: line-matched entries annotate silently; exit 3 surfaces
candidates). This command is the manual fallback for web-UI PRs or when
hooks are disabled.

If the hook did surface a candidate list (exit 3) right after `gh pr create`,
that output includes the suggested `--pick` command line — **run it
immediately**, don't defer. If the hook didn't fire at all (e.g., user
opened the PR via the GitHub web UI or via a non-Bash tool, or
`FOUND_ISSUES_AUTO_ANNOTATE=off`), invoke this command manually with the
PR number.

## Multi-PR entries

A single entry can be addressed by multiple PRs (e.g., partial fix → revert
→ re-fix). Running `/found-issues:annotate-pr` multiple times with different PR
numbers is safe — both annotations get appended:

```
- [open] 2026-05-06 src/foo.py:42 — leak (PR: org/repo#5) (PR: org/repo#7)
```

Sync checks each PR independently; the entry flips to `[fixed]` when any
one merges to the default branch.
