---
feature: Sync closes fixed entries
also-called: sync, /found-issues:sync, auto-close, closure, tombstone, held
sources:
  - lib/sync.sh
  - commands/sync.md
  - bin/found-issues
proven: 2026-11-27
---

## What it is

Reconciles the ledger with git and GitHub: an entry flips to `[fixed]` when its annotated commit or PR lands on the default branch, or git confirms its file was removed. Critical and held entries are never closed automatically.

## Parts

| What you see | What it does | Handle |
|---|---|---|
| `Synced. Closed: N (P PR + C commit + T tombstone).` | Entries flipped | `cmd_sync` |
| `Synced. Nothing to close.` | No change | `cmd_sync` |
| `--dry-run` | Reports and writes nothing | `cmd_sync` |
| `Held: 1 entry for human verification (NOT closed):` | A `[!]` or `(hold: ...)` entry would have closed | `cmd_sync` |
| `Read-only clone (found-issues.readonly) — nothing written.` | `git config found-issues.readonly true` | `fi_sync_readonly` |
| `(closure: tombstone)` | The cited file was removed in a commit | `fi_git_confirms_removed` |

## How to get to it

`/found-issues:sync`; the plugin also runs it at session start, after `gh pr merge`, and from the statusline.

## Driving it

Commit closure (the entry must be annotated first, see annotate.md):

Run the whole block as one shell call:

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new sync-commit)"
$F run "$SB" "found-issues log 'src/util.py:2 — divide has no zero check' && git add docs && git commit -qm ledger && git switch -qc fix/zero"
$F run "$SB" "sed -i.bak 's|return a / b|return a / b if b else 0|' src/util.py && rm src/util.py.bak && git commit -qam 'guard divide' && found-issues annotate-commit HEAD --pick src/util.py:2"
$F snap "$SB" before-merge
$F run "$SB" 'found-issues sync'                       # Nothing to close: not on main yet
$F run "$SB" 'git commit -qam annotate && git switch -q main && git merge -q --no-ff fix/zero -m merge && found-issues sync'
$F snap "$SB" after-merge
$F rm "$SB"
```

PR closure, with the `gh` mock answering that PR 7 merged into `main`:

Run the whole block as one shell call:

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new sync-pr --github)"
$F run "$SB" "found-issues log 'src/util.py:2 — divide has no zero check'"
$F run "$SB" "GH_MOCK_PR_VIEW=\$'7\\tsrc/util.py' GH_MOCK_PR_FILES=\$'7\\tsrc/util.py' found-issues annotate-pr 7 --pick src/util.py:2"
$F run "$SB" "GH_MOCK_PR_VIEW=\$'7\\t{\"state\":\"MERGED\",\"baseRefName\":\"main\",\"mergedAt\":\"2026-01-01T12:00:00Z\",\"isDraft\":false}' found-issues sync"
$F snap "$SB" after-sync
$F rm "$SB"
```

Tombstone, hold and read-only clone: log an entry, commit the ledger, `git rm` the cited file, commit, then `found-issues sync` (set `git config found-issues.readonly true` first for the read-only report; log with `--critical` for the hold).

## What proves it works

- Before the merge: `Synced. Nothing to close.` After: `Closed: 1 (0 PR + 1 commit + 0 tombstone).`
- PR drive: `Closed: 1 (1 PR + 0 commit + 0 tombstone).`; `after-sync.gh-calls.log` ends with a `pr view 7 --repo fi-sandbox/demo` call.
- The snapshot line reads `[fixed] ... (commit: SHA) (fixed: date)` or `(PR: fi-sandbox/demo#7)`.
- Tombstone: `(closure: tombstone)`. Critical: `Held:` and the line stays `[open]` with `(hold: needs human verify)`. Read-only: the report, and `git status --short` stays empty.

## Gotchas

A `[fixed]` entry cannot be reopened. PR closure is proven against the `gh` mock only. Not driven in the proving run: rename following, PR-closed and commit-stale demotion, stacked PRs, `(until: ...)` wake-up and auto-archive.
