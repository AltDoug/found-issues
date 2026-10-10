#!/usr/bin/env bats
# Batch 4 review follow-up (lib/autofix.sh fixer path): like the verifier, the
# fixer's watchdog timeout is told by FI_AF_CHILD_TIMEDOUT, never by a bare
# exit 124 (3.4.2 convention). A fixer that exits 124 on its own is an engine
# error, not a timeout.

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_fixture; fi_use_standins
  export GH_MOCK_TRACE="$TMP/gh.trace"
  export GH_MOCK_PR_VIEW=$'7\t{"number":7,"state":"OPEN","statusCheckRollup":[]}'
  export PATH="$TEST_REPO_ROOT/bin:$PATH"
  fi_af_queue_fixture; ST="$FI_AF_ST"
}
teardown() { fi_teardown_tmp; }

@test "batch4 fixer: a fixer that exits 124 by itself is an engine error, not a timeout" {
  export FI_STANDIN_FIXER_CRASH=124
  run "$FI_BIN" autofix run "$ID" --engine claude
  grep -q 'fixer rc=124' "$FI_AF_RUNS/$ID.log"
  ! grep -q 'fixer timed out' "$FI_AF_RUNS/$ID.log" || false
  grep -q 'claude exited 124' "$FI_AF_RUNS/$ID.log"
}

@test "batch4 fixer: a fixer killed by the watchdog is logged as timed out" {
  export FI_STANDIN_SLEEP=5 FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS=1
  run "$FI_BIN" autofix run "$ID" --engine claude
  grep -q 'fixer timed out' "$FI_AF_RUNS/$ID.log"
}
