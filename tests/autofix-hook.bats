#!/usr/bin/env bats
# v3 hook launcher selection (spec §4.1-§4.2, §4.4; phase 3 plan Task 6).

load 'helpers'
load 'autofix-helpers'

HOOK="$TEST_REPO_ROOT/hooks/post-bash-dispatch.sh"

setup() {
  fi_setup_tmp; fi_af_fixture
  fi_af_queue_fixture; ST="$FI_AF_ST"
  # A stand-in found-issues that only records how it was launched.
  mkdir -p "$TMP/fake"
  printf '#!/usr/bin/env bash\nprintf "%%s|%%s\\n" "$PWD" "$*" >>"%s/spawned"\n' "$TMP" >"$TMP/fake/found-issues"
  chmod +x "$TMP/fake/found-issues"
  export FOUND_ISSUES_BIN="$TMP/fake/found-issues"
  unset FOUND_ISSUES_HARNESS
  export CLAUDE_CODE_ENTRYPOINT=cli
}
teardown() { fi_teardown_tmp; }

# payload <permission_mode|""> <stdout> [agent_id] [command]
payload() {
  jq -cn --arg m "$1" --arg o "$2" --arg a "${3:-}" --arg c "${4:-found-issues log --fix small x}" \
    '{session_id:"s",cwd:"/x",hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:$o,stderr:"",interrupted:false}}
     + (if $m == "" then {} else {permission_mode:$m} end)
     + (if $a == "" then {} else {agent_id:$a, agent_type:"x"} end)'
}
hook() { printf '%s' "$1" | "$HOOK"; }
wait_spawn() { local i; for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/spawned" ] && return 0; sleep 0.3; done; return 1; }
no_spawn() { sleep 0.5; [ ! -e "$TMP/spawned" ]; }

@test "hook: claude default, acceptEdits, plan, dontAsk and missing modes start launcher A" {
  local m
  for m in default acceptEdits plan dontAsk ""; do
    rm -f "$TMP/spawned"; fi_af_item_set "$QITEM" launched ""
    run hook "$(payload "$m" "Logged.
AUTOFIX-QUEUED $ID")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    wait_spawn
    grep -q "^$REPO|autofix run $ID --engine claude$" "$TMP/spawned"
    grep -q '^launcher=A$' "$QITEM"
  done
}

@test "hook: claude auto and bypassPermissions nudge the main agent (launcher B)" {
  local m
  for m in auto bypassPermissions; do
    rm -f "$TMP/spawned"
    run hook "$(payload "$m" "AUTOFIX-QUEUED $ID")"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"'
    ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" == *"found-issues:found-issues-fixer"* ]]
    [[ "$ctx" == *"Fix found-issues auto-fix item $ID."* ]]
    grep -q '^launcher=B$' "$QITEM"
    grep -Eq '^launched=[0-9]+$' "$QITEM"
    no_spawn
  done
}

@test "hook: codex always starts launcher A with the codex engine" {
  export FOUND_ISSUES_HARNESS=codex
  run hook "$(payload bypassPermissions "AUTOFIX-QUEUED $ID")"
  [ "$status" -eq 0 ]
  wait_spawn
  grep -q "autofix run $ID --engine codex$" "$TMP/spawned"
}

@test "hook: a codex string tool_response is read too" {
  export FOUND_ISSUES_HARNESS=codex
  p="$(jq -cn --arg o "AUTOFIX-QUEUED $ID" '{hook_event_name:"PostToolUse",tool_name:"Bash",permission_mode:"default",tool_input:{command:"found-issues log x"},tool_response:$o}')"
  run hook "$p"
  wait_spawn
}

@test "hook: agent_id (inside a subagent) launches nothing and leaves the item unstamped" {
  run hook "$(payload bypassPermissions "AUTOFIX-QUEUED $ID" agent-123)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  no_spawn
  ! grep -q '^launched=' "$QITEM" || false
}

@test "hook: FOUND_ISSUES_AUTOFIX_CHILD launches nothing" {
  FOUND_ISSUES_AUTOFIX_CHILD=1 run hook "$(payload default "AUTOFIX-QUEUED $ID")"
  no_spawn
}

@test "hook: a marker for an id that is not queued launches nothing" {
  run hook "$(payload default "AUTOFIX-QUEUED 20990101-000000-00000")"
  [ -z "$output" ]
  no_spawn
}

@test "hook: a marker only in the command, not the output, launches nothing" {
  run hook "$(payload default "" "" "echo AUTOFIX-QUEUED $ID")"
  no_spawn
}

@test "hook: two markers start one launcher A run and stamp both items" {
  "$FI_BIN" log --fix small "src/calc.sh:1 — add ignores a third argument" >/dev/null
  id2="$(ls "$ST/queue" | grep -v "^$ID$" | head -1)"
  [ -n "$id2" ]
  run hook "$(payload default "AUTOFIX-QUEUED $ID
AUTOFIX-QUEUED $id2")"
  wait_spawn; sleep 0.5
  [ "$(wc -l <"$TMP/spawned" | tr -d ' ')" = 1 ]
  grep -q '^launcher=A$' "$ST/queue/$id2"
}

@test "hook: FOUND_ISSUES_AUTOFIX_LAUNCHER=headless forces launcher A in bypass mode" {
  FOUND_ISSUES_AUTOFIX_LAUNCHER=headless run hook "$(payload bypassPermissions "AUTOFIX-QUEUED $ID")"
  [ -z "$output" ]
  wait_spawn
}

@test "hook: commit route plus marker emit one JSON object" {
  export FOUND_ISSUES_BIN="$FI_BIN"
  printf 'x\n' >f.txt; git add f.txt; git commit -q -m x
  run hook "$(payload auto "AUTOFIX-QUEUED $ID" "" "git commit -m x && found-issues log --fix small y")"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -s 'length')" = 1 ]
}

@test "hook: a queued item whose repo root is gone still exits 0" {
  fi_af_item_set "$QITEM" root "$TMP/gone"
  run hook "$(payload default "AUTOFIX-QUEUED $ID")"
  [ "$status" -eq 0 ]
  no_spawn
}

sweep_item() {
  SWID=20261004-000000-00042
  fi_af_item_write "$ST/queue/$SWID" "id=$SWID" kind=sweep "root=$REPO" slug=foo/bar loc=sweep engine=claude crashes=0
}

@test "hook: a sweep marker in bypass nudges the sweeper agent" {
  sweep_item
  run hook "$(payload bypassPermissions "AUTOFIX-SWEEP-DUE $SWID")"
  [ "$status" -eq 0 ]
  ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" == *"found-issues:found-issues-sweeper"* ]]
  [[ "$ctx" == *"Run found-issues auto-fix sweep $SWID."* ]]
  [[ "$ctx" != *"found-issues-fixer"* ]]
  grep -q '^launcher=B$' "$ST/queue/$SWID"
  no_spawn
}

@test "hook: a sweep marker in default mode starts launcher A" {
  sweep_item
  run hook "$(payload default "AUTOFIX-SWEEP-DUE $SWID")"
  [ "$status" -eq 0 ]
  wait_spawn
  grep -q "autofix run $SWID --engine claude$" "$TMP/spawned"
}

@test "hook: a spot marker and a sweep marker in one call nudge the fixer and the sweeper" {
  sweep_item
  run hook "$(payload auto "AUTOFIX-QUEUED $ID
AUTOFIX-SWEEP-DUE $SWID")"
  ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" == *"Fix found-issues auto-fix item $ID."* ]]
  [[ "$ctx" == *"Run found-issues auto-fix sweep $SWID."* ]]
}
