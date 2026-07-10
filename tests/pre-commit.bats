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

@test "pre-commit: untouched historical violations do not block a clean new entry" {
  # Rules apply to lines the commit ADDS, not the whole file — otherwise a
  # v1.5.x-era line grandfathered by the old rules blocks every future
  # commit of the file.
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [fixed] 2026-03-01 src/old.py:1 — legacy, see PR #100 (PR: org/repo#102) (fixed: 2026-03-02)
- [fixed] 2026-03-01 src/older.py:1 — pre-v1.5.4 tokenless flip (fixed: 2026-03-02)
EOF
  git add docs/found-issues.md
  git commit -q -m "seed legacy file"
  echo "- [open] 2026-07-10 src/new.py:5 — fresh valid entry" >> docs/found-issues.md
  git add docs/found-issues.md
  run "$HOOK"
  [ "$status" -eq 0 ]
}

@test "pre-commit: newly added bare-PR line still blocks" {
  mkdir -p docs
  echo "# found-issues" > docs/found-issues.md
  git add docs/found-issues.md
  git commit -q -m "seed"
  echo "- [open] 2026-07-10 src/new.py:5 — bug PR #7" >> docs/found-issues.md
  git add docs/found-issues.md
  run "$HOOK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bare 'PR #N'"* ]]
}

@test "pre-commit: modified [fixed] line with bare PR alongside canonical passes (historical exemption)" {
  mkdir -p docs
  echo "- [fixed] 2026-03-01 src/old.py:1 — legacy, see PR #100 (PR: org/repo#102) (fixed: 2026-03-02) (touched: 2026-07-10)" > docs/found-issues.md
  git add docs/found-issues.md
  run "$HOOK"
  [ "$status" -eq 0 ]
}
