#!/usr/bin/env bats
# Statusline 🔧N (runs in progress) and ❓N (decisions waiting) — spec §8,
# phase 5 ruling 1.

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_fixture; fi_use_standins; fi_af_queue_fixture
  ST="$FI_AF_ST"
  export FOUND_ISSUES_CACHE_DIR="$TMP/cache"
}
teardown() { fi_teardown_tmp; }

seg() { "$FI_BIN" status --format=segment --cwd "${1:-$REPO}"; }

@test "statusline: a decide entry shows a question-mark count" {
  printf -- '- [open] 2026-10-02 src/calc.sh:1 — rounding (decide: floor or round?)\n' >> docs/found-issues.md
  run seg
  [[ "$output" == *"❓1"* ]]
  run "$FI_BIN" status --format=json --cwd "$REPO"
  [[ "$output" == *'"decisions":1'* ]]
}

@test "statusline: a claimed item shows a wrench count and finishing clears it" {
  "$FI_BIN" autofix claim "$ID" >/dev/null
  run seg
  [[ "$output" == *"🔧1"* ]]
  "$FI_BIN" autofix release "$ID" --failed "x" >/dev/null
  run seg
  [[ "$output" != *"🔧"* ]]
}

@test "statusline: the wrench count is not served stale from the segment cache" {
  seg >/dev/null; seg >/dev/null          # warm the cache
  "$FI_BIN" autofix claim "$ID" >/dev/null
  run seg
  [[ "$output" == *"🔧1"* ]]
}

@test "statusline: the running count shows when the ledger is reached through a symlink" {
  ln -s "$REPO" "$TMP/link"
  "$FI_BIN" autofix claim "$ID" >/dev/null
  run seg "$TMP/link"
  [[ "$output" == *"🔧1"* ]]
}

@test "statusline: a reaped crash clears the running state file" {
  "$FI_BIN" autofix claim "$ID" >/dev/null
  run seg
  [[ "$output" == *"🔧1"* ]]
  printf 'pid=999999\n' >> "$ST/running/$ID"   # a dead A run
  rmdir "$ST/lock" 2>/dev/null || rm -rf "$ST/lock"
  "$FI_BIN" autofix status >/dev/null
  run seg
  [[ "$output" != *"🔧"* ]]
}

@test "statusline: only the wrench shows when the ledger has nothing open" {
  "$FI_BIN" autofix claim "$ID" >/dev/null
  sed -i.bak 's/^- \[open\]/- [fixed]/' docs/found-issues.md && rm -f docs/found-issues.md.bak
  run seg
  [ "$output" = $' | \033[35m🔧1\033[0m' ]
}

@test "statusline: json running is the run count, not the color code" {
  "$FI_BIN" autofix claim "$ID" >/dev/null
  run "$FI_BIN" status --format=json --cwd "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"running":1}'* ]]
}
