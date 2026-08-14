---
name: fi-annotate-commit
description: After committing a fix directly (no PR — push-to-main workflows), attach a (commit: <sha>) reference so sync auto-flips the entry once that commit reaches the default branch. Defaults to HEAD: run it AFTER the fix commit exists, never right after cutting a branch — a target already on the default branch is rejected because it predates the fix and would false-close the entry (--force overrides for genuinely retroactive annotation). Prefer $fi-annotate-pr when a PR exists. Same --pick discipline for ambiguous matches, never --all as a shortcut.
---
<!-- loc-override: generated 1:1 from commands/annotate-commit.md by scripts/gen-codex-skills.sh; length is owned by the source command file -->

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
Run it AFTER the fix commit exists: on a branch, a target that is already
an ancestor of the default branch is rejected (exit 2), because a commit
that predates your fix cannot be the fix — annotating it would false-close
the entry the moment sync's ancestor closer sees it. `--force` overrides
for the rare genuinely-retroactive annotation of an already-merged fix.

Pass through the CLI's output:

- `Annotated N entries with (commit: <short>)` — happy path
- `annotate-commit: no [open] entries match files touched by commit <sha>. No changes.` — commit didn't touch any logged paths
- `annotate-commit: <sha> is already on '<branch>' ...` (exit 2) — the
  guard above fired. Commit the fix first, then annotate THAT commit;
  only pass `--force` if this really is a retroactive annotation.
- A candidate list ending in a `--pick` instruction — several entries cite
  one touched file, so the CLI annotates none of them (auto-tagging all
  would false-flip the unfixed ones when the commit lands). Compare each
  candidate's symptom against what the commit actually changes, then
  re-run with `--pick <path:line>,...` for the entries it genuinely
  addresses (or `--all` when it addresses every candidate). For two
  entries at the SAME path:line, use the extended pick form
  `--pick "<path:line> — <symptom fragment>"`.

## When to invoke

The post-bash dispatcher hook normally handles this automatically
(`--hook-auto`: line-matched entries annotate silently; exit 3 surfaces
candidates). This command is the manual fallback for web-UI PRs or when
hooks are disabled.

If the hook surfaced a candidate list (exit 3) right after `git commit`
succeeded, **run the suggested `$fi-annotate-commit` immediately** —
do not defer. If the hook didn't fire at all (e.g. a non-Bash commit path,
or `FOUND_ISSUES_AUTO_ANNOTATE=off`), invoke this command manually.

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
