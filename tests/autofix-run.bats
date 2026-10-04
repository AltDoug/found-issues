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
  grep -q '^pr merge 7 --auto --squash --repo foo/bar$' "$GH_MOCK_TRACE"
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
  ! grep -q 'pr create' "$GH_MOCK_TRACE" 2>/dev/null || false
  [ ! -d "$REPO/.claude/worktrees/fi-autofix-$ID" ]
}

@test "autofix run: red tests after the edit count as a failed attempt" {
  export FI_STANDIN_EDIT="echo '# touched' >> src/calc.sh"
  run "$FI_BIN" autofix run "$ID" --engine claude
  grep -q '(autofix-failed: tests fail after 2 attempts)$' "$REPO/docs/found-issues.md"
}

@test "autofix run: retry feedback names the failing tests, not just the tail" {
  git config found-issues.autofix.testCommand "printf 'not ok 1 early %s\n' failure; i=2; while [ \$i -le 40 ]; do echo \"ok \$i fine\"; i=\$((i+1)); done; exit 1"
  run "$FI_BIN" autofix run "$ID" --engine claude
  grep -q 'not ok 1 early failure' "$FI_STANDIN_TRACE"
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

@test "autofix run: locked leaves the item queued, starts no engine, exits 4" {
  fi_af_context   # setup already sourced the CLI (a second source hits its readonly vars)
  fi_af_lock someone-else
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 4 ]
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

@test "autofix run: a fixer that left a change but said manual is still tested and verified" {
  export FI_STANDIN_RESULT="FI-RESULT: manual could not run the tests"
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '^result=shipped: PR #7' "$ST/done/$ID"
}

@test "autofix run: cost is recorded for every outcome, not only shipped" {
  export FI_STANDIN_RESULT="FI-RESULT: decide plus or table?" FI_STANDIN_EDIT=true
  run "$FI_BIN" autofix run "$ID" --engine claude
  grep -q '^cost=0.2500$' "$ST/done/$ID"
}

@test "autofix run: an engine outage requeues the item untagged and stops the drain" {
  export FI_STANDIN_ERROR="usage limit reached" FI_STANDIN_EDIT=true
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 7 ]
  [[ "$output" == *"engine error"* ]]
  [ -f "$ST/queue/$ID" ]
  ! grep -q 'autofix-failed' "$REPO/docs/found-issues.md" || false
  [ "$(grep -c '^claude' "$FI_STANDIN_TRACE")" = 1 ]
  [ ! -d "$ST/lock" ]
  [ ! -d "$REPO/.claude/worktrees/fi-autofix-$ID" ]
}

@test "autofix run: switching auto-fix off stops the drain before the next item" {
  printf -- '- [open] 2026-10-02 test.sh:2 — second thing (fix: small)\n' >> "$REPO/docs/found-issues.md"
  sleep 1
  fi_af_queue_spot "$(grep 'second thing' "$REPO/docs/found-issues.md")" >/dev/null
  export FI_STANDIN_EDIT="sed -i.bak 's/ - / + /' src/calc.sh && rm -f src/calc.sh.bak && touch '$FOUND_ISSUES_STATE_DIR/autofix/disabled'"
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$(ls "$ST/done" | wc -l | tr -d ' ')" = 1 ]
  [ "$(ls "$ST/queue" | wc -l | tr -d ' ')" = 1 ]
}

@test "autofix run: git and gh run with credential prompts disabled" {
  git config found-issues.autofix.testCommand "env > '$TMP/env.txt'; sh test.sh"
  run "$FI_BIN" autofix run "$ID" --engine claude
  grep -q '^GIT_TERMINAL_PROMPT=0$' "$TMP/env.txt"
  grep -q '^GH_PROMPT_DISABLED=1$' "$TMP/env.txt"
}

@test "autofix run: a TERM to the run kills the engine child too" {
  export FI_STANDIN_SLEEP=4712
  "$FI_BIN" autofix run "$ID" --engine claude >/dev/null 2>&1 &
  rpid=$!
  for _ in $(seq 1 40); do pgrep -f 'sleep 4712' >/dev/null && break; sleep 0.25; done
  pgrep -f 'sleep 4712' >/dev/null
  kill -TERM "$rpid"; wait "$rpid" || true
  sleep 1
  ! pgrep -f 'sleep 4712' >/dev/null || false
}

@test "autofix run: a test run that leaves a new file after approval is not shipped" {
  # $RANDOM, not date +%N: macOS date has no %N, so the artifact would be stable
  git config found-issues.autofix.testCommand 'sh test.sh && echo $RANDOM$RANDOM > artifact.txt'
  run "$FI_BIN" autofix run "$ID" --engine claude
  grep -q 'differs from what the verifier approved' "$ST/done/$ID"
}

@test "autofix run: an unknown id is refused and the queue is not drained" {
  run "$FI_BIN" autofix run 20990101-000000-00000 --engine claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"no queued item 20990101-000000-00000"* ]]
  [ -f "$ST/queue/$ID" ]
}

@test "autofix run: a locked repo exits 4 and keeps the item queued" {
  mkdir "$ST/lock"; echo other >"$ST/lock/owner"
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 4 ]
  [ -f "$ST/queue/$ID" ]
}

@test "autofix run: the daily cap exits 3 and leaves a capped marker" {
  git config found-issues.autofix.dailyFixes 1
  echo earlier >"$ST/day/$(date +%Y-%m-%d).spot"
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 3 ]
  [ -f "$ST/day/$(date +%Y-%m-%d).capped" ]
}
