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

@test "stop-reminder: blocks when marker missing" {
  TR="$(mktemp)"
  echo "Some response without the marker" > "$TR"
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"acknowledgment"* ]]
  rm -f "$TR"
}

@test "stop-reminder: allows when marker present (none-noticed)" {
  TR="$(mktemp)"
  echo 'response <!-- found-issues-checked: none-noticed --> done' > "$TR"
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
  rm -f "$TR"
}

@test "stop-reminder: allows when marker present (logged)" {
  TR="$(mktemp)"
  echo 'response <!-- found-issues-checked: logged --> done' > "$TR"
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
  rm -f "$TR"
}

@test "stop-reminder: allows when marker present (deferred)" {
  TR="$(mktemp)"
  echo 'response <!-- found-issues-checked: deferred --> done' > "$TR"
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
  rm -f "$TR"
}

@test "stop-reminder: respects FOUND_ISSUES_STOP_REMINDER=off" {
  export FOUND_ISSUES_STOP_REMINDER=off
  TR="$(mktemp)"
  echo "no marker" > "$TR"
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
