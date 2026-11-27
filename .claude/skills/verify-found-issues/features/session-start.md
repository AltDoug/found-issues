---
feature: Session start context
also-called: SessionStart, the rules injection, what the agent sees at start
sources:
  - hooks/session-start.sh
  - lib/session-context.sh
  - lib/rules-full.md
  - skills/rules/SKILL.md
proven: 2026-11-27
---

## What it is

At the start of a session the agent receives the logging rules, the counts, and only the critical entries plus a few whose location is not a file. It also syncs quietly.

## Parts

| What you see | What it does | Handle |
|---|---|---|
| `# found-issues — agent rules` | The rules block | `__fi_rules_body` |
| `## found-issues — 1 critical · 2 other` | Counts and selected entries, fenced as untrusted data | `lib/session-context.sh` |
| `FOUND_ISSUES_SESSION_CONTEXT` = `standard`, `lean`, `full` | How much is injected | `fi_ss_mode` |
| `source` = `resume` | Injects nothing | `fi_ss_inject` |
| `source` = `compact` or `clear` | Forgets which files first-touch already showed | `hooks/session-start.sh` |

## How to get to it

Claude Code or Codex runs it on SessionStart.

## Driving it

Run the whole block as one shell call:

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new session-context)"
$F run "$SB" "found-issues log --critical 'src/app.sh:3 — empty name'; found-issues log 'src/util.py:2 — no zero check'; found-issues log 'release/naming — two names'"
$F hook "$SB" session-start '{"session_id":"s9","source":"startup","cwd":"__REPO__"}'
$F hook "$SB" session-start '{"session_id":"s9","source":"resume","cwd":"__REPO__"}'
$F rm "$SB"
```

## What proves it works

- Startup output has the rules, the counts line, the critical entry and the topic entry, and **not** the `src/util.py` entry.
- The resume call prints nothing and exits 0.

## Gotchas

The hook takes the CLI from `FOUND_ISSUES_BIN`, then PATH, and only then the copy beside it, so outside the sandbox it silently runs the installed plugin (`FOUND_ISSUES_DEBUG_BIN=1` prints which one). A fresh sandbox HOME also prints the one-time setup hint. Not driven in the proving run: `lean` and `full`, Codex output, the auto-fix summary and statusline nudges.
