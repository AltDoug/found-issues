---
feature: Ledger entries shown to the agent
also-called: session-start, first-touch, SessionStart
sources:
  - hooks/session-start.sh
  - hooks/first-touch.sh
  - lib/session-context.sh
  - lib/rules-full.md
  - skills/rules/SKILL.md
proven-with: hand-built hook payloads (no Claude Code or Codex)
proven: 2026-11-27
proven-hash: 63beb74e1127
---

## What it is

At the start of a session the agent receives the logging rules, the counts, the critical entries and the few whose location is not a file, and the ledger is synced quietly. Later, the first time the session reads or edits a file, it is shown that file's open entries.

## Parts

| What you see | What it does | Drive it by |
|---|---|---|
| `# found-issues — agent rules` | The rules block | a `session-start` payload with `"source":"startup"` |
| `## found-issues — 1 critical · 2 other` | Counts and selected entries, fenced as untrusted data | the same payload, with entries logged |
| Nothing | A resumed session gets no injection | `"source":"resume"` |
| `found-issues: open entries for src/util.py.` | One file's entries, once per session | a `first-touch` payload for a Read of that file |
| The entries again | Compaction or clear forgets what was shown | `session-start` with `"source":"compact"` or `"clear"` |
| How much is injected | `standard`, `lean`, `full` | `FOUND_ISSUES_SESSION_CONTEXT=lean` before the hook name |

## How to get to it

Claude Code or Codex runs it on SessionStart, and `first-touch` after Read, Edit, Write and MultiEdit (PostToolUse).

## Driving it

Session start: the critical and the topic entry are injected, the ordinary file entry is not.

```bash
set -eo pipefail
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new session-context)"; trap '$F rm "$SB"' EXIT
$F registered "$SB" SessionStart session-start
$F run "$SB" "found-issues log --critical 'src/app.sh:3 — empty name'; found-issues log 'src/util.py:2 — no zero check'; found-issues log 'release/naming — two names'"
$F hook "$SB" session-start '{"session_id":"s9","source":"startup","cwd":"__REPO__"}'
$F has "$SB" '# found-issues — agent rules'
$F has "$SB" '## found-issues — 1 critical · 2 other'
$F has "$SB" 'src/app.sh:3 — empty name'
$F has "$SB" 'release/naming — two names'
$F lacks "$SB" 'no zero check'
$F hook "$SB" session-start '{"session_id":"s9","source":"resume","cwd":"__REPO__"}'
$F silent "$SB"
```

First touch: shown once, shown again after a compaction, nothing for a file with no entry.

```bash
set -eo pipefail
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new first-touch)"; trap '$F rm "$SB"' EXIT
$F registered "$SB" PostToolUse first-touch Read
$F run "$SB" "found-issues log 'src/util.py:2 — divide has no zero check'"
READ='{"session_id":"s9","cwd":"__REPO__","hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"__REPO__/src/util.py"}}'
$F hook "$SB" first-touch "$READ"
$F has "$SB" 'found-issues: open entries for src/util.py.'
$F has "$SB" 'divide has no zero check'
$F hook "$SB" first-touch "$READ"
$F silent "$SB"
$F hook "$SB" session-start '{"session_id":"s9","source":"compact","cwd":"__REPO__"}' >/dev/null
$F hook "$SB" first-touch "$READ"
$F has "$SB" 'divide has no zero check'
$F hook "$SB" first-touch '{"session_id":"s9","cwd":"__REPO__","hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"__REPO__/src/app.sh"}}'
$F silent "$SB"
```

## What proves it works

- Startup output has the rules, the counts line, the critical entry and the topic entry, and **not** the ordinary `src/util.py` entry. A resume prints nothing.
- First touch prints JSON `additionalContext` quoting the entry, then nothing, then the entry again after `compact`.

## Gotchas

- The session-start hook takes the CLI from `FOUND_ISSUES_BIN`, then PATH, and only then the copy beside it, so outside the sandbox it silently runs the installed plugin (`FOUND_ISSUES_DEBUG_BIN=1` prints which one).
- First touch fails open: any problem is silence with exit 0, so check the payload before blaming the hook.
- Session start runs `sync` only when the ledger has an `[open]` entry, or a `[deferred]` one with `(until: pr:...)` or `(until: date:...)`. A fixture with neither proves nothing about sync-on-start.
- A fresh sandbox HOME also prints the one-time setup hint.
- Not driven: sync-on-start, `lean` and `full`, `clear`, Codex output and its `apply_patch` path form, and the auto-fix summary and statusline nudges. The `hooks.json` lines are read, not fired.
