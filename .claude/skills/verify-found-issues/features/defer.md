---
feature: Defer and revive
also-called: park it, /found-issues:defer, promote-deferred, touched
sources:
  - lib/defer.sh
  - lib/promote-deferred.sh
  - commands/defer.md
  - commands/promote-deferred.md
proven: 2026-11-27
---

## What it is

Parks an issue so it leaves the counter but stays tracked. Logging it again counts a touch and nudges to bring it back.

## Parts

| What you see | What it does | Handle |
|---|---|---|
| `Deferred 1 entry. (cycle 1, threshold for nudge: 3 touches)` | `defer MATCH --reason "why"` | `cmd_defer` |
| `Touched [deferred]: ... (cycle 1, 1x of 3)` | A re-log of the same entry | `fi_handle_deferred_touch` |
| `Promoted [deferred] → [open]:` | `promote-deferred MATCH` | `cmd_promote_deferred` |
| `--until pr:org/repo#N or date:YYYY-MM-DD`, `--mute-until` | Wake-up trigger, or silence nudges | `cmd_defer` |

## How to get to it

`/found-issues:defer` with a path:line or a distinctive fragment.

## Driving it

Run the whole block as one shell call:

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new defer)"
$F run "$SB" "found-issues log 'src/util.py:2 — divide has no zero check'"
$F run "$SB" "found-issues defer 'zero check' --reason 'wait for a second report' && found-issues status --format=plain"
$F run "$SB" "for i in 1 2 3; do found-issues log 'src/util.py:2 — divide has no zero check'; done"
$F run "$SB" "found-issues promote-deferred 'zero check' && found-issues list"
$F snap "$SB" final
$F rm "$SB"
```

## What proves it works

- After defer the count is `0 open`.
- The third touch prints `(at threshold)` and, on stderr, `Consider: found-issues promote-deferred --match src/util.py:2`.
- After promoting, `list` shows the entry `[open]` with its `(reason:)` and `(touched:)` history.

## Gotchas

The line printed after `Promoted [deferred] → [open]:` is the entry as it was before. Same-day touches each count. Not driven in the proving run: `--until`, `--mute-until`, a second cycle and the critical auto-promote.
