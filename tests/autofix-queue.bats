#!/usr/bin/env bats
# v3 auto-fix queue items and the log trigger (spec §4.1, §4.4).

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
  export FOUND_ISSUES_STATE_DIR="$TMP/state"
  export HOME="$TMP/home"; mkdir -p "$HOME"
  unset FOUND_ISSUES_AUTOFIX FOUND_ISSUES_AUTOFIX_CHILD
  git remote add origin https://github.com/foo/bar.git
  mkdir -p src docs
  printf 'a\nb\nc\n' > src/a.py
  git add -A && git commit -q -m init
  QDIR="$TMP/state/autofix/foo__bar/queue"
}
teardown() { fi_teardown_tmp; }

@test "autofix queue: log --fix small queues one item when enabled" {
  git config found-issues.autofix true
  run "$FI_BIN" log --fix small 'src/a.py:2 — off by one'
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUTOFIX-QUEUED "* ]]
  [ "$(ls "$QDIR" | wc -l | tr -d ' ')" = 1 ]
  f="$QDIR/$(ls "$QDIR")"
  grep -q '^kind=spot$' "$f"
  grep -q '^slug=foo/bar$' "$f"
  grep -q '^loc=src/a.py:2$' "$f"
  [ "$(sed -n 's/^root=//p' "$f")" = "$(git rev-parse --show-toplevel)" ]
  grep -q '^entry=- \[open\] .*src/a.py:2 — off by one (fix: small)$' "$f"
}

@test "autofix queue: nothing is queued when auto-fix is off" {
  run "$FI_BIN" log --fix small 'src/a.py:2 — off by one'
  [ "$status" -eq 0 ]
  [[ "$output" != *"AUTOFIX-QUEUED"* ]]
  [ ! -d "$QDIR" ] || [ -z "$(ls "$QDIR")" ]
}

@test "autofix queue: medium, large, decide and untagged entries are not spot-queued" {
  git config found-issues.autofix true
  "$FI_BIN" log --fix medium 'src/a.py:1 — medium thing'
  "$FI_BIN" log --fix large 'src/a.py:3 — large thing'
  "$FI_BIN" log --decide 'which way?' 'src/a.py:2 — needs a call'
  "$FI_BIN" log 'src/a.py — untagged'
  [ ! -d "$QDIR" ] || [ -z "$(ls "$QDIR")" ]
}

@test "autofix queue: re-logging the same entry does not queue it twice" {
  git config found-issues.autofix true
  "$FI_BIN" log --fix small 'src/a.py:2 — off by one'
  run "$FI_BIN" log --fix small 'src/a.py:2 — off by one'
  [ "$(ls "$QDIR" | wc -l | tr -d ' ')" = 1 ]
}

@test "autofix queue: log --fix small on an entry already tagged medium does not queue it" {
  "$FI_BIN" log --fix medium 'src/a.py:2 — off by one'
  git config found-issues.autofix true
  run "$FI_BIN" log --fix small 'src/a.py:2 — off by one'
  [[ "$output" != *"AUTOFIX-QUEUED"* ]]
  [ ! -d "$QDIR" ] || [ -z "$(ls "$QDIR")" ]
}

@test "autofix queue: tagging an existing open entry small through log queues it" {
  "$FI_BIN" log 'src/a.py:2 — off by one'
  git config found-issues.autofix true
  run "$FI_BIN" log --fix small 'src/a.py:2 — off by one'
  [[ "$output" == *"AUTOFIX-QUEUED "* ]]
  [ "$(ls "$QDIR" | wc -l | tr -d ' ')" = 1 ]
}

@test "autofix queue: inside a fixer the item is queued without the launch marker" {
  git config found-issues.autofix true
  FOUND_ISSUES_AUTOFIX_CHILD=1 run "$FI_BIN" log --fix small 'src/a.py:2 — off by one'
  [ "$status" -eq 0 ]
  [[ "$output" != *"AUTOFIX-QUEUED"* ]]
  [[ "$output" == *"inside a fixer"* ]]
  [ "$(ls "$QDIR" | wc -l | tr -d ' ')" = 1 ]
}

@test "autofix queue: an off-limits path is tagged manual and never queued" {
  git config found-issues.autofix true
  mkdir -p .github/workflows && echo x > .github/workflows/ci.yml && git add -A && git commit -q -m ci
  run "$FI_BIN" log --fix small '.github/workflows/ci.yml:1 — bad step'
  [[ "$output" != *"AUTOFIX-QUEUED"* ]]
  grep -q '(manual: off-limits: ci)' docs/found-issues.md
}

@test "autofix queue: no GitHub origin logs normally and queues nothing" {
  git remote remove origin
  git config found-issues.autofix true
  run "$FI_BIN" log --fix small 'src/a.py:2 — off by one'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Logged:"* ]]
  [[ "$output" != *"AUTOFIX"* ]]
}

@test "autofix queue: item read and set round-trip values with = and spaces" {
  source "$FI_BIN"
  fi_af_item_write "$TMP/item" "id=x1" "entry=- [open] a = b (fix: small)" "crashes=0"
  fi_af_item_read "$TMP/item"
  [ "$AFI_id" = x1 ]
  [ "$AFI_entry" = "- [open] a = b (fix: small)" ]
  fi_af_item_set "$TMP/item" crashes 1
  fi_af_item_set "$TMP/item" pid 4242
  fi_af_item_read "$TMP/item"
  [ "$AFI_crashes" = 1 ]
  [ "$AFI_pid" = 4242 ]
  [ "$AFI_entry" = "- [open] a = b (fix: small)" ]
}

@test "autofix queue: item_set on a vanished item recreates nothing" {
  source "$FI_BIN"
  mkdir -p "$QDIR"
  ! fi_af_item_set "$QDIR/gone" launched 1 || false
  [ ! -e "$QDIR/gone" ]
  [ -z "$(ls -A "$QDIR" 2>/dev/null)" ]
}
