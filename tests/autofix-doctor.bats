#!/usr/bin/env bats
# doctor: the auto-fix section (spec §8; phase 5 ruling 9).

load 'helpers'
load 'autofix-helpers'

setup() { fi_setup_tmp; fi_af_fixture; fi_use_standins; }
teardown() { fi_teardown_tmp; }

@test "doctor auto-fix: on, with test command source, caps and the auto-merge sentence" {
  git config found-issues.autofix.dailyFixes 2
  run "$FI_BIN" doctor
  [[ "$output" == *"== Auto-fix =="* ]]
  [[ "$output" == *"Auto-fix: on"* ]]
  [[ "$output" == *"Test command: sh test.sh (local)"* ]]
  [[ "$output" == *"2 spot fixes/day"* ]]
  [[ "$output" == *"Fix PRs merge themselves"* ]]
  [[ "$output" == *"claude:"* ]]
}

@test "doctor auto-fix: off says how to turn it on" {
  git config found-issues.autofix false
  run "$FI_BIN" doctor
  [[ "$output" == *"Auto-fix: off"* ]]
  [[ "$output" == *"found-issues config autofix true"* ]]
}

@test "doctor auto-fix: a missing test command is a failure line" {
  git config --unset found-issues.autofix.testCommand
  run "$FI_BIN" doctor
  [[ "$output" == *"No test command"* ]]
}

@test "doctor auto-fix: a missing engine CLI is reported" {
  export PATH="$TEST_REPO_ROOT/tests/bin-shims:/usr/bin:/bin"
  run "$FI_BIN" doctor
  [[ "$output" == *"claude not on PATH"* ]]
  [[ "$output" == *"codex not on PATH"* ]]
}
