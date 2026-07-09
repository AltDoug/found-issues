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

@test "status: plain solo residual uses 'issue/issues' (no other counters)" {
  # 2026-05-10 UX audit, surfaces 2.1 / 9.1. The solo plain case keeps
  # natural language: "1 issue" / "3 issues" — no rename when nothing else
  # is on display.
  mkdir -p docs
  # Dynamic date: a hardcoded one goes stale after 30 days, adding a stale
  # counter that relabels the solo residual from "issue" to "other".
  cat > docs/found-issues.md <<EOF
# found-issues
- [open] $(date +%Y-%m-%d) src/foo.py:42 — null check
EOF
  fi_run status --format=plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 issue"* ]]
  [[ "$output" != *"other"* ]]
}

@test "status: plain residual relabels to 'other' when critical is also showing" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] [!] 2026-05-10 src/auth.ts:88 — leaks token
- [open] 2026-05-10 src/foo.py:42 — null check
- [open] 2026-05-10 src/bar.py:99 — race
EOF
  fi_run status --format=plain
  [ "$status" -eq 0 ]
  # critical=1, other=2 (3 total open minus 1 critical minus 0 in_pr)
  [[ "$output" == *"1 critical"* ]]
  [[ "$output" == *"2 other"* ]]
  # And the old "N issues" wording is gone in this mixed case
  [[ "$output" != *"issues"* ]]
}

@test "status: plain residual relabels to 'other' when in-PR is also showing" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] 2026-05-10 src/foo.py:42 — null check (PR: org/repo#5)
- [open] 2026-05-10 src/bar.py:99 — race
EOF
  fi_run status --format=plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 other"* ]]
  [[ "$output" == *"1 in PR"* ]]
}

@test "status: segment uses same label policy as plain (other when mixed)" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] [!] 2026-05-10 src/auth.ts:88 — leaks token
- [open] 2026-05-10 src/foo.py:42 — null check
EOF
  fi_run status --format=segment
  [ "$status" -eq 0 ]
  # ANSI codes wrap the labels, so we strip them for the assertion
  stripped="$(fi_strip_ansi "$output")"
  [[ "$stripped" == *"1 critical"* ]]
  [[ "$stripped" == *"1 other"* ]]
}

@test "status: JSON key stays 'issues' (backwards compat)" {
  # The user-facing label was renamed; the JSON wire format intentionally
  # did NOT change so external tooling doesn't break.
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] [!] 2026-05-10 src/a.py:1 — x
- [open] 2026-05-10 src/b.py:1 — y
EOF
  fi_run status --format=json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"issues":'* ]]
  [[ "$output" != *'"other":'* ]]
}

@test "fi_has_conflict_markers: returns 0 when file contains <<<<<<< markers" {
  mkdir -p tmp
  cat > tmp/conflict.md <<'EOF'
- [open] 2026-05-01 a.ts:1 — entry one
<<<<<<< HEAD
- [open] 2026-05-02 b.ts:1 — branch HEAD
=======
- [fixed] 2026-05-02 b.ts:1 — branch OTHER
>>>>>>> other
- [open] 2026-05-03 c.ts:1 — entry two
EOF
  source "${BATS_TEST_DIRNAME}/../lib/parse-entries.sh"
  run fi_has_conflict_markers tmp/conflict.md
  [ "$status" -eq 0 ]
}

@test "fi_has_conflict_markers: returns 1 when file has no markers" {
  mkdir -p tmp
  cat > tmp/clean.md <<'EOF'
- [open] 2026-05-01 a.ts:1 — entry one
- [open] 2026-05-03 c.ts:1 — entry two
EOF
  source "${BATS_TEST_DIRNAME}/../lib/parse-entries.sh"
  run fi_has_conflict_markers tmp/clean.md
  [ "$status" -eq 1 ]
}

@test "fi_has_conflict_markers: returns 1 when file does not exist" {
  source "${BATS_TEST_DIRNAME}/../lib/parse-entries.sh"
  run fi_has_conflict_markers tmp/nonexistent.md
  [ "$status" -eq 1 ]
}

@test "fi_entries: skips lines inside <<<<<<< / >>>>>>> conflict regions" {
  mkdir -p tmp
  cat > tmp/conflict.md <<'EOF'
- [open] 2026-05-01 a.ts:1 — entry one
<<<<<<< HEAD
- [open] 2026-05-02 b.ts:1 — branch HEAD version
=======
- [open] 2026-05-02 b.ts:1 — branch OTHER version
>>>>>>> other
- [open] 2026-05-03 c.ts:1 — entry two
EOF
  source "${BATS_TEST_DIRNAME}/../lib/parse-entries.sh"
  run fi_entries tmp/conflict.md open
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" = "2" ]
  echo "$output" | grep -q 'a.ts:1'
  echo "$output" | grep -q 'c.ts:1'
  ! echo "$output" | grep -q 'b.ts:1'
}

@test "fi_count open: returns conflict-skipped count" {
  mkdir -p tmp
  cat > tmp/conflict.md <<'EOF'
- [open] 2026-05-01 a.ts:1 — entry one
<<<<<<< HEAD
- [open] 2026-05-02 b.ts:1 — branch HEAD
=======
- [open] 2026-05-02 b.ts:1 — branch OTHER
>>>>>>> other
- [open] 2026-05-03 c.ts:1 — entry two
EOF
  source "${BATS_TEST_DIRNAME}/../lib/parse-entries.sh"
  run fi_count tmp/conflict.md open
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "fi_entries: 'all' ignores non-canonical statuses (e.g. [TODO], [in-progress])" {
  mkdir -p tmp
  cat > tmp/mixed.md <<'EOF'
- [open] 2026-05-01 a.ts:1 — canonical open
- [deferred] 2026-05-02 b.ts:1 — canonical deferred
- [fixed] 2026-05-03 c.ts:1 — canonical fixed
- [TODO] 2026-05-04 d.ts:1 — non-canonical status
- [in-progress] 2026-05-05 e.ts:1 — non-canonical status
EOF
  source "${BATS_TEST_DIRNAME}/../lib/parse-entries.sh"
  run fi_entries tmp/mixed.md all
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" = "3" ]
  echo "$output" | grep -q 'a.ts:1'
  echo "$output" | grep -q 'b.ts:1'
  echo "$output" | grep -q 'c.ts:1'
  ! echo "$output" | grep -q 'd.ts:1'
  ! echo "$output" | grep -q 'e.ts:1'
}

@test "status: critical entry in PR does not hide plain open entries (overlap)" {
  local today
  today="$(date +%Y-%m-%d)"
  mkdir -p docs
  cat > docs/found-issues.md <<EOF
# found-issues

- [open] [!] $today src/a.py:1 — critical bug already in PR (PR: org/repo#7)
- [open] $today src/b.py:1 — plain open entry
EOF
  fi_run status --format=json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"critical":1'* ]]
  [[ "$output" == *'"issues":1'* ]]
  [[ "$output" == *'"in_pr":1'* ]]
  [[ "$output" == *'"total_open":2'* ]]

  fi_run status --format=plain
  [[ "$output" == *"1 critical"* ]]
  [[ "$output" == *"1 other"* ]]
  [[ "$output" == *"1 in PR"* ]]
}
