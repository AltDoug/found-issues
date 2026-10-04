#!/usr/bin/env bats
# v3 auto-fix release outcomes (spec §5 steps 2 and 4).

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_fixture; fi_af_queue_fixture; ST="$FI_AF_ST"
  "$FI_BIN" autofix claim "$ID" >/dev/null
  WT="$REPO/.claude/worktrees/fi-autofix-$ID"
}
teardown() { fi_teardown_tmp; }

assert_released() {
  [ -f "$ST/done/$ID" ]
  [ ! -e "$ST/running/$ID" ]
  [ ! -d "$ST/lock" ]
  [ ! -d "$WT" ]
  ! git -C "$REPO" rev-parse --verify -q "refs/heads/fi/autofix/src-calc-sh-1-$ID" || false
}

@test "autofix release: --failed tags the entry and keeps the fix tag" {
  run "$FI_BIN" autofix release "$ID" --failed "tests fail after 2 attempts"
  [ "$status" -eq 0 ]
  grep -q '(fix: small) (autofix-failed: tests fail after 2 attempts)$' docs/found-issues.md
  grep -q '^result=failed: tests fail after 2 attempts$' "$ST/done/$ID"
  assert_released
}

@test "autofix release: --decide swaps the fix tag for the question" {
  run "$FI_BIN" autofix release "$ID" --decide "plus or a lookup table?"
  [ "$status" -eq 0 ]
  grep -q 'add subtracts (decide: plus or a lookup table?)$' docs/found-issues.md
  ! grep -q '(fix: small)' docs/found-issues.md || false
  assert_released
}

@test "autofix release: --manual records why" {
  run "$FI_BIN" autofix release "$ID" --manual "needs a real device"
  grep -q '(manual: needs a real device)$' docs/found-issues.md
  assert_released
}

@test "autofix release: --already-fixed closes the entry as verified by ai" {
  run "$FI_BIN" autofix release "$ID" --already-fixed "add already uses plus at origin/main"
  [ "$status" -eq 0 ]
  grep -q "^- \[fixed\] 2026-10-01 src/calc.sh:1 — add subtracts (fix: small) (verified: ai) (fixed: $(date +%Y-%m-%d))$" docs/found-issues.md
  grep -q 'already-fixed: add already uses plus' "$ST/done/$ID"
  assert_released
}

@test "autofix release: an entry removed from the ledger still releases the item" {
  printf '# found-issues\n\n' > docs/found-issues.md
  run "$FI_BIN" autofix release "$ID" --failed "boom"
  [ "$status" -eq 0 ]
  assert_released
}

@test "autofix release: needs exactly one outcome and a text" {
  run "$FI_BIN" autofix release "$ID"
  [ "$status" -eq 2 ]
  run "$FI_BIN" autofix release "$ID" --failed
  [ "$status" -eq 2 ]
  run "$FI_BIN" autofix release nope --failed x
  [ "$status" -eq 1 ]
}

@test "autofix release: the second crash tags the entry crashed" {
  fi_af_context   # setup already sourced the CLI (a second source hits its readonly vars)
  fi_af_item_set "$ST/running/$ID" pid 999999
  fi_af_item_set "$ST/running/$ID" crashes 1
  fi_af_reap
  grep -q '(autofix-failed: crashed)$' docs/found-issues.md
}
