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

@test "log: touch below threshold prints brief stderr 'Nx of M for promotion'" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — null check missing
EOF
  unset FOUND_ISSUES_DEFER_TOUCH_THRESHOLD FOUND_ISSUES_DEFER_ESCALATION_FACTOR
  # Touch 1 of 3
  fi_run log "src/foo.py:42 — null check missing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1x of 3"* ]] || [[ "$output" == *"1 of 3"* ]]
  [[ "$output" == *"src/foo.py:42"* ]]
}

@test "log: touch == threshold (non-critical) prints nudge with promote-deferred command" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — null check missing (touched: 2026-05-21, 2026-05-28)
EOF
  unset FOUND_ISSUES_DEFER_TOUCH_THRESHOLD FOUND_ISSUES_DEFER_ESCALATION_FACTOR
  # 3rd touch hits threshold
  fi_run log "src/foo.py:42 — null check missing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"now 3x"* ]] || [[ "$output" == *"3x, threshold 3"* ]]
  [[ "$output" == *"promote-deferred"* ]]
  # Entry should still be [deferred] (non-critical doesn't auto-promote)
  grep -F "[deferred]" docs/found-issues.md
  ! grep -F "[open]" docs/found-issues.md
}

@test "log: touch >= threshold (critical [!]) auto-promotes inline" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] [!] 2026-05-10 src/foo.py:42 — auth bypass (touched: 2026-05-21, 2026-05-28)
EOF
  unset FOUND_ISSUES_DEFER_TOUCH_THRESHOLD FOUND_ISSUES_DEFER_ESCALATION_FACTOR
  fi_run log "src/foo.py:42 — auth bypass"
  [ "$status" -eq 0 ]
  [[ "$output" == *"auto-promoted"* ]]
  [[ "$output" == *"3x"* ]]
  # Entry now [open] [!]
  grep -F "[open] [!]" docs/found-issues.md
  ! grep -F "[deferred]" docs/found-issues.md
}

@test "log: cycle 2 threshold = 6 (default base 3, factor 2)" {
  # Entry already in cycle 2 with 5 touches in current segment
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-01, 2026-05-08, 2026-05-15; 2026-07-01, 2026-07-08, 2026-07-15, 2026-07-22, 2026-07-29) (defer-cycle: 2)
EOF
  unset FOUND_ISSUES_DEFER_TOUCH_THRESHOLD FOUND_ISSUES_DEFER_ESCALATION_FACTOR
  # 6th touch in cycle 2 hits threshold (6 = 3 * 2^1)
  fi_run log "src/foo.py:42 — bug"
  [ "$status" -eq 0 ]
  [[ "$output" == *"6x, threshold 6"* ]] || [[ "$output" == *"now 6x"* ]]
  [[ "$output" == *"promote-deferred"* ]]
}

@test "log: cycle 3 threshold = 12 - escalation across multiple cycles" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-01, 2026-05-08, 2026-05-15; 2026-07-01, 2026-07-08, 2026-07-15, 2026-07-22, 2026-07-29, 2026-08-05; 2026-09-01, 2026-09-08, 2026-09-15, 2026-09-22, 2026-09-29, 2026-10-06, 2026-10-13, 2026-10-20, 2026-10-27, 2026-11-03, 2026-11-10) (defer-cycle: 3)
EOF
  unset FOUND_ISSUES_DEFER_TOUCH_THRESHOLD FOUND_ISSUES_DEFER_ESCALATION_FACTOR
  # 12th touch in cycle 3 hits threshold (12 = 3 * 2^2)
  fi_run log "src/foo.py:42 — bug"
  [ "$status" -eq 0 ]
  [[ "$output" == *"now 12x"* ]] || [[ "$output" == *"12x, threshold 12"* ]]
}

@test "log: deferred-touch nudge surfaces on stdout (not just stderr)" {
  # Regression for the 2026-05-10 UX audit (surface 3.3). Pre-v1.0.6,
  # fi_handle_deferred_touch printed only to stderr — wrappers that swallow
  # stderr saw zero feedback. Now stdout carries a single parseable summary.
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — null check missing
EOF
  unset FOUND_ISSUES_DEFER_TOUCH_THRESHOLD FOUND_ISSUES_DEFER_ESCALATION_FACTOR
  stdout_only="$("$FI_BIN" log "src/foo.py:42 — null check missing" 2>/dev/null)"
  [[ "$stdout_only" == *"Touched [deferred]"* ]]
  [[ "$stdout_only" == *"src/foo.py:42"* ]]
  [[ "$stdout_only" == *"cycle 1"* ]]
  [[ "$stdout_only" == *"1x of 3"* ]]
}

@test "log: deferred-touch at-threshold stdout flags 'consider promote-deferred'" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — null check missing (touched: 2026-05-21, 2026-05-28)
EOF
  unset FOUND_ISSUES_DEFER_TOUCH_THRESHOLD FOUND_ISSUES_DEFER_ESCALATION_FACTOR
  stdout_only="$("$FI_BIN" log "src/foo.py:42 — null check missing" 2>/dev/null)"
  [[ "$stdout_only" == *"at threshold"* ]]
  [[ "$stdout_only" == *"consider promote-deferred"* ]]
  [[ "$stdout_only" == *"3x of 3"* ]]
}

@test "log: deferred-touch auto-promote stdout reports the flip" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] [!] 2026-05-10 src/foo.py:42 — auth bypass (touched: 2026-05-21, 2026-05-28)
EOF
  unset FOUND_ISSUES_DEFER_TOUCH_THRESHOLD FOUND_ISSUES_DEFER_ESCALATION_FACTOR
  stdout_only="$("$FI_BIN" log "src/foo.py:42 — auth bypass" 2>/dev/null)"
  [[ "$stdout_only" == *"auto-promoted to [open]"* ]]
  [[ "$stdout_only" == *"src/foo.py:42"* ]]
  [[ "$stdout_only" == *"3x of 3"* ]]
}

@test "log: same-day double touch appends date twice" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — bug
EOF
  fi_run log "src/foo.py:42 — bug"
  [ "$status" -eq 0 ]
  fi_run log "src/foo.py:42 — bug"
  [ "$status" -eq 0 ]
  today="$(date +%Y-%m-%d)"
  # Date appears twice in the (touched: ...) annotation
  count_in_annotation="$(grep -oE "(touched: [^)]+)" docs/found-issues.md | grep -oE "$today" | wc -l | tr -d ' ')"
  [ "$count_in_annotation" -eq 2 ]
}

@test "log: FOUND_ISSUES_DEFER_TOUCH_THRESHOLD=5 overrides default" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, 2026-05-22, 2026-05-23, 2026-05-24)
EOF
  FOUND_ISSUES_DEFER_TOUCH_THRESHOLD=5 fi_run log "src/foo.py:42 — bug"
  [ "$status" -eq 0 ]
  [[ "$output" == *"5x, threshold 5"* ]] || [[ "$output" == *"now 5x"* ]]
}

@test "log: invalid FOUND_ISSUES_DEFER_TOUCH_THRESHOLD warns + falls back to 3" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, 2026-05-22)
EOF
  FOUND_ISSUES_DEFER_TOUCH_THRESHOLD=garbage fi_run log "src/foo.py:42 — bug"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning"* ]] || [[ "$output" == *"invalid"* ]]
  # Falls back to default 3 → 3rd touch hits threshold
  [[ "$output" == *"now 3x"* ]] || [[ "$output" == *"3x, threshold 3"* ]]
}

@test "log: matching neither [open] nor [deferred] adds new [open] (regression)" {
  mkdir -p docs
  fi_run log "src/foo.py:42 — null check"
  [ "$status" -eq 0 ]
  fi_run log "src/bar.py:99 — different bug"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^- \[open\]' docs/found-issues.md)" -eq 2 ]
}

@test "log: full lifecycle - log, defer, 3x touch, nudge, promote, re-defer, 6x touch, second nudge" {
  unset FOUND_ISSUES_DEFER_TOUCH_THRESHOLD FOUND_ISSUES_DEFER_ESCALATION_FACTOR

  # Step 1: log
  fi_run log "src/auth.py:88 — leaks session token"
  [ "$status" -eq 0 ]

  # Step 2: defer
  fi_run defer "src/auth.py:88" --reason "tracked in JIRA"
  [ "$status" -eq 0 ]
  grep -F "[deferred]" docs/found-issues.md
  grep -F "(reason: tracked in JIRA)" docs/found-issues.md

  # Step 3: 3 touches → nudge fires on 3rd
  fi_run log "src/auth.py:88 — leaks session token"
  [[ "$output" == *"1x of 3"* ]]
  fi_run log "src/auth.py:88 — leaks session token"
  [[ "$output" == *"2x of 3"* ]]
  fi_run log "src/auth.py:88 — leaks session token"
  [[ "$output" == *"now 3x"* ]] || [[ "$output" == *"3x, threshold 3"* ]]
  [[ "$output" == *"promote-deferred"* ]]
  # Still [deferred] (non-critical)
  grep -F "[deferred]" docs/found-issues.md

  # Step 4: promote
  fi_run promote-deferred "src/auth.py:88"
  [ "$status" -eq 0 ]
  grep -F "[open]" docs/found-issues.md

  # Step 5: re-defer (cycle 2)
  fi_run defer "src/auth.py:88" --reason "rescoped"
  [ "$status" -eq 0 ]
  grep -F "(defer-cycle: 2)" docs/found-issues.md
  grep -F "(reason: rescoped)" docs/found-issues.md

  # Step 6: 6 touches in cycle 2 → second nudge at 6th
  fi_run log "src/auth.py:88 — leaks session token"
  [[ "$output" == *"1x of 6"* ]]
  fi_run log "src/auth.py:88 — leaks session token"
  fi_run log "src/auth.py:88 — leaks session token"
  fi_run log "src/auth.py:88 — leaks session token"
  fi_run log "src/auth.py:88 — leaks session token"
  fi_run log "src/auth.py:88 — leaks session token"
  [[ "$output" == *"now 6x"* ]] || [[ "$output" == *"6x, threshold 6"* ]]
}
