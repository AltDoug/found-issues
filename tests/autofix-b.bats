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
