---
feature: Auto-fix settings and status
also-called: config, autofix off, autofix status, autofix ready, why is auto-fix waiting
sources:
  - lib/autofix-config.sh
  - lib/autofix-status.sh
  - lib/autofix-ready.sh
proven: 2026-11-27
---

## What it is

Reads and sets auto-fix options in git config, and says whether this repo is able to run it. Auto-fix itself stays off while verifying.

## Parts

| What you see | What it does | Handle |
|---|---|---|
| `config` | Every `found-issues.*` setting with its source | `cmd_config` |
| `Set found-issues.autofix.dailyFixes = 3 (local)` | `config KEY VALUE`, validated | `cmd_config` |
| `autofix ready` with a `verdict:` line | Why it can or cannot run here | `lib/autofix-ready.sh` |
| `autofix status` | Queued, running, done today | `cmd_autofix` |
| `autofix on, off` | Kill switch for every repo | `cmd_autofix` |

## How to get to it

`/found-issues:setup` for the opt-in; the commands at a shell.

## Driving it

Run the whole block as one shell call:

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new autofix-settings)"
$F run "$SB" 'found-issues config'
$F run "$SB" 'found-issues config autofix.dailyFixes 3 && git config --get found-issues.autofix.dailyFixes'
$F run "$SB" 'found-issues config autofix.dailyFixes abc' || true     # exit 2
$F run "$SB" 'found-issues autofix ready'
$F run "$SB" 'found-issues autofix status' || true
$F rm "$SB"
```

## What proves it works

- The set value is read back from git config; the bad value exits 2 with `takes a whole number of 1 or more`.
- `ready` prints `auto-fix: off (FOUND_ISSUES_AUTOFIX=off)` and `verdict: waiting: no test command ...`.
- In a sandbox with no GitHub remote, `status` says `autofix: not in a GitHub repo` and exits 1.

## Gotchas

Not driven in the proving run: `autofix on` and `off` (the kill switch file), `summary`, and `status` inside a `--github` sandbox.
