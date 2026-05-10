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

@test "status: [deferred] entries do not count toward 'issues'" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] 2026-05-10 src/foo.py:42 — null check
- [deferred] 2026-05-10 src/bar.py:99 — kicked down road
EOF
  fi_run status --format=json
  [ "$status" -eq 0 ]
  # total_open should be 1 (only the [open] entry)
  echo "$output" | grep -F '"total_open":1'
}

@test "status: promoted entry counts in [open] (transition correctness)" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — null check (touched: 2026-05-21, 2026-05-28, 2026-06-04)
EOF
  # Pre-promote: 0 in 'issues'
  fi_run status --format=json
  echo "$output" | grep -F '"total_open":0'
  # Promote
  fi_run promote-deferred "src/foo.py:42"
  # Post-promote: 1 in 'issues'
  fi_run status --format=json
  echo "$output" | grep -F '"total_open":1'
}

@test "status: critical [!] post-auto-promote bumps 'critical' (not generic 'issues')" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] [!] 2026-05-10 src/foo.py:42 — auth bypass (touched: 2026-05-21, 2026-05-28)
EOF
  unset FOUND_ISSUES_DEFER_TOUCH_THRESHOLD FOUND_ISSUES_DEFER_ESCALATION_FACTOR
  # 3rd touch auto-promotes critical
  fi_run log "src/foo.py:42 — auth bypass"
  [ "$status" -eq 0 ]
  fi_run status --format=json
  # critical: 1, issues: 0 (critical excluded from 'issues' subtraction)
  echo "$output" | grep -F '"critical":1'
}
