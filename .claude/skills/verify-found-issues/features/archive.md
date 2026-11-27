---
feature: Archive old fixed entries
also-called: archive, /found-issues:archive
sources:
  - lib/archive.sh
  - commands/archive.md
proven: 2026-11-27
---

## What it is

Moves old `[fixed]` entries into `docs/found-issues-archive.md` so the active ledger stays short.

## Parts

| What you see | What it does | Handle |
|---|---|---|
| `archive (dry-run): would move N entries to ...` | `--dry-run` | `cmd_archive` |
| `archive: moved N entries from ... to ...` | The move | `cmd_archive` |
| `--days N`, `--count N` | Age and count thresholds (30 and 50) | `cmd_archive` |

## How to get to it

`/found-issues:archive`; an explicit sync also runs it when a threshold is passed.

## Driving it

Run the whole block as one shell call:

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new archive)"
$F run "$SB" "found-issues log 'src/util.py:2 — one' && found-issues log 'src/util.py:6 — two' && found-issues resolve 'one' --verified review"
$F snap "$SB" before
$F run "$SB" 'found-issues archive --dry-run --count=0 && found-issues archive --count=0'
$F snap "$SB" after
$F rm "$SB"
```

## What proves it works

- The dry run says it would move 1 entry; the real run says it moved 1.
- `after.found-issues-archive.md` holds the `[fixed]` line; `after.found-issues.md` keeps only the open one.

## Gotchas

None known. Not driven in the proving run: the `--days` threshold and the refusal on merge-conflict markers.
