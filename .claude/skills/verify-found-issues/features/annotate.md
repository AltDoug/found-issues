---
feature: Link an entry to a PR or commit
also-called: annotate-pr, annotate-commit, unannotate, /found-issues:annotate-pr, /found-issues:annotate-commit
sources:
  - lib/annotate.sh
  - lib/annotate-commands.sh
  - lib/unannotate.sh
  - commands/annotate-pr.md
  - commands/annotate-commit.md
  - codex-skills/fi-annotate-pr/
  - codex-skills/fi-annotate-commit/
proven-with: mock gh for the PR form
proven: 2026-11-27
proven-hash: 9b37ae229dbc
---

## What it is

Attaches the PR or commit that fixes an entry. Only an explicit `--pick` (or `--all`) writes the closing form; everything inferred is a non-closing suggestion.

## Parts

| What you see | What it does | Drive it by |
|---|---|---|
| `Annotated 1 entry with (commit: SHA)` or `(PR: org/repo#N)` | The closing form | `annotate-commit SHA --pick path:line`, `annotate-pr N --pick path:line`, or `--all` |
| `Suggested 1 entry with (commit-auto: SHA)` | A non-closing suggestion, written when the hook runs it | see commit-pr-hook.md |
| `2 [open] entries not annotated — each needs judgment:` | A candidate list, nothing written | see commit-pr-hook.md |
| `Unannotated 1 entry. Removed (commit: SHA)` | Takes the link off again | `unannotate MATCH SHA` |

## How to get to it

After `gh pr create` or a commit, usually from the hook's printed command (see commit-pr-hook.md).

## Driving it

Commit form and its undo.

```bash
set -eo pipefail
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new annotate)"; trap '$F rm "$SB"' EXIT
L=docs/found-issues.md
$F run "$SB" "found-issues log 'src/util.py:2 — divide has no zero check' && git add docs && git commit -qm ledger && git switch -qc fix/zero && echo '# note' >> src/util.py && git commit -qam change"
SHA="$(git -C "$SB/repo" log -1 --format=%h)"
$F run "$SB" 'found-issues annotate-commit HEAD --pick src/util.py:2'
$F has "$SB" "Annotated 1 entry with (commit: $SHA)"
$F has "$SB" "divide has no zero check (commit: $SHA)" "$L"
$F snap "$SB" picked
$F run "$SB" "found-issues unannotate 'src/util.py:2' $SHA"
$F has "$SB" 'Unannotated 1 entry.'
$F lacks "$SB" '(commit:' "$L"
$F has "$SB" '- [open] ' "$L"
```

PR form against the `gh` mock. A mock row is the PR number, a tab, then the answer.

```bash
set -eo pipefail
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new annotate-pr --github)"; trap '$F rm "$SB"' EXIT
$F run "$SB" "found-issues log 'src/util.py:2 — divide has no zero check'"
$F run "$SB" "GH_MOCK_PR_VIEW=\$'7\\tsrc/util.py' GH_MOCK_PR_FILES=\$'7\\tsrc/util.py' found-issues annotate-pr 7 --pick src/util.py:2"
$F has "$SB" 'Annotated 1 entry with (PR: fi-sandbox/demo#7)'
$F has "$SB" '1 in PR'
$F has "$SB" 'divide has no zero check (PR: fi-sandbox/demo#7)' docs/found-issues.md
$F has "$SB" 'pr view 7' "$SB/gh-calls.log"
$F snap "$SB" picked
```

## What proves it works

- The ledger line gains `(commit: SHA)`; after `unannotate` it is gone and the entry is still `[open]`.
- PR form: the line gains `(PR: fi-sandbox/demo#7)`, the count reads `1 in PR`, and the mock's call log shows `pr view 7`.

## Gotchas

- `unannotate` on a `[fixed]` entry exits 3: closures are not reversible.
- `annotate-commit` refuses a commit already on the default branch (`--force` overrides).
- A link to a commit that never touched the cited file is accepted here, but sync will not close it (sync.md).
- Not driven: `--all`, symptom-fragment picks, those two refusals and the over-100-files fallback. Real GitHub is never called.
