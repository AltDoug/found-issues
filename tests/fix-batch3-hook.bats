#!/usr/bin/env bats
# Batch 3 hook fixes: marker grace and repo match, Stop fallback config and
# cap, removed-worktree roots (ledger lib/autofix-hook.sh:58, :123, :80).

load 'helpers'
load 'autofix-helpers'

HOOK="$TEST_REPO_ROOT/hooks/post-bash-dispatch.sh"
STOP="$TEST_REPO_ROOT/hooks/stop-reminder.sh"

setup() {
  fi_setup_tmp; fi_af_fixture
  fi_af_queue_fixture; ST="$FI_AF_ST"
  mkdir -p "$TMP/fake"
  printf '#!/usr/bin/env bash\nprintf "%%s|%%s\\n" "$PWD" "$*" >>"%s/spawned"\n' "$TMP" >"$TMP/fake/found-issues"
  chmod +x "$TMP/fake/found-issues"
  export FOUND_ISSUES_BIN="$TMP/fake/found-issues"
  export FOUND_ISSUES_STOP_REMINDER=off
  unset FOUND_ISSUES_HARNESS
  export CLAUDE_CODE_ENTRYPOINT=cli
}
teardown() { fi_teardown_tmp; }

payload() { # <permission_mode> <stdout>
  jq -cn --arg m "$1" --arg o "$2" \
    '{session_id:"s",cwd:"/x",hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"found-issues log --fix small x"},tool_response:{stdout:$o,stderr:"",interrupted:false},permission_mode:$m}'
}
hook() { printf '%s' "$1" | "$HOOK"; }
stop() { # $1 cwd
  jq -cn --arg c "$1" '{session_id:"s1",hook_event_name:"Stop",cwd:$c,stop_hook_active:false}' | "$STOP"
}
wait_spawn() { local i; for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/spawned" ] && return 0; sleep 0.3; done; return 1; }
no_spawn() { sleep 0.5; [ ! -e "$TMP/spawned" ]; }

# ---- lib/autofix-hook.sh:58 ----

@test "b37 marker: a re-printed marker within the grace launches nothing (launcher A)" {
  local now; now="$(date +%s)"
  fi_af_item_set "$QITEM" launched "$now"
  run hook "$(payload default "AUTOFIX-QUEUED $ID")"
  [ "$status" -eq 0 ]
  no_spawn
  grep -q "^launched=$now$" "$QITEM"
}

@test "b37 marker: a re-printed marker within the grace emits no second B nudge" {
  local now; now="$(date +%s)"
  fi_af_item_set "$QITEM" launched "$now"
  run hook "$(payload auto "AUTOFIX-QUEUED $ID")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q "^launched=$now$" "$QITEM"
}

@test "b37 marker: a marker older than the grace launches again" {
  fi_af_item_set "$QITEM" launched "$(( $(date +%s) - 300 ))"
  run hook "$(payload default "AUTOFIX-QUEUED $ID")"
  wait_spawn
}

@test "b37 marker: a marker for another repo's item does not spawn there" {
  mkdir -p "$TMP/other" && git -C "$TMP/other" init -q
  fi_af_item_set "$QITEM" root "$TMP/other"
  run hook "$(payload default "AUTOFIX-QUEUED $ID")"
  [ "$status" -eq 0 ]
  no_spawn
  ! grep -q '^launched=' "$QITEM" || false
}

# ---- lib/autofix-hook.sh:123 ----

@test "b37 stop: a repo with found-issues.autofix=false spawns nothing" {
  git config found-issues.autofix false
  run stop "$REPO"
  [ "$status" -eq 0 ]
  no_spawn
  ! grep -q '^launched=' "$QITEM" || false
}

@test "b37 stop: a repo with the daily spot cap already taken spawns nothing" {
  git config found-issues.autofix.dailyFixes 2
  printf 'a\nb\n' >"$ST/day/$(date +%Y-%m-%d).spot"
  run stop "$REPO"
  [ "$status" -eq 0 ]
  no_spawn
}

@test "b37 stop: a day under its spot cap still spawns" {
  git config found-issues.autofix.dailyFixes 3
  printf 'a\nb\n' >"$ST/day/$(date +%Y-%m-%d).spot"
  run stop "$REPO"
  wait_spawn
}

# ---- lib/autofix-hook.sh:80 ----

@test "b37 stop: an item from a removed nested worktree launches from the main checkout" {
  WID=20261010-000000-00077
  fi_af_item_write "$ST/queue/$WID" "id=$WID" kind=spot "root=$REPO/.claude/worktrees/gone" slug=foo/bar loc=src/calc.sh:1 engine=claude crashes=0
  rm -f "$QITEM"
  run stop "$REPO"
  [ "$status" -eq 0 ]
  wait_spawn
  grep -q "^$REPO|autofix run $WID --engine claude$" "$TMP/spawned"
}

@test "b37 stop: a removed worktree whose prefix is a different repo is still refused" {
  WID=20261010-000000-00078
  mkdir -p "$TMP/elsewhere" && git -C "$TMP/elsewhere" init -q
  fi_af_item_write "$ST/queue/$WID" "id=$WID" kind=spot "root=$TMP/elsewhere/.claude/worktrees/gone" slug=foo/bar loc=src/calc.sh:1 engine=claude crashes=0
  rm -f "$QITEM"
  run stop "$REPO"
  [ "$status" -eq 0 ]
  no_spawn
}

@test "b37 stop: a removed root outside any .claude/worktrees path is still refused" {
  fi_af_item_set "$QITEM" root "$TMP/gone"
  run stop "$REPO"
  no_spawn
}

@test "b37 marker: a removed nested worktree root launches A from the main checkout" {
  fi_af_item_set "$QITEM" root "$REPO/.claude/worktrees/gone"
  run hook "$(payload default "AUTOFIX-QUEUED $ID")"
  [ "$status" -eq 0 ]
  wait_spawn
  grep -q "^$REPO|autofix run $ID --engine claude$" "$TMP/spawned"
}
