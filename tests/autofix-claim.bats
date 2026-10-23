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

# Ledger lib/autofix-queue.sh:621: memos of deleted or abandoned branches
# were never removed. Writing a memo prunes those untouched for 14 days.
@test "autofix claim: writing a red-base memo prunes memos untouched for 14 days" {
  printf 'abc make test' > "$ST/base-red.111-4"
  printf 'def make test' > "$ST/base-red.222-5"
  touch -t 202001010000 "$ST/base-red.111-4"
  git config found-issues.autofix.testCommand 'echo "not ok 1 red"; exit 1'
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 5 ]
  [ ! -e "$ST/base-red.111-4" ]
  [ -f "$ST/base-red.222-5" ]
  [ "$(ls "$ST"/base-red.* | wc -l | tr -d ' ')" = 2 ]
}

@test "autofix claim: a flaky base that passes on its re-run is not red" {
  git config found-issues.autofix.testCommand "echo run >> '$TMP/base-runs'; [ \$(wc -l < '$TMP/base-runs') -ge 2 ]"
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TMP/base-runs" | tr -d ' ')" = 2 ]
  [ -f "$ST/running/$ID" ]
}

# Ledger lib/autofix-queue.sh:694: cosmo main failed two unit tests, then one
# e2e test, and every later item skipped as known red. Two runs that fail
# different tests are a flaky suite: no memo, and the item goes ahead.
@test "autofix claim: a base whose two runs fail different tests is flaky, not red" {
  git config found-issues.autofix.testCommand "echo run >> '$TMP/base-runs'; n=\$(wc -l < '$TMP/base-runs'); echo \"ok 1 a\"; echo \"not ok 2 unit \$n\"; exit 1"
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TMP/base-runs" | tr -d ' ')" = 2 ]
  [ -f "$ST/running/$ID" ]
  grep -q '^base_flaky=1$' "$ST/running/$ID"
  [ -z "$(ls "$ST" | grep '^base-red\.' || true)" ]
  grep -q 'flaky base: the two base runs failed different tests' "$FI_AF_RUNS/$ID.log"
}

@test "autofix claim: a base whose two runs share a failing test stays red" {
  git config found-issues.autofix.testCommand "echo run >> '$TMP/base-runs'; n=\$(wc -l < '$TMP/base-runs'); echo \"not ok 1 always\"; echo \"not ok 2 unit \$n\"; exit 1"
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 5 ]
  grep -q '^result=stale: tests fail at base$' "$ST/done/$ID"
  [ -n "$(ls "$ST" | grep '^base-red\.' || true)" ]
}

@test "autofix claim: failing test names drop TAP numbers, pytest messages and runner timings" {
  fi_af_context   # setup already sourced the CLI (a second source hits its readonly vars)
  printf '%s\n' 'not ok 12 bats name # skip nothing' '# diag line' 'FAILED tests/t.py::test_x - AssertionError: 1 != 2' \
    '--- FAIL: TestY (0.02s)' 'FAIL src/z.test.ts' 'ok 3 passes' \
    '   × vitest name 1032ms' '    ✕ jest name (5 ms)' '   ✓ passing name 3ms' > "$TMP/a.log"
  run fi_af_test_failed_names "$TMP/a.log"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' 'TestY' 'bats name' 'jest name' 'src/z.test.ts' 'tests/t.py::test_x' 'vitest name')" ]
  printf '%s\n' 'not ok 4 bats name' > "$TMP/b.log"
  ! fi_af_runs_flaky "$TMP/a.log" "$TMP/b.log" || false
  printf '%s\n' 'Error: crashed' > "$TMP/c.log"
  ! fi_af_runs_flaky "$TMP/a.log" "$TMP/c.log" || false
}

@test "autofix claim: the failing-tests excerpt includes vitest and jest indented marker lines" {
  fi_af_context
  printf '%s\n' '   ✓ passing name 3ms' '   × vitest name 1032ms' '    ✕ jest name (5 ms)' > "$TMP/v.log"
  run fi_af_test_failures "$TMP/v.log"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' '   × vitest name 1032ms' '    ✕ jest name (5 ms)')" ]
}

@test "autofix claim: a failed fix on a flaky base says the base was flaky" {
  git config found-issues.autofix.testCommand "echo run >> '$TMP/base-runs'; n=\$(wc -l < '$TMP/base-runs'); echo \"not ok 1 unit \$n\"; exit 1"
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 0 ]
  run "$FI_BIN" autofix release "$ID" --failed "tests still fail"
  [ "$status" -eq 0 ]
  grep -q '^result=failed: tests still fail; base tests flaky$' "$ST/done/$ID"
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

# 3.10.2 (ledger lib/autofix-queue.sh:651): a red base under a GUESSED test
# command says so, with the setting that fixes a wrong guess.
auto_red_base() { # no configured command; the base tree's Makefile is detected
  git config --unset found-issues.autofix.testCommand
  printf 'test:\n\techo run >> %s/base-runs; echo "not ok 1 red"; exit 1\n' "$TMP" > Makefile
  git add Makefile && git commit -qm "red make test" && git push -q origin main
}

@test "autofix claim: a red base under an auto-detected command names the command and the setting" {
  auto_red_base
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 5 ]
  [[ "$output" == *"tests fail at base (set found-issues.autofix.testCommand; auto-detected: make test)"* ]]
  grep -q '^result=stale: tests fail at base (set found-issues.autofix.testCommand; auto-detected: make test)$' "$ST/done/$ID"
}

@test "autofix claim: a known-red skip under an auto-detected command carries the same hint" {
  auto_red_base
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 5 ]
  "$FI_BIN" log --fix small 'test.sh:2 — second entry' >/dev/null
  ID2="$(ls "$ST/queue" | head -1)"
  run "$FI_BIN" autofix claim "$ID2"
  [ "$status" -eq 5 ]
  [ "$(wc -l < "$TMP/base-runs" | tr -d ' ')" = 2 ]
  grep -q '^result=stale: tests fail at base (set found-issues.autofix.testCommand; auto-detected: make test)$' "$ST/done/$ID2"
}

# Ledger lib/autofix-queue.sh:1080: fi_af_finish clips a result to 160
# characters, so the setting must come before a long guessed command.
@test "autofix claim: a long auto-detected command still leaves the setting inside the clipped result" {
  fi_af_context   # setup already sourced the CLI (a second source hits its readonly vars)
  AFI_wt="$REPO" AFI_root="$REPO" AFI_base=main
  git config --unset found-issues.autofix.testCommand || true
  long="npm ci && npm run build:server-deps && npm run test --workspace=@x/server && npm run test --workspace=@x/builtin-plugins"
  why="$(_fi_af_base_red_why "$long")"
  [[ "${why:0:160}" == "tests fail at base (set found-issues.autofix.testCommand; auto-detected: npm ci"* ]]
}

# Ledger lib/autofix-queue.sh:640: a red base on a landing branch behind the
# default branch hints that merging the default branch in may fix it.
@test "autofix claim: a red base on a landing branch behind origin/main says so" {
  git checkout -q -b feat && git push -q -u origin feat
  git checkout -q main
  echo one >> README.md && git add README.md && git commit -qm one
  echo two >> README.md && git add README.md && git commit -qm two
  git push -q origin main
  git checkout -q feat
  git config found-issues.autofix.testCommand 'echo "not ok 1 red"; exit 1'
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 5 ]
  grep -q '^result=stale: tests fail at base; landing branch is 2 commits behind origin/main; merge it in$' "$ST/done/$ID"
}

@test "autofix claim: a base suite that exits 124 on its own is red, not a watchdog timeout" {
  git config found-issues.autofix.testCommand 'echo "not ok 1 hung"; exit 124'
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 5 ]
  grep -q '^result=stale: tests fail at base$' "$ST/done/$ID"
}
