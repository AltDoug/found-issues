#!/usr/bin/env bats
# Tests for hooks/pre-commit.sh — git pre-commit hook (per-repo, opt-in)

load 'helpers'

HOOK="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/hooks/pre-commit.sh"

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
  unset FOUND_ISSUES_PRE_COMMIT
}

@test "pre-commit: blocks bare PR in staged content" {
  mkdir -p docs
  echo "- [open] 2026-05-08 src/foo.py:42 — bug PR #5" > docs/found-issues.md
  git add docs/found-issues.md
  run "$HOOK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bare 'PR #N'"* ]]
}

@test "pre-commit: allows canonical PR annotation" {
  mkdir -p docs
  echo "- [open] 2026-05-08 src/foo.py:42 — bug (PR: org/repo#5)" > docs/found-issues.md
  git add docs/found-issues.md
  run "$HOOK"
  [ "$status" -eq 0 ]
}

@test "pre-commit: passes when found-issues.md not staged" {
  echo "unrelated" > other.txt
  git add other.txt
  run "$HOOK"
  [ "$status" -eq 0 ]
}

@test "pre-commit: blocks uppercase status" {
  mkdir -p docs
  echo "- [OPEN] 2026-05-08 src/foo.py:42 — bug" > docs/found-issues.md
  git add docs/found-issues.md
  run "$HOOK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"lowercase"* ]]
}

@test "pre-commit: respects FOUND_ISSUES_PRE_COMMIT=off" {
  export FOUND_ISSUES_PRE_COMMIT=off
  mkdir -p docs
  echo "- [OPEN] PR #5 — garbage" > docs/found-issues.md
  git add docs/found-issues.md
  run "$HOOK"
  [ "$status" -eq 0 ]
}

@test "pre-commit: handles .found-issues.md (local mode)" {
  echo "- [open] 2026-05-08 src/foo.py:42 — bug PR #5" > .found-issues.md
  git add .found-issues.md
  run "$HOOK"
  [ "$status" -eq 1 ]
}

@test "pre-commit: accepts (touched: ...) defer-flow annotation" {
  mkdir -p docs
  echo "- [deferred] 2026-05-08 src/foo.py:42 — not now (touched: 2026-05-21, 2026-05-28)" > docs/found-issues.md
  git add docs/found-issues.md
  run "$HOOK"
  [ "$status" -eq 0 ]
}

@test "pre-commit: accepts (touched: ...) with (defer-cycle: N) annotation" {
  mkdir -p docs
  echo "- [deferred] 2026-05-08 src/foo.py:42 — not now (touched: 2026-05-21; 2026-05-28) (defer-cycle: 2)" > docs/found-issues.md
  git add docs/found-issues.md
  run "$HOOK"
  [ "$status" -eq 0 ]
}

@test "pre-commit: accepts (reason: ...) defer-flow annotation" {
  mkdir -p docs
  echo "- [deferred] 2026-05-08 src/foo.py:42 — not now (reason: tracked in JIRA-1234)" > docs/found-issues.md
  git add docs/found-issues.md
  run "$HOOK"
  [ "$status" -eq 0 ]
}

# === v1.6.0: rule parity with format-enforcer.sh ===

@test "pre-commit: blocks bare PR coexisting with a canonical annotation" {
  mkdir -p docs
  echo "- [open] 2026-05-08 src/foo.py:42 — bug, see PR #7 (PR: org/repo#5)" > docs/found-issues.md
  git add docs/found-issues.md
  run "$HOOK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bare 'PR #N'"* ]]
}

@test "pre-commit: blocks [fixed] without a verification token (rule 6)" {
  mkdir -p docs
  echo "- [fixed] 2026-05-08 src/foo.py:42 — bug (fixed: 2026-05-09)" > docs/found-issues.md
  git add docs/found-issues.md
  run "$HOOK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"verification token"* ]]
}

@test "pre-commit: allows [fixed] with (verified: ai)" {
  mkdir -p docs
  echo "- [fixed] 2026-05-08 src/foo.py:42 — bug (verified: ai) (fixed: 2026-05-09)" > docs/found-issues.md
  git add docs/found-issues.md
  run "$HOOK"
  [ "$status" -eq 0 ]
}

@test "pre-commit: allows [fixed] with canonical PR annotation" {
  mkdir -p docs
  echo "- [fixed] 2026-05-08 src/foo.py:42 — bug (PR: org/repo#5) (fixed: 2026-05-09)" > docs/found-issues.md
  git add docs/found-issues.md
  run "$HOOK"
  [ "$status" -eq 0 ]
}

@test "pre-commit: allows [fixed] with (closure: tombstone)" {
  mkdir -p docs
  echo "- [fixed] 2026-05-08 src/gone.py:42 — bug (closure: tombstone) (fixed: 2026-05-09)" > docs/found-issues.md
  git add docs/found-issues.md
  run "$HOOK"
  [ "$status" -eq 0 ]
}

@test "pre-commit: blocks [fixed] with only demoted (PR-closed: ...)" {
  mkdir -p docs
  echo "- [fixed] 2026-05-08 src/foo.py:42 — bug (PR-closed: org/repo#5) (fixed: 2026-05-09)" > docs/found-issues.md
  git add docs/found-issues.md
  run "$HOOK"
  [ "$status" -eq 1 ]
}
