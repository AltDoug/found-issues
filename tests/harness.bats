#!/usr/bin/env bats
# Tests for lib/harness.sh - harness detection and context emission

load 'helpers'

setup() {
  fi_setup_tmp
  source "$FI_LIB_DIR/harness.sh"
}

teardown() { fi_teardown_tmp; }

@test "detect: CLAUDE_CODE_ENTRYPOINT set means claude" {
  CLAUDE_CODE_ENTRYPOINT=cli PLUGIN_DATA=/tmp/x run fi_detect_harness
  [ "$output" = "claude" ]
}

@test "detect: PLUGIN_DATA without entrypoint means codex" {
  unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
  PLUGIN_DATA=/tmp/x run fi_detect_harness
  [ "$output" = "codex" ]
}

@test "detect: neither signal defaults to claude" {
  unset CLAUDE_CODE_ENTRYPOINT PLUGIN_DATA 2>/dev/null || true
  run fi_detect_harness
  [ "$output" = "claude" ]
}

@test "detect: FOUND_ISSUES_HARNESS=codex wins with no other signal" {
  unset CLAUDE_CODE_ENTRYPOINT PLUGIN_DATA 2>/dev/null || true
  FOUND_ISSUES_HARNESS=codex run fi_detect_harness
  [ "$output" = "codex" ]
}

@test "detect: FOUND_ISSUES_HARNESS=claude wins with no other signal" {
  unset CLAUDE_CODE_ENTRYPOINT PLUGIN_DATA 2>/dev/null || true
  FOUND_ISSUES_HARNESS=claude run fi_detect_harness
  [ "$output" = "claude" ]
}

@test "detect: FOUND_ISSUES_HARNESS=codex overrides CLAUDE_CODE_ENTRYPOINT" {
  CLAUDE_CODE_ENTRYPOINT=cli FOUND_ISSUES_HARNESS=codex run fi_detect_harness
  [ "$output" = "codex" ]
}

@test "detect: FOUND_ISSUES_HARNESS=claude overrides PLUGIN_DATA (precedence over PLUGIN_DATA)" {
  unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
  PLUGIN_DATA=/tmp/x FOUND_ISSUES_HARNESS=claude run fi_detect_harness
  [ "$output" = "claude" ]
}

@test "detect: unrecognized FOUND_ISSUES_HARNESS value falls back to heuristics" {
  unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
  PLUGIN_DATA=/tmp/x FOUND_ISSUES_HARNESS=bogus run fi_detect_harness
  [ "$output" = "codex" ]
}

@test "emit: plain text on claude" {
  CLAUDE_CODE_ENTRYPOINT=cli run fi_emit_post_context "hello world"
  [ "$output" = "hello world" ]
}

@test "emit: JSON additionalContext on codex" {
  unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
  PLUGIN_DATA=/tmp/x run fi_emit_post_context $'line1\nline "2"'
  # Codex PostToolUse hook-output schema (verified empirically, Task 11,
  # codex-cli 0.144.5): additionalContext must be nested under
  # hookSpecificOutput alongside hookEventName="PostToolUse". A flat
  # top-level additionalContext is dropped (schema additionalProperties:false).
  printf '%s' "$output" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')" = "PostToolUse" ]
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')" = $'line1\nline "2"' ]
}

@test "emit: codex without jq emits nothing and exits 0" {
  unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
  # PATH with no jq
  PLUGIN_DATA=/tmp/x PATH="/usr/bin/nonexistent" run fi_emit_post_context "x"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "session-emit: plain text on claude" {
  CLAUDE_CODE_ENTRYPOINT=cli run fi_emit_session_context "hello world"
  [ "$output" = "hello world" ]
}

@test "session-emit: JSON additionalContext with hookEventName SessionStart on codex" {
  unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
  PLUGIN_DATA=/tmp/x run fi_emit_session_context $'line1\nline "2"'
  # Mirrors the PostToolUse schema (Task 11b assumption — see file header):
  # additionalContext nested under hookSpecificOutput, hookEventName is
  # the literal event name for this hook.
  printf '%s' "$output" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')" = "SessionStart" ]
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')" = $'line1\nline "2"' ]
}

@test "session-emit: codex without jq emits nothing and exits 0" {
  unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
  PLUGIN_DATA=/tmp/x PATH="/usr/bin/nonexistent" run fi_emit_session_context "x"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "session-emit: empty text emits nothing and exits 0" {
  CLAUDE_CODE_ENTRYPOINT=cli run fi_emit_session_context ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
