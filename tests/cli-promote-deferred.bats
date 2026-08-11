#!/usr/bin/env bats
# Tests for `found-issues promote-deferred`

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

@test "promote-deferred: flips [deferred] to [open], preserves annotations" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — null check (reason: tracked) (touched: 2026-05-21, 2026-05-28, 2026-06-04)
EOF
  fi_run promote-deferred "src/foo.py:42"
  [ "$status" -eq 0 ]
  grep -F "[open]" docs/found-issues.md
  ! grep -F "[deferred]" docs/found-issues.md
  # All annotations preserved byte-identical
  grep -F "(reason: tracked)" docs/found-issues.md
  grep -F "(touched: 2026-05-21, 2026-05-28, 2026-06-04)" docs/found-issues.md
}

@test "promote-deferred: no match exits 1" {
  fi_run promote-deferred "nonexistent"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no [deferred] entries match"* ]]
}

@test "promote-deferred: ambiguous match exits 2 with listing" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — null check
- [deferred] 2026-05-10 src/foo.py:88 — leak
EOF
  fi_run promote-deferred "foo.py"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ambiguous"* ]]
  [[ "$output" == *"src/foo.py:42"* ]]
  [[ "$output" == *"src/foo.py:88"* ]]
}

@test "promote-deferred: exit 3 with helpful message when match is [open]" {
  fi_run log "src/foo.py:42 — null check"
  fi_run promote-deferred "src/foo.py:42"
  [ "$status" -eq 3 ]
  [[ "$output" == *"not [deferred]"* ]] || [[ "$output" == *"[open]"* ]]
}

@test "promote-deferred: --match flag accepted (alias for positional)" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — null check
EOF
  fi_run promote-deferred --match "src/foo.py:42"
  [ "$status" -eq 0 ]
  grep -F "[open]" docs/found-issues.md
}

@test "promote-deferred: preserves (defer-cycle: N) as evidence" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — null check (touched: 2026-05-21, 2026-05-28; 2026-07-15) (defer-cycle: 2)
EOF
  fi_run promote-deferred "src/foo.py:42"
  [ "$status" -eq 0 ]
  grep -F "(defer-cycle: 2)" docs/found-issues.md
  grep -F "(touched: 2026-05-21, 2026-05-28; 2026-07-15)" docs/found-issues.md
}

@test "promote-deferred: strips (mute-until: ...) on flip to [open]" {
  # 2026-05-10 UX audit surface 4.4 design. mute-until is a defer-state
  # concept; an [open] entry has no nudge to suppress. Stripping it on
  # promote keeps the active file readable. touch/cycle/reason stay.
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — null check (reason: blocked) (touched: 2026-05-21) (mute-until: 2099-12-31)
EOF
  fi_run promote-deferred "src/foo.py:42"
  [ "$status" -eq 0 ]
  grep -F "[open]" docs/found-issues.md
  # mute-until is gone
  ! grep -F "(mute-until:" docs/found-issues.md
  # other annotations stay
  grep -F "(reason: blocked)" docs/found-issues.md
  grep -F "(touched: 2026-05-21)" docs/found-issues.md
}

# === final-partial-line data loss (v2.2.1) ===
#
# promote-deferred rewrites via fi_promote_entry_to_open, which is also the
# auto-promote path fired by a deferred entry crossing its touch threshold.
# See fi_seed_no_trailing_newline in helpers.bash.

@test "promote-deferred: does not drop a final entry that lacks a trailing newline" {
  fi_seed_no_trailing_newline deferred

  fi_run promote-deferred "first entry"
  [ "$status" -eq 0 ]
  fi_assert_both_entries_survived
  grep -q '^- \[open\].*first entry' docs/found-issues.md
}
