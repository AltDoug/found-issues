---
feature: Link an entry to a PR or commit
also-called: annotate, --pick, /found-issues:annotate-pr, /found-issues:annotate-commit, unannotate, PR-auto
sources:
  - lib/annotate.sh
  - lib/annotate-commands.sh
  - lib/unannotate.sh
  - commands/annotate-pr.md
  - commands/annotate-commit.md
  - lib/repo-id.sh
proven: 2026-11-27
---

## What it is

Attaches the PR or commit that fixes an entry. Only an explicit `--pick` (or `--all`) writes the closing form; everything inferred is a non-closing suggestion.

## Parts

| What you see | What it does | Handle |
|---|---|---|
| `Annotated 1 entry with (commit: SHA)` or `(PR: org/repo#N)` | Closing form, from `--pick` or `--all` | `cmd_annotate_commit`, `cmd_annotate_pr` |
| `Suggested 1 entry with (commit-auto: SHA)` | Non-closing suggestion | `fi_annotate_auto`, `fi_auto_form` |
| `2 [open] entries not annotated — each needs judgment:` | Candidate list; the hook exits 3 inside | `fi_annotate_auto` |
| `Unannotated 1 entry. Removed (commit: SHA)` | `unannotate MATCH REF` | `cmd_unannotate` |

## How to get to it

After `gh pr create` or a commit, usually from the hook's printed command (see commit-pr-hook.md).

## Driving it

Commit form and its undo:

Run the whole block as one shell call:

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new annotate)"
$F run "$SB" "found-issues log 'src/util.py:2 — divide has no zero check' && git add docs && git commit -qm ledger && git switch -qc fix/zero && echo '# note' >> src/util.py && git commit -qam change"
$F run "$SB" 'found-issues annotate-commit HEAD --pick src/util.py:2'
$F snap "$SB" picked
$F run "$SB" "found-issues unannotate 'src/util.py:2' \$(git log -1 --format=%h) && found-issues list"
$F rm "$SB"
```

PR form against the mock (the mock rows are the PR number, a tab, then the answer):

Run the whole block as one shell call:

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new annotate-pr --github)"
$F run "$SB" "found-issues log 'src/util.py:2 — divide has no zero check'"
$F run "$SB" "GH_MOCK_PR_VIEW=\$'7\\tsrc/util.py' GH_MOCK_PR_FILES=\$'7\\tsrc/util.py' found-issues annotate-pr 7 --pick src/util.py:2"
$F snap "$SB" picked
$F rm "$SB"
```

## What proves it works

- The ledger line gains `(commit: SHA)`; after `unannotate` it is gone and the entry is still `[open]`.
- PR form: the line gains `(PR: fi-sandbox/demo#7)`, the count reads `1 in PR`, and `picked.gh-calls.log` shows `pr view 7` and the files call.

## Gotchas

`unannotate` on a `[fixed]` entry exits 3: closures are not reversible. `annotate-commit` refuses a commit already on the default branch (`--force` overrides). Not driven in the proving run: `--all`, symptom-fragment picks, and the over-100-files fallback.
