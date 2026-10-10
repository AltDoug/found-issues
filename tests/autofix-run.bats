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
  # The PR lands on main, this checkout's branch: it carries the annotation, so
  # the source ledger stays clean and the entry is recorded as in flight.
  ! grep -q '(PR: foo/bar#7)' "$REPO/docs/found-issues.md" || false
  [ "$(ls "$ST/inflight" | wc -l | tr -d ' ')" = 1 ]
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

@test "autofix run: tests that fail at base end stale without starting an engine" {
  git config found-issues.autofix.testCommand 'exit 1'
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '^result=stale: tests fail at base$' "$ST/done/$ID"
  [ ! -f "$FI_STANDIN_TRACE" ] || ! grep -q '^claude' "$FI_STANDIN_TRACE" || false
  ! grep -q 'autofix-failed' "$REPO/docs/found-issues.md" || false
}

@test "autofix run: retry feedback names the failing tests, not just the tail" {
  git config found-issues.autofix.testCommand "[ -z \"\$(git status --porcelain -- src)\" ] && exit 0; printf 'not ok 1 early %s\n' failure; i=2; while [ \$i -le 40 ]; do echo \"ok \$i fine\"; i=\$((i+1)); done; exit 1"
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

@test "autofix run: with no budget set a claude run never stops on cost" {
  export FI_STANDIN_COST=50
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '^result=shipped' "$ST/done/$ID"
  ! grep -q -- '--max-budget-usd' "$FI_STANDIN_TRACE" || false
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
  # A sleep value unique to this test process: a machine-wide pgrep on a
  # fixed value matched another suite run's child (or any sleep with that argv).
  sl="4712.$$"
  export FI_STANDIN_SLEEP="$sl"
  "$FI_BIN" autofix run "$ID" --engine claude >/dev/null 2>&1 &
  rpid=$!
  for _ in $(seq 1 40); do pgrep -f "sleep $sl" >/dev/null && break; sleep 0.25; done
  pgrep -f "sleep $sl" >/dev/null
  kill -TERM "$rpid"; wait "$rpid" || true
  sleep 1
  ! pgrep -f "sleep $sl" >/dev/null || false
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

@test "autofix run: a codex fixer on a rejected model requeues as an outage" {
  export FI_STANDIN_CODEX_FAIL=workspace-write
  run "$FI_BIN" autofix run "$ID" --engine codex
  [ "$status" -eq 7 ]
  [ -f "$ST/queue/$ID" ]
  grep -q "requeued: engine error: The 'bad-model' model is not supported" "$FI_AF_RUNS/$ID.log"
  ! grep -q 'autofix-failed' "$REPO/docs/found-issues.md" || false
}

@test "autofix run: a verifier engine error requeues instead of counting as a reject" {
  export FI_STANDIN_CODEX_FAIL=read-only
  run "$FI_BIN" autofix run "$ID" --engine codex
  [ "$status" -eq 7 ]
  [ -f "$ST/queue/$ID" ]
  [ ! -d "$REPO/.claude/worktrees/fi-autofix-$ID" ]
  ! grep -q 'autofix-failed' "$REPO/docs/found-issues.md" || false
}

@test "autofix run: a verifier that dies with no verdict is an outage, not a reject" {
  export FI_STANDIN_VERIFIER_CRASH=1
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 7 ]
  [ -f "$ST/queue/$ID" ]
  grep -q 'requeued: engine error: claude verifier exited 1' "$FI_AF_RUNS/$ID.log"
  ! grep -q 'autofix-failed' "$REPO/docs/found-issues.md" || false
  grep -q '^outages=1$' "$ST/queue/$ID"
}

@test "autofix run: a codex verifier timeout exit with no verdict is an outage" {
  export FI_STANDIN_VERIFIER_CRASH=124
  run "$FI_BIN" autofix run "$ID" --engine codex
  [ "$status" -eq 7 ]
  [ -f "$ST/queue/$ID" ]
  grep -q 'requeued: engine error: codex verifier exited 124' "$FI_AF_RUNS/$ID.log"
}

@test "autofix run: a verifier that exits non-zero but left a verdict keeps the verdict" {
  export FI_STANDIN_VERIFIER_RC=1
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '^result=shipped' "$ST/done/$ID"
}

@test "autofix run: the third outage in a row finishes the item failed with the outage text" {
  export FI_STANDIN_VERIFIER_CRASH=1
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 7 ]
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 7 ]
  grep -q '^outages=2$' "$ST/queue/$ID"
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  [ ! -f "$ST/queue/$ID" ]
  grep -q '^result=failed: engine error after 3 tries: claude verifier exited 1' "$ST/done/$ID"
  grep -q '(autofix-failed: engine error after 3 tries' "$REPO/docs/found-issues.md"
}

@test "autofix run: FOUND_ISSUES_AUTOFIX_OUTAGE_MAX sets how many outages are tolerated" {
  export FI_STANDIN_VERIFIER_CRASH=1 FOUND_ISSUES_AUTOFIX_OUTAGE_MAX=1
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '^result=failed: engine error after 1 tries' "$ST/done/$ID"
}

@test "autofix run: a verdict clears the outage count" {
  fi_af_item_set "$ST/queue/$ID" outages 2
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '^result=shipped' "$ST/done/$ID"
  grep -q '^outages=0$' "$ST/done/$ID"
}

@test "autofix run: codex stops at the token cap before the verifier" {
  git config found-issues.autofix.codexRunTokens 1000
  run "$FI_BIN" autofix run "$ID" --engine codex
  [ "$status" -eq 0 ]
  grep -q '^result=failed: run budget spent (1500 tokens)' "$ST/done/$ID"
  grep -q '(autofix-failed: run budget spent \[1500 tokens\])' "$REPO/docs/found-issues.md"
  # the fixer prompt says read-only, so match the verifier's sandbox flag
  [ "$(grep -c 'sandbox.read-only' "$FI_STANDIN_TRACE")" = 0 ]
}

@test "autofix run: the claude budget ignores the codex token cap" {
  git config found-issues.autofix.codexRunTokens 1
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '^result=shipped' "$ST/done/$ID"
}

@test "autofix run: the run log names each codex child's model and tokens against the cap" {
  run "$FI_BIN" autofix run "$ID" --engine codex
  [ "$status" -eq 0 ]
  grep -q 'codex fixer: model gpt-6.1-sol (medium), 1500 tokens, run total 1500$' "$FI_AF_RUNS/$ID.log"
  grep -q 'codex verifier: model gpt-6-astra (high), 1500 tokens, run total 3000$' "$FI_AF_RUNS/$ID.log"
  grep -q 'Run cost: .*codex models: fixer gpt-6.1-sol (medium), verifier gpt-6-astra (high)' "$FI_AF_RUNS/$ID.pr-body.md"
}

# 3.4.3: a flaky test (kh2-midgar build.bats 55-57, a shared build lock) used
# to fail a good fix, feed attempt 2 unrelated failures and tag the entry
# autofix-failed. A red suite after a fix is re-run once before it counts.
@test "autofix run: a suite that fails once after the fix and passes on the re-run ships on attempt 1" {
  git config found-issues.autofix.testCommand "[ -z \"\$(git status --porcelain -- src)\" ] && exit 0; n=\$(cat '$TMP/runs' 2>/dev/null || echo 0); echo \$((n+1)) > '$TMP/runs'; [ \$n -ge 1 ] && exec sh test.sh; echo 'not ok 55 shared lock busy'; exit 1"
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '^result=shipped: PR #7' "$ST/done/$ID"
  [ "$(grep -c '^claude' "$FI_STANDIN_TRACE")" = 2 ]
  grep -q 'tests failed (not ok 55 shared lock busy); re-running once' "$FI_AF_RUNS/$ID.log"
  grep -q 'tests passed on the re-run: the first failure was flaky' "$FI_AF_RUNS/$ID.log"
  grep -q 'not ok 55' "$FI_AF_RUNS/$ID.tests1.first.log"
}

@test "autofix run: a fix that is red twice in a row still fails the attempt, one re-run each" {
  git config found-issues.autofix.testCommand "[ -z \"\$(git status --porcelain -- src)\" ] && exit 0; echo x >> '$TMP/runs'; echo 'not ok 1 broken'; exit 1"
  run "$FI_BIN" autofix run "$ID" --engine claude
  grep -q '(autofix-failed: tests fail after 2 attempts)$' "$REPO/docs/found-issues.md"
  [ "$(wc -l < "$TMP/runs" | tr -d ' ')" = 4 ]
}

@test "autofix run: a suite the watchdog kills after the fix is not re-run" {
  git config found-issues.autofix.testCommand "[ -z \"\$(git status --porcelain -- src)\" ] && exit 0; echo x >> '$TMP/runs'; sleep 30"
  FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS=3 run "$FI_BIN" autofix run "$ID" --engine claude
  grep -q '^result=failed: tests fail after 2 attempts' "$ST/done/$ID"
  [ "$(wc -l < "$TMP/runs" | tr -d ' ')" = 2 ]
}
