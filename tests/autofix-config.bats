#!/usr/bin/env bats
# v3 auto-fix settings, kill switch, test command and engine (spec §5.3, §8, §9).

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
  export FOUND_ISSUES_STATE_DIR="$TMP/state"
  export HOME="$TMP/home"; mkdir -p "$HOME"
  unset FOUND_ISSUES_AUTOFIX CLAUDECODE
}
teardown() { fi_teardown_tmp; }

src() {
  source "$FI_BIN"
}

@test "autofix config: disabled until found-issues.autofix is true" {
  git remote add origin https://github.com/foo/bar.git
  src
  run fi_af_enabled
  [ "$status" -eq 1 ]
  git config found-issues.autofix true
  run fi_af_enabled
  [ "$status" -eq 0 ]
}

@test "autofix config: a local false overrides a global true" {
  git remote add origin https://github.com/foo/bar.git
  git config --global found-issues.autofix true
  git config found-issues.autofix false
  src
  run fi_af_enabled
  [ "$status" -eq 1 ]
}

@test "autofix config: FOUND_ISSUES_AUTOFIX=off and the kill switch both win over true" {
  git remote add origin https://github.com/foo/bar.git
  git config found-issues.autofix true
  src
  FOUND_ISSUES_AUTOFIX=off run fi_af_enabled
  [ "$status" -eq 1 ]
  run "$FI_BIN" autofix off
  [ "$status" -eq 0 ]
  [ -e "$TMP/state/autofix/disabled" ]
  run fi_af_enabled
  [ "$status" -eq 1 ]
  run "$FI_BIN" autofix on
  [ ! -e "$TMP/state/autofix/disabled" ]
  run fi_af_enabled
  [ "$status" -eq 0 ]
}

@test "autofix config: no GitHub origin means disabled" {
  git config found-issues.autofix true
  src
  run fi_af_enabled
  [ "$status" -eq 1 ]
}

@test "autofix config: fi_repo_id survives an insteadOf rewrite to a local path" {
  git remote add origin https://github.com/foo/bar.git
  git config url."$TMP/bare.git".insteadOf https://github.com/foo/bar.git
  src
  run fi_repo_id
  [ "$status" -eq 0 ]
  [ "$output" = "foo/bar" ]
}

@test "autofix config: fi_repo_id fails on a GitHub URL with no org/repo" {
  git remote add origin https://github.com/onlyorg
  src
  run fi_repo_id
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "autofix config: integer settings fall back on garbage" {
  src
  [ "$(fi_af_int dailyFixes 5)" = 5 ]
  git config found-issues.autofix.dailyFixes 3
  [ "$(fi_af_int dailyFixes 5)" = 3 ]
  git config found-issues.autofix.dailyFixes lots
  run fi_af_int dailyFixes 5
  [ "${lines[${#lines[@]}-1]}" = 5 ]
  # default 3: a measured live claude fix (2 attempts) cost $1.58 (2026-10-03)
  [ "$(fi_af_budget)" = 3 ]
  git config found-issues.autofix.runBudget 1.5
  [ "$(fi_af_budget)" = 1.5 ]
  git config found-issues.autofix.runBudget '$2'
  run fi_af_budget
  [ "${lines[${#lines[@]}-1]}" = 3 ]
}

@test "autofix config: dirs are per repo under the state and cache roots" {
  src
  fi_af_dirs foo/bar
  [ "$FI_AF_ST" = "$TMP/state/autofix/foo__bar" ]
  [ -d "$FI_AF_ST/queue" ] && [ -d "$FI_AF_ST/running" ] && [ -d "$FI_AF_ST/done" ] && [ -d "$FI_AF_ST/day" ]
  [[ "$FI_AF_RUNS" == */autofix/foo__bar/runs ]]
  [ -d "$FI_AF_RUNS" ]
}

@test "autofix config: test command - explicit setting wins" {
  mkdir -p tests && touch tests/a.bats
  git config found-issues.autofix.testCommand 'make check'
  src
  [ "$(fi_af_test_command "$TMP")" = "make check" ]
}

@test "autofix config: test command detection order bats npm pytest go cargo make" {
  src
  run fi_af_test_command "$TMP"
  [ "$status" -eq 1 ]
  printf 'test:\n\techo ok\n' > Makefile
  [ "$(fi_af_test_command "$TMP")" = "make test" ]
  touch Cargo.toml
  [ "$(fi_af_test_command "$TMP")" = "cargo test" ]
  touch go.mod
  [ "$(fi_af_test_command "$TMP")" = "go test ./..." ]
  touch pytest.ini
  [ "$(fi_af_test_command "$TMP")" = "pytest" ]
  printf '{\n  "scripts": {\n    "test": "vitest run"\n  }\n}\n' > package.json
  [ "$(fi_af_test_command "$TMP")" = "npm test" ]
  mkdir -p tests && touch tests/x.bats
  [ "$(fi_af_test_command "$TMP")" = "bats tests/" ]
}

@test "autofix config: npm's placeholder test script is not a test command" {
  printf '{ "scripts": { "test": "echo \\"Error: no test specified\\" && exit 1" } }\n' > package.json
  src
  run fi_af_test_command "$TMP"
  [ "$status" -eq 1 ]
}

@test "autofix config: a Makefile without a test target is not a test command" {
  printf 'build:\n\techo hi\n' > Makefile
  src
  run fi_af_test_command "$TMP"
  [ "$status" -eq 1 ]
}

@test "autofix config: engine - explicit, setting, then the calling harness" {
  src
  [ "$(fi_af_engine codex)" = codex ]
  git config found-issues.autofix.engine claude
  [ "$(fi_af_engine)" = claude ]
  git config found-issues.autofix.engine auto
  CLAUDECODE=1 run fi_af_engine
  [ "$output" = claude ]
  CODEX_THREAD_ID=x PATH="/usr/bin:/bin" run fi_af_engine
  [ "$output" = codex ]
}
