---
feature: Resolve by verification
also-called: close it, mark fixed, resolve --verified
sources:
  - lib/resolve.sh
proven: 2026-11-27
---

## What it is

Closes one entry because someone read the code and confirmed it is fixed. It is the only supported hand-close.

## Parts

| What you see | What it does | Handle |
|---|---|---|
| `Resolved 1 entry. (verified: review, fixed: DATE)` | `resolve MATCH --verified ai, review or human` | `cmd_resolve` |
| `resolve: no [open] entries match` (exit 1), `ambiguous match` (exit 2) | Refusals | `cmd_resolve` |
| `entry is on hold ... waits for a human` (exit 2) | `ai` cannot close a held entry | `cmd_resolve` |
| `--deferred` | Close a deferred entry | `cmd_resolve` |

## How to get to it

Used by the sync command's AI pass and by a person who checked the code.

## Driving it

Run the whole block as one shell call:

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new resolve)"
$F run "$SB" "found-issues log 'src/util.py:6 — first() raises on empty' && found-issues tag 'raises on empty' --hold 'needs a human'"
$F run "$SB" "found-issues resolve 'raises on empty' --verified ai" || true       # exit 2, held
$F run "$SB" "found-issues resolve 'nothing like this'" || true                   # exit 1
$F run "$SB" "found-issues resolve 'raises on empty' --verified review && found-issues list --status=all"
$F snap "$SB" final
$F rm "$SB"
```

## What proves it works

- The `ai` close exits 2 and changes nothing; the missing match exits 1.
- The `review` close flips the line to `[fixed]`, drops `(hold: ...)` and appends `(verified: review) (fixed: date)`.

## Gotchas

An entry with an active `(PR: ...)` is refused too (exit 4 in `lib/resolve.sh`), because sync closes it. Not driven in the proving run: that refusal and `--deferred`.
