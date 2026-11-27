---
feature: Counts and list
also-called: status, the count, N critical · N other, list, show me the critical ones
sources:
  - lib/list-status.sh
  - lib/parse-entries.sh
  - commands/status.md
proven: 2026-11-27
---

## What it is

Shows how many entries are open, by bucket, and prints the entries themselves. Both only read.

## Parts

| What you see | What it does | Handle |
|---|---|---|
| `status --format=plain` | `1 critical · 3 other`, `2 issues`, or `0 open` | `cmd_status` |
| `status --format=json` | `critical`, `issues`, `in_pr`, `stale`, `total_open`, `decisions`, `running` | `cmd_status` |
| `status --format=segment` | The colored ` \| ...` piece for a statusline (the default format), with `❓N` for open decisions | `cmd_status` |
| `list` | Open entries, verbatim | `cmd_list` |
| `list --status=open, deferred, fixed or all` | Filter | `cmd_list` |
| `list --path FILE` | One file's open entries | `fi_sc_entries_for_path` |
| `list --json` | One object per entry (`path`, `line`, `critical`, `status`, ...) | `fi_entry_to_json` |
| `--cwd DIR` | Which repo to read | `cmd_list`, `cmd_status` |

## How to get to it

`/found-issues:status` in a session, or either command at a shell.

## Driving it

Run the whole block as one shell call:

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new counts)"
$F run "$SB" "found-issues log --critical 'src/app.sh:3 — empty name'; found-issues log 'src/util.py:2 — no zero check'"
$F run "$SB" 'found-issues status --format=plain'
$F run "$SB" 'found-issues status --format=json'
$F run "$SB" 'found-issues status --format=segment | cat -v'
$F run "$SB" "found-issues list --json | jq -c '.[] | {path,line,critical,status}'"
$F run "$SB" 'found-issues list --path src/util.py'
$F run "$SB" 'found-issues list --status=bogus' || true   # exit 2
$F rm "$SB"
```

## What proves it works

- Plain reads `1 critical · 1 other`; JSON has `"critical":1,"issues":1,"total_open":2`.
- The segment starts ` | ` and shows ANSI codes under `cat -v`.
- `list --path` prints only the `src/util.py` line; the bogus filter exits 2.

## Gotchas

`CLAUDE_PROJECT_DIR` wins over the current folder for both commands (`--cwd` wins over it). The segment is cached (`lib/segment-cache.sh`). `symptom` in `--json` is cut at the first parenthesis; match on `raw`.
