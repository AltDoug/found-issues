---
feature: Log an issue
also-called: log it, /found-issues:log, /fi log, fi-log
sources:
  - lib/log.sh
  - lib/canonicalize.sh
  - commands/log.md
  - bin/found-issues
proven: 2026-11-27
---

## What it is

Records a defect noticed outside the current task as one `[open]` line in the repo's ledger. A repeat of the same location and symptom is not added twice.

## Parts

| What you see | What it does | Handle |
|---|---|---|
| `Logged: - [open] ...` | A new entry was appended | `cmd_log` |
| `Skipped — already logged:` | Duplicate of an open entry | `fi_dedup_key_v` |
| `Touched [deferred]:` | Matched a deferred entry (see defer.md) | `fi_handle_deferred_touch` |
| `--critical` | `[!]` flag; must come first. On an open entry it prints `Escalated to critical:` | `cmd_log` |
| `--fix small, medium or large`, `--decide "question"`, `--manual "why"` | The one fix tag; must come before the entry | `fi_tag_resolve` |
| Location | `path:line`, `path:23-49`, a bare path, or a topic such as `release/naming` | `cmd_log` |

## How to get to it

In an agent session the model runs `/found-issues:log`; at a shell it is `found-issues log`. The count line is printed after every log.

## Driving it

Run the whole block as one shell call:

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new log-an-issue)"
$F run "$SB" "found-issues log 'src/util.py:2 — divide has no zero check (suggested: guard b == 0)'"
$F run "$SB" "found-issues log 'src/util.py:2 — divide has no zero check'"          # duplicate
$F run "$SB" "found-issues log --critical 'src/app.sh:3 — greets with an empty name'"
$F run "$SB" "found-issues log --fix small 'src/util.py:6 — first() raises IndexError'"
$F run "$SB" "found-issues log 'src/util.py:2 - hyphen instead of em dash'" || true  # exit 2
$F run "$SB" "found-issues log 'src/util.py:9,12 — bad line spec'" || true          # exit 2
$F snap "$SB" after-log
$F rm "$SB"
```

## What proves it works

- First call prints `Logged:` and `1 issue`; the duplicate prints `Skipped — already logged:` and exits 0.
- After the critical one the count reads `1 critical · 1 other`.
- Both bad inputs exit 2 with a message on stderr and add nothing.
- `after-log.found-issues.md` holds exactly the three entries, with `(suggested: ...)` and `(fix: small)` at the end of their lines.

## Gotchas

A symptom that ends in any annotation other than `(suggested: ...)` is refused. `FOUND_ISSUES_TODAY` does not change the date `log` writes. Not driven in the proving run: the off-limits path rewrite to `(manual: ...)` and local mode (`--local`, root `.found-issues.md`).
