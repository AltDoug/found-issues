#!/usr/bin/env bats
# found-issues config: the auto-fix settings wrapper (spec §8; phase 5 ruling 7).

load 'helpers'
load 'autofix-helpers'

setup() { fi_setup_tmp; fi_af_fixture; git config --unset found-issues.autofix; }
teardown() { fi_teardown_tmp; }

@test "config: lists every setting with its source" {
  run "$FI_BIN" config
  [ "$status" -eq 0 ]
  for k in autofix autofix.engine autofix.testCommand autofix.dailyFixes autofix.dailySweeps \
           autofix.sweepThreshold autofix.sweepBatch autofix.runBudget autofix.sweepBudget autofix.runTimeoutMin; do
    [[ "$output" == *"found-issues.$k "* ]] || false
  done
  [[ "$output" == *"found-issues.autofix.dailyFixes"*"5"*"(default)"* ]]
  [[ "$output" == *"found-issues.autofix.testCommand"*"sh test.sh"*"(local)"* ]]
  [[ "$output" == *"found-issues.autofix.runBudget"*"(default)"* ]]
  [[ "$output" == *"found-issues.autofix.sweepBudget"*"(default)"* ]]
}

@test "config: set writes this repo, get reads it back" {
  run "$FI_BIN" config autofix.dailyFixes 2
  [ "$status" -eq 0 ]
  [ "$(git config --local --get found-issues.autofix.dailyFixes)" = 2 ]
  run "$FI_BIN" config autofix.dailyFixes
  [ "$output" = 2 ]
}

@test "config: --global warns when this repo has a local value that overrides it" {
  run "$FI_BIN" config autofix.testCommand "make test" --global
  [ "$status" -eq 0 ]
  [ "$(git config --global --get found-issues.autofix.testCommand)" = "make test" ]
  [[ "$output" == *"Note:"* ]]
  [[ "$output" == *"sh test.sh"* ]]
  run "$FI_BIN" config autofix.dailyFixes 2 --global
  [ "$status" -eq 0 ]
  [[ "$output" != *"Note:"* ]]
}

@test "config: --global writes the global file and local overrides it" {
  "$FI_BIN" config autofix.sweepBatch 4 --global
  [ "$(git config --global --get found-issues.autofix.sweepBatch)" = 4 ]
  run "$FI_BIN" config
  [[ "$output" == *"found-issues.autofix.sweepBatch"*"4"*"(global)"* ]]
  "$FI_BIN" config autofix.sweepBatch 6
  run "$FI_BIN" config autofix.sweepBatch
  [ "$output" = 6 ]
}

@test "config: invalid keys and values are refused" {
  run "$FI_BIN" config autofix.bogus 1
  [ "$status" -eq 2 ]
  run "$FI_BIN" config autofix.dailyFixes 0
  [ "$status" -eq 2 ]
  run "$FI_BIN" config autofix.engine gpt
  [ "$status" -eq 2 ]
  run "$FI_BIN" config autofix maybe
  [ "$status" -eq 2 ]
  run "$FI_BIN" config autofix.runBudget 3x
  [ "$status" -eq 2 ]
  [ -z "$(git config --get found-issues.autofix.runBudget)" ]
}

@test "config: --unset removes the value" {
  "$FI_BIN" config autofix.dailyFixes 2
  run "$FI_BIN" config autofix.dailyFixes --unset
  [ "$status" -eq 0 ]
  [ -z "$(git config --local --get found-issues.autofix.dailyFixes)" ]
}

@test "config: turning auto-fix on says fix PRs merge themselves" {
  run "$FI_BIN" config autofix true
  [ "$status" -eq 0 ]
  [[ "$output" == *"Fix PRs merge themselves"* ]]
  [[ "$output" == *"found-issues autofix off"* ]]
  [ "$(git config --local --get found-issues.autofix)" = true ]
}

@test "config: setting a repo value outside a git repo asks for --global" {
  cd "$TMP"; mkdir plain && cd plain
  run "$FI_BIN" config autofix.dailyFixes 2
  [ "$status" -eq 1 ]
  [[ "$output" == *"--global"* ]]
}
