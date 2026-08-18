#!/usr/bin/env bats
# Tests for format-enforcer accepting new sibling annotations.
# The enforcer is blocklist-based; new sibling annotations should pass cleanly.
# These tests guard against accidental tightening of the blocklist.

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
  export FOUND_ISSUES_MODE=github-direct
}

teardown() {
  fi_teardown_tmp
  unset FOUND_ISSUES_MODE
}

HOOK="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/hooks/format-enforcer.sh"

@test "format-enforcer: (PR-closed: ...) annotation passes" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [open] 2026-05-11 src/a.py:1 — bug (PR-closed: foo/bar#42)"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "format-enforcer: (commit-stale: ...) annotation passes" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [open] 2026-05-11 src/a.py:1 — bug (commit-stale: deadbeef)"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "format-enforcer: (renamed-from: ...) annotation passes" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [open] 2026-05-11 src/new.py:1 — bug (renamed-from: src/old.py)"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "format-enforcer: multiple new annotations together pass" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [open] 2026-05-11 src/new.py:1 — bug (renamed-from: src/old.py) (commit-stale: deadbeef)"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "format-enforcer: still blocks bare PR #N (regression guard)" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [open] 2026-05-11 src/a.py:1 — bug PR #42"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"bare"* ]]
}

@test "format-enforcer: (PR-closed: ...) with full org/repo format passes" {
  # [fixed] needs a verification token; (PR-closed: …) is demoted evidence,
  # not verification. Pair with (verified: ai) — the canonical shape after sync flips a
  # demoted-PR entry that AI verified by reading code.
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [fixed] 2026-05-11 src/auth.ts:88 — token leak (PR-closed: myorg/myrepo#123) (verified: ai) (fixed: 2026-05-11)"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "format-enforcer: (renamed-from: ...) with nested path passes" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [open] 2026-05-11 src/components/Button.tsx:15 — missing export (renamed-from: src/ui/Button.tsx)"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "format-enforcer: new annotations don't interfere with existing (PR: ...) canonical form" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [open] 2026-05-11 src/a.py:1 — bug (PR: foo/bar#42) (commit-stale: abc1234)"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}


# === Suggestion tokens (2026-08-17) ===========================================
# (PR-auto:)/(commit-auto:) are hook SUGGESTIONS: legal on an [open] entry,
# and deliberately NOT accepted as the verification token a [fixed] entry
# requires — only a confirmed annotation closes work.

@test "format-enforcer: (commit-auto: ...) passes on an [open] entry" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [open] 2026-08-17 src/a.py:1 — bug (commit-auto: abc1234)"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "format-enforcer: (PR-auto: ...) passes on an [open] entry" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [open] 2026-08-17 src/a.py:1 — bug (PR-auto: org/repo#7)"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "format-enforcer: (commit-auto: ...) alone does NOT satisfy the [fixed] token rule" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [fixed] 2026-08-17 src/a.py:1 — bug (commit-auto: abc1234)"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -ne 0 ]
}

@test "format-enforcer: (PR-auto: ...) alone does NOT satisfy the [fixed] token rule" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [fixed] 2026-08-17 src/a.py:1 — bug (PR-auto: org/repo#7)"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -ne 0 ]
}
