#!/usr/bin/env bats
# v3 launcher A end to end with stand-in engines (spec §5, §9, §10).

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_fixture; fi_use_standins
  export GH_MOCK_TRACE="$TMP/gh.trace"
  export GH_MOCK_PR_VIEW=$'7\t{"number":7,"state":"OPEN","statusCheckRollup":[]}'
  export FI_STANDIN_EDIT="sed -i.bak 's/ - / + /' src/calc.sh && rm -f src/calc.sh.bak"
  fi_af_queue_fixture; ST="$FI_AF_ST"
}
teardown() { fi_teardown_tmp; }

@test "autofix run: claude engine ships a self-merging PR and cleans up" {
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '^result=shipped: PR #7' "$ST/done/$ID"
  grep -q '^pr=7$' "$ST/done/$ID"
  grep -q '^cost=0.5000$' "$ST/done/$ID"
  [ ! -d "$REPO/.claude/worktrees/fi-autofix-$ID" ]
  [ ! -d "$ST/lock" ]
  grep -q '(PR: foo/bar#7)' "$REPO/docs/found-issues.md"
  [ "$(grep -c '^claude' "$FI_STANDIN_TRACE")" = 2 ]
  grep -q '^pr merge 7 --auto --squash$' "$GH_MOCK_TRACE"
}

@test "autofix run: codex engine ships and records tokens" {
  run "$FI_BIN" autofix run "$ID" --engine codex
  [ "$status" -eq 0 ]
  grep -q '^result=shipped: PR #7' "$ST/done/$ID"
  grep -q '^tokens=3000$' "$ST/done/$ID"
  grep -q 'workspace-write' "$FI_STANDIN_TRACE"
  grep -q 'read-only' "$FI_STANDIN_TRACE"
}

@test "autofix run: a reject then an approve ships on attempt 2 from a reset worktree" {
  printf '%s\n' '{"approve":false,"reason":"no test added"}' '{"approve":true,"reason":"ok now"}' > "$TMP/verdicts"
  export FI_STANDIN_VERDICTS="$TMP/verdicts"
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '^result=shipped' "$ST/done/$ID"
  [ "$(grep -c '^claude' "$FI_STANDIN_TRACE")" = 4 ]
  grep -q 'no test added' "$FI_STANDIN_TRACE"
}

@test "autofix run: two failed attempts tag autofix-failed and ship nothing" {
  export FI_STANDIN_EDIT="true"
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '(autofix-failed: no change after 2 attempts)$' "$REPO/docs/found-issues.md"
  grep -q '^result=failed' "$ST/done/$ID"
  ! grep -q 'pr create' "$GH_MOCK_TRACE" 2>/dev/null
  [ ! -d "$REPO/.claude/worktrees/fi-autofix-$ID" ]
}

@test "autofix run: red tests after the edit count as a failed attempt" {
  export FI_STANDIN_EDIT="echo '# touched' >> src/calc.sh"
  run "$FI_BIN" autofix run "$ID" --engine claude
  grep -q '(autofix-failed: tests fail after 2 attempts)$' "$REPO/docs/found-issues.md"
}

@test "autofix run: FI-RESULT decide releases the entry to the decision queue" {
  export FI_STANDIN_RESULT="FI-RESULT: decide plus, or a lookup table?"
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  grep -q 'add subtracts (decide: plus, or a lookup table?)$' "$REPO/docs/found-issues.md"
  [ "$(grep -c '^claude' "$FI_STANDIN_TRACE")" = 1 ]
}

@test "autofix run: no test command releases as manual without starting an engine" {
  git config --unset found-issues.autofix.testCommand
  run "$FI_BIN" autofix run "$ID" --engine claude
  grep -q '(manual: no test command)$' "$REPO/docs/found-issues.md"
  [ ! -s "$FI_STANDIN_TRACE" ]
}

@test "autofix run: a hung engine is killed and the run still ends with an outcome" {
  export FI_STANDIN_SLEEP=30 FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS=1
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '(autofix-failed: ' "$REPO/docs/found-issues.md"
  [ ! -d "$ST/lock" ]
}

@test "autofix run: a spent budget stops before the next child" {
  git config found-issues.autofix.runBudget 0.3
  export FI_STANDIN_COST=0.25
  run "$FI_BIN" autofix run "$ID" --engine claude
  grep -q '(autofix-failed: run budget spent' "$REPO/docs/found-issues.md"
  [ "$(grep -c '^claude' "$FI_STANDIN_TRACE")" = 1 ]
}

@test "autofix run: drains the rest of the queue oldest first" {
  printf -- '- [open] 2026-10-02 test.sh:2 — second thing (fix: small)\n' >> "$REPO/docs/found-issues.md"
  git -C "$REPO" commit -qam "second entry" && git -C "$REPO" push -q
  fi_af_context   # setup already sourced the CLI (a second source hits its readonly vars)
  sleep 1
  fi_af_queue_spot "$(grep 'second thing' "$REPO/docs/found-issues.md")" >/dev/null
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$(ls "$ST/done" | wc -l | tr -d ' ')" = 2 ]
  [ -z "$(ls "$ST/queue")" ]
}

@test "autofix run: capped or locked leaves the item queued and exits 0" {
  fi_af_context   # setup already sourced the CLI (a second source hits its readonly vars)
  fi_af_lock someone-else
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  [ -f "$ST/queue/$ID" ]
  [ ! -s "$FI_STANDIN_TRACE" ]
}

@test "autofix status: shows the switch, today's count, queue and results" {
  run "$FI_BIN" autofix status
  [[ "$output" == *"Auto-fix: on"* ]]
  [[ "$output" == *"Queued (1)"* ]]
  [[ "$output" == *"src/calc.sh:1"* ]]
  "$FI_BIN" autofix run "$ID" --engine claude >/dev/null
  run "$FI_BIN" autofix status
  [[ "$output" == *"Today: 1/5 spot fixes"* ]]
  [[ "$output" == *"shipped: PR #7"* ]]
  "$FI_BIN" autofix off >/dev/null
  run "$FI_BIN" autofix status
  [[ "$output" == *"Auto-fix: off"* ]]
}
