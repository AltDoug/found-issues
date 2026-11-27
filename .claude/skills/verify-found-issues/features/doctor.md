---
feature: Health check
also-called: doctor, /found-issues:doctor, is it wired
sources:
  - lib/doctor.sh
  - commands/doctor.md
  - lib/detect-mode.sh
proven: 2026-11-27
---

## What it is

One report of whether the install is healthy: ledger, CLI, statusline, gh, mode, auto-fix and opt-outs.

## Parts

| What you see | What it does | Handle |
|---|---|---|
| `found-issues doctor — v3.11.0` | Report header | `cmd_doctor` |
| Sections `Source file health`, `Plugin runtime`, `Statusline`, `gh CLI`, `Mode detection`, `Auto-fix`, `Hook opt-outs`, `Issues file` | One area each, lines marked ✓, ! or ✗ | `lib/doctor.sh` |
| `Recommended next` | Follow-ups | `lib/doctor.sh` |

## How to get to it

`/found-issues:doctor`.

## Driving it

Run the whole block as one shell call:

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new doctor)"
$F run "$SB" "found-issues log 'src/util.py:2 — no zero check' >/dev/null; found-issues doctor"
$F rm "$SB"
```

## What proves it works

- Exit 0; `CLI:` and `lib dir:` name this checkout; `Detected mode: git`; `open: 1`.
- Auto-fix reads `off — FOUND_ISSUES_AUTOFIX=off`.

## Gotchas

In the sandbox, `gh authenticated as unknown` and `claude (version unknown)` come from the mock and the refusing stand-ins. Not driven in the proving run: a ledger with conflict markers and a broken statusline.
