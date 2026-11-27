---
feature: Fix tags and the decision queue
also-called: tag, hold, decide, /found-issues:decide, decisions waiting
sources:
  - lib/tag.sh
  - lib/decide.sh
  - lib/autofix-tags.sh
  - commands/decide.md
proven: 2026-11-27
---

## What it is

Each entry can carry one fix tag. Entries tagged `(decide: ...)` form a queue of questions that need a person's answer.

## Parts

| What you see | What it does | Handle |
|---|---|---|
| `Tagged: - [open] ...` | `tag MATCH --fix, --decide, --manual, --hold, --unhold or --retry` | `cmd_tag` |
| `1. release/naming — rename or alias?` | `decide` lists open questions | `cmd_decide` |
| `decide --count` | The number only | `cmd_decide` |
| `decide MATCH --answer "text"` | Replaces `(decide:)` with `(decided:)` | `cmd_decide` |
| `No decisions waiting.` | Empty queue | `cmd_decide` |

## How to get to it

`/found-issues:decide` in a session; `❓N` in the statusline shows how many wait.

## Driving it

Run the whole block as one shell call:

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new decisions)"
$F run "$SB" "found-issues log --decide 'rename or alias?' 'release/naming — two names for one command'"
$F run "$SB" "found-issues decide && found-issues decide --count"
$F run "$SB" "found-issues decide 'two names' --answer 'alias' && found-issues decide"
$F run "$SB" "found-issues log 'src/util.py:2 — no zero check' && found-issues tag 'zero check' --fix medium && found-issues tag 'zero check' --hold 'needs a human'"
$F snap "$SB" final
$F rm "$SB"
```

## What proves it works

- The queue prints the numbered question and count `1`, then `No decisions waiting.`
- The snapshot has `(decided: alias)` on one line and `(fix: medium) (hold: needs a human)` on the other.

## Gotchas

Off-limits paths (CI config, manifests, secrets, untracked files) are forced to `(manual: off-limits: ...)`. Not driven in the proving run: that rewrite, `--unhold` and `--retry`.
