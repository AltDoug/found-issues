#!/usr/bin/env bats
# Tests for hooks/pre-branch-delete.sh

load 'helpers'

HOOK="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/hooks/pre-branch-delete.sh"

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
  unset FOUND_ISSUES_PROMOTE_GUARD
}

@test "pre-branch-delete: passes through non-delete commands" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "pre-branch-delete: passes when target branch has no [open] entries" {
  fi_run log "src/foo.py:1 — main entry"
  git add -A; git commit -q -m "init"
  git checkout -q -b feat/clean
  git add -A; git commit -q --allow-empty -m "branch (no entries)"
  git checkout -q main

  input='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git branch -d feat/clean"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "pre-branch-delete: blocks when branch has unpromoted [open] entries" {
  fi_run log "src/foo.py:1 — main entry"
  git add -A; git commit -q -m "init"
  git checkout -q -b feat/test
  fi_run log "src/branch_only.py:1 — branch-only"
  git add -A; git commit -q -m "branch entry"
  git checkout -q main

  input='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git branch -d feat/test"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unpromoted"* ]] || [[ "$output" == *"not yet promoted"* ]]
}

@test "pre-branch-delete: catches 'git branch -D' (force delete)" {
  fi_run log "src/foo.py:1 — main"
  git add -A; git commit -q -m "init"
  git checkout -q -b feat/test
  fi_run log "src/x.py:1 — branch-only"
  git add -A; git commit -q -m "x"
  git checkout -q main

  input='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git branch -D feat/test"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 2 ]
}

@test "pre-branch-delete: catches 'git push origin --delete <branch>'" {
  fi_run log "src/foo.py:1 — main"
  git add -A; git commit -q -m "init"
  git checkout -q -b feat/test
  fi_run log "src/x.py:1 — branch-only"
  git add -A; git commit -q -m "x"

  input='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git push origin --delete feat/test"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 2 ]
}

@test "pre-branch-delete: respects FOUND_ISSUES_PROMOTE_GUARD=off" {
  export FOUND_ISSUES_PROMOTE_GUARD=off
  fi_run log "src/foo.py:1 — main"
  git add -A; git commit -q -m "init"
  git checkout -q -b feat/test
  fi_run log "src/x.py:1 — branch"
  git add -A; git commit -q -m "x"

  input='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git branch -d feat/test"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "pre-branch-delete: ignores attempts to delete the default branch" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git branch -d main"}}'
  run bash -c "echo '$input' | '$HOOK'"
  # Skip on default branch (we don't enforce promote-before-delete-of-main)
  [ "$status" -eq 0 ]
}
