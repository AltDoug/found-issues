#!/usr/bin/env bats
# Tests for `found-issues status --format=segment` auto-sync behavior.
#
# Segment renders should opportunistically refresh the on-disk file in the
# background so the count doesn't go stale mid-session when PRs merge
# externally. Throttled by ~/.cache/found-issues/segment-autosync-ts.

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
  # Seed a minimal found-issues.md so cmd_status has something to render
  # (the autosync branch is gated on file existence). Dynamic date: a
  # hardcoded one goes stale after 30 days and flips the "1 issue" label
  # asserted below to "1 other · 1 stale".
  mkdir -p docs
  printf '# found-issues\n\n- [open] %s src/foo.py — bug\n' "$(date +%Y-%m-%d)" > docs/found-issues.md

  # helpers.bash defaults FOUND_ISSUES_SEGMENT_AUTOSYNC=off for test
  # isolation; unset here so THIS test file actually exercises the
  # autosync path. (Individual tests that want it off explicitly re-export
  # it — see the "respects =off" case below.)
  unset FOUND_ISSUES_SEGMENT_AUTOSYNC

  # Redirect the autosync cache into the test tmpdir so concurrent test runs
  # don't share state through ~/.cache/found-issues.
  export FOUND_ISSUES_CACHE_DIR="$TMP/autosync-cache"

  # Marker file written by the test-mode FOUND_ISSUES_AUTOSYNC_CMD.
  MARKER="$TMP/sync-marker"
  export FOUND_ISSUES_AUTOSYNC_CMD="touch '$MARKER'"
}

teardown() {
  unset FOUND_ISSUES_CACHE_DIR
  unset FOUND_ISSUES_AUTOSYNC_CMD
  unset FOUND_ISSUES_SEGMENT_AUTOSYNC
  unset FOUND_ISSUES_SEGMENT_AUTOSYNC_INTERVAL
  fi_teardown_tmp
}

_wait_for_marker() {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -e "$MARKER" ]] && return 0
    sleep 0.05
  done
  return 1
}

@test "segment-autosync: triggers sync on first render (no timestamp yet)" {
  fi_run status --format=segment --cwd "$TMP"
  [ "$status" -eq 0 ]
  _wait_for_marker
  [ -e "$MARKER" ]
  # Timestamp file was created
  [ -f "$FOUND_ISSUES_CACHE_DIR/segment-autosync-ts" ]
}

@test "segment-autosync: skips re-trigger when within interval" {
  # First call: triggers (no timestamp exists).
  fi_run status --format=segment --cwd "$TMP"
  _wait_for_marker
  [ -e "$MARKER" ]
  rm -f "$MARKER"

  # Second call immediately after: timestamp is fresh, no re-trigger.
  fi_run status --format=segment --cwd "$TMP"
  [ "$status" -eq 0 ]
  sleep 0.4   # give any errant background spawn time to fire
  [ ! -e "$MARKER" ]
}

@test "segment-autosync: re-triggers when timestamp is older than interval" {
  # Prime: trigger once, then backdate the timestamp file past the interval.
  fi_run status --format=segment --cwd "$TMP"
  _wait_for_marker
  rm -f "$MARKER"

  # Backdate (set interval = 1s, then sleep 2s so the timestamp ages out).
  export FOUND_ISSUES_SEGMENT_AUTOSYNC_INTERVAL=1
  sleep 2

  fi_run status --format=segment --cwd "$TMP"
  [ "$status" -eq 0 ]
  _wait_for_marker
  [ -e "$MARKER" ]
}

@test "segment-autosync: respects FOUND_ISSUES_SEGMENT_AUTOSYNC=off" {
  export FOUND_ISSUES_SEGMENT_AUTOSYNC=off
  fi_run status --format=segment --cwd "$TMP"
  [ "$status" -eq 0 ]
  sleep 0.4
  [ ! -e "$MARKER" ]
  [ ! -f "$FOUND_ISSUES_CACHE_DIR/segment-autosync-ts" ]
}

@test "segment-autosync: only fires for segment format, not plain or json" {
  # plain
  fi_run status --format=plain --cwd "$TMP"
  [ "$status" -eq 0 ]
  sleep 0.4
  [ ! -e "$MARKER" ]
  [ ! -f "$FOUND_ISSUES_CACHE_DIR/segment-autosync-ts" ]

  # json
  fi_run status --format=json --cwd "$TMP"
  [ "$status" -eq 0 ]
  sleep 0.4
  [ ! -e "$MARKER" ]
}

@test "segment-autosync: segment output is unchanged by autosync logic" {
  # The segment string itself should match what status --format=segment
  # produced before autosync was added (label policy + ANSI codes).
  # Disable autosync here so the background `touch` doesn't race the
  # teardown's rm -rf on $TMP.
  export FOUND_ISSUES_SEGMENT_AUTOSYNC=off
  fi_run status --format=segment --cwd "$TMP"
  [ "$status" -eq 0 ]
  # 1 open entry, 0 in PR, 0 critical, 0 stale → "1 issue" with leading " | "
  [[ "$output" == *"1 issue"* ]]
}

@test "segment-autosync: no-op when found-issues.md doesn't exist" {
  rm -f docs/found-issues.md
  fi_run status --format=segment --cwd "$TMP"
  [ "$status" -eq 0 ]
  sleep 0.4
  [ ! -e "$MARKER" ]
}

@test "segment-autosync: default dispatch survives a CLI path containing a space" {
  # The default autosync command is the CLI itself ($0 sync). An install path
  # with a space used to word-split inside bash -c and exit 127 silently.
  unset FOUND_ISSUES_AUTOSYNC_CMD
  mkdir -p "$TMP/spaced dir"
  cp "$FI_BIN" "$TMP/spaced dir/found-issues"
  chmod +x "$TMP/spaced dir/found-issues"
  # The seeded entry cites src/foo.py which does not exist, so a real sync
  # tombstones it — observable evidence the background dispatch ran.
  run "$TMP/spaced dir/found-issues" status --format=segment --cwd "$TMP"
  [ "$status" -eq 0 ]
  for _ in $(seq 1 40); do
    grep -q '\[fixed\]' docs/found-issues.md 2>/dev/null && break
    sleep 0.25
  done
  grep -q 'closure: tombstone' docs/found-issues.md
}
