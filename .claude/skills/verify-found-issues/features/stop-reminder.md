---
feature: Stop reminder
also-called: stop hook, the nudge, Stop hook error, found-issues-checked marker, prompt-nudge
sources:
  - hooks/stop-reminder.sh
  - hooks/prompt-nudge.sh
proven: 2026-11-27
---

## What it is

After a turn that changed files, the agent is reminded once per session to log what it noticed: silently with the next prompt by default, or as a visible block in `block` mode.

## Parts

| What you see | What it does | Handle |
|---|---|---|
| Nothing at Stop, then `your previous turn changed files` with the next prompt | Default (`on`) | `<session>.nudge` then `.nudged` under `~/.claude/found-issues/reminded/` |
| `Stop blocked: include a found-issues acknowledgment` and exit 2 | `FOUND_ISSUES_STOP_REMINDER=block`, after a code edit | `hooks/stop-reminder.sh` |
| `<!-- found-issues-checked: none-noticed -->` | Marker that satisfies the block (`logged`, `deferred`) | `text_has_marker` |
| `FOUND_ISSUES_STOP_REMINDER=off` | Disabled | `hooks/stop-reminder.sh` |

## How to get to it

Fires on Stop; `prompt-nudge.sh` on UserPromptSubmit delivers the silent form.

## Driving it

The payload points at a transcript file in JSONL form: a user line, then an assistant line with a `tool_use` block.

Run the whole block as one shell call:

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new stop-nudge)"
$F run "$SB" 'printf "%s\n" "{\"type\":\"user\",\"message\":\"fix it\"}" "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Edit\",\"input\":{\"file_path\":\"src/util.py\"}}]}}" > "$SB/transcript.jsonl"'
$F hook "$SB" stop-reminder '{"session_id":"s-silent","transcript_path":"__SB__/transcript.jsonl"}'
$F hook "$SB" prompt-nudge '{"session_id":"s-silent","prompt":"next"}'
$F hook "$SB" prompt-nudge '{"session_id":"s-silent","prompt":"again"}'
$F hook "$SB" FOUND_ISSUES_STOP_REMINDER=block stop-reminder '{"session_id":"s-block","transcript_path":"__SB__/transcript.jsonl"}' || true   # exit 2
$F hook "$SB" FOUND_ISSUES_STOP_REMINDER=block stop-reminder '{"session_id":"s-block","transcript_path":"__SB__/transcript.jsonl"}'          # exit 0
$F rm "$SB"
```

## What proves it works

- Default: Stop is silent with exit 0; the first prompt-nudge prints the reminder JSON, the second prints nothing.
- Block mode: exit 2 once with the three markers on stderr, then exit 0 for the same session.

## Gotchas

It stays silent when `CLAUDE_CODE_ENTRYPOINT` is set to anything but `cli`, which is why it must be driven from the sandbox's empty environment. Not driven in the proving run: the marker passing the block, read-only turns and the Codex branch.
