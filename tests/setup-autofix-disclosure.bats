#!/usr/bin/env bats
# The setup disclosure says plainly what auto-fix does before it is enabled
# (spec §8), and its caps match the code's defaults.

load 'helpers'

S="$TEST_REPO_ROOT/commands/setup.md"

@test "setup disclosure: states auto-merge, billing, caps and the off switch" {
  grep -q 'Fix PRs merge themselves' "$S"
  grep -q 'bill your' "$S"
  grep -q 'including in the background' "$S"
  grep -q 'found-issues autofix off' "$S"
  grep -q 'FOUND_ISSUES_AUTOFIX=off' "$S"
  grep -q 'Not now (Recommended)' "$S"
}

@test "setup disclosure: the caps it states are the code defaults" {
  grep -q '5 spot fixes and 1 sweep a day' "$S"
  grep -q 'up to 8 entries' "$S"
  grep -q '\$3 per fix run, \$10 per sweep, 20 minutes per run' "$S"
  grep -rqF 'fi_af_int dailyFixes 5' "$TEST_REPO_ROOT/lib"
  grep -rqF 'fi_af_int dailySweeps 1' "$TEST_REPO_ROOT/lib"
  grep -rqF 'fi_af_int sweepMax 8' "$TEST_REPO_ROOT/lib"
  grep -rqF 'key=runBudget def=3' "$TEST_REPO_ROOT/lib"
  grep -rqF 'key=sweepBudget def=10' "$TEST_REPO_ROOT/lib"
  grep -rqF 'runTimeoutMin 20' "$TEST_REPO_ROOT/lib"
}
