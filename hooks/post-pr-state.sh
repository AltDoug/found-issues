#!/usr/bin/env bash
# post-pr-state.sh — PostToolUse hook on Bash
#
# Fires after every Bash invocation. When the command was a PR state-change
# action (`gh pr merge`, `gh pr close`, `gh pr reopen`), spawns
# `found-issues sync` in the background so the statusline reflects the
# new annotation state immediately, without waiting for the next
# session-start sync.
#
# Why this exists: `(PR: org/repo#N)` annotations only flip to `[fixed]`
# when sync runs and queries gh for PR state. Sync runs at SessionStart,
# so without this hook the user has to start a new Claude Code session
# to see the count drop after merging their own PR.
#
# Scope (intentionally narrow): only the three commands above. We don't
# fire on every `git push` because pushes don't change PR merge state by
# themselves, and we don't fire on every Bash because that's wasteful
# (gh API calls per match). External merges (web UI, teammate) are
# caught separately by the throttled segment-autosync path in
# `found-issues status --format=segment`.
#
# Hook event: PostToolUse (matcher: Bash)
# Exit code: 0 always (additive; never blocks).
# Stdout: none (sync runs detached; user gets the update via statusline).
# Opt out: FOUND_ISSUES_POST_PR_STATE=off

set -euo pipefail

if [[ "${FOUND_ISSUES_POST_PR_STATE:-on}" == "off" ]]; then
  exit 0
fi

input="$(cat)"

get_field() {
  local field="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$input" | jq -r "$field // empty" 2>/dev/null || true
  fi
}

tool_name="$(get_field '.tool_name')"
[[ "$tool_name" != "Bash" ]] && exit 0

command="$(get_field '.tool_input.command')"
[[ -z "$command" ]] && exit 0

# Match `gh pr merge|close|reopen` anywhere in the command (handles `&&`
# chaining, `time gh pr merge ...`, etc.). Word boundary on both sides
# avoids matching subcommand fragments embedded in other strings.
if ! [[ "$command" =~ (^|[[:space:];|&])gh[[:space:]]+pr[[:space:]]+(merge|close|reopen)([[:space:]]|$) ]]; then
  exit 0
fi

# Locate CLI binary (same fallback chain as post-pr-create.sh).
FI_BIN="${FOUND_ISSUES_BIN:-found-issues}"
if ! command -v "$FI_BIN" >/dev/null 2>&1; then
  if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -x "$CLAUDE_PLUGIN_ROOT/bin/found-issues" ]]; then
    FI_BIN="$CLAUDE_PLUGIN_ROOT/bin/found-issues"
  else
    # No CLI available — silent no-op, don't block.
    exit 0
  fi
fi

# Fire-and-forget background sync. Detached subshell so the parent
# (PostToolUse hook) exits immediately and Claude is never blocked
# waiting on gh network calls. FOUND_ISSUES_AUTOSYNC_CMD is a testing
# knob — tests set it to a marker-creating command to verify dispatch
# without invoking the real sync.
sync_cmd="${FOUND_ISSUES_AUTOSYNC_CMD:-$FI_BIN sync}"
( bash -c "$sync_cmd" >/dev/null 2>&1 & ) >/dev/null 2>&1

exit 0
