---
feature: Sync closes fixed entries
also-called: sync, /found-issues:sync, fi-sync, tombstone, held
sources:
  - lib/sync.sh
  - commands/sync.md
  - codex-skills/fi-sync/
proven-with: mock gh for PR closure
proven: 2026-11-27
proven-hash: e240efe5cd5b
---

## What it is

Reconciles the ledger with git and GitHub: an entry flips to `[fixed]` when its annotated commit or PR lands on the default branch, or git confirms its file was removed. Critical and held entries are never closed automatically.

## Parts

| What you see | What it does | Drive it by |
|---|---|---|
| `Synced. Closed: N (P PR + C commit + T tombstone).` | Entries flipped | `found-issues sync` |
| `Synced. Nothing to close.` | No change | `sync` before the fix is on the default branch |
| `Dry run — nothing written.` | Reports only | `sync --dry-run` |
| `Held: 1 entry for human verification (NOT closed):` | A `[!]` or `(hold: ...)` entry would have closed | a `--critical` entry whose file is removed |
| `Read-only clone (found-issues.readonly) — nothing written.` | A clone that only pulls | `git config found-issues.readonly true` |
| `(closure: tombstone)` on the line | The cited file was removed in a commit | `git rm` the file and commit |
| `... did not touch FILE — left [open]` | The annotated commit never changed the cited file | annotate with an unrelated commit |

## How to get to it

`/found-issues:sync`; the plugin also runs it at session start, after `gh pr merge`, and from the statusline.

## Driving it

Commit closure. The entry is annotated first (annotate.md). A second entry is linked to a commit that never touched its file, and must stay open.

```bash
set -eo pipefail
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new sync-commit)"; trap '$F rm "$SB"' EXIT
L=docs/found-issues.md
$F run "$SB" "found-issues log 'src/util.py:2 — divide has no zero check' && found-issues log 'src/app.sh:3 — greets with an empty name' && git add docs && git commit -qm ledger && git switch -qc fix/zero"
$F run "$SB" "sed -i.bak 's|return a / b|return a / b if b else 0|' src/util.py && rm src/util.py.bak && git commit -qam 'guard divide' && found-issues annotate-commit HEAD --pick src/util.py:2 && found-issues annotate-commit HEAD --pick src/app.sh:3"
$F snap "$SB" before-merge
$F run "$SB" 'found-issues sync'
$F has "$SB" 'Synced. Nothing to close.'
$F count "$SB" 2 '- [open] ' "$L"
$F run "$SB" 'git commit -qam annotate && git switch -q main && git merge -q --no-ff fix/zero -m merge && found-issues sync'
$F has "$SB" 'Synced. Closed: 1 (0 PR + 1 commit + 0 tombstone).'
$F has "$SB" 'did not touch src/app.sh'
$F match "$SB" '^- \[fixed\] .*src/util\.py:2 .*\(commit: [0-9a-f]+\) \(fixed: ' "$L"
$F match "$SB" '^- \[open\] .*src/app\.sh:3 ' "$L"
$F snap "$SB" after-merge
```

PR closure against the `gh` mock: an open PR closes nothing, a PR merged into `main` closes the entry.

```bash
set -eo pipefail
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new sync-pr --github)"; trap '$F rm "$SB"' EXIT
L=docs/found-issues.md
$F run "$SB" "found-issues log 'src/util.py:2 — divide has no zero check'"
$F run "$SB" "GH_MOCK_PR_VIEW=\$'7\\tsrc/util.py' GH_MOCK_PR_FILES=\$'7\\tsrc/util.py' found-issues annotate-pr 7 --pick src/util.py:2"
$F run "$SB" "GH_MOCK_PR_VIEW=\$'7\\t{\"state\":\"OPEN\",\"baseRefName\":\"main\",\"mergedAt\":null,\"isDraft\":false}' found-issues sync"
$F has "$SB" 'Synced. Nothing to close.'
$F has "$SB" '- [open] ' "$L"
$F run "$SB" "GH_MOCK_PR_VIEW=\$'7\\t{\"state\":\"MERGED\",\"baseRefName\":\"main\",\"mergedAt\":\"2026-01-01T12:00:00Z\",\"isDraft\":false}' found-issues sync"
$F has "$SB" 'Synced. Closed: 1 (1 PR + 0 commit + 0 tombstone).'
$F match "$SB" '^- \[fixed\] .*\(PR: fi-sandbox/demo#7\)' "$L"
$F has "$SB" 'pr view 7 --repo fi-sandbox/demo' "$SB/gh-calls.log"
$F snap "$SB" after-sync
```

Removed files: a dry run and a read-only clone write nothing; the real run tombstones the ordinary entry and holds the critical one.

```bash
set -eo pipefail
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new sync-tombstone)"; trap '$F rm "$SB"' EXIT
L=docs/found-issues.md
$F run "$SB" "found-issues log 'src/util.py:2 — gone with the file' && found-issues log --critical 'src/app.sh:3 — critical gone too' && git add docs && git commit -qm ledger && git rm -q src/util.py src/app.sh && git commit -qm remove"
$F run "$SB" 'found-issues sync --dry-run && git status --short'
$F has "$SB" 'Dry run — nothing written.'
$F count "$SB" 2 '- [open] ' "$L"
$F run "$SB" 'git config found-issues.readonly true && found-issues sync && git status --short && git config --unset found-issues.readonly'
$F has "$SB" 'Read-only clone (found-issues.readonly) — nothing written.'
$F lacks "$SB" 'docs/found-issues.md'
$F count "$SB" 2 '- [open] ' "$L"
$F run "$SB" 'found-issues sync'
$F has "$SB" 'Synced. Closed: 1 (0 PR + 0 commit + 1 tombstone).'
$F has "$SB" 'Held: 1 entry for human verification (NOT closed):'
$F match "$SB" '^- \[fixed\] .*gone with the file \(closure: tombstone\)' "$L"
$F match "$SB" '^- \[open\] \[!\] .*critical gone too \(hold: needs human verify\)' "$L"
$F snap "$SB" after-tombstone
```

## What proves it works

- Nothing closes before the fix is on `main`, or while the PR is open.
- After the merge the line reads `[fixed] ... (commit: SHA) (fixed: date)` or `(PR: fi-sandbox/demo#7)`; the entry linked to the unrelated commit stays `[open]` with a note on stderr.
- Tombstone: the ordinary entry gains `(closure: tombstone)`; the critical one stays `[open]` with `(hold: needs human verify)`.
- Dry run and read-only clone report the same counts and leave `git status` clean.

## Gotchas

- A `[fixed]` entry cannot be reopened.
- PR closure is proven against the `gh` mock only. The mock's `gh pr view` fails unless `GH_MOCK_PR_VIEW` has a row for that number.
- Not driven: rename following, PR-closed and commit-stale demotion, stacked PRs, `(until: ...)` wake-up and auto-archive. The AI verification pass in `commands/sync.md` is a model following prose; its only write is `resolve --verified ai` (close-and-archive.md).
