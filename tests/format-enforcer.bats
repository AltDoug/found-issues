#!/usr/bin/env bats
# Tests for hooks/format-enforcer.sh

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
  # github-pr/github-direct require gh — force github-direct via env
  # so the hook hard-blocks (matches its production behavior)
  export FOUND_ISSUES_MODE=github-direct
}

teardown() {
  fi_teardown_tmp
  unset FOUND_ISSUES_MODE
}

HOOK="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/hooks/format-enforcer.sh"

@test "format-enforcer: blocks bare 'PR #N'" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [open] 2026-05-08 src/foo.py:42 — bug fixed by PR #5"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"bare 'PR #N'"* ]]
}

@test "format-enforcer: allows canonical (PR: org/repo#N)" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [open] 2026-05-08 src/foo.py:42 — bug (PR: org/repo#5)"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "format-enforcer: blocks uppercase status" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [OPEN] 2026-05-08 src/foo.py:42 — bug"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"lowercase"* ]]
}

@test "format-enforcer: blocks [critical] bundled into status" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [critical] 2026-05-08 src/foo.py:42 — bug"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"separate token"* ]]
}

@test "format-enforcer: passes through non-found-issues files" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"src/random.py","content":"PR #5 here"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "format-enforcer: silent in local mode (no git)" {
  fi_teardown_tmp
  fi_setup_tmp
  unset FOUND_ISSUES_MODE
  export FOUND_ISSUES_MODE=local
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [open] 2026-05-08 src/foo.py:42 — bug PR #5"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "format-enforcer: warns (exit 0) in git mode" {
  unset FOUND_ISSUES_MODE
  export FOUND_ISSUES_MODE=git
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [open] 2026-05-08 src/foo.py:42 — bug PR #5"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
  # Warning should be emitted to stderr though
}

@test "format-enforcer: blocks Edit with bad new_string" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"docs/found-issues.md","old_string":"X","new_string":"- [open] 2026-05-08 src/foo.py:42 — bug PR #5"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 2 ]
}

@test "format-enforcer: respects FOUND_ISSUES_FORMAT_ENFORCER=off" {
  export FOUND_ISSUES_FORMAT_ENFORCER=off
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [OPEN] PR #5 garbage"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
  unset FOUND_ISSUES_FORMAT_ENFORCER
}

@test "format-enforcer: accepts (touched: ...) defer-flow annotation" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [deferred] 2026-05-08 src/foo.py:42 — not now (touched: 2026-05-21, 2026-05-28)"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "format-enforcer: accepts (touched: ...) with (defer-cycle: N) annotation" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [deferred] 2026-05-08 src/foo.py:42 — not now (touched: 2026-05-21; 2026-05-28) (defer-cycle: 2)"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "format-enforcer: accepts (reason: ...) defer-flow annotation" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [deferred] 2026-05-08 src/foo.py:42 — not now (reason: tracked in JIRA-1234)"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

# === Workflow: [fixed] requires verification token ===
# These guard against the failure mode where an AI manually edits docs/found-issues.md
# to flip [open] → [fixed] without going through /found-issues:sync. The sync flow
# always adds a verification token; a direct edit usually doesn't.

@test "format-enforcer: blocks [fixed] without any verification token" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [fixed] 2026-05-08 src/foo.py:42 — bug"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"verification token"* ]]
}

@test "format-enforcer: blocks Edit transition [open] → [fixed] without verification" {
  # This is the exact incident shape from the 2026-05-21 orchard session.
  old='- [open] 2026-05-08 src/foo.py:42 — bug (suggested: add guard)'
  new='- [fixed] 2026-05-08 src/foo.py:42 — bug (suggested: add guard)'
  input="$(printf '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"docs/found-issues.md","old_string":"%s","new_string":"%s"}}' "$old" "$new")"
  run bash -c "printf '%s' '$input' | '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"verification token"* ]]
}

@test "format-enforcer: allows [fixed] with (PR: org/repo#N)" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [fixed] 2026-05-08 src/foo.py:42 — bug (PR: myorg/myrepo#42) (fixed: 2026-05-09)"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "format-enforcer: allows [fixed] with (commit: <sha>)" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [fixed] 2026-05-08 src/foo.py:42 — bug (commit: deadbeef) (fixed: 2026-05-09)"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "format-enforcer: allows [fixed] with (verified: ai)" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [fixed] 2026-05-08 src/foo.py:42 — bug (verified: ai) (fixed: 2026-05-09)"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "format-enforcer: allows [fixed] with (verified: review)" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [fixed] 2026-05-08 src/foo.py:42 — bug (verified: review) (fixed: 2026-05-09)"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "format-enforcer: allows [fixed] with (closure: tombstone)" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [fixed] 2026-05-08 src/foo.py:42 — bug (closure: tombstone) (fixed: 2026-05-09)"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "format-enforcer: blocks [fixed] with only demoted (PR-closed: ...)" {
  # Demoted PR alone is weak evidence per spec — not a verification token.
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [fixed] 2026-05-08 src/foo.py:42 — bug (PR-closed: myorg/myrepo#42)"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"verification token"* ]]
}

@test "format-enforcer: blocks [fixed] with only demoted (commit-stale: ...)" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [fixed] 2026-05-08 src/foo.py:42 — bug (commit-stale: deadbeef)"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"verification token"* ]]
}

@test "format-enforcer: [fixed] verification check is silent in local mode" {
  fi_teardown_tmp
  fi_setup_tmp
  unset FOUND_ISSUES_MODE
  export FOUND_ISSUES_MODE=local
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [fixed] 2026-05-08 src/foo.py:42 — bug"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "format-enforcer: [fixed] verification check warns (exit 0) in git mode" {
  unset FOUND_ISSUES_MODE
  export FOUND_ISSUES_MODE=git
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [fixed] 2026-05-08 src/foo.py:42 — bug"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}
