#!/usr/bin/env bats
# v3 launcher B for sweeps (spec §4.2, §6; phase 4 plan Task 6).

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_sweep_fixture 4; fi_use_standins
  export GH_MOCK_TRACE="$TMP/gh.trace" GH_MOCK_PR_CREATE_URL=https://github.com/foo/bar/pull/9
  export GH_MOCK_PR_VIEW=$'9\t{"number":9,"state":"OPEN","statusCheckRollup":[]}'
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  SID="$(printf '%s\n' "$output" | sed -n 's/^AUTOFIX-SWEEP-DUE //p')"
  ST="$FOUND_ISSUES_STATE_DIR/autofix/foo__bar"
  "$FI_BIN" autofix claim "$SID" >/dev/null
  WT="$REPO/.claude/worktrees/fi-sweep-$SID"
}
teardown() { fi_teardown_tmp; }

fix_current() { # fix the entry `next` names (an fN entry), with a test
  loc="$("$FI_BIN" autofix next "$SID" | sed -n 's/^Entry [0-9]*\/[0-9]*: .* \(src\/f[0-9]*\.sh\):1 .*/\1/p')"
  [ -n "$loc" ]
  n="${loc#src/f}"; n="${n%.sh}"
  sed -i.bak 's/- 1/+ 0/' "$WT/$loc"; rm -f "$WT/$loc.bak"
  printf '[ "$(f%s 2)" = 2 ]\n' "$n" >> "$WT/test.sh"
}

@test "sweep b: brief lists next, test, verify, release and ship" {
  run "$FI_BIN" autofix brief "$SID"
  [ "$status" -eq 0 ]
  for c in next test verify release ship; do [[ "$output" == *"found-issues autofix $c $SID"* ]]; done
  [[ "$output" == *"$WT"* ]]
  [[ "$output" == *"Entries:  5"* ]]
}

@test "sweep b: next names entry 1 of 5" {
  run "$FI_BIN" autofix next "$SID"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "Entry 1/5: - [open] "* ]]
}

@test "sweep b: next on a spot item is refused" {
  "$FI_BIN" log --fix small 'src/calc.sh:2 — add is slow' >/dev/null
  qid="$(ls "$ST/queue" | head -1)"
  run "$FI_BIN" autofix next "$qid"
  [ "$status" -ne 0 ]
}

@test "sweep b: verify approves, commits and advances" {
  fix_current
  run "$FI_BIN" autofix verify "$SID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"autofix next $SID"* ]]
  grep -q '^cur=2$' "$ST/running/$SID"
  grep -q '^fixed=1$' "$ST/running/$SID"
  [ -z "$(git -C "$WT" status --porcelain)" ]
}

@test "sweep b: two rejects fail the entry and the sweep goes on" {
  fix_current
  printf '%s\n' '{"approve":false,"reason":"no"}' '{"approve":false,"reason":"no"}' > "$TMP/v"
  export FI_STANDIN_VERDICTS="$TMP/v"
  run "$FI_BIN" autofix verify "$SID"; [ "$status" -eq 1 ]
  run "$FI_BIN" autofix verify "$SID"; [ "$status" -eq 5 ]
  [[ "$output" == *"autofix next $SID"* ]]
  grep -q '^cur=2$' "$ST/running/$SID"
  [ -f "$ST/running/$SID" ]
  [ -z "$(git -C "$WT" status --porcelain)" ]
}

@test "sweep b: release settles only the current entry" {
  run "$FI_BIN" autofix release "$SID" --manual "needs hardware"
  [ "$status" -eq 0 ]
  [[ "$output" == *"autofix next $SID"* ]]
  grep -q '^cur=2$' "$ST/running/$SID"
  [ "$(grep -c '(manual: needs hardware)' docs/found-issues.md)" = 1 ]
  [ -f "$ST/running/$SID" ]
}

@test "sweep b: ship after the last entry opens one PR" {
  fix_current; "$FI_BIN" autofix verify "$SID" >/dev/null
  for i in 2 3 4 5; do "$FI_BIN" autofix release "$SID" --failed "skip" >/dev/null; done
  run "$FI_BIN" autofix next "$SID"
  [[ "$output" == *"No entries left"* ]]
  run "$FI_BIN" autofix ship "$SID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #9"* ]]
  [ -f "$ST/done/$SID" ]
  [ "$(grep -c '^pr create' "$GH_MOCK_TRACE")" = 1 ]
}

@test "sweep b: ship with nothing fixed finishes stale, no PR" {
  for i in 1 2 3 4 5; do "$FI_BIN" autofix release "$SID" --failed "skip" >/dev/null; done
  run "$FI_BIN" autofix ship "$SID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fixed nothing"* ]]
  [ -f "$ST/done/$SID" ]
  ! grep -q '^pr create' "$GH_MOCK_TRACE" 2>/dev/null || false
}

@test "sweep b: verify with no entry in progress says to ship" {
  for i in 1 2 3 4 5; do "$FI_BIN" autofix release "$SID" --failed "skip" >/dev/null; done
  run "$FI_BIN" autofix verify "$SID"
  [ "$status" -eq 2 ]
  [[ "$output" == *"autofix ship $SID"* ]]
}
