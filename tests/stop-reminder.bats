#!/usr/bin/env bats
# Tests for hooks/stop-reminder.sh

load 'helpers'

HOOK="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/hooks/stop-reminder.sh"

setup() {
  fi_setup_tmp
}

teardown() {
  fi_teardown_tmp
  unset FOUND_ISSUES_STOP_REMINDER
}

@test "stop-reminder: blocks when marker missing AND substantive tool use occurred" {
  TR="$(mktemp)"
  # Simulate a transcript where the assistant turn included an Edit tool use
  # but did not include the required marker.
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"please fix the bug"}
{"type":"assistant","message":"sure, editing now","tool_uses":[{"name":"Edit","input":{"file_path":"foo.py"}}]}
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"acknowledgment"* ]]
  rm -f "$TR"
}

@test "stop-reminder: allows pure-conversation turn without marker (smart-fire)" {
  TR="$(mktemp)"
  # Simulate a transcript where the assistant just had a chat reply — no
  # Edit/Write/Bash tool use. The marker shouldn't be required for that.
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"hello"}
{"type":"assistant","message":"hi, what would you like to work on?"}
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
  rm -f "$TR"
}

@test "stop-reminder: allows when marker present (none-noticed)" {
  TR="$(mktemp)"
  # Include both a tool use (so smart-fire would normally trigger) AND the marker.
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"fix this"}
{"type":"assistant","message":"done","tool_uses":[{"name":"Edit","input":{}}]}
response <!-- found-issues-checked: none-noticed --> done
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
  rm -f "$TR"
}

@test "stop-reminder: allows when marker present (logged)" {
  TR="$(mktemp)"
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"fix this"}
{"type":"assistant","message":"done","tool_uses":[{"name":"Edit","input":{}}]}
response <!-- found-issues-checked: logged --> done
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
  rm -f "$TR"
}

@test "stop-reminder: allows when marker present (deferred)" {
  TR="$(mktemp)"
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"fix this"}
{"type":"assistant","message":"done","tool_uses":[{"name":"Edit","input":{}}]}
response <!-- found-issues-checked: deferred --> done
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
  rm -f "$TR"
}

@test "stop-reminder: respects FOUND_ISSUES_STOP_REMINDER=off" {
  export FOUND_ISSUES_STOP_REMINDER=off
  TR="$(mktemp)"
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"fix this"}
{"type":"assistant","message":"done","tool_uses":[{"name":"Edit","input":{}}]}
no marker
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
  rm -f "$TR"
}

@test "stop-reminder: fails open when transcript_path is missing or invalid" {
  input='{"hook_event_name":"Stop","transcript_path":"/nonexistent/path"}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}
