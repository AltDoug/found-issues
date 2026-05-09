#!/usr/bin/env bats
# Tests for `found-issues status`

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

@test "status: silent (no output) on plain when no file" {
  fi_run status --format=plain
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "status: returns zeroed JSON when no file" {
  fi_run status --format=json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"critical":0'* ]]
  [[ "$output" == *'"issues":0'* ]]
  [[ "$output" == *'"in_pr":0'* ]]
  [[ "$output" == *'"stale":0'* ]]
}

@test "status: counts a single open entry" {
  fi_seed_sample docs/found-issues.md
  fi_run status --format=plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"critical"* ]] || [[ "$output" == *"issues"* ]]
}

@test "status: JSON with sample data shows correct counts" {
  fi_seed_sample docs/found-issues.md
  fi_run status --format=json
  [ "$status" -eq 0 ]
  # Sample has: 1 critical, 4 open total, 1 in PR, 1 fixed, 1 deferred
  # issues = open_total - in_pr - critical = 4 - 1 - 1 = 2
  [[ "$output" == *'"critical":1'* ]]
  [[ "$output" == *'"issues":2'* ]]
  [[ "$output" == *'"in_pr":1'* ]]
  [[ "$output" == *'"total_open":4'* ]]
}

@test "status: plain format uses middle-dot separator" {
  fi_seed_sample docs/found-issues.md
  fi_run status --format=plain
  [[ "$output" == *" · "* ]]
}

@test "status: segment format includes ANSI codes" {
  fi_seed_sample docs/found-issues.md
  fi_run status --format=segment
  # Segment should contain escape character (\033)
  [[ "$output" == *$'\033'* ]]
}

@test "status: segment starts with ' | ' separator" {
  fi_seed_sample docs/found-issues.md
  fi_run status --format=segment
  [[ "$output" == " | "* ]]
}

@test "status: rejects unknown format" {
  fi_seed_sample docs/found-issues.md
  fi_run status --format=garbage
  [ "$status" -ne 0 ]
}
