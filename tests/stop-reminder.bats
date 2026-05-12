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

@test "stop-reminder: blocks on realistic Claude Code transcript with tool_result envelope (regression)" {
  # Real Claude Code transcripts wrap tool_result content in a top-level
  # "type":"user" envelope (role:user, content:tool_result). The smart-fire
  # awk used to treat those as user-message boundaries, throwing away the
  # earlier assistant tool_use and silently allowing every code-modifying
  # turn through with no marker requirement.
  #
  # Repros bug observed 2026-05-12. Hook must exit 2 (block) here.
  TR="$(mktemp)"
  cat > "$TR" <<'TRANSCRIPT'
{"parentUuid":"u-1","isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"text","text":"please run git status"}]},"uuid":"user-1","timestamp":"2026-05-12T00:00:00Z","sessionId":"s-1","cwd":"/x","version":"2.1.139"}
{"parentUuid":"user-1","type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_01","name":"Bash","input":{"command":"git status"}}]},"uuid":"asst-1","timestamp":"2026-05-12T00:00:01Z","sessionId":"s-1"}
{"parentUuid":"asst-1","type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01","type":"tool_result","content":"On branch main","is_error":false}]},"uuid":"toolres-1","timestamp":"2026-05-12T00:00:02Z","toolUseResult":{"stdout":"On branch main","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false},"sourceToolAssistantUUID":"asst-1","sessionId":"s-1"}
{"parentUuid":"toolres-1","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"You are on main."}]},"uuid":"asst-2","timestamp":"2026-05-12T00:00:03Z","sessionId":"s-1"}
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"acknowledgment"* ]]
  rm -f "$TR"
}

@test "stop-reminder: allows realistic transcript with marker present" {
  # Same realistic shape, with the marker baked into the assistant's
  # final text response. Hook must allow.
  TR="$(mktemp)"
  cat > "$TR" <<'TRANSCRIPT'
{"parentUuid":"u-1","isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"text","text":"edit foo.py"}]},"uuid":"user-1","timestamp":"2026-05-12T00:00:00Z","sessionId":"s-1"}
{"parentUuid":"user-1","type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_02","name":"Edit","input":{"file_path":"foo.py"}}]},"uuid":"asst-1","timestamp":"2026-05-12T00:00:01Z","sessionId":"s-1"}
{"parentUuid":"asst-1","type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_02","type":"tool_result","content":"edited","is_error":false}]},"uuid":"toolres-1","timestamp":"2026-05-12T00:00:02Z","sessionId":"s-1"}
{"parentUuid":"toolres-1","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done. <!-- found-issues-checked: none-noticed -->"}]},"uuid":"asst-2","timestamp":"2026-05-12T00:00:03Z","sessionId":"s-1"}
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
  rm -f "$TR"
}
