#!/usr/bin/env bats
# 3.4.0 lean SessionStart: core rules, budgets, resume skip, full mode.

load 'helpers'

core_body() { LC_ALL=C awk 'c >= 2 { print } /^---$/ { c++ }' "$TEST_REPO_ROOT/skills/rules/SKILL.md"; }

setup() { fi_setup_tmp; }
teardown() { fi_teardown_tmp; }

@test "lean rules: core body is at most 1150 bytes" {
  [ "$(core_body | wc -c | tr -d ' ')" -le 1150 ]
}

@test "lean rules: core keeps the mandate, the three tags, pick, stop marker and four hard rules" {
  b="$(core_body)"
  [[ "$b" == *"Issues found and not tracked are issues lost"* ]]
  [[ "$b" == *"--fix small|medium|large"* ]]
  [[ "$b" == *"--decide"* ]]
  [[ "$b" == *"--manual"* ]]
  [[ "$b" == *"--pick"* ]]
  [[ "$b" == *"found-issues-checked"* ]]
  [[ "$b" == *"never write the ledger directly"* ]]
  [[ "$b" == *"never delete"* ]]
  [[ "$b" == *"never mark"* ]]
  [[ "$b" == *"pre-branch-delete"* ]]
  [[ "$b" == *"dead code:"* ]]
}

@test "lean rules: the full text is preserved in lib/rules-full.md" {
  f="$TEST_REPO_ROOT/lib/rules-full.md"
  [ -f "$f" ]
  grep -q '^## Sync' "$f"
  grep -q '^## Dead code' "$f"
  grep -q '^## Format' "$f"
}

@test "lean rules: the dead-code procedure lives in the log command" {
  grep -q 'actually-live component' "$TEST_REPO_ROOT/commands/log.md"
}
