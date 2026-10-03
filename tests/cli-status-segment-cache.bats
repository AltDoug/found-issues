#!/usr/bin/env bats
# Tests for lib/segment-cache.sh — the builtin-only fast path for
# `found-issues status --format=segment` (statusline renders).

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
  mkdir -p docs
  printf '# found-issues\n\n- [open] %s src/foo.py — bug\n' "$(date +%Y-%m-%d)" >docs/found-issues.md
  export FOUND_ISSUES_CACHE_DIR="$TMP/cache"
  BASH_BIN="$(command -v bash)"
  # A PATH holding only stubs that record their own name: any external
  # command the CLI runs is logged. bash builtins never consult PATH.
  mkdir -p "$TMP/stubs"
  local t
  for t in awk grep sed date stat mkdir dirname mv rm cat head cut tr wc readlink sort git jq; do
    printf '#!%s\necho %s >>"%s/external-calls"\n' "$BASH_BIN" "$t" "$TMP" >"$TMP/stubs/$t"
    chmod +x "$TMP/stubs/$t"
  done
}

teardown() {
  unset FOUND_ISSUES_CACHE_DIR FOUND_ISSUES_SEGMENT_CACHE FOUND_ISSUES_STALE_DAYS
  fi_teardown_tmp
}

# Render with the stub-only PATH (fast path must not need anything else).
render_stubbed() {
  rm -f "$TMP/external-calls"
  PATH="$TMP/stubs" "$BASH_BIN" "$FI_BIN" status --format=segment --cwd "$TMP"
}

@test "segment-cache: a warm render prints the same segment with no external command" {
  fi_run status --format=segment --cwd "$TMP"
  [ "$status" -eq 0 ]
  cold="$output"
  [[ "$cold" == *"1 issue"* ]]
  run render_stubbed
  [ "$status" -eq 0 ]
  [ "$output" == "$cold" ]
  [ ! -e "$TMP/external-calls" ]
}

@test "segment-cache: a ledger edit is never served from the cache, even within the same second" {
  fi_run status --format=segment --cwd "$TMP"
  printf -- '- [open] [!] %s src/bar.py — crash\n' "$(date +%Y-%m-%d)" >>docs/found-issues.md
  fi_run status --format=segment --cwd "$TMP"
  [[ "$output" == *"1 critical"* ]]
  [[ "$output" == *"1 other"* ]]
}

@test "segment-cache: same-size rewrite with different content recomputes" {
  printf '# found-issues\n\n- [open] %s src/foo.py — bug\n' "$(date +%Y-%m-%d)" >docs/found-issues.md
  fi_run status --format=segment --cwd "$TMP"
  [[ "$output" == *"1 issue"* ]]
  # Same byte count (an older date of the same width), different count.
  printf '# found-issues\n\n- [open] 2020-01-01 src/foo.py — bug\n' >docs/found-issues.md
  fi_run status --format=segment --cwd "$TMP"
  [[ "$output" == *"1 stale"* ]]
}

@test "segment-cache: FOUND_ISSUES_STALE_DAYS is part of the key" {
  printf '# found-issues\n\n- [open] 2020-01-01 src/foo.py — old bug\n' >docs/found-issues.md
  FOUND_ISSUES_STALE_DAYS=30 fi_run status --format=segment --cwd "$TMP"
  [[ "$output" == *"1 stale"* ]]
  FOUND_ISSUES_STALE_DAYS=999999 fi_run status --format=segment --cwd "$TMP"
  [[ "$output" != *"stale"* ]]
}

@test "segment-cache: no ledger anywhere up the tree prints nothing with no external command" {
  # Outside $TMP: $TMP itself holds a ledger the walk would find.
  local bare
  bare="$(mktemp -d -t fi-bare.XXXXXX)"
  mkdir -p "$bare/sub"
  rm -f "$TMP/external-calls"
  run env PATH="$TMP/stubs" "$BASH_BIN" "$FI_BIN" status --format=segment --cwd "$bare/sub"
  rm -rf "$bare"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$TMP/external-calls" ]
}

@test "segment-cache: FOUND_ISSUES_SEGMENT_CACHE=off writes no cache and always runs the full path" {
  export FOUND_ISSUES_SEGMENT_CACHE=off
  fi_run status --format=segment --cwd "$TMP"
  [[ "$output" == *"1 issue"* ]]
  [ ! -d "$TMP/cache/segment" ]
  run render_stubbed
  [ -e "$TMP/external-calls" ]
}

@test "segment-cache: plain and json formats never use the fast path" {
  fi_run status --format=segment --cwd "$TMP"
  rm -f "$TMP/external-calls"
  run env PATH="$TMP/stubs" "$BASH_BIN" "$FI_BIN" status --format=plain --cwd "$TMP"
  [ -e "$TMP/external-calls" ]
}

@test "segment-cache: an autosync stamp without an epoch (pre-2.9 CLI) falls back to the full path" {
  unset FOUND_ISSUES_SEGMENT_AUTOSYNC
  export FOUND_ISSUES_AUTOSYNC_CMD="true"
  fi_run status --format=segment --cwd "$TMP"
  # The full path stamped an epoch: a warm render is fully builtin.
  [[ "$(cat "$TMP/cache/segment-autosync-ts")" =~ ^[0-9]+$ ]]
  run render_stubbed
  [ ! -e "$TMP/external-calls" ]
  # An older CLI truncates the stamp: the fast path must not guess its age.
  : >"$TMP/cache/segment-autosync-ts"
  run render_stubbed
  [ -e "$TMP/external-calls" ]
  unset FOUND_ISSUES_AUTOSYNC_CMD
}

@test "segment-cache: an autosync that is due runs the full path (which dispatches the sync)" {
  unset FOUND_ISSUES_SEGMENT_AUTOSYNC
  export FOUND_ISSUES_AUTOSYNC_CMD="touch '$TMP/synced'"
  fi_run status --format=segment --cwd "$TMP"
  for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -e "$TMP/synced" ]] && break; sleep 0.05; done
  [ -e "$TMP/synced" ]
  rm -f "$TMP/synced"
  # Long overdue by both clocks: the epoch the fast path reads and the
  # mtime the full path stats.
  echo 1 >"$TMP/cache/segment-autosync-ts"
  touch -t 200001010000 "$TMP/cache/segment-autosync-ts"
  fi_run status --format=segment --cwd "$TMP"
  for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -e "$TMP/synced" ]] && break; sleep 0.05; done
  [ -e "$TMP/synced" ]
  unset FOUND_ISSUES_AUTOSYNC_CMD
}
