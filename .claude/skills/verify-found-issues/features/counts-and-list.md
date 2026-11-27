---
feature: Counts and list
also-called: status, list, /found-issues:status, fi-status
sources:
  - lib/list-status.sh
  - commands/status.md
  - codex-skills/fi-status/
proven: 2026-11-27
proven-hash: 8f704cbdfd35
---

## What it is

Shows how many entries are open, by bucket, and prints the entries themselves. Both only read.

## Parts

| What you see | What it does | Drive it by |
|---|---|---|
| `1 critical · 3 other`, `2 issues`, `0 open` | The count in plain words | `status --format=plain` |
| `{"critical":1,"issues":1,...}` | The same as JSON, with `in_pr`, `stale`, `total_open`, `decisions`, `running` | `status --format=json` |
| A colored ` \| ...` piece, `❓N` for open decisions | The piece for a statusline (the default format) | `status --format=segment` |
| Entry lines, verbatim | Open entries | `list` |
| Only some statuses | Filter | `list --status=open`, `deferred`, `fixed` or `all` |
| One file's open entries | Filter by file | `list --path FILE` |
| One JSON object per entry (`path`, `line`, `critical`, `status`, ...) | For scripts | `list --json` |
| Another repo's ledger | Which repo to read | `--cwd DIR` |

## How to get to it

`/found-issues:status` in a session, or either command at a shell.

## Driving it

```bash
set -eo pipefail
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new counts)"; trap '$F rm "$SB"' EXIT
$F run "$SB" "found-issues log --critical 'src/app.sh:3 — empty name'; found-issues log 'src/util.py:2 — no zero check'"
$F run "$SB" 'found-issues status --format=plain'
$F is "$SB" '1 critical · 1 other'
$F run "$SB" 'found-issues status --format=json'
$F has "$SB" '"critical":1,"issues":1,"in_pr":0,"stale":0,"total_open":2'
$F run "$SB" 'found-issues status --format=segment | cat -v'
$F match "$SB" '^ \| \^\[\[1;31m1 critical\^\[\[0m'
$F run "$SB" 'CLAUDE_PROJECT_DIR=/nonexistent found-issues status --format=plain --cwd "$REPO"'
$F is "$SB" '1 critical · 1 other'
$F run "$SB" "found-issues list --json | jq -c '.[] | {path,line,critical,status}'"
$F has "$SB" '{"path":"src/app.sh","line":3,"critical":true,"status":"open"}'
$F has "$SB" '{"path":"src/util.py","line":2,"critical":false,"status":"open"}'
$F run "$SB" 'found-issues list --path src/util.py'
$F has "$SB" 'src/util.py:2 — no zero check'
$F lacks "$SB" 'src/app.sh'
$F run "$SB" 'found-issues list --status=fixed'
$F lacks "$SB" '- [open]'
$F run "$SB" 'found-issues list --status=bogus' || true
$F rc "$SB" 2
$F has "$SB" 'invalid --status: bogus'
```

## What proves it works

- Plain reads `1 critical · 1 other`; JSON has one critical, one other, two open in total.
- The segment starts ` | ` and shows ANSI codes under `cat -v`. `--cwd` wins over a wrong `CLAUDE_PROJECT_DIR`.
- `list --path` prints only that file's entry; the bogus filter exits 2.

## Gotchas

- `CLAUDE_PROJECT_DIR` wins over the current folder for both commands (`--cwd` wins over it).
- The segment is cached (`lib/segment-cache.sh`).
- `symptom` in `--json` is cut at the first parenthesis; match on `raw`.
- A hand-written fixture entry needs today's date: after 30 days the label changes (`1 issue` becomes `1 other · 1 stale`).
- Not driven: the `stale` and `in_pr` buckets and the `❓N` mark.
