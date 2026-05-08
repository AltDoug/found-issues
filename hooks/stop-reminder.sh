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

# Check the last ~8KB of the transcript for the marker.
# 8KB is enough to capture the most recent assistant turn even with long output.
if tail -c 8192 "$transcript_path" 2>/dev/null \
   | grep -q '<!-- found-issues-checked:'; then
  exit 0
fi

# Block with the canonical message
cat >&2 <<'EOF'
Stop blocked: include a found-issues acknowledgment in your final message.

Add ONE of these as an HTML comment anywhere in your response:
  <!-- found-issues-checked: none-noticed -->
  <!-- found-issues-checked: logged -->
  <!-- found-issues-checked: deferred -->

The marker forces conscious consideration; it does not auto-detect issues.
Use /fi log to log items frictionlessly.
EOF
exit 2
