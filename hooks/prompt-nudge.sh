#!/usr/bin/env bash
# prompt-nudge.sh — UserPromptSubmit hook (3.2.1 stop-reminder hybrid).
#
# stop-reminder.sh blocks a Stop only when the session edited code. Any other
# substantive turn without the marker leaves one pending reminder,
# ~/.claude/found-issues/reminded/<session_id>.nudge. A Stop hook cannot
# reach the model without forcing another (billed) turn, so this hook hands
# the reminder over with the user's next prompt instead, once, and marks it
# delivered (<session_id>.nudged). Zero forks when nothing is pending.
#
# Exit code: 0 always. Output: hookSpecificOutput.additionalContext JSON.

set -euo pipefail

IFS= read -r -d '' input || true

re='"session_id"[[:space:]]*:[[:space:]]*"([^"]*)"'
[[ "$input" =~ $re ]] || exit 0
sid="${BASH_REMATCH[1]}"
case "$sid" in ""|*[!A-Za-z0-9._-]*) exit 0 ;; esac   # a file name, nothing else
pending="$HOME/.claude/found-issues/reminded/$sid.nudge"
[[ -f "$pending" ]] || exit 0
mv -f "$pending" "${pending}d" 2>/dev/null || exit 0

printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"found-issues: your previous turn changed files but ended without a found-issues acknowledgment. If you noticed any defect OUTSIDE that task (a bug, a broken contract, dead code, misleading docs), log it with /found-issues:log. End this reply with one of <!-- found-issues-checked: none-noticed --> | <!-- found-issues-checked: logged --> | <!-- found-issues-checked: deferred -->."}}'
exit 0
