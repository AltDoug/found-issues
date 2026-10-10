#!/usr/bin/env bats
# v3 auto-fix claim: lock, caps, eligibility, reaping, worktree (spec §5.1, §7, §8).

load 'helpers'
load 'autofix-helpers'

setup() { fi_setup_tmp; fi_af_fixture; fi_af_queue_fixture; ST="$FI_AF_ST"; }
teardown() { fi_teardown_tmp; }

@test "autofix claim: claims, cuts a worktree from origin, records it" {
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 0 ]
  wt="$REPO/.claude/worktrees/fi-autofix-$ID"
  [ "${lines[${#lines[@]}-1]}" = "$wt" ]
  [ -f "$wt/src/calc.sh" ]
  [ "$(git -C "$wt" branch --show-current)" = "fi/autofix/src-calc-sh-1-$ID" ]
  [ ! -e "$ST/queue/$ID" ]
  grep -q "^wt=$wt$" "$ST/running/$ID"
  grep -q '^base=main$' "$ST/running/$ID"
  [ -d "$ST/lock" ]
  [ "$(wc -l < "$ST/day/$(date +%Y-%m-%d).spot" | tr -d ' ')" = 1 ]
}

@test "autofix claim: a second claimer for the same repo gets exit 4 and the item stays queued" {
  fi_af_context   # setup already sourced the CLI (a second source hits its readonly vars)
  fi_af_lock other-run
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 4 ]
  [ -f "$ST/queue/$ID" ]
  [ "$(cat "$ST/lock/owner")" = other-run ]
}

@test "autofix claim: a lock older than 60 minutes is broken" {
  fi_af_context   # setup already sourced the CLI (a second source hits its readonly vars)
  fi_af_lock other-run
  touch -t 202001010000 "$ST/lock"
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 0 ]
  [ "$(cat "$ST/lock/owner")" = "$ID" ]
}

@test "autofix claim: the daily cap holds the item in the queue" {
  git config found-issues.autofix.dailyFixes 1
  printf 'earlier\n' > "$ST/day/$(date +%Y-%m-%d).spot"
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 3 ]
  [ -f "$ST/queue/$ID" ]
  [ ! -d "$ST/lock" ]
}

@test "autofix claim: an entry that gained a PR annotation is retired, not claimed" {
  sed -i.bak 's/(fix: small)/(fix: small) (PR: foo\/bar#9)/' docs/found-issues.md
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 5 ]
  [ -f "$ST/done/$ID" ]
  grep -q '^result=stale: entry already has a fix reference$' "$ST/done/$ID"
  [ ! -d "$ST/lock" ]
}

@test "autofix claim: autofix-failed and retagged entries are not claimed" {
  sed -i.bak 's/(fix: small)/(fix: small) (autofix-failed: tests fail)/' docs/found-issues.md
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 5 ]
  grep -q 'auto-fix failed before' "$ST/done/$ID"
}

@test "autofix claim: a decided entry is fixable now" {
  sed -i.bak 's/(fix: small)/(decided: use plus)/' docs/found-issues.md
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 0 ]
}

@test "autofix claim: a dead running item is requeued once, then failed as crashed" {
  "$FI_BIN" autofix claim "$ID" >/dev/null
  fi_af_context   # setup already sourced the CLI (a second source hits its readonly vars)
  fi_af_item_set "$ST/running/$ID" pid 999999
  fi_af_reap
  [ -f "$ST/queue/$ID" ]
  grep -q '^crashes=1$' "$ST/queue/$ID"
  [ ! -d "$ST/lock" ]
  [ ! -d "$REPO/.claude/worktrees/fi-autofix-$ID" ]
  "$FI_BIN" autofix claim "$ID" >/dev/null
  fi_af_item_set "$ST/running/$ID" pid 999999
  fi_af_reap
  [ -f "$ST/done/$ID" ]
  grep -q '^result=failed: crashed$' "$ST/done/$ID"
}

@test "autofix claim: unknown id exits 1" {
  run "$FI_BIN" autofix claim nope
  [ "$status" -eq 1 ]
}

@test "autofix claim: crash reaping happens only under the repo lock" {
  "$FI_BIN" autofix claim "$ID" >/dev/null
  fi_af_item_set "$ST/running/$ID" pid 999999
  rm -rf "$ST/lock"
  fi_af_lock other-run
  printf -- '- [open] 2026-10-02 test.sh:2 — second (fix: small)\n' >> docs/found-issues.md
  fi_af_queue_spot "$(grep 'second (fix' docs/found-issues.md)" >/dev/null
  id2="$(ls "$ST/queue" | head -1)"
  run "$FI_BIN" autofix claim "$id2"
  [ "$status" -eq 4 ]
  [ -f "$ST/running/$ID" ]
}

@test "autofix claim: the running item carries a pid from the moment it exists" {
  FI_AF_PID=4242 run "$FI_BIN" autofix claim "$ID"
  grep -q '^pid=4242$' "$ST/running/$ID"
  [ "$(grep -c '^pid=' "$ST/running/$ID")" = 1 ]
}

@test "autofix claim: a forged worktree path in a dead item never touches the source checkout" {
  "$FI_BIN" autofix claim "$ID" >/dev/null
  fi_af_context
  printf 'keep\n' > "$REPO/precious.txt"
  fi_af_item_set "$ST/running/$ID" wt "$REPO"
  fi_af_item_set "$ST/running/$ID" pid 999999
  fi_af_reap
  [ -f "$REPO/precious.txt" ]
  [ -f "$REPO/src/calc.sh" ]
}

@test "autofix claim: B calls refuse an item whose worktree is outside fi- worktrees" {
  "$FI_BIN" autofix claim "$ID" >/dev/null
  fi_af_context
  printf 'keep\n' > "$REPO/precious.txt"
  fi_af_item_set "$ST/running/$ID" wt "$REPO/.claude/worktrees/fi-autofix-$ID/../../../$(basename "$REPO")"
  run "$FI_BIN" autofix verify "$ID"
  [ "$status" -ne 0 ]
  run "$FI_BIN" autofix release "$ID" --failed "x"
  [ "$status" -ne 0 ]
  [ -f "$REPO/precious.txt" ]
  [ -f "$REPO/src/calc.sh" ]
}

# 3.2.1 (ledger lib/autofix.sh:127): a suite that already fails at base fails
# every attempt whatever the fix does, so claim runs it once first.
@test "autofix claim: tests that fail at base retire the item stale before any fixer" {
  git config found-issues.autofix.testCommand 'echo "not ok 1 needs donor files"; exit 1'
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 5 ]
  [[ "$output" == *"retired"*"tests fail at base"* ]]
  grep -q '^result=stale: tests fail at base$' "$ST/done/$ID"
  [ ! -d "$REPO/.claude/worktrees/fi-autofix-$ID" ]
  [ -z "$(git branch --list 'fi/autofix/*')" ]
  [ ! -d "$ST/lock" ]
  # Stale, not failed: the entry stays fixable for a later run.
  ! grep -q 'autofix-failed' docs/found-issues.md || false
  grep -q 'not ok 1 needs donor files' "$FI_AF_RUNS/$ID.log"
}

# 3.6.0: kh2-midgar ran its whole suite at base for 21 items in a row on the
# same red base. A red base is re-run once (a flake is not red), then
# remembered by commit and test command until either changes.
@test "autofix claim: a base already red at the same commit is not re-run for the next item" {
  git config found-issues.autofix.testCommand "echo run >> '$TMP/base-runs'; echo 'not ok 1 red'; exit 1"
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 5 ]
  [ "$(wc -l < "$TMP/base-runs" | tr -d ' ')" = 2 ]
  "$FI_BIN" log --fix small 'test.sh:2 — second entry' >/dev/null
  ID2="$(ls "$ST/queue" | head -1)"
  run "$FI_BIN" autofix claim "$ID2"
  [ "$status" -eq 5 ]
  [ "$(wc -l < "$TMP/base-runs" | tr -d ' ')" = 2 ]
  grep -q '^result=stale: tests fail at base$' "$ST/done/$ID2"
  grep -q 'known red at' "$FI_AF_RUNS/$ID2.log"
  # A new commit on the base is tested again.
  echo more >> README.md && git add README.md && git commit -qm more && git push -q origin main
  "$FI_BIN" log --fix small 'test.sh:3 — third entry' >/dev/null
  ID3="$(ls "$ST/queue" | head -1)"
  run "$FI_BIN" autofix claim "$ID3"
  [ "$status" -eq 5 ]
  [ "$(wc -l < "$TMP/base-runs" | tr -d ' ')" = 4 ]
}

@test "autofix claim: a flaky base that passes on its re-run is not red" {
  git config found-issues.autofix.testCommand "echo run >> '$TMP/base-runs'; [ \$(wc -l < '$TMP/base-runs') -ge 2 ]"
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TMP/base-runs" | tr -d ' ')" = 2 ]
  [ -f "$ST/running/$ID" ]
}

@test "autofix claim: an entry another open PR already fixes retires stale before any fixer" {
  export GH_MOCK_PR_LIST='[{"number":571,"headRefName":"feat/wanda","files":[{"path":"docs/found-issues.md"}]}]'
  export GH_MOCK_PR_DIFF='+- [open] 2026-10-01 src/calc.sh:1 — add subtracts (fix: small) (PR: foo/bar#571)'
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 5 ]
  grep -q '^result=stale: fix in flight in PR #571$' "$ST/done/$ID"
  [ ! -d "$REPO/.claude/worktrees/fi-autofix-$ID" ]
}

@test "autofix claim: a PR annotating a different entry at the same line does not block" {
  export GH_MOCK_TRACE="$TMP/gh.trace"
  export GH_MOCK_PR_LIST='[{"number":571,"headRefName":"feat/wanda","files":[{"path":"docs/found-issues.md"}]},{"number":572,"headRefName":"feat/docs","files":[{"path":"README.md"}]}]'
  export GH_MOCK_PR_DIFF='+- [open] 2026-10-01 src/calc.sh:1 — a different symptom here (fix: small) (PR: foo/bar#571)'
  git config found-issues.autofix.testCommand 'true'
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 0 ]
  [ -f "$ST/running/$ID" ]
  # PR 572 touches no ledger file, so it is never diffed.
  ! grep -q '^pr diff 572 ' "$GH_MOCK_TRACE" || false
}

@test "autofix claim: tests that pass at base run once and the claim proceeds" {
  git config found-issues.autofix.testCommand "echo base >> '$TMP/base-runs'"
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TMP/base-runs" | tr -d ' ')" = 1 ]
  [ -f "$ST/running/$ID" ]
}

# 3.4.2 (ledger lib/autofix-queue.sh:341): a suite slower than the watchdog is
# not red; the result names the timeout and the setting that raises it.
@test "autofix claim: a base suite the watchdog kills retires as timed out, not red" {
  git config found-issues.autofix.testCommand 'echo "ok 1 slow"; sleep 30'
  FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS=2 run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 5 ]
  grep -q '^result=stale: base tests timed out after 2s (raise found-issues.autofix.runTimeoutMin)$' "$ST/done/$ID"
  ! grep -q 'tests fail at base' "$FI_AF_RUNS/$ID.log" || false
  [ ! -d "$ST/lock" ]
}

@test "autofix claim: a base suite that exits 124 on its own is red, not a watchdog timeout" {
  git config found-issues.autofix.testCommand 'echo "not ok 1 hung"; exit 124'
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 5 ]
  grep -q '^result=stale: tests fail at base$' "$ST/done/$ID"
}
