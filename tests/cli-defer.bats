#!/usr/bin/env bats
# Tests for `found-issues defer`

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

@test "defer: flips [open] to [deferred] on basic match" {
  fi_run log "src/foo.py:42 — null check missing"
  [ "$status" -eq 0 ]
  fi_run defer "src/foo.py:42"
  [ "$status" -eq 0 ]
  grep -F "[deferred]" docs/found-issues.md
  ! grep -F "[open]" docs/found-issues.md
}

@test "defer: --reason captures (reason: ...) annotation" {
  fi_run log "src/foo.py:42 — null check missing"
  fi_run defer "src/foo.py:42" --reason "tracked in JIRA-1234"
  [ "$status" -eq 0 ]
  grep -F "(reason: tracked in JIRA-1234)" docs/found-issues.md
}

@test "defer: no match exits 1 with clear error" {
  fi_run log "src/foo.py:42 — null check"
  fi_run defer "nonexistent"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no [open] entries match"* ]]
  [[ "$output" == *"nonexistent"* ]]
}

@test "defer: ambiguous match exits 2 with listing" {
  fi_run log "src/foo.py:42 — null check"
  fi_run log "src/foo.py:88 — leak"
  fi_run defer "foo.py"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ambiguous match"* ]]
  [[ "$output" == *"src/foo.py:42"* ]]
  [[ "$output" == *"src/foo.py:88"* ]]
  [[ "$output" == *"more specific"* ]]
}

@test "defer: already-deferred exits 3 with re-defer guidance" {
  fi_run log "src/foo.py:42 — null check"
  fi_run defer "src/foo.py:42"
  [ "$status" -eq 0 ]
  fi_run defer "src/foo.py:42"
  [ "$status" -eq 3 ]
  [[ "$output" == *"already [deferred]"* ]]
  [[ "$output" == *"promote"* ]]
}

@test "defer: blocks in-PR entry with exit 4 and recovery message" {
  fi_run log "src/foo.py:42 — null check"
  # Manually add a PR annotation to simulate annotate-pr having run
  sed -i.bak 's/null check/null check (PR: AltDoug\/found-issues#42)/' docs/found-issues.md
  fi_run defer "src/foo.py:42"
  [ "$status" -eq 4 ]
  [[ "$output" == *"active PR annotation"* ]]
  [[ "$output" == *"AltDoug/found-issues#42"* ]] || [[ "$output" == *"(PR:"* ]]
  [[ "$output" == *"sync"* ]] || [[ "$output" == *"merge"* ]]
}

@test "defer: re-defer increments defer-cycle and appends ';' to touched" {
  # Simulate: an entry that was previously deferred + touched + promoted, now [open]
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] 2026-05-10 src/foo.py:42 — null check (touched: 2026-05-21, 2026-05-28, 2026-06-04)
EOF
  fi_run defer "src/foo.py:42" --reason "rescoped, parking for v2"
  [ "$status" -eq 0 ]
  grep -F "[deferred]" docs/found-issues.md
  grep -F "(defer-cycle: 2)" docs/found-issues.md
  grep -F "(touched: 2026-05-21, 2026-05-28, 2026-06-04; )" docs/found-issues.md
  grep -F "(reason: rescoped, parking for v2)" docs/found-issues.md
}

@test "defer: re-defer with new --reason replaces old reason annotation" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] 2026-05-10 src/foo.py:42 — null check (reason: original reason) (touched: 2026-05-21, 2026-05-28, 2026-06-04) (defer-cycle: 2)
EOF
  fi_run defer "src/foo.py:42" --reason "new reason"
  [ "$status" -eq 0 ]
  grep -F "(reason: new reason)" docs/found-issues.md
  ! grep -F "(reason: original reason)" docs/found-issues.md
  grep -F "(defer-cycle: 3)" docs/found-issues.md
}

# === 2026-05-10 UX audit surface 4.4 — --mute-until flag ===

@test "defer: --mute-until adds (mute-until: ...) annotation" {
  fi_run log "src/foo.py:42 — null check missing"
  fi_run defer "src/foo.py:42" --mute-until "2099-12-31"
  [ "$status" -eq 0 ]
  grep -F "(mute-until: 2099-12-31)" docs/found-issues.md
  grep -F "[deferred]" docs/found-issues.md
}

@test "defer: --mute-until and --reason combine on one line" {
  fi_run log "src/foo.py:42 — null check"
  fi_run defer "src/foo.py:42" --reason "blocked on JIRA-42" --mute-until "2099-12-31"
  [ "$status" -eq 0 ]
  grep -F "(reason: blocked on JIRA-42)" docs/found-issues.md
  grep -F "(mute-until: 2099-12-31)" docs/found-issues.md
}

@test "defer: --mute-until validates YYYY-MM-DD format and rejects garbage" {
  fi_run log "src/foo.py:42 — null check"
  fi_run defer "src/foo.py:42" --mute-until "next-thursday"
  [ "$status" -eq 2 ]
  [[ "$output" == *"YYYY-MM-DD"* ]]
  # Entry should NOT have been deferred (we exited before the file mutation)
  grep -F "[open]" docs/found-issues.md
  ! grep -F "[deferred]" docs/found-issues.md
}

@test "defer: --mute-until in the past prints a warning but still defers" {
  fi_run log "src/foo.py:42 — null check"
  fi_run defer "src/foo.py:42" --mute-until "2020-01-01"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not in the future"* ]] || [[ "$output" == *"warning"* ]]
  grep -F "[deferred]" docs/found-issues.md
  grep -F "(mute-until: 2020-01-01)" docs/found-issues.md
}

@test "defer: re-defer replaces existing (mute-until: ...) annotation" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] 2026-05-10 src/foo.py:42 — null check (mute-until: 2099-01-01) (touched: 2026-05-21, 2026-05-28, 2026-06-04)
EOF
  fi_run defer "src/foo.py:42" --mute-until "2099-12-31"
  [ "$status" -eq 0 ]
  grep -F "(mute-until: 2099-12-31)" docs/found-issues.md
  ! grep -F "(mute-until: 2099-01-01)" docs/found-issues.md
}

@test "defer: allows entries with only (PR-closed: ...) annotation" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] 2026-05-11 src/a.py:1 — bug (PR-closed: foo/bar#42)
EOF
  fi_run defer "src/a.py:1"
  [ "$status" -eq 0 ]
  grep -q '^- \[deferred\].*src/a.py:1' docs/found-issues.md
}

@test "defer: still blocks entries with active (PR: ...) annotation (regression guard)" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] 2026-05-11 src/a.py:1 — bug (PR: foo/bar#42)
EOF
  fi_run defer "src/a.py:1"
  [ "$status" -eq 4 ]
  [[ "$output" == *"active PR annotation"* ]]
}

@test "defer: allows entries with (commit-stale: ...) annotation" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] 2026-05-11 src/a.py:1 — bug (commit-stale: deadbeef)
EOF
  fi_run defer "src/a.py:1"
  [ "$status" -eq 0 ]
  grep -q '^- \[deferred\].*src/a.py:1' docs/found-issues.md
}

# === final-partial-line data loss (v2.2.1) ===
#
# See fi_seed_no_trailing_newline in helpers.bash for the bug shape.

@test "defer: does not drop a final entry that lacks a trailing newline" {
  fi_seed_no_trailing_newline

  fi_run defer "first entry"
  [ "$status" -eq 0 ]
  fi_assert_both_entries_survived
  grep -q '^- \[deferred\].*first entry' docs/found-issues.md
}
