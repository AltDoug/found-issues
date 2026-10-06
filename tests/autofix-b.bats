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

@test "b: brief offers autofix search instead of Grep and Glob" {
  claim
  run "$FI_BIN" autofix brief "$ID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"found-issues autofix search $ID '<regex>'"* ]]
  [[ "$output" == *"found-issues autofix search $ID --files"* ]]
  [[ "$output" != *"Grep"* ]]
}

@test "b: search greps the claimed worktree, lists its files, and says when nothing matches" {
  claim
  run "$FI_BIN" autofix search "$ID" 'echo \$\(\('
  [ "$status" -eq 0 ]
  [[ "$output" == *"src/calc.sh:1:add()"* ]]
  run "$FI_BIN" autofix search "$ID" 'add' test.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"test.sh:3:"* ]]
  [[ "$output" != *"src/calc.sh"* ]]
  run "$FI_BIN" autofix search "$ID" --files 'src/*'
  [ "$status" -eq 0 ]
  [ "$output" = "src/calc.sh" ]
  run "$FI_BIN" autofix search "$ID" 'no_such_symbol_anywhere'
  [ "$status" -eq 1 ]
  [ "$output" = "no matches" ]
}

@test "b: search never turns its arguments into git flags" {
  claim
  run "$FI_BIN" autofix search "$ID" "--open-files-in-pager=touch $TMP/pwned" "--output=$TMP/pwned2"
  [ "$status" -le 1 ]
  [ ! -e "$TMP/pwned" ]
  [ ! -e "$TMP/pwned2" ]
  run "$FI_BIN" autofix search "$ID" '('
  [ "$status" -eq 2 ]
}

@test "b: search sees a file the fixer just created, but not ignored ones" {
  claim
  printf 'brand_new_marker\n' > "$WT/new.bats"
  printf 'brand_new_marker\n' > "$WT/skip.log"
  printf '*.log\n' > "$WT/.gitignore"
  run "$FI_BIN" autofix search "$ID" brand_new_marker
  [ "$status" -eq 0 ]
  [[ "$output" == *"new.bats:1:brand_new_marker"* ]]
  [[ "$output" != *"skip.log"* ]]
  run "$FI_BIN" autofix search "$ID" --files
  [[ "$output" == *"new.bats"* ]]
  [[ "$output" != *"skip.log"* ]]
}

@test "b: search caps long output and says how much was cut" {
  claim
  for i in $(seq 1 230); do printf 'needle %s\n' "$i"; done > "$WT/many.txt"
  git -C "$WT" add many.txt
  run "$FI_BIN" autofix search "$ID" needle
  [ "$status" -eq 0 ]
  [[ "$output" == *"many.txt:200:needle 200"* ]]
  [[ "$output" != *"many.txt:201:"* ]]
  [[ "$output" == *"[30 more lines; narrow the regex or pass a path]"* ]]
}

@test "b: search refuses an item that is not claimed" {
  run "$FI_BIN" autofix search "$ID" add
  [ "$status" -eq 1 ]
  [[ "$output" == *"not claimed"* ]]
}

@test "b: brief refuses an item that is not claimed" {
  run "$FI_BIN" autofix brief "$ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not claimed"* ]]
}

@test "b: test runs the repo test command in the worktree and reports fail then pass" {
  claim
  printf '# touched\n' >>"$WT/src/calc.sh"   # the bug's test runs once src/ changes
  run "$FI_BIN" autofix test "$ID"
  [ "$status" -ne 0 ]
  [[ "$output" == *"tests: fail"* ]]
  fix_it
  run "$FI_BIN" autofix test "$ID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tests: pass"* ]]
}

# A TAP run whose only failure is far above the last 30 lines; it passes at
# base (claim runs it there first) and fails once fail.flag exists.
tap_fail_cmd() {
  printf '%s' "[ -f fail.flag ] || exit 0; printf 'not ok 1 early %s\n# (in test file t.bats, line 3)\n' failure; i=2; while [ \$i -le 40 ]; do echo \"ok \$i fine\"; i=\$((i+1)); done; exit 1"
}

@test "b: the repo test command runs without FOUND_ISSUES_AUTOFIX_CHILD" {
  git -C "$REPO" config found-issues.autofix.testCommand '[ -z "${FOUND_ISSUES_AUTOFIX_CHILD:-}" ]'
  claim
  run "$FI_BIN" autofix test "$ID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tests: pass"* ]]
}

@test "b: test lists every failing TAP test with its diagnostics, not just the tail" {
  git -C "$REPO" config found-issues.autofix.testCommand "$(tap_fail_cmd)"
  claim
  touch "$WT/fail.flag"
  run "$FI_BIN" autofix test "$ID"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not ok 1 early failure"* ]]
  [[ "$output" == *"# (in test file t.bats, line 3)"* ]]
  [[ "$output" == *"ok 40 fine"* ]]
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

@test "b: claim refuses while auto-fix is switched off and leaves the item queued" {
  "$FI_BIN" autofix off >/dev/null
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"switched off"* ]]
  [ -f "$ST/queue/$ID" ]
  [ ! -d "$REPO/.claude/worktrees/fi-autofix-$ID" ]
}

@test "b: verify switched off mid-fix requeues the item and runs no verifier" {
  claim; fix_it
  "$FI_BIN" autofix off >/dev/null
  run "$FI_BIN" autofix verify "$ID"
  [ "$status" -eq 8 ]
  [[ "$output" == *"requeued; stop"* ]]
  [ -f "$ST/queue/$ID" ]
  [ ! -e "$ST/running/$ID" ]
  ! grep -q 'opus' "$FI_STANDIN_TRACE" 2>/dev/null || false
}

@test "b: ship switched off after approval requeues the item and opens no PR" {
  export GH_MOCK_TRACE="$TMP/gh.trace"
  claim; fix_it
  "$FI_BIN" autofix verify "$ID" >/dev/null
  FOUND_ISSUES_AUTOFIX=off run "$FI_BIN" autofix ship "$ID"
  [ "$status" -eq 8 ]
  [[ "$output" == *"requeued; stop"* ]]
  [ -f "$ST/queue/$ID" ]
  ! grep -q '^pr create' "$GH_MOCK_TRACE" 2>/dev/null || false
}

@test "b: ship refuses an approving verdict with no recorded tree" {
  export GH_MOCK_TRACE="$TMP/gh.trace"
  claim; fix_it
  "$FI_BIN" autofix verify "$ID" >/dev/null
  fi_af_item_set "$ST/running/$ID" verdict_tree ""
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"autofix verify"* ]]
  ! grep -q '^pr create' "$GH_MOCK_TRACE" 2>/dev/null || false
}
