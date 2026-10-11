#!/usr/bin/env bats
# Batch 6: fix ship prints the test gate's summary on success too, so the PR
# body can quote it (ledger lib/fix-plumbing.sh:113).

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp
  export PATH="$TEST_REPO_ROOT/bin:$TEST_REPO_ROOT/tests/bin-shims:$PATH"
}
teardown() { fi_teardown_tmp; }

ship_setup() {
  fi_af_fixture
  export GH_MOCK_TRACE="$TMP/gh.trace" GH_MOCK_PR_CREATE_URL=https://github.com/foo/bar/pull/11
  export GH_MOCK_PR_VIEW=$'11\t{"number":11,"state":"OPEN","files":[]}'
  out="$("$FI_BIN" fix workspace)"
  WT="$(printf '%s\n' "$out" | sed -n 's/^worktree=//p')"
  sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"
  git -C "$WT" commit -qam "fix: add subtracts (found-issues src/calc.sh:1)"
  printf 'b\n' > "$TMP/body"
}

@test "b6 fix ship: a green TAP suite prints its plan and counts" {
  ship_setup
  git config found-issues.autofix.testCommand 'echo 1..3; echo "ok 1 a"; echo "ok 2 b # skip slow"; echo "ok 3 c"'
  run "$FI_BIN" fix ship "$WT" --title "fix: add" --body-file "$TMP/body" --pick src/calc.sh:1
  [ "$status" -eq 0 ]
  [[ "$output" == *"tests: pass — 1..3, 3 ok, 0 not ok"* ]]
  [[ "$output" == *"PR #11"* ]]
}

@test "b6 fix ship: a green non-TAP suite still says the gate passed" {
  ship_setup
  git config found-issues.autofix.testCommand 'echo "all good"'
  run "$FI_BIN" fix ship "$WT" --title "fix: add" --body-file "$TMP/body" --pick src/calc.sh:1
  [ "$status" -eq 0 ]
  [[ "$output" == *"tests: pass"* ]]
  [[ "$output" != *"not ok"* ]]
}

@test "b6 fix test: a red TAP suite reports its counts too" {
  ship_setup
  git config found-issues.autofix.testCommand 'echo 1..2; echo "ok 1 a"; echo "not ok 2 b"; exit 1'
  run "$FI_BIN" fix test "$WT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"tests: fail (exit 1) — 1..2, 1 ok, 1 not ok"* ]]
}
