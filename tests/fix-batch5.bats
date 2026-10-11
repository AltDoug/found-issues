#!/usr/bin/env bats
# Batch 5: an item records engine=auto unless the setting names claude or
# codex, so the draining harness runs it (ledger lib/autofix-hook.sh:124); a
# --global switch-off keeps the STUCK marker of repos still on locally
# (lib/autofix-config.sh:409); fix ship takes repeated --pick flags, so
# fragment picks and plain picks ship together (lib/fix-plumbing.sh:75).

load 'helpers'
load 'autofix-helpers'

HOOK="$TEST_REPO_ROOT/hooks/post-bash-dispatch.sh"

setup() {
  fi_setup_tmp
  export PATH="$TEST_REPO_ROOT/bin:$TEST_REPO_ROOT/tests/bin-shims:$PATH"
  export FOUND_ISSUES_CACHE_DIR="$TMP/cache"
}
teardown() { fi_teardown_tmp; }

seg() { "$FI_BIN" status --format=segment --cwd "${1:-$REPO}"; }

# ===== lib/autofix-hook.sh:124 — engine=auto is resolved at launch =========

queued_engine() { sed -n 's/^engine=//p' "$1"; }

@test "b5 engine: a spot item queued under Claude with the setting unset records auto" {
  fi_af_fixture
  export CLAUDECODE=1
  fi_af_queue_fixture
  [ "$(queued_engine "$QITEM")" = auto ]
}

@test "b5 engine: an explicit codex setting is still recorded as codex" {
  fi_af_fixture
  git config found-issues.autofix.engine codex
  export CLAUDECODE=1
  fi_af_queue_fixture
  [ "$(queued_engine "$QITEM")" = codex ]
}

@test "b5 engine: an explicit claude setting is still recorded as claude" {
  fi_af_fixture
  git config found-issues.autofix.engine claude
  fi_af_queue_fixture
  [ "$(queued_engine "$QITEM")" = claude ]
}

@test "b5 engine: a sweep queued under Claude with the setting unset records auto" {
  fi_af_sweep_fixture 4
  export CLAUDECODE=1
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  SID="$(printf '%s\n' "$output" | sed -n 's/^AUTOFIX-SWEEP-DUE //p')"
  [ -n "$SID" ]
  [ "$(queued_engine "$FOUND_ISSUES_STATE_DIR/autofix/foo__bar/queue/$SID")" = auto ]
}

@test "b5 engine: an item queued under Claude and drained by a Codex hook launches codex" {
  fi_af_fixture
  export CLAUDECODE=1
  fi_af_queue_fixture
  unset CLAUDECODE
  mkdir -p "$TMP/fake"
  printf '#!/usr/bin/env bash\nprintf "%%s|%%s\\n" "$PWD" "$*" >>"%s/spawned"\n' "$TMP" >"$TMP/fake/found-issues"
  chmod +x "$TMP/fake/found-issues"
  export FOUND_ISSUES_BIN="$TMP/fake/found-issues" FOUND_ISSUES_HARNESS=codex FOUND_ISSUES_STOP_REMINDER=off
  local p
  p="$(jq -cn --arg o "AUTOFIX-QUEUED $ID" \
    '{session_id:"s",cwd:"/x",hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:"found-issues log --fix small x"},tool_response:{stdout:$o,stderr:"",interrupted:false},permission_mode:"default"}')"
  run bash -c "printf '%s' '$p' | '$HOOK'"
  [ "$status" -eq 0 ]
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/spawned" ] && break; sleep 0.3; done
  grep -q "autofix run $ID --engine codex$" "$TMP/spawned"
}

@test "b5 engine: a spot run of an auto item records the engine it ran on" {
  fi_af_fixture; fi_use_standins
  export CLAUDECODE=1
  fi_af_queue_fixture
  "$FI_BIN" autofix run "$ID" --engine codex || true
  [ "$(queued_engine "$FI_AF_ST/done/$ID")" = codex ]
}

@test "b5 engine: a continuation of an auto sweep keeps the engine its chain resolved" {
  fi_af_sweep_fixture 4; fi_use_standins
  export CLAUDECODE=1
  export FI_STANDIN_EDIT='mkdir -p tests; for f in src/f*.sh; do n="${f#src/f}"; n="${n%.sh}"; case "$FI_STANDIN_PROMPT" in *"src/f$n.sh:1"*) sed -i.bak "s/- 1/+ 0/" "$f"; rm -f "$f.bak"; printf "[ \"\$(f%s 2)\" = 2 ]\n" "$n" >> tests/t_f$n.sh ;; esac; done'
  export GH_MOCK_TRACE="$TMP/gh.trace" GH_MOCK_PR_CREATE_URL=https://github.com/foo/bar/pull/9
  export GH_MOCK_PR_VIEW=$'9\t{"number":9,"state":"OPEN","statusCheckRollup":[]}'
  git config found-issues.autofix.sweepBatch 2
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  SID="$(printf '%s\n' "$output" | sed -n 's/^AUTOFIX-SWEEP-DUE //p')"
  ST="$FOUND_ISSUES_STATE_DIR/autofix/foo__bar"
  [ "$(queued_engine "$ST/queue/$SID")" = auto ]
  "$FI_BIN" autofix run "$SID" --engine codex
  c="$(grep -l '^cont=2' "$ST"/done/* "$ST"/queue/* 2>/dev/null | head -1)"
  [ -n "$c" ]
  [ "$(queued_engine "$c")" = codex ]
}

# ===== lib/autofix-config.sh:409 — a --global off keeps local-on repos =====

stuck_setup() {
  fi_af_fixture
  fi_af_queue_fixture
  ST="$FI_AF_ST"
  git config found-issues.autofix.testCommand 'echo "not ok 1 needs donor files"; exit 1'
  git config found-issues.autofix.dailyFixes 50
  STUCK_FILE="$FI_AF_ROOT/stuck/${REPO//[^A-Za-z0-9._-]/_}"
}
retire_one() {
  local id
  id="$(ls "$ST/queue" | head -1)"
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 5 ]
  "$FI_BIN" log --fix small "test.sh:$(( $1 + 10 )) — entry $1" >/dev/null
}
make_stuck() { retire_one 1; retire_one 2; retire_one 3; run seg; [[ "$output" == *"stuck"* ]]; }

@test "b5 stuck: the stuck file records the repo root on line 4" {
  stuck_setup; make_stuck
  [ "$(sed -n 4p "$STUCK_FILE")" = "$REPO" ]
}

@test "b5 stuck: config autofix false --global keeps the marker of a repo whose local setting is true" {
  stuck_setup; make_stuck
  run "$FI_BIN" config autofix false --global
  [ "$status" -eq 0 ]
  [ -f "$STUCK_FILE" ]
  run seg
  [[ "$output" == *"stuck"* ]]
}

@test "b5 stuck: config autofix false --global clears the marker of a repo with no local setting" {
  stuck_setup; make_stuck
  git config --global found-issues.autofix true
  git config --unset found-issues.autofix
  run "$FI_BIN" config autofix false --global
  [ "$status" -eq 0 ]
  [ ! -f "$STUCK_FILE" ]
}

@test "b5 stuck: a --global off clears a pre-3.8.1 stuck file that names no root" {
  stuck_setup; make_stuck
  printf '3\nx\n%s\n' "$(date +%s)" >"$STUCK_FILE"
  run "$FI_BIN" config autofix false --global
  [ "$status" -eq 0 ]
  [ ! -f "$STUCK_FILE" ]
}

@test "b5 stuck: autofix off (the kill switch) still clears every marker" {
  stuck_setup; make_stuck
  run "$FI_BIN" autofix off
  [ "$status" -eq 0 ]
  [ ! -f "$STUCK_FILE" ]
  "$FI_BIN" autofix on >/dev/null
}

# ===== lib/fix-plumbing.sh:75 — repeated --pick ============================

ship_setup() {
  fi_af_fixture
  export GH_MOCK_TRACE="$TMP/gh.trace" GH_MOCK_PR_CREATE_URL=https://github.com/foo/bar/pull/11
  export GH_MOCK_PR_VIEW=$'11\t{"number":11,"state":"OPEN","files":[]}'
  printf -- '- [open] 2026-10-02 src/calc.sh:1 — add is slow\n- [open] 2026-10-02 src/other.sh:2 — other bug\n' >> docs/found-issues.md
  git commit -qam entries && git push -q origin main
  out="$("$FI_BIN" fix workspace)"
  WT="$(printf '%s\n' "$out" | sed -n 's/^worktree=//p')"
  sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"
  git -C "$WT" commit -qam "fix: add subtracts (found-issues src/calc.sh:1)"
  printf 'b\n' > "$TMP/body"
}

@test "b5 fix ship: a fragment pick and a plain pick in two --pick flags both annotate" {
  ship_setup
  run "$FI_BIN" fix ship "$WT" --title "fix: add" --body-file "$TMP/body" \
    --pick "src/calc.sh:1 — add subtracts" --pick src/other.sh:2
  [ "$status" -eq 0 ]
  grep -F 'add subtracts' "$REPO/docs/found-issues.md" | grep -q '(PR: foo/bar#11)'
  grep -F 'other bug' "$REPO/docs/found-issues.md" | grep -q '(PR: foo/bar#11)'
  ! grep -F 'add is slow' "$REPO/docs/found-issues.md" | grep -q '(PR: foo/bar#11)' || false
  # the same annotation is committed onto the PR branch
  git -C "$WT" show HEAD:docs/found-issues.md | grep -F 'add subtracts' | grep -q '(PR: foo/bar#11)'
  git -C "$WT" show HEAD:docs/found-issues.md | grep -F 'other bug' | grep -q '(PR: foo/bar#11)'
}

@test "b5 fix ship: a comma list in one --pick still splits" {
  ship_setup
  run "$FI_BIN" fix ship "$WT" --title "fix: add" --body-file "$TMP/body" --pick "src/other.sh:2,src/nope.sh:9"
  [ "$status" -ne 0 ]
  [[ "$output" == *"src/nope.sh:9"* ]]
  grep -F 'other bug' "$REPO/docs/found-issues.md" | grep -q '(PR: foo/bar#11)'
}

@test "b5 fix ship: usage names the repeatable --pick" {
  run "$FI_BIN" fix
  [[ "$output" == *"--pick <loc>[,<loc>...] [--pick <loc> — <fragment>]..."* ]]
}
