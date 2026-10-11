#!/usr/bin/env bats
# Batch 4 hook fixes: the item's recorded engine wins at launch, and the Stop
# fallback shares the enabled/cap gate with the CLI (ledger
# lib/autofix-hook.sh:82, :231).

load 'helpers'
load 'autofix-helpers'

HOOK="$TEST_REPO_ROOT/hooks/post-bash-dispatch.sh"
STOP="$TEST_REPO_ROOT/hooks/stop-reminder.sh"

setup() {
  fi_setup_tmp; fi_af_fixture
  export PATH="$TEST_REPO_ROOT/bin:$PATH"
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

# ---- lib/autofix-hook.sh:82 ----

@test "b4 engine: a Stop launch passes the item's recorded codex engine, not the claude harness" {
  fi_af_item_set "$QITEM" engine codex
  run stop "$REPO"
  [ "$status" -eq 0 ]
  wait_spawn
  grep -q "autofix run $ID --engine codex$" "$TMP/spawned"
}

@test "b4 engine: a marker launch passes the item's recorded codex engine, not the claude harness" {
  fi_af_item_set "$QITEM" engine codex
  run hook "$(payload default "AUTOFIX-QUEUED $ID")"
  [ "$status" -eq 0 ]
  wait_spawn
  grep -q "autofix run $ID --engine codex$" "$TMP/spawned"
}

@test "b4 engine: a recorded claude engine wins over a codex harness" {
  export FOUND_ISSUES_HARNESS=codex
  fi_af_item_set "$QITEM" engine claude
  run hook "$(payload default "AUTOFIX-QUEUED $ID")"
  [ "$status" -eq 0 ]
  wait_spawn
  grep -q "autofix run $ID --engine claude$" "$TMP/spawned"
}

@test "b4 engine: an empty recorded engine follows the harness" {
  export FOUND_ISSUES_HARNESS=codex
  fi_af_item_set "$QITEM" engine ""
  run hook "$(payload default "AUTOFIX-QUEUED $ID")"
  [ "$status" -eq 0 ]
  wait_spawn
  grep -q "autofix run $ID --engine codex$" "$TMP/spawned"
}

@test "b4 engine: a recorded auto engine follows the harness" {
  export FOUND_ISSUES_HARNESS=codex
  fi_af_item_set "$QITEM" engine auto
  run hook "$(payload default "AUTOFIX-QUEUED $ID")"
  [ "$status" -eq 0 ]
  wait_spawn
  grep -q "autofix run $ID --engine codex$" "$TMP/spawned"
}

# ---- lib/autofix-hook.sh:231 ----

# The GitHub origin is checked when an item is queued (fi_af_queue_spot needs
# fi_repo_id), so Stop does not fork for it again; an item with no slug is the
# cheap skip.
@test "b4 stop: a repo whose origin is not on GitHub never gets an item queued" {
  git config --unset url."$TMP/remote.git".insteadOf
  git remote set-url origin "$TMP/remote.git"
  rm -f "$QITEM"
  fi_af_queue_spot "$(grep -m1 '^- \[open\]' docs/found-issues.md)"
  [ -z "$(ls "$ST/queue")" ]
  run stop "$REPO"
  [ "$status" -eq 0 ]
  no_spawn
}

@test "b4 stop: an item with no recorded slug spawns nothing" {
  fi_af_item_set "$QITEM" slug ""
  run stop "$REPO"
  [ "$status" -eq 0 ]
  no_spawn
  ! grep -q '^launched=' "$QITEM" || false
}

@test "b4 stop: a GitHub origin reached through insteadOf still spawns" {
  run stop "$REPO"
  [ "$status" -eq 0 ]
  wait_spawn
}

@test "b4 stop: the enabled gate and the cap read cost one config call per queued item" {
  local real; real="$(command -v git)"
  mkdir -p "$TMP/gitshim"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/gitlog"\nexec "%s" "$@"\n' "$TMP" "$real" >"$TMP/gitshim/git"
  chmod +x "$TMP/gitshim/git"
  export PATH="$TMP/gitshim:$PATH"
  : >"$TMP/gitlog"
  run stop "$REPO"
  [ "$status" -eq 0 ]
  wait_spawn
  local n
  n="$(grep -c 'config.*found-issues' "$TMP/gitlog" || true)"
  [ "$n" -eq 1 ]
}

@test "b4 stop: an invalid dailyFixes falls back to 5 like the CLI, so five claims cap the day" {
  git config found-issues.autofix.dailyFixes abc
  printf 'a\nb\nc\nd\ne\n' >"$ST/day/$(date +%Y-%m-%d).spot"
  run stop "$REPO"
  [ "$status" -eq 0 ]
  no_spawn
}

@test "b4 shared: fi_af_repo_cfg reads the toggle and the cap of a given dir in one call" {
  git config found-issues.autofix.dailyFixes 7
  ( cd / && fi_af_repo_cfg "$REPO" && [ "$FI_AF_RC_ON" = true ] && [ "$FI_AF_RC_CAP" = 7 ] )
  git config found-issues.autofix false
  ( cd / && fi_af_repo_cfg "$REPO" && [ "$FI_AF_RC_ON" != true ] )
}
