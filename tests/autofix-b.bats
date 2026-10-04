#!/usr/bin/env bats
# v3 launcher B fixer-side CLI (spec §4.2-§4.3, §5; phase 3 plan Tasks 3-4).

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_fixture; fi_use_standins
  fi_af_queue_fixture; ST="$FI_AF_ST"
}
teardown() { fi_teardown_tmp; }

claim() { "$FI_BIN" autofix claim "$ID" >/dev/null; WT="$REPO/.claude/worktrees/fi-autofix-$ID"; }
fix_it() { sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"; }

@test "b: a standalone claim records launcher B and no pid" {
  claim
  grep -q '^launcher=B$' "$ST/running/$ID"
  grep -q '^pid=$' "$ST/running/$ID"
}

@test "b: a standalone claim survives a later run while its lock is fresh" {
  claim
  "$FI_BIN" log --fix small "src/calc.sh:1 — add ignores a third argument" >/dev/null
  other="$(ls "$ST/queue" | head -1)"
  [ -n "$other" ]
  run "$FI_BIN" autofix run "$other" --engine claude
  [ "$status" -eq 4 ]
  [ -f "$ST/running/$ID" ]
  [ -d "$WT" ]
}

@test "b: brief names the entry, worktree, branch, test command and the allowed calls" {
  claim
  run "$FI_BIN" autofix brief "$ID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"add subtracts"* ]]
  [[ "$output" == *"$WT"* ]]
  [[ "$output" == *"fi/autofix/"* ]]
  [[ "$output" == *"sh test.sh"* ]]
  [[ "$output" == *"found-issues autofix test $ID"* ]]
  [[ "$output" == *"found-issues autofix verify $ID"* ]]
  [[ "$output" == *"found-issues autofix ship $ID"* ]]
  [[ "$output" == *"found-issues autofix release $ID"* ]]
}

@test "b: brief refuses an item that is not claimed" {
  run "$FI_BIN" autofix brief "$ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not claimed"* ]]
}

@test "b: test runs the repo test command in the worktree and reports fail then pass" {
  claim
  run "$FI_BIN" autofix test "$ID"
  [ "$status" -ne 0 ]
  [[ "$output" == *"tests: fail"* ]]
  fix_it
  run "$FI_BIN" autofix test "$ID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tests: pass"* ]]
}

@test "b: test refreshes the repo lock" {
  claim
  touch -t 202001010000 "$ST/lock"
  "$FI_BIN" autofix test "$ID" >/dev/null || true
  [ "$(find "$ST" -maxdepth 1 -name lock -mmin -5 | wc -l | tr -d ' ')" = 1 ]
}

@test "b: verify approves a green fix and records the verdict and tree" {
  claim; fix_it
  run "$FI_BIN" autofix verify "$ID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"approved"* ]]
  grep -q '^verdict=approve$' "$ST/running/$ID"
  grep -Eq '^verdict_tree=[0-9a-f]{40}$' "$ST/running/$ID"
  grep -q '^attempts=1$' "$ST/running/$ID"
}

@test "b: verify refuses red tests without counting an attempt" {
  claim
  printf '# touched\n' >>"$WT/src/calc.sh"
  run "$FI_BIN" autofix verify "$ID"
  [ "$status" -eq 3 ]
  ! grep -q '^attempts=[1-9]' "$ST/running/$ID" || false
}

@test "b: verify with no change exits 2" {
  claim
  run "$FI_BIN" autofix verify "$ID"
  [ "$status" -eq 2 ]
  [[ "$output" == *"nothing to verify"* ]]
}

@test "b: two rejects finish the item as failed" {
  claim; fix_it
  printf '%s\n' '{"approve":false,"reason":"no test"}' '{"approve":false,"reason":"still no test"}' >"$TMP/verdicts"
  export FI_STANDIN_VERDICTS="$TMP/verdicts"
  run "$FI_BIN" autofix verify "$ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no test"* ]]
  run "$FI_BIN" autofix verify "$ID"
  [ "$status" -eq 5 ]
  [ -f "$ST/done/$ID" ]
  grep -q '(autofix-failed: verifier rejected: still no test' "$REPO/docs/found-issues.md"
}

@test "b: an unavailable verifier requeues the item" {
  claim; fix_it
  export FI_STANDIN_ERROR="usage limit reached"
  run "$FI_BIN" autofix verify "$ID"
  [ "$status" -eq 7 ]
  [ -f "$ST/queue/$ID" ]
}

@test "b: ship refuses without an approving verdict" {
  claim; fix_it
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"autofix verify"* ]]
}

@test "b: ship refuses a tree that changed after approval" {
  claim; fix_it
  "$FI_BIN" autofix verify "$ID" >/dev/null
  printf '# later edit\n' >>"$WT/src/calc.sh"
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"differs from what the verifier approved"* ]]
}

@test "b: claim, test, verify, ship end to end opens a PR labelled launcher B" {
  export GH_MOCK_TRACE="$TMP/gh.trace"
  export GH_MOCK_PR_VIEW=$'7\t{"number":7,"state":"OPEN","statusCheckRollup":[]}'
  claim; fix_it
  "$FI_BIN" autofix test "$ID" >/dev/null
  "$FI_BIN" autofix verify "$ID" >/dev/null
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #7"* ]]
  grep -q 'launcher B' "$FI_AF_RUNS/$ID.pr-body.md"
  [ -f "$ST/done/$ID" ]
}
