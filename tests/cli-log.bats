#!/usr/bin/env bats
# Tests for `found-issues log`

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

@test "log: appends a basic entry" {
  fi_run log "src/foo.py:42 — null check missing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Logged:"* ]]
  [[ "$output" == *"src/foo.py:42"* ]]
}

@test "log: creates docs/found-issues.md if missing" {
  [ ! -f docs/found-issues.md ]
  fi_run log "src/foo.py:42 — bug"
  [ "$status" -eq 0 ]
  [ -f docs/found-issues.md ]
}

@test "log: dedups identical entry (same path:line+symptom)" {
  fi_run log "src/foo.py:42 — null check (suggested: A)"
  [ "$status" -eq 0 ]
  fi_run log "src/foo.py:42 — null check (suggested: B)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipped"* ]]

  count="$(grep -cE '^- \[open\]' docs/found-issues.md)"
  [ "$count" = "1" ]
}

@test "log: same path:line, different symptom does NOT dedup" {
  fi_run log "src/foo.py:42 — null check"
  fi_run log "src/foo.py:42 — wrong type cast"
  count="$(grep -cE '^- \[open\]' docs/found-issues.md)"
  [ "$count" = "2" ]
}

@test "log: --critical adds [!] flag" {
  fi_run log --critical "src/auth.ts:88 — leaks token"
  [ "$status" -eq 0 ]
  grep -qE '^- \[open\] \[!\] ' docs/found-issues.md
}

@test "log: abstract entry (no path:line) works" {
  fi_run log "workflow/shutdown — sigterm kills sessions silently"
  [ "$status" -eq 0 ]
  grep -qE '^- \[open\] [0-9-]+ workflow/shutdown — ' docs/found-issues.md
}

@test "log: rejects empty symptom" {
  fi_run log "src/foo.py:42 — "
  [ "$status" -ne 0 ]
}

@test "log: rejects missing em-dash separator" {
  fi_run log "src/foo.py:42 - bug"
  [ "$status" -ne 0 ]
}

@test "log: no blank lines between entries" {
  fi_run log "src/foo.py:1 — first"
  fi_run log "src/foo.py:2 — second"
  fi_run log "src/foo.py:3 — third"
  # Count consecutive [open] lines (no gaps)
  blank_between="$(awk '/^- \[open\]/ {n++; if(n>1 && prev_blank) bad++; prev_blank=0} /^$/ {prev_blank=1} END{print bad+0}' docs/found-issues.md)"
  [ "$blank_between" = "0" ]
}

@test "log: --critical and dedup interact correctly" {
  fi_run log --critical "src/foo.py:42 — bug"
  fi_run log --critical "src/foo.py:42 — bug"
  [[ "$output" == *"Skipped"* ]]
  count="$(grep -cE '^- \[open\] \[!\]' docs/found-issues.md)"
  [ "$count" = "1" ]
}

@test "log: trailing total includes singular 'issue' for count=1" {
  fi_run log "src/foo.py:42 — bug"
  [[ "$output" == *"1 issue"$'\n'* ]] || [[ "$output" == *"1 issue" ]]
}

@test "log: trailing total uses plural 'issues' for count>=2" {
  fi_run log "src/foo.py:42 — bug A"
  fi_run log "src/foo.py:43 — bug B"
  [[ "$output" == *"2 issues"* ]]
}

@test "log: matching [deferred] entry appends today's date to (touched: ...)" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — null check missing
EOF
  fi_run log "src/foo.py:42 — null check missing"
  [ "$status" -eq 0 ]
  # Today's date appears as a touched annotation
  today="$(date +%Y-%m-%d)"
  grep -F "(touched: $today)" docs/found-issues.md
  # No new [open] entry created
  ! grep -F "[open]" docs/found-issues.md
  # Single [deferred] entry remains
  [ "$(grep -c '^- \[deferred\]' docs/found-issues.md)" -eq 1 ]
}

@test "log: matching [deferred] without prior touched: creates the annotation" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — null check missing (reason: scoped out)
EOF
  fi_run log "src/foo.py:42 — null check missing"
  [ "$status" -eq 0 ]
  today="$(date +%Y-%m-%d)"
  grep -F "(touched: $today)" docs/found-issues.md
  # Existing reason annotation preserved
  grep -F "(reason: scoped out)" docs/found-issues.md
}
