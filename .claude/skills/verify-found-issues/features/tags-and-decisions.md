---
feature: Fix tags and the decision queue
also-called: tag, decide, /found-issues:decide, fi-decide, decisions waiting
sources:
  - lib/tag.sh
  - lib/decide.sh
  - lib/autofix-tags.sh
  - commands/decide.md
  - codex-skills/fi-decide/
proven: 2026-11-27
---

## What it is

Each entry can carry one fix tag, plus a hold. Entries tagged `(decide: ...)` form a queue of questions that need a person's answer.

## Parts

| What you see | What it does | Drive it by |
|---|---|---|
| `Tagged: - [open] ...` | Sets or changes a tag | `tag MATCH --fix medium`, `--decide`, `--manual`, `--hold 'why'`, `--unhold`, `--retry` |
| `1. release/naming — rename or alias?` | The open questions | `decide` |
| A number | How many wait | `decide --count` |
| `(decided: alias)` in place of `(decide: ...)` | Records the answer | `decide MATCH --answer 'alias'` |
| `No decisions waiting.` | Empty queue | `decide` after the last answer |

## How to get to it

`/found-issues:decide` in a session; `❓N` in the statusline shows how many wait.

## Driving it

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new decisions)"; trap '$F rm "$SB"' EXIT
L=docs/found-issues.md
$F run "$SB" "found-issues log --decide 'rename or alias?' 'release/naming — two names for one command'"
$F run "$SB" 'found-issues decide'
$F has "$SB" '1. release/naming — rename or alias?'
$F run "$SB" 'found-issues decide --count'
$F is "$SB" '1'
$F run "$SB" "found-issues decide 'two names' --answer 'alias'"
$F has "$SB" '(decided: alias)' "$L"
$F lacks "$SB" '(decide:' "$L"
$F run "$SB" 'found-issues decide'
$F is "$SB" 'No decisions waiting.'
$F run "$SB" "found-issues log 'src/util.py:2 — no zero check' && found-issues tag 'zero check' --fix medium && found-issues tag 'zero check' --hold 'needs a human'"
$F has "$SB" 'no zero check (fix: medium) (hold: needs a human)' "$L"
$F snap "$SB" held
$F run "$SB" "found-issues tag 'zero check' --unhold"
$F lacks "$SB" '(hold:' "$L"
$F has "$SB" 'no zero check (fix: medium)' "$L"
```

## What proves it works

- The queue prints the numbered question and count `1`, then `No decisions waiting.`
- The answered line carries `(decided: alias)` and no `(decide:`. The hold is added after the fix tag and `--unhold` removes only the hold.

## Gotchas

- Off-limits paths (CI config, manifests, secrets, untracked files) are forced to `(manual: off-limits: ...)` (driven for an untracked file in logging.md).
- A `[!]` or `(hold: ...)` entry is never auto-closed (sync.md), and `resolve --verified ai` refuses a held one (close-and-archive.md).
- Not driven: `--retry`, `--manual` and re-tagging an entry from one fix tag to another.
