---
feature: Health check
also-called: doctor, /found-issues:doctor, fi-doctor
sources:
  - lib/doctor.sh
  - commands/doctor.md
  - codex-skills/fi-doctor/
proven-with: mock gh and refusing stand-ins for claude and codex
proven: 2026-11-27
---

## What it is

One report of whether the install is healthy: ledger, CLI, statusline, gh, mode, auto-fix and opt-outs.

## Parts

| What you see | What it does | Drive it by |
|---|---|---|
| `found-issues doctor — v3.11.0` | Report header | `found-issues doctor` |
| Sections `Source file health`, `Plugin runtime`, `Statusline`, `gh CLI`, `Mode detection`, `Auto-fix`, `Hook opt-outs`, `Issues file` | One area each, lines marked ✓, ! or ✗ | read the section |
| `✗ Source file has merge conflict markers` | A broken ledger, with line numbers | a ledger holding `<<<<<<<` |
| `Recommended next` | Follow-ups | the end of the report |

## How to get to it

`/found-issues:doctor`.

## Driving it

A healthy ledger first, then one with merge conflict markers, which it must name.

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new doctor)"; trap '$F rm "$SB"' EXIT
$F run "$SB" "found-issues log 'src/util.py:2 — no zero check' >/dev/null; found-issues doctor"
$F has "$SB" 'found-issues doctor — v'
$F has "$SB" "CLI: $(git rev-parse --show-toplevel)/bin/found-issues"
$F has "$SB" "lib dir: $(git rev-parse --show-toplevel)/lib"
$F has "$SB" 'Detected mode: git'
$F has "$SB" 'Auto-fix: off — FOUND_ISSUES_AUTOFIX=off'
$F has "$SB" 'open: 1 (critical: 0'
$F has "$SB" '(no conflict markers)'
$F run "$SB" "printf '<<<<<<< HEAD\n=======\n>>>>>>> other\n' >> docs/found-issues.md; found-issues doctor || true"
$F has "$SB" '✗ Source file has merge conflict markers'
$F has "$SB" '<<<<<<< HEAD'
```

## What proves it works

- `CLI:` and `lib dir:` name this checkout, the mode and the open count match the sandbox, and auto-fix reads off.
- With conflict markers in the ledger the report says so with `✗`.

## Gotchas

- This is the product's own doctor, not the kit's: the kit's is `fi-sandbox.sh doctor`.
- In the sandbox, `gh authenticated as unknown` and `claude (version unknown)` come from the mock and the refusing stand-ins.
- Not driven: a broken statusline, GitHub modes, and the Codex trust lines.
