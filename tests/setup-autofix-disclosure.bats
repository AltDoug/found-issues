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
  grep -q '8 fixes per PR' "$S"
  grep -q 'no dollar cap unless you set one' "$S"
  grep -q '20 minutes per run' "$S"
  grep -rqF 'fi_af_int dailyFixes 5' "$TEST_REPO_ROOT/lib"
  grep -rqF 'fi_af_int dailySweeps 1' "$TEST_REPO_ROOT/lib"
  grep -qx 'autofix.sweepBatch|int|8' "$TEST_REPO_ROOT/lib/autofix-config.sh"
  grep -qx 'autofix.runBudget|usd|' "$TEST_REPO_ROOT/lib/autofix-config.sh"
  grep -qx 'autofix.sweepBudget|usd|' "$TEST_REPO_ROOT/lib/autofix-config.sh"
  grep -rqF 'runTimeoutMin 20' "$TEST_REPO_ROOT/lib"
}

# 3.2.1: after turning auto-fix on, setup asks when a sweep starts and writes
# autofix.sweepThreshold at the scope auto-fix was turned on in.
@test "setup sweep trigger: offers 5 (the code default), 10, 20 and a custom number" {
  grep -qF '`5 (Recommended)`' "$S"
  grep -qF '`10`' "$S"
  grep -qF '`20`' "$S"
  grep -qF 'found-issues config autofix.sweepThreshold <n>' "$S"
  grep -qF 'found-issues config autofix.sweepThreshold <n> --global' "$S"
  grep -rqF 'fi_af_int sweepThreshold 5' "$TEST_REPO_ROOT/lib"
  c="$TEST_REPO_ROOT/codex-skills/fi-setup/SKILL.md"
  grep -qF '`5 (Recommended)`' "$c"
  grep -qF 'found-issues config autofix.sweepThreshold <n>' "$c"
}
