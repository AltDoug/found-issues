---
feature: Stop reminder
also-called: stop-reminder, prompt-nudge, Stop hook error, found-issues-checked
sources:
  - hooks/stop-reminder.sh
  - hooks/prompt-nudge.sh
proven-with: hand-built hook payloads and transcripts (no Claude Code or Codex)
proven: 2026-11-27
proven-hash: a30b1b6de91c
---

## What it is

After a turn that changed files, the agent is reminded once per session to log what it noticed: silently with the next prompt by default, or as a visible block in `block` mode.

## Parts

| What you see | What it does | Drive it by |
|---|---|---|
| Nothing at Stop, then `your previous turn changed files` with the next prompt | Default mode | `stop-reminder`, then `prompt-nudge` with the same `session_id` |
| `Stop blocked: include a found-issues acknowledgment`, exit 2 | Block mode, after a code edit | `FOUND_ISSUES_STOP_REMINDER=block` before the hook name |
| `<!-- found-issues-checked: none-noticed -->` (or `logged`, `deferred`) | The marker that satisfies the block | put it in the transcript's assistant text |
| Nothing | A turn that only read files | a transcript whose only tool use is `Read` |
| Nothing | Switched off | `FOUND_ISSUES_STOP_REMINDER=off` |

## How to get to it

Fires on Stop; `prompt-nudge.sh` on UserPromptSubmit delivers the silent form.

## Driving it

The payload points at a transcript file in JSONL form. The block writes three: a turn that edited a file, the same turn with the marker, and a read-only turn.

```bash
set -eo pipefail
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new stop-nudge)"; trap '$F rm "$SB"' EXIT
$F registered "$SB" Stop stop-reminder
$F registered "$SB" UserPromptSubmit prompt-nudge
USER_LINE='{"type":"user","message":"fix it"}'
EDIT='{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"src/util.py"}}]}}'
MARK='{"type":"assistant","message":{"content":[{"type":"text","text":"done <!-- found-issues-checked: logged -->"}]}}'
READ='{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"src/util.py"}}]}}'
printf '%s\n' "$USER_LINE" "$EDIT" > "$SB/edited.jsonl"
printf '%s\n' "$USER_LINE" "$EDIT" "$MARK" > "$SB/marked.jsonl"
printf '%s\n' "$USER_LINE" "$READ" > "$SB/read.jsonl"
stop() { printf '{"session_id":"%s","transcript_path":"__SB__/%s.jsonl"}' "$1" "$2"; }
$F hook "$SB" stop-reminder "$(stop s-silent edited)"
$F silent "$SB"
$F hook "$SB" prompt-nudge '{"session_id":"s-silent","prompt":"next"}'
$F has "$SB" 'your previous turn changed files'
$F hook "$SB" prompt-nudge '{"session_id":"s-silent","prompt":"again"}'
$F silent "$SB"
$F hook "$SB" FOUND_ISSUES_STOP_REMINDER=block stop-reminder "$(stop s-block edited)" || true
$F rc "$SB" 2
$F has "$SB" 'Stop blocked: include a found-issues acknowledgment'
$F hook "$SB" FOUND_ISSUES_STOP_REMINDER=block stop-reminder "$(stop s-block edited)"
$F silent "$SB"
$F hook "$SB" FOUND_ISSUES_STOP_REMINDER=block stop-reminder "$(stop s-marked marked)"
$F silent "$SB"
$F hook "$SB" FOUND_ISSUES_STOP_REMINDER=block stop-reminder "$(stop s-read read)"
$F silent "$SB"
$F hook "$SB" FOUND_ISSUES_STOP_REMINDER=off stop-reminder "$(stop s-off edited)"
$F silent "$SB"
$F hook "$SB" prompt-nudge '{"session_id":"s-off","prompt":"next"}'
$F silent "$SB"
```

## What proves it works

- Default: Stop is silent; the first prompt-nudge prints the reminder, the second nothing.
- Block mode: exit 2 once, with the three markers on stderr, then silence for the same session.
- With the marker, after a read-only turn, or switched off, nothing blocks.

## Gotchas

- It stays silent when `CLAUDE_CODE_ENTRYPOINT` is set to anything but `cli`, so drive it only from the sandbox's empty environment. The same variable breaks the test suite: `tests/helpers.bash` does not unset it, so from an agent session 28 of 50 tests in `tests/stop-reminder.bats` and 2 of 37 in `tests/session-start.bats` failed (measured 2026-11-27 with the value `claude-desktop`; `tests/session-start.bats` then passed every test with it unset). Run those two files under `env -u CLAUDE_CODE_ENTRYPOINT`.
- Not driven: the Codex branch and the `none-noticed` and `deferred` marker words. The `hooks.json` lines are read, not fired.
