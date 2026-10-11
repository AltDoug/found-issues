#!/usr/bin/env bats
# Ledger batch 4 (lib/autofix.sh:77): a verifier that hits its own run limit
# (error_max_turns, error_max_budget_usd, any error_max_*) is a REJECT, not an
# outage; only the watchdog timeout (FI_AF_CHILD_TIMEDOUT, not a bare exit 124) and a real crash/login/network
# failure are outages. The carve-out in fi_af_collect (error_max_* is not an
# engine error) must hold even when claude -p exits non-zero.

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_fixture; fi_use_standins
  export GH_MOCK_TRACE="$TMP/gh.trace"
  export GH_MOCK_PR_VIEW=$'7\t{"number":7,"state":"OPEN","statusCheckRollup":[]}'
  export FI_STANDIN_EDIT="sed -i.bak 's/ - / + /' src/calc.sh && rm -f src/calc.sh.bak"
  export PATH="$TEST_REPO_ROOT/bin:$PATH"
  fi_af_queue_fixture; ST="$FI_AF_ST"
}
teardown() { fi_teardown_tmp; }

@test "batch4 verifier: error_max_turns with a non-zero exit is a reject, not an outage" {
  export FI_STANDIN_VERIFIER_LIMIT=error_max_turns
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  [ ! -f "$ST/queue/$ID" ]
  grep -q '^result=failed: verifier rejected: ' "$ST/done/$ID"
  grep -q 'error_max_turns' "$ST/done/$ID"
  ! grep -q 'engine error' "$FI_AF_RUNS/$ID.log" || false
  ! grep -q '^outages=' "$ST/done/$ID" || false
}

@test "batch4 verifier: error_max_budget_usd with a non-zero exit is a reject" {
  export FI_STANDIN_VERIFIER_LIMIT=error_max_budget_usd
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  [ ! -f "$ST/queue/$ID" ]
  grep -q '^result=failed: verifier rejected: ' "$ST/done/$ID"
}

@test "batch4 verifier: a future error_max_ subtype is a reject too" {
  export FI_STANDIN_VERIFIER_LIMIT=error_max_structured_output_retries
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '^result=failed: verifier rejected: ' "$ST/done/$ID"
}

@test "batch4 verifier: a limit hit never re-runs the item as an outage, whatever the outage cap" {
  export FI_STANDIN_VERIFIER_LIMIT=error_max_turns FOUND_ISSUES_AUTOFIX_OUTAGE_MAX=1
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  [ ! -f "$ST/queue/$ID" ]
  # fixer + verifier, twice: the normal two-attempt reject path
  [ "$(grep -c '^claude' "$FI_STANDIN_TRACE")" = 4 ]
}

@test "batch4 verifier: autofix verify on a limit hit is a reject (exit 1, one attempt left), not an outage (exit 7)" {
  "$FI_BIN" autofix claim "$ID" >/dev/null
  WT="$REPO/.claude/worktrees/fi-autofix-$ID"
  sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"
  export FI_STANDIN_VERIFIER_LIMIT=error_max_turns
  run "$FI_BIN" autofix verify "$ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"rejected: verifier hit its run limit"* ]]
  run "$FI_BIN" autofix verify "$ID"
  [ "$status" -eq 5 ]
  [ -f "$ST/done/$ID" ]
  [ ! -f "$ST/queue/$ID" ]
}

@test "batch4 verifier: the watchdog timeout is an outage, named explicitly" {
  export FI_STANDIN_VERIFIER_HANG=30 FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS=1
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 7 ]
  [ -f "$ST/queue/$ID" ]
  grep -q 'requeued: engine error: claude verifier exited 124 (timed out)' "$FI_AF_RUNS/$ID.log"
  grep -q '^outages=1$' "$ST/queue/$ID"
}

@test "batch4 verifier: a codex verifier watchdog timeout is an outage, named explicitly" {
  export FI_STANDIN_VERIFIER_HANG=30 FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS=1
  run "$FI_BIN" autofix run "$ID" --engine codex
  [ "$status" -eq 7 ]
  [ -f "$ST/queue/$ID" ]
  grep -q 'requeued: engine error: codex verifier exited 124 (timed out)' "$FI_AF_RUNS/$ID.log"
}

@test "batch4 verifier: a plain crash with no limit subtype is still an outage" {
  export FI_STANDIN_VERIFIER_CRASH=1
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 7 ]
  grep -q 'requeued: engine error: claude verifier exited 1' "$FI_AF_RUNS/$ID.log"
}

@test "batch4 verifier: a real engine error (usage limit) is still an outage" {
  export FI_STANDIN_ERROR="usage limit reached"
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 7 ]
  [ -f "$ST/queue/$ID" ]
}
