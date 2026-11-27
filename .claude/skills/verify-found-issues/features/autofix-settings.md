---
feature: Auto-fix settings and status
also-called: config, autofix status, autofix ready
sources:
  - lib/autofix-config.sh
  - lib/autofix-status.sh
  - lib/autofix-ready.sh
proven: 2026-11-27
proven-hash: 198b5059965c
---

## What it is

Reads and sets auto-fix options in git config, and says whether this repo is able to run it. Auto-fix itself stays off while verifying (the runs are in autofix-runs.md).

## Parts

| What you see | What it does | Drive it by |
|---|---|---|
| Every `found-issues.*` setting with its source | Lists settings | `found-issues config` |
| `Set found-issues.autofix.dailyFixes = 3 (local)` | Sets one, validated | `config autofix.dailyFixes 3` |
| `takes a whole number of 1 or more` (exit 2) | Refuses a bad value | `config autofix.dailyFixes abc` |
| A `verdict:` line | Why auto-fix can or cannot run here | `found-issues autofix ready` |
| Queued, running, done today | The queue | `autofix status`, in a GitHub repo |
| A switch for every repo | Stops and resumes auto-fix | `autofix off`, `autofix on` |

## How to get to it

`/found-issues:setup` for the opt-in; the commands at a shell.

## Driving it

```bash
set -eo pipefail
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new autofix-settings)"; trap '$F rm "$SB"' EXIT
$F run "$SB" 'found-issues config'
$F match "$SB" '^found-issues\.autofix\.dailyFixes +5 +\(default\)$'
$F run "$SB" 'found-issues config autofix.dailyFixes 3'
$F is "$SB" 'Set found-issues.autofix.dailyFixes = 3 (local)'
$F run "$SB" 'git config --get found-issues.autofix.dailyFixes'
$F is "$SB" '3'
$F run "$SB" 'found-issues config autofix.dailyFixes abc' || true
$F rc "$SB" 2
$F has "$SB" 'takes a whole number of 1 or more'
$F run "$SB" 'git config --get found-issues.autofix.dailyFixes'
$F is "$SB" '3'
$F run "$SB" 'found-issues autofix ready'
$F has "$SB" 'auto-fix: off (FOUND_ISSUES_AUTOFIX=off)'
$F has "$SB" 'verdict: waiting: no test command'
$F run "$SB" 'found-issues autofix status' || true
$F rc "$SB" 1
$F has "$SB" 'autofix: not in a GitHub repo'
```

## What proves it works

- The default is listed, the set value is read back from git config, and the bad value exits 2 and leaves it.
- `ready` says auto-fix is off by the environment and waits for a test command.
- With no GitHub remote, `status` exits 1.

## Gotchas

- Not driven: `autofix on` and `off` (the kill switch), `summary`, and `status` inside a `--github` sandbox.
- Never drop `FOUND_ISSUES_AUTOFIX=off` to see another verdict.
