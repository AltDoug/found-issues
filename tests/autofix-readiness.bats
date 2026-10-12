#!/usr/bin/env bats
# 3.9.0: per-repo auto-fix readiness (measured base suite, a watchdog sized
# from it, a queue gate, one SessionStart line, `autofix ready`) and the
# superseded retire of ledger lib/autofix-ship.sh:206.

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_fixture; fi_use_standins
  export GH_MOCK_TRACE="$TMP/gh.trace"
  export GH_MOCK_PR_VIEW=$'7\t{"number":7,"state":"OPEN","statusCheckRollup":[]}'
  export FI_STANDIN_EDIT="sed -i.bak 's/ - / + /' src/calc.sh && rm -f src/calc.sh.bak"
  unset FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS
}
teardown() { fi_teardown_tmp; }

# Commit <file> changed on origin/main from a separate clone (a live session).
push_change() {
  local file="$1"
  rm -rf "$TMP/other-clone"
  git clone -q "$TMP/remote.git" "$TMP/other-clone"
  printf '# touched by another session\n' >>"$TMP/other-clone/$file"
  git -C "$TMP/other-clone" add -A
  git -C "$TMP/other-clone" -c user.email=o@x -c user.name=o commit -qm "other session"
  git -C "$TMP/other-clone" push -q origin main
}

@test "readiness: a green base run is recorded and shown by autofix ready" {
  fi_af_queue_fixture
  "$FI_BIN" autofix claim "$ID" >/dev/null
  run "$FI_BIN" autofix ready
  [ "$status" -eq 0 ]
  [[ "$output" == *"test command: sh test.sh"* ]]
  [[ "$output" == *"last base run: green in "* ]]
  [[ "$output" == *"verdict: ready"* ]]
}

@test "readiness: autofix ready with no test command says waiting" {
  git config --unset found-issues.autofix.testCommand
  run "$FI_BIN" autofix ready
  [ "$status" -eq 0 ]
  [[ "$output" == *"test command: none"* ]]
  [[ "$output" == *"last base run: never"* ]]
  [[ "$output" == *"verdict: waiting: no test command"* ]]
}

@test "readiness: the watchdog is twice the measured green suite, floored by runTimeoutMin and capped" {
  source "$FI_BIN"; fi_af_context
  fi_af_ready_write "$REPO" green 1500 "sh test.sh"
  [ "$(fi_af_timeout_secs "$REPO")" = 3000 ]
  # 2 x 61 s rounds up to 3 min, under the 20-min default floor
  fi_af_ready_write "$REPO" green 61 "sh test.sh"
  [ "$(fi_af_timeout_secs "$REPO")" = 1200 ]
  git config found-issues.autofix.runTimeoutMin 60
  [ "$(fi_af_timeout_secs "$REPO")" = 3600 ]
  fi_af_ready_write "$REPO" green 2562 "sh test.sh"
  [ "$(fi_af_timeout_secs "$REPO")" = 5160 ]
  fi_af_ready_write "$REPO" green 5000 "sh test.sh"
  [ "$(fi_af_timeout_secs "$REPO")" = 7200 ]
  # an explicit setting above the cap is honoured
  git config found-issues.autofix.runTimeoutMin 150
  [ "$(fi_af_timeout_secs "$REPO")" = 9000 ]
}

@test "readiness: after a timeout the next limit doubles, up to the cap" {
  source "$FI_BIN"; fi_af_context
  fi_af_ready_write "$REPO" timeout 1200 "sh test.sh"
  [ "$(fi_af_timeout_secs "$REPO")" = 2400 ]
  fi_af_ready_write "$REPO" timeout 4800 "sh test.sh"
  [ "$(fi_af_timeout_secs "$REPO")" = 7200 ]
}

@test "readiness: the env override wins, and a record for another test command is ignored" {
  source "$FI_BIN"; fi_af_context
  fi_af_ready_write "$REPO" green 3000 "sh test.sh"
  FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS=7 run fi_af_timeout_secs "$REPO"
  [ "$output" = 7 ]
  git config found-issues.autofix.testCommand 'sh test.sh --all'
  [ "$(fi_af_timeout_secs "$REPO")" = 1200 ]
}

@test "readiness: a red run sizes the limit too" {
  source "$FI_BIN"; fi_af_context
  fi_af_ready_write "$REPO" red 2562 "sh test.sh"
  [ "$(fi_af_timeout_secs "$REPO")" = 5160 ]
}

@test "readiness: a record older than a week still sizes the limit but no longer gates" {
  source "$FI_BIN"; fi_af_context
  fi_af_ready_write "$REPO" timeout 7200 "sh test.sh"
  fi_af_ready_ok "$REPO" && false
  fi_af_stuck_key "$REPO"
  f="$FI_AF_ROOT/ready/$FI_AF_KEY"
  sed -i.bak "3s/.*/$(( $(date +%s) - 8 * 86400 ))/" "$f"; rm -f "$f.bak"
  [ "$(fi_af_timeout_secs "$REPO")" = 7200 ]
  fi_af_ready_ok "$REPO"
  run "$FI_BIN" autofix ready
  [[ "$output" == *"over a week old"* ]]
  [[ "$output" == *"verdict: ready"* ]]
}

@test "readiness: a base run that passed only on its re-run records one run's time" {
  git config found-issues.autofix.testCommand "sleep 2; if [ -f '$TMP/flaked' ]; then exit 0; fi; : > '$TMP/flaked'; exit 1"
  fi_af_queue_fixture
  "$FI_BIN" autofix claim "$ID" >/dev/null
  fi_af_ready_read "$REPO"
  [ "$FI_AF_RD_STATUS" = green ]
  (( FI_AF_RD_SECS >= 1 && FI_AF_RD_SECS <= 3 ))
}

@test "readiness: a base timeout at the limit gates the queue until the limit can grow" {
  git config found-issues.autofix.testCommand 'sleep 4'
  export FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS=1
  fi_af_queue_fixture; ST="$FI_AF_ST"
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 5 ]
  grep -q '^result=stale: base tests timed out after 1s' "$ST/done/$ID"
  run "$FI_BIN" log --fix small 'src/calc.sh:7 — second bug'
  [[ "$output" == *"Auto-fix: not queued, waiting: base tests timed out at the 1s limit"* ]]
  [ -z "$(ls "$ST/queue")" ]
  run "$FI_BIN" autofix ready
  [[ "$output" == *"last base run: timed out at the 1s limit"* ]]
  [[ "$output" == *"verdict: waiting: base tests timed out"* ]]
  # without the pin, the next limit doubles from the measured one: queue again
  unset FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS
  run "$FI_BIN" log --fix small 'src/calc.sh:9 — third bug'
  [[ "$output" == *"AUTOFIX-QUEUED"* ]]
}

@test "readiness: a gated timeout keeps the sweep from queueing too" {
  source "$FI_BIN"; fi_af_context
  fi_af_ready_write "$REPO" timeout 7200 "sh test.sh"
  fi_af_ready_ok "$REPO" && false
  [[ "$FI_AF_WHY" == "waiting: base tests timed out at the 120 min limit"* ]]
  rc=0; fi_af_sweep_check >"$TMP/sweep.out" || rc=$?
  ! grep -q 'AUTOFIX-SWEEP-DUE' "$TMP/sweep.out" || false
}

@test "readiness: SessionStart summary names a repo with no test command" {
  git config --unset found-issues.autofix.testCommand
  run "$FI_BIN" autofix summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"Auto-fix is waiting in this repo: no test command"* ]]
  [[ "$output" == *"found-issues config autofix.testCommand"* ]]
  [ "$(printf '%s\n' "$output" | grep -c 'waiting in this repo')" = 1 ]
}

@test "readiness: no waiting line when auto-fix is off or nothing is tagged for it" {
  git config --unset found-issues.autofix.testCommand
  git config found-issues.autofix false
  run "$FI_BIN" autofix summary
  [[ "$output" != *"waiting in this repo"* ]] || false
  git config found-issues.autofix true
  printf '# found-issues\n\n- [open] 2026-10-01 src/calc.sh:1 — add subtracts (manual: needs eyes)\n' > docs/found-issues.md
  run "$FI_BIN" autofix summary
  [[ "$output" != *"waiting in this repo"* ]] || false
}

@test "readiness: a ready repo prints no waiting line" {
  fi_af_queue_fixture
  "$FI_BIN" autofix claim "$ID" >/dev/null
  run "$FI_BIN" autofix summary
  [[ "$output" != *"waiting in this repo"* ]] || false
}

@test "superseded: the cited file changed on the base mid-run retires the item at ship" {
  fi_af_queue_fixture; ST="$FI_AF_ST"
  "$FI_BIN" autofix claim "$ID" >/dev/null
  WT="$REPO/.claude/worktrees/fi-autofix-$ID"
  sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"
  "$FI_BIN" autofix verify "$ID" >/dev/null
  push_change src/calc.sh
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -eq 0 ]
  grep -Eq '^result=stale: superseded: src/calc.sh changed on main since [0-9a-f]{7}$' "$ST/done/$ID"
  ! grep -q '^pr create' "$GH_MOCK_TRACE" || false
  grep -q '^- \[open\].*add subtracts' "$REPO/docs/found-issues.md"
}

@test "superseded: a change to another file on the base still ships" {
  fi_af_queue_fixture; ST="$FI_AF_ST"
  "$FI_BIN" autofix claim "$ID" >/dev/null
  WT="$REPO/.claude/worktrees/fi-autofix-$ID"
  sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"
  "$FI_BIN" autofix verify "$ID" >/dev/null
  push_change test.sh
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #7"* ]]
}

@test "superseded: a change landing during the base tests retires before the fixer runs" {
  cat >"$TMP/bump.sh" <<EOF
[ -f "$TMP/bumped" ] && exit 0
: >"$TMP/bumped"
rm -rf "$TMP/other-clone"
git clone -q "$TMP/remote.git" "$TMP/other-clone"
printf '# touched\n' >>"$TMP/other-clone/src/calc.sh"
git -C "$TMP/other-clone" add -A
git -C "$TMP/other-clone" -c user.email=o@x -c user.name=o commit -qm other
git -C "$TMP/other-clone" push -q origin main
EOF
  git config found-issues.autofix.testCommand "sh test.sh && sh '$TMP/bump.sh'"
  fi_af_queue_fixture; ST="$FI_AF_ST"
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  grep -Eq '^result=stale: superseded: src/calc.sh changed on main since [0-9a-f]{7}$' "$ST/done/$ID"
  # the fixer never ran: the stand-in engine left no trace
  [ ! -s "$FI_STANDIN_TRACE" ]
}

@test "superseded: a change far from the cited line does not retire the item" {
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do printf '# filler %s\n' "$i" >>src/calc.sh; done
  git commit -qam filler && git push -q origin main
  fi_af_queue_fixture; ST="$FI_AF_ST"
  "$FI_BIN" autofix claim "$ID" >/dev/null
  WT="$REPO/.claude/worktrees/fi-autofix-$ID"
  sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"
  "$FI_BIN" autofix verify "$ID" >/dev/null
  rm -rf "$TMP/other-clone"
  git clone -q "$TMP/remote.git" "$TMP/other-clone"
  sed -i.bak 's/^# filler 20$/# filler twenty/' "$TMP/other-clone/src/calc.sh"; rm -f "$TMP/other-clone/src/calc.sh.bak"
  git -C "$TMP/other-clone" -c user.email=o@x -c user.name=o commit -qam "far edit"
  git -C "$TMP/other-clone" push -q origin main
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #7"* ]]
}

@test "superseded: a path:name entry counts a changed line naming it; a bare path counts any change" {
  source "$FI_BIN"; fi_af_context
  printf 'wm_check() { :; }\nother() { :; }\n' > src/w.sh
  git add -A && git commit -qm w && git push -q origin main
  AFI_root="$REPO" AFI_base=main AFI_base_sha="$(git rev-parse HEAD)"
  rm -rf "$TMP/other-clone"; git clone -q "$TMP/remote.git" "$TMP/other-clone"
  sed -i.bak 's/^other() { :; }$/other() { true; }/' "$TMP/other-clone/src/w.sh"; rm -f "$TMP/other-clone/src/w.sh.bak"
  git -C "$TMP/other-clone" -c user.email=o@x -c user.name=o commit -qam "edit other"
  git -C "$TMP/other-clone" push -q origin main
  AFI_loc="src/w.sh:wm_check"
  fi_af_superseded && false
  AFI_loc="src/w.sh:other"
  fi_af_superseded
  [[ "$FI_AF_WHY" == "superseded: src/w.sh changed on main since "* ]]
  AFI_loc="src/w.sh"
  fi_af_superseded
}

@test "superseded: a topic entry (no file) is never superseded" {
  source "$FI_BIN"; fi_af_context
  AFI_root="$REPO" AFI_base=main AFI_base_sha="$(git rev-parse HEAD)" AFI_loc="release process"
  push_change src/calc.sh
  fi_af_superseded && false
  true
}
