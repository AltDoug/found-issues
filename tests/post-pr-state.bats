#!/usr/bin/env bats
# Tests for hooks/post-pr-state.sh — PostToolUse hook that fires a background
# sync after gh pr merge/close/reopen so the statusline reflects the new
# annotation state without waiting for SessionStart.

load 'helpers'

HOOK="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/hooks/post-pr-state.sh"

setup() {
  fi_setup_tmp
  # Marker file written by the test-mode FOUND_ISSUES_AUTOSYNC_CMD.
  # If this file exists after the hook runs, sync dispatch fired.
  MARKER="$TMP/sync-marker"
  export FOUND_ISSUES_AUTOSYNC_CMD="touch '$MARKER'"
}

teardown() {
  unset FOUND_ISSUES_AUTOSYNC_CMD
  unset FOUND_ISSUES_POST_PR_STATE
  fi_teardown_tmp
}

# Helper: invoke the hook with a synthetic PostToolUse payload, wait briefly
# for the detached background spawn to land its marker, return exit code.
_run_hook() {
  local cmd="$1"
  local input
  input="$(printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":%s}}' \
           "$(printf '%s' "$cmd" | jq -Rs .)")"
  echo "$input" | "$HOOK"
  local code=$?
  # Give the detached subshell a moment to fire `touch`.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -e "$MARKER" ]] && break
    sleep 0.05
  done
  return $code
}

@test "post-pr-state: fires sync on 'gh pr merge'" {
  run _run_hook "gh pr merge 42 --squash"
  [ "$status" -eq 0 ]
  [ -e "$MARKER" ]
}

@test "post-pr-state: fires sync on 'gh pr close'" {
  run _run_hook "gh pr close 7"
  [ "$status" -eq 0 ]
  [ -e "$MARKER" ]
}

@test "post-pr-state: fires sync on 'gh pr reopen'" {
  run _run_hook "gh pr reopen 7"
  [ "$status" -eq 0 ]
  [ -e "$MARKER" ]
}

@test "post-pr-state: fires sync when 'gh pr merge' appears after '&&'" {
  run _run_hook "git push && gh pr merge --auto"
  [ "$status" -eq 0 ]
  [ -e "$MARKER" ]
}

@test "post-pr-state: does NOT fire on 'gh pr create'" {
  # gh pr create is post-pr-create.sh's territory; this hook should ignore it
  # so we don't double-spawn sync.
  run _run_hook "gh pr create --title foo"
  [ "$status" -eq 0 ]
  [ ! -e "$MARKER" ]
}

@test "post-pr-state: does NOT fire on unrelated Bash" {
  run _run_hook "ls -la"
  [ "$status" -eq 0 ]
  [ ! -e "$MARKER" ]
}

@test "post-pr-state: does NOT fire on 'git push'" {
  # Push alone doesn't change merge state — skip.
  run _run_hook "git push origin main"
  [ "$status" -eq 0 ]
  [ ! -e "$MARKER" ]
}

@test "post-pr-state: substring match avoids false positives ('mergeable' in another arg)" {
  run _run_hook "echo 'mergeable status'"
  [ "$status" -eq 0 ]
  [ ! -e "$MARKER" ]
}

@test "post-pr-state: respects FOUND_ISSUES_POST_PR_STATE=off" {
  export FOUND_ISSUES_POST_PR_STATE=off
  run _run_hook "gh pr merge 42"
  [ "$status" -eq 0 ]
  [ ! -e "$MARKER" ]
}

@test "post-pr-state: ignores non-Bash tool events" {
  local input='{"hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"foo"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
  [ ! -e "$MARKER" ]
}
