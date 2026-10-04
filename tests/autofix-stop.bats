#!/usr/bin/env bats
# v3 Stop-hook claim fallback (spec §4.3; phase 3 plan Task 7).

load 'helpers'
load 'autofix-helpers'

STOP="$TEST_REPO_ROOT/hooks/stop-reminder.sh"

setup() {
  fi_setup_tmp; fi_af_fixture
  fi_af_queue_fixture; ST="$FI_AF_ST"
  mkdir -p "$TMP/fake"
  printf '#!/usr/bin/env bash\nprintf "%%s|%%s\\n" "$PWD" "$*" >>"%s/spawned"\n' "$TMP" >"$TMP/fake/found-issues"
  chmod +x "$TMP/fake/found-issues"
  export FOUND_ISSUES_BIN="$TMP/fake/found-issues"
  export FOUND_ISSUES_STOP_REMINDER=off   # isolate the fallback from the marker check
  unset FOUND_ISSUES_HARNESS
}
teardown() { fi_teardown_tmp; }

stop() { # $1 cwd [$2 agent_id]
  jq -cn --arg c "$1" --arg a "${2:-}" \
    '{session_id:"s1",hook_event_name:"Stop",cwd:$c,stop_hook_active:false,permission_mode:"bypassPermissions"} + (if $a == "" then {} else {agent_id:$a} end)' \
    | "$STOP"
}
wait_spawn() { local i; for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/spawned" ] && return 0; sleep 0.3; done; return 1; }
no_spawn() { sleep 0.5; [ ! -e "$TMP/spawned" ]; }

@test "stop: an item with no launched stamp is launched with launcher A" {
  run stop "$REPO"
  [ "$status" -eq 0 ]
  wait_spawn
  grep -q "^$REPO|autofix run $ID --engine claude$" "$TMP/spawned"
  grep -q '^launcher=A$' "$QITEM"
}

@test "stop: cwd under the repo root matches" {
  run stop "$REPO/src"
  wait_spawn
}

@test "stop: another repo is ignored" {
  mkdir -p "$TMP/other"
  run stop "$TMP/other"
  no_spawn
}

@test "stop: an item nudged within the grace period is left for its fixer" {
  fi_af_item_set "$QITEM" launched "$(date +%s)"
  run stop "$REPO"
  no_spawn
  fi_af_item_set "$QITEM" launched "$(( $(date +%s) - 120 ))"
  run stop "$REPO"
  wait_spawn
}

@test "stop: a held repo lock is left alone" {
  mkdir "$ST/lock"
  run stop "$REPO"
  no_spawn
}

@test "stop: today's capped marker is left alone" {
  : >"$ST/day/$(date +%Y-%m-%d).capped"
  run stop "$REPO"
  no_spawn
}

@test "stop: kill switch, agent_id and fixer children launch nothing" {
  FOUND_ISSUES_AUTOFIX=off run stop "$REPO"; no_spawn
  run stop "$REPO" agent-9; no_spawn
  FOUND_ISSUES_AUTOFIX_CHILD=1 run stop "$REPO"; no_spawn
  mkdir -p "$FOUND_ISSUES_STATE_DIR/autofix"; : >"$FOUND_ISSUES_STATE_DIR/autofix/disabled"
  run stop "$REPO"; no_spawn
}

@test "stop: an empty queue runs no external command" {
  rm -f "$ST"/queue/*
  mkdir -p "$TMP/shim"
  for c in date jq git; do
    printf '#!/usr/bin/env bash\necho %s >>"%s/ext-calls"\nexit 0\n' "$c" "$TMP" >"$TMP/shim/$c"; chmod +x "$TMP/shim/$c"
  done
  # payload built with the real jq first; only the hook runs under the shims
  jq -cn --arg c "$REPO" '{session_id:"s1",hook_event_name:"Stop",cwd:$c,stop_hook_active:false}' >"$TMP/stop.json"
  PATH="$TMP/shim:$PATH" run bash -c "'$STOP' < '$TMP/stop.json'"
  [ "$status" -eq 0 ]
  [ ! -e "$TMP/ext-calls" ]
}

@test "stop: codex uses the codex engine and still gives the marker nudge" {
  export FOUND_ISSUES_HARNESS=codex
  unset FOUND_ISSUES_STOP_REMINDER
  out="$(jq -cn --arg c "$REPO" '{session_id:"s2",hook_event_name:"Stop",cwd:$c,stop_hook_active:false,last_assistant_message:"done",transcript_path:null,permission_mode:"default",turn_id:"t"}' | "$STOP")"
  wait_spawn
  grep -q "autofix run $ID --engine codex$" "$TMP/spawned"
  printf '%s' "$out" | jq -e '.decision == "block"'
}
