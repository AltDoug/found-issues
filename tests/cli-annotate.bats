#!/usr/bin/env bats
# Tests for `found-issues annotate-pr` and `annotate-commit`

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

# === annotate-commit ===

@test "annotate-commit: adds (commit: <sha>) to matching entry" {
  mkdir -p src
  echo "x" > src/foo.py
  fi_run log "src/foo.py:1 — bug"
  git add -A
  git commit -q -m "fix foo"
  short_sha="$(git rev-parse --short=7 HEAD)"

  fi_run annotate-commit HEAD
  [ "$status" -eq 0 ]
  grep -q "src/foo.py:1.*\(commit: $short_sha\)" docs/found-issues.md
}

@test "annotate-commit: defaults to HEAD" {
  mkdir -p src
  echo "x" > src/foo.py
  fi_run log "src/foo.py:1 — bug"
  git add -A
  git commit -q -m "fix"
  short_sha="$(git rev-parse --short=7 HEAD)"

  fi_run annotate-commit
  [ "$status" -eq 0 ]
  grep -q "(commit: $short_sha)" docs/found-issues.md
}

@test "annotate-commit: no-op when commit doesn't touch logged paths" {
  mkdir -p src
  echo "x" > src/foo.py
  fi_run log "src/foo.py:1 — bug"
  echo "y" > src/other.py
  git add src/other.py
  git commit -q -m "unrelated"

  fi_run annotate-commit HEAD
  [ "$status" -eq 0 ]
  [[ "$output" == *"no [open] entries match"* ]]
  ! grep -q '(commit:' docs/found-issues.md
}

@test "annotate-commit: idempotent (same SHA twice doesn't double-annotate)" {
  mkdir -p src
  echo "x" > src/foo.py
  fi_run log "src/foo.py:1 — bug"
  git add -A
  git commit -q -m "fix"

  fi_run annotate-commit HEAD
  fi_run annotate-commit HEAD

  # Should have exactly one (commit: ...) annotation
  count="$(grep -oE '\(commit: [a-f0-9]+\)' docs/found-issues.md | wc -l | tr -d ' ')"
  [ "$count" = "1" ]
}

@test "annotate-commit: rejects invalid SHA" {
  fi_run annotate-commit zzznotasha
  [ "$status" -ne 0 ]
}

# === annotate-pr ===

@test "annotate-pr: errors gracefully without GitHub remote" {
  fi_run log "src/foo.py:1 — bug"
  fi_run annotate-pr 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"not in a GitHub repo"* ]] || [[ "$output" == *"not in a GitHub"* ]]
}

@test "annotate-pr: rejects non-numeric PR" {
  fi_run annotate-pr abc
  [ "$status" -ne 0 ]
  [[ "$output" == *"numeric"* ]]
}
