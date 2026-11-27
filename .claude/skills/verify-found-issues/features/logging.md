---
feature: Log an issue
also-called: /found-issues:log, fi-log
sources:
  - lib/log.sh
  - commands/log.md
  - codex-skills/fi-log/
proven: 2026-11-27
proven-hash: a94d8ff75444
---

## What it is

Records a defect noticed outside the current task as one `[open]` line in the repo's ledger. A repeat of the same location and symptom is not added twice.

## Parts

| What you see | What it does | Drive it by |
|---|---|---|
| `Logged: - [open] ...` | A new entry was appended | `found-issues log 'path:line — symptom (suggested: fix)'` |
| `Skipped — already logged:` | Duplicate of an open entry | the same location and symptom again |
| `Touched [deferred]:` | Matched a deferred entry (see defer.md) | re-log a deferred entry |
| `[open] [!]`, `Escalated to critical:` | The critical flag; on an entry already open it escalates | `--critical`, first argument |
| `(fix: small)`, `(decide: ...)`, `(manual: ...)` | The one fix tag, before the entry | `--fix small`, `--decide 'question'`, `--manual 'why'` |
| `(manual: off-limits: ...)` | A fix tag on a CI file or an untracked file is rewritten, with a note on stderr | `--fix small` on a path git does not track |
| Location | `path:line`, `path:23-49`, a bare path, or a topic such as `release/naming` | the text before ` — ` |
| `.found-issues.md` at the root | Local mode, for a folder with no git | `new <slug> --local` |

## How to get to it

In an agent session the model runs `/found-issues:log`; at a shell it is `found-issues log`. The count line is printed after every log.

## Driving it

A log, a duplicate, a critical one, a tagged one, two bad inputs, then the ledger on disk.

```bash
set -eo pipefail
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new log-an-issue)"; trap '$F rm "$SB"' EXIT
L=docs/found-issues.md
$F run "$SB" "found-issues log 'src/util.py:2 — divide has no zero check (suggested: guard b == 0)'"
$F has "$SB" 'Logged: - [open] '
$F has "$SB" '1 issue'
$F run "$SB" "found-issues log 'src/util.py:2 — divide has no zero check'"
$F has "$SB" 'Skipped — already logged:'
$F count "$SB" 1 '- [open] ' "$L"
$F run "$SB" "found-issues log --critical 'src/app.sh:3 — greets with an empty name'"
$F has "$SB" '1 critical · 1 other'
$F run "$SB" "found-issues log --fix small 'src/util.py:6 — first() raises IndexError'"
$F has "$SB" '1 critical · 2 other'
$F run "$SB" "found-issues log 'src/util.py:2 - hyphen instead of em dash'" || true
$F rc "$SB" 2
$F has "$SB" "missing ' — ' separator"
$F run "$SB" "found-issues log 'src/util.py:9,12 — bad line spec'" || true
$F rc "$SB" 2
$F has "$SB" 'invalid line spec'
$F snap "$SB" after-log
$F count "$SB" 3 '- [open] ' "$L"
$F has "$SB" 'src/util.py:2 — divide has no zero check (suggested: guard b == 0)' "$L"
$F has "$SB" '- [open] [!] ' "$L"
$F has "$SB" 'src/util.py:6 — first() raises IndexError (fix: small)' "$L"
```

The off-limits rewrite, and local mode in a folder with no git.

```bash
set -eo pipefail
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new log-offlimits)"; trap '$F rm "$SB"' EXIT
$F run "$SB" "echo x > untracked.py && found-issues log --fix small 'untracked.py:1 — not in git'"
$F has "$SB" 'is off-limits for auto-fix (off-limits: untracked)'
$F has "$SB" '(manual: off-limits: untracked)' docs/found-issues.md
$F lacks "$SB" '(fix: small)' docs/found-issues.md
```

```bash
set -eo pipefail
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new log-local --local)"; trap '$F rm "$SB"' EXIT
$F run "$SB" "found-issues log 'src/util.py:2 — local mode entry' && found-issues status --format=plain"
$F has "$SB" '1 issue'
$F has "$SB" 'src/util.py:2 — local mode entry' .found-issues.md
$F gone "$SB" docs/found-issues.md
```

## What proves it works

- The first call prints `Logged:` and `1 issue`; the duplicate prints `Skipped — already logged:` and adds nothing.
- Both bad inputs exit 2 with their message and add nothing: the ledger holds exactly three entries, tags at the end of their lines.
- A tag on an untracked file lands as `(manual: off-limits: untracked)`. With no git the ledger is `.found-issues.md` at the root.
- Evidence: `transcript.txt` and `after-log.found-issues.md`.

## Gotchas

- A symptom that ends in any annotation other than `(suggested: ...)` is refused.
- `FOUND_ISSUES_TODAY` does not change the date `log` writes.
- Not driven: `--decide` and `--manual` here (`--decide` is in tags-and-decisions.md), `--critical` on an entry already open, the CI-file form of the off-limits rewrite, and a range or bare-path location.
