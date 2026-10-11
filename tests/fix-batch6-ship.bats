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

@test "b6 fix ship: a green TAP suite prints its counts and the PR body carries them" {
  ship_setup
  git config found-issues.autofix.testCommand 'echo 1..3; echo "ok 1 a"; echo "ok 2 b # skip slow"; echo "ok 3 c"'
  export GH_MOCK_PR_BODY_COPY="$TMP/sent-body"
  run "$FI_BIN" fix ship "$WT" --title "fix: add" --body-file "$TMP/body" --pick src/calc.sh:1
  [ "$status" -eq 0 ]
  [[ "$output" == *"tests: pass — 3 planned, 2 ok, 0 not ok, 1 skipped"* ]]
  [[ "$output" == *"PR #11"* ]]
  head -n 1 "$TMP/sent-body" | grep -qx 'b'
  grep -q 'Test gate (`fix ship`): tests: pass — 3 planned, 2 ok, 0 not ok, 1 skipped' "$TMP/sent-body"
  [ "$(cat "$TMP/body")" = b ]
}

@test "b6 fix test: a command that runs bats twice sums both plans" {
  ship_setup
  git config found-issues.autofix.testCommand 'echo 1..2; echo "ok 1 a"; echo "ok 2 b"; echo 1..3; echo "ok 1 c"; echo "ok 2 d"; echo "ok 3 e"'
  run "$FI_BIN" fix test "$WT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tests: pass — 5 planned, 5 ok, 0 not ok"* ]]
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
  [[ "$output" == *"tests: fail (exit 1) — 2 planned, 1 ok, 1 not ok"* ]]
}

# ===== lib/autofix-queue.sh:583 — a crashed run's commits survive the reap ===

crash_setup() {
  fi_af_fixture
  fi_af_queue_fixture
  "$FI_BIN" autofix claim "$ID" >/dev/null
  WT="$(sed -n 's/^wt=//p' "$FI_AF_ST/running/$ID")"
  BR="$(sed -n 's/^branch=//p' "$FI_AF_ST/running/$ID")"
  fi_af_item_set "$FI_AF_ST/running/$ID" pid 999999
}

@test "b6 reap: a dead run with commits past its base keeps them on fi/rescued/<id>" {
  crash_setup
  sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"
  git -C "$WT" commit -qam "fix: add subtracts"
  sha="$(git -C "$WT" rev-parse HEAD)"
  fi_af_reap
  [ -f "$FI_AF_ST/queue/$ID" ]
  [ "$(git rev-parse "refs/heads/fi/rescued/$ID")" = "$sha" ]
  [ -z "$(git branch --list "$BR")" ]
  [ ! -d "$WT" ]
  grep -q "fi/rescued/$ID" "$FI_AF_RUNS/$ID.log"
  grep -q "^rescued=fi/rescued/$ID$" "$FI_AF_ST/queue/$ID"
  run "$FI_BIN" autofix status
  [[ "$output" == *"commits kept on local branch fi/rescued/$ID"* ]]
}

@test "b6 reap: a dead run with no commits still drops its branch" {
  crash_setup
  fi_af_reap
  [ -f "$FI_AF_ST/queue/$ID" ]
  [ -z "$(git branch --list "$BR")" ]
  [ -z "$(git branch --list "fi/rescued/*")" ]
  ! grep -q '^rescued=' "$FI_AF_ST/queue/$ID" || false
}

@test "b6 reap: a second crash with no commits of its own still names the first one's branch" {
  crash_setup
  sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"
  git -C "$WT" commit -qam "fix: add subtracts"
  sha="$(git -C "$WT" rev-parse HEAD)"
  fi_af_reap
  "$FI_BIN" autofix claim "$ID" >/dev/null
  fi_af_item_set "$FI_AF_ST/running/$ID" pid 999999
  fi_af_reap
  [ -f "$FI_AF_ST/done/$ID" ]
  [ "$(git rev-parse "refs/heads/fi/rescued/$ID")" = "$sha" ]
  grep -q '^result=failed: crashed$' "$FI_AF_ST/done/$ID"
  grep -q "^rescued=fi/rescued/$ID$" "$FI_AF_ST/done/$ID"
  run "$FI_BIN" autofix status
  [[ "$output" == *"commits kept on local branch fi/rescued/$ID"* ]]
}

@test "b6 reap: the ledger tag of a crashed spot item never names the local branch" {
  crash_setup
  fi_af_reap
  "$FI_BIN" autofix claim "$ID" >/dev/null
  WT="$(sed -n 's/^wt=//p' "$FI_AF_ST/running/$ID")"
  fi_af_item_set "$FI_AF_ST/running/$ID" pid 999999
  sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"
  git -C "$WT" commit -qam "fix: add subtracts"
  fi_af_reap
  grep -q '(autofix-failed: crashed)' docs/found-issues.md
  ! grep -q 'fi/rescued' docs/found-issues.md || false
  [ -n "$(git branch --list "fi/rescued/$ID")" ]
}

@test "b6 reap: a rename git refuses keeps the branch under its own name" {
  crash_setup
  sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"
  git -C "$WT" commit -qam "fix: add subtracts"
  sha="$(git -C "$WT" rev-parse HEAD)"
  mkdir -p "$(git rev-parse --git-common-dir)/refs/heads/fi/rescued"
  : > "$(git rev-parse --git-common-dir)/refs/heads/fi/rescued/$ID.lock"
  fi_af_reap
  [ -f "$FI_AF_ST/queue/$ID" ]
  [ "$(git rev-parse "refs/heads/$BR")" = "$sha" ]
  grep -q "could not rename $BR" "$FI_AF_RUNS/$ID.log"
  grep -q "^rescued=$BR$" "$FI_AF_ST/queue/$ID"
}
