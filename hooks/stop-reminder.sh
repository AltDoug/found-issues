#!/usr/bin/env bash
# stop-reminder.sh — Stop hook
#
# Forces <!-- found-issues-checked: ... --> marker on every assistant turn.
# This is the discipline-enforcer that creates the proactive logging habit.
#
# Hook event: Stop
# Exit codes:
#   0  — allow stop (marker present, or check skipped)
#   2  — block stop (marker missing); message to stderr
#
# Stdin: JSON describing the hook event including transcript_path.

set -euo pipefail

# Allow opt-out via env var (for users who installed but want it off)
if [[ "${FOUND_ISSUES_STOP_REMINDER:-on}" == "off" ]]; then
  exit 0
fi

# Read JSON from stdin
input="$(cat)"

# Honor stop_hook_active: when Claude Code re-fires Stop after a previous
# block, the assistant has already had its chance to add the marker. Exit
# 0 to break the loop. Required because Claude Code fires Stop *before*
# the final assistant text is flushed to the transcript file (tool
# results stream as tools run, but the closing text is buffered until
# end-of-turn), so the marker check below can race even when the
# assistant included the marker. Other Stop hooks in the wild (e.g.
# stop-tests-pass.sh) follow this same pattern.
stop_hook_active=""
if command -v jq >/dev/null 2>&1; then
  stop_hook_active="$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || true)"
fi
if [[ -z "$stop_hook_active" || "$stop_hook_active" == "false" ]]; then
  # Fallback: grep for the literal flag in the input
  if printf '%s' "$input" | grep -qE '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
    stop_hook_active="true"
  fi
fi
if [[ "$stop_hook_active" == "true" ]]; then
  exit 0
fi

# Extract transcript_path
transcript_path=""
if command -v jq >/dev/null 2>&1; then
  transcript_path="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
fi
if [[ -z "$transcript_path" ]]; then
  # Fallback: grep extraction
  transcript_path="$(printf '%s' "$input" \
    | grep -oE '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' \
    | head -1)"
fi

# If we can't find the transcript, don't block — fail open.
if [[ -z "$transcript_path" || ! -f "$transcript_path" ]]; then
  exit 0
fi

# Smart-fire: only block when the most recent assistant turn included a
# substantive tool use (Edit/Write/MultiEdit/Bash). Pure-conversation turns
# (greetings, Q&A, brainstorm) skip the marker requirement — those don't
# create code-change opportunities to notice issues against.
#
# Logic: walk back through the last ~16KB of transcript, find the most
# recent user message boundary, then check if any tool_use of a
# substantive type appears between that boundary and end-of-transcript.
#
# Important: Claude Code wraps tool_result content in a top-level
# `"type":"user"` envelope (role:"user" content:tool_result). Those are
# NOT real user-message boundaries — they appear mid-turn after every
# assistant tool_use. Detect them by the presence of `"tool_use_id"` on
# the same line and skip them when finding the turn boundary; otherwise
# every tool-call turn looks like "nothing happened after the user spoke"
# and smart-fire silently exits 0.
recent_tail="$(tail -c 16384 "$transcript_path" 2>/dev/null || true)"
if [[ -n "$recent_tail" ]]; then
  # Take everything after the last real user message marker (excluding
  # tool_result envelopes, which also carry "type":"user").
  last_turn="$(printf '%s' "$recent_tail" | awk '
    /"type":"user"/ && !/"tool_use_id"/ { buf=""; next }
    { buf = buf "\n" $0 }
    END { print buf }
  ')"
  # If no substantive tool use in the most recent assistant turn, allow stop
  if ! printf '%s' "$last_turn" \
     | grep -qE '"name":"(Edit|Write|MultiEdit|Bash|NotebookEdit)"'; then
    exit 0
  fi
fi

# Check the last ~8KB of the transcript for the marker. 8KB is enough to
# capture the most recent assistant turn even with long output.
#
# Brief retry: Claude Code fires Stop before the final assistant text is
# flushed to disk, so a first-pass check can miss a marker the assistant
# actually included. One short sleep gives the flush a chance to land
# before we block. If the marker still isn't present, stop_hook_active
# on the retry-fire (above) prevents an infinite block loop.
for attempt in 1 2; do
  if tail -c 8192 "$transcript_path" 2>/dev/null \
     | grep -q '<!-- found-issues-checked:'; then
    exit 0
  fi
  [[ $attempt -eq 1 ]] && sleep 0.3
done

# Block with the canonical message
cat >&2 <<'EOF'
Stop blocked: include a found-issues acknowledgment in your final message.

Add ONE of these as an HTML comment anywhere in your response:
  <!-- found-issues-checked: none-noticed -->
  <!-- found-issues-checked: logged -->
  <!-- found-issues-checked: deferred -->

The marker forces conscious consideration; it does not auto-detect issues.
Use /found-issues:log to log items frictionlessly.
EOF
exit 2
