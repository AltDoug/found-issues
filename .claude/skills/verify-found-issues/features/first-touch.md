---
feature: File entries on first touch
also-called: first-touch, entries for a file appear when you open it
sources:
  - hooks/first-touch.sh
  - lib/session-context.sh
proven: 2026-11-27
---

## What it is

The first time a session reads or edits a file, the agent is shown that file's open entries.

## Parts

| What you see | What it does | Handle |
|---|---|---|
| `found-issues: open entries for src/util.py.` | Injected once per file per session | `hooks/first-touch.sh` |
| No output | Already shown, no entries, or no ledger | session file under the cache folder |

## How to get to it

Fires after Read, Edit, Write and MultiEdit (PostToolUse).

## Driving it

Run the whole block as one shell call:

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new first-touch)"
$F run "$SB" "found-issues log 'src/util.py:2 — divide has no zero check'"
READ='{"session_id":"s9","cwd":"__REPO__","hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"__REPO__/src/util.py"}}'
$F hook "$SB" first-touch "$READ"
$F hook "$SB" first-touch "$READ"      # silent
$F hook "$SB" session-start '{"session_id":"s9","source":"compact","cwd":"__REPO__"}' >/dev/null
$F hook "$SB" first-touch "$READ"      # shown again
$F rm "$SB"
```

## What proves it works

- First call: JSON `additionalContext` quoting the entry. Second: nothing. After the compact event: the entry again.
- All of it is in `transcript.txt`.

## Gotchas

It fails open: any problem is silence with exit 0, so check the payload first. Not driven in the proving run: the Codex `apply_patch` path form.
