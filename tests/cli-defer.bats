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
