---
feature: Defer and revive
also-called: defer, /found-issues:defer, promote-deferred, /found-issues:promote-deferred
sources:
  - lib/defer.sh
  - lib/promote-deferred.sh
  - commands/defer.md
  - commands/promote-deferred.md
  - codex-skills/fi-defer/
  - codex-skills/fi-promote-deferred/
proven: 2026-11-27
---

## What it is

Parks an issue so it leaves the counter but stays tracked. Logging it again counts a touch and nudges to bring it back.

## Parts

| What you see | What it does | Drive it by |
|---|---|---|
| `Deferred 1 entry. (cycle 1, threshold for nudge: 3 touches)` | Parks the match | `defer MATCH --reason 'why'` |
| `Touched [deferred]: ... (cycle 1, 1x of 3)` | A re-log of the same entry | `log` with the same location and symptom |
| `(at threshold)`, `Consider: found-issues promote-deferred` | The nudge, on the third touch | three re-logs |
| `Promoted [deferred] → [open]:` | Brings it back | `promote-deferred MATCH` |
| A wake-up trigger, or silenced nudges | | `--until pr:org/repo#N` or `date:YYYY-MM-DD`; `--mute-until` |

## How to get to it

`/found-issues:defer` with a path:line or a distinctive fragment.

## Driving it

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new defer)"; trap '$F rm "$SB"' EXIT
L=docs/found-issues.md
$F run "$SB" "found-issues log 'src/util.py:2 — divide has no zero check'"
$F run "$SB" "found-issues defer 'zero check' --reason 'wait for a second report'"
$F has "$SB" 'Deferred 1 entry. (cycle 1, threshold for nudge: 3 touches)'
$F has "$SB" '- [deferred] ' "$L"
$F run "$SB" 'found-issues status --format=plain'
$F is "$SB" '0 open'
$F run "$SB" "for i in 1 2 3; do found-issues log 'src/util.py:2 — divide has no zero check'; done"
$F has "$SB" 'Touched [deferred] (at threshold)'
$F has "$SB" 'Consider: found-issues promote-deferred --match src/util.py:2'
$F count "$SB" 1 'src/util.py:2' "$L"
$F run "$SB" "found-issues promote-deferred 'zero check' && found-issues list"
$F has "$SB" 'Promoted [deferred] → [open]:'
$F match "$SB" '^- \[open\] .*divide has no zero check \(reason: wait for a second report\) \(touched: [0-9, -]+\)$' "$L"
$F snap "$SB" final
```

## What proves it works

- After defer the count is `0 open` and the line reads `[deferred]`.
- Three re-logs add no second line; the third prints `(at threshold)` and, on stderr, the `Consider:` command.
- After promoting, the ledger shows the entry `[open]` with its `(reason:)` and `(touched:)` history.

## Gotchas

- The line printed after `Promoted [deferred] → [open]:` is the entry as it was before.
- Same-day touches each count.
- Not driven: `--until`, `--mute-until`, a second cycle and the critical auto-promote.
