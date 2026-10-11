#!/usr/bin/env bats
# Batch 4 plumbing: lib-less hook warnings reach the model on Claude
# (hooks/pre-branch-delete.sh:284, hooks/format-enforcer.sh:261), the fix ship
# test gate has its own timeout and prints its report (lib/fix-plumbing.sh),
# and fix ship --pick accepts the ledger location as written and fails loudly
# on an unmatched pick.

load 'helpers'
load 'autofix-helpers'

ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  fi_setup_tmp
  export PATH="$TEST_REPO_ROOT/bin:$TEST_REPO_ROOT/tests/bin-shims:$PATH"
}
teardown() { fi_teardown_tmp; }

# A copy of the hooks with no sibling lib/, and no lib override anywhere.
libless_hooks() {
  mkdir -p "$TMP/iso/hooks"
  cp "$ROOT/hooks/pre-branch-delete.sh" "$ROOT/hooks/format-enforcer.sh" "$TMP/iso/hooks/"
  unset FOUND_ISSUES_LIB_DIR CLAUDE_PLUGIN_ROOT
}

# --- 1. lib-less hook warnings -------------------------------------------

@test "b4 pre-branch-delete: missing lib warns the model via additionalContext on claude" {
  libless_hooks
  fi_init_git
  input='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git branch -D feat/x"}}'
  run bash -c "echo '$input' | FOUND_ISSUES_HARNESS=claude bash '$TMP/iso/hooks/pre-branch-delete.sh' 2>'$TMP/err'"
  [ "$status" -eq 0 ]
  [ ! -s "$TMP/err" ]
  [ "$(printf '%s' "$output" | jq -s 'length')" = 1 ]
  printf '%s' "$output" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null
  printf '%s' "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("branch delete NOT checked")' >/dev/null
}

@test "b4 pre-branch-delete: missing lib keeps stderr on codex" {
  libless_hooks
  fi_init_git
  input='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git branch -D feat/x"}}'
  run bash -c "echo '$input' | FOUND_ISSUES_HARNESS=codex bash '$TMP/iso/hooks/pre-branch-delete.sh' 2>'$TMP/err'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q 'branch delete NOT checked' "$TMP/err"
}

@test "b4 format-enforcer: missing lib warns the model via additionalContext on claude" {
  libless_hooks
  fi_init_git
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [OPEN] 2026-05-08 src/foo.py:42 — bug"}}'
  run bash -c "echo '$input' | FOUND_ISSUES_HARNESS=claude bash '$TMP/iso/hooks/format-enforcer.sh' 2>'$TMP/err'"
  [ "$status" -eq 0 ]
  [ ! -s "$TMP/err" ]
  [ "$(printf '%s' "$output" | jq -s 'length')" = 1 ]
  printf '%s' "$output" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null
  printf '%s' "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("ledger format NOT enforced")' >/dev/null
}

@test "b4 format-enforcer: missing lib keeps stderr on codex" {
  libless_hooks
  fi_init_git
  input='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"docs/found-issues.md","content":"- [OPEN] 2026-05-08 src/foo.py:42 — bug"}}'
  run bash -c "echo '$input' | FOUND_ISSUES_HARNESS=codex bash '$TMP/iso/hooks/format-enforcer.sh' 2>'$TMP/err'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q 'ledger format NOT enforced' "$TMP/err"
}

# --- 2/3. fix ship ---------------------------------------------------------

ship_setup() {
  fi_af_fixture
  export PATH="$TEST_REPO_ROOT/bin:$TEST_REPO_ROOT/tests/bin-shims:$PATH"
  export GH_MOCK_TRACE="$TMP/gh.trace" GH_MOCK_PR_CREATE_URL=https://github.com/foo/bar/pull/11
  export GH_MOCK_PR_VIEW=$'11\t{"number":11,"state":"OPEN","files":[]}'
  out="$("$FI_BIN" fix workspace)"
  WT="$(printf '%s\n' "$out" | sed -n 's/^worktree=//p')"
  sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"
  git -C "$WT" commit -qam "fix: add subtracts (found-issues src/calc.sh:1)"
  printf 'b\n' > "$TMP/body"
}

@test "b4 fix ship: a suite longer than runTimeoutMin is not killed by the autofix watchdog" {
  ship_setup
  git config found-issues.autofix.testCommand 'sleep 3; sh test.sh'
  export FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS=1
  run "$FI_BIN" fix ship "$WT" --title "fix: add" --body-file "$TMP/body" --pick src/calc.sh:1
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #11"* ]]
}

@test "b4 fix ship: its own timeout kills a hung suite and says so" {
  ship_setup
  git config found-issues.autofix.testCommand 'sleep 30'
  export FOUND_ISSUES_FIX_SHIP_TIMEOUT_SECS=1
  run "$FI_BIN" fix ship "$WT" --title "fix: add" --body-file "$TMP/body" --pick src/calc.sh:1
  [ "$status" -eq 1 ]
  [[ "$output" == *"tests fail"* ]]
  [[ "$output" == *"timed out after 1s"* ]]
  ! grep -q '^pr create' "$GH_MOCK_TRACE" 2>/dev/null || false
}

@test "b4 fix ship: a red suite prints the failing-tests report" {
  ship_setup
  git config found-issues.autofix.testCommand 'echo "not ok 1 widget renders"; echo "# expected 5 got 4"; exit 1'
  run "$FI_BIN" fix ship "$WT" --title "fix: add" --body-file "$TMP/body" --pick src/calc.sh:1
  [ "$status" -eq 1 ]
  [[ "$output" == *"tests fail"* ]]
  [[ "$output" == *"not ok 1 widget renders"* ]]
  [[ "$output" == *"expected 5 got 4"* ]]
}

@test "b4 fix ship: --pick accepts the location exactly as written in the ledger" {
  ship_setup
  ( cd "$REPO" && printf -- '- [open] 2026-10-02 src/calc.sh (annotate-pr --pick) — add misreads picks\n' >> docs/found-issues.md )
  run "$FI_BIN" fix ship "$WT" --title "fix: add" --body-file "$TMP/body" --pick "src/calc.sh (annotate-pr --pick)"
  [ "$status" -eq 0 ]
  grep -F 'add misreads picks' "$REPO/docs/found-issues.md" | grep -q '(PR: foo/bar#11)'
  ! grep -F 'add subtracts' "$REPO/docs/found-issues.md" | grep -q '(PR: foo/bar#11)' || false
}

@test "b4 fix ship: an unmatched pick fails loudly and names it, even when another pick matched" {
  ship_setup
  run "$FI_BIN" fix ship "$WT" --title "fix: add" --body-file "$TMP/body" --pick "src/calc.sh:1,src/nope.sh:9"
  [ "$status" -ne 0 ]
  [[ "$output" == *"src/nope.sh:9"* ]]
  [[ "$output" == *"annotate"* ]]
  # the matched one was still annotated
  grep -q '(PR: foo/bar#11)' "$REPO/docs/found-issues.md"
}

@test "b4 fix ship: a lone unmatched pick exits non-zero naming the pick" {
  ship_setup
  run "$FI_BIN" fix ship "$WT" --title "fix: add" --body-file "$TMP/body" --pick "src/nope.sh:9"
  [ "$status" -ne 0 ]
  [[ "$output" == *"src/nope.sh:9"* ]]
}

# --- 3. annotate-pr exact matching is not weakened --------------------------

@test "b4 annotate-pr: a pick that is only a prefix of the location text still does not match" {
  fi_af_fixture
  printf -- '- [open] 2026-10-02 src/calc.sh (annotate-pr --pick) — add misreads picks\n' >> docs/found-issues.md
  export GH_MOCK_PR_VIEW=$'11\t{"number":11,"state":"OPEN","files":[]}'
  run "$FI_BIN" annotate-pr 11 --pick "src/calc.sh (annotate-pr"
  [ "$status" -ne 0 ]
  ! grep -q '(PR: foo/bar#11)' docs/found-issues.md || false
}

@test "b4 annotate-pr: an unmatched pick alongside a match is non-zero only under strict mode" {
  fi_af_fixture
  export GH_MOCK_PR_VIEW=$'11\t{"number":11,"state":"OPEN","files":[]}'
  run "$FI_BIN" annotate-pr 11 --pick "src/calc.sh:1,src/nope.sh:9"
  [ "$status" -eq 0 ]
  git checkout -q docs/found-issues.md
  FOUND_ISSUES_PICK_STRICT=1 run "$FI_BIN" annotate-pr 11 --pick "src/calc.sh:1,src/nope.sh:9"
  [ "$status" -ne 0 ]
  [[ "$output" == *"src/nope.sh:9"* ]]
  grep -q '(PR: foo/bar#11)' docs/found-issues.md
}
