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
  # 3.3.0: no default dollar cap; a set value is read, a bad one means no cap
  [ -z "$(fi_af_budget)" ]
  git config found-issues.autofix.runBudget 1.5
  [ "$(fi_af_budget)" = 1.5 ]
  git config found-issues.autofix.runBudget '$2'
  run fi_af_budget
  [[ "$output" == *"is not a USD amount"* ]]
  [ -z "$(fi_af_budget 2>/dev/null)" ]
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

@test "autofix config: test command - make test only when no other suite is found" {
  src
  run fi_af_test_command "$TMP"
  [ "$status" -eq 1 ]
  printf 'test:\n\techo ok\n' > Makefile
  [ "$(fi_af_test_command "$TMP")" = "make test" ]
  touch Cargo.toml
  [ "$(fi_af_test_command "$TMP")" = "cargo test" ]
}

# 3.6.0: auto-fix stopped at the first suite it found, so kh2-midgar's fixes
# ran only bats tests/ and never its 73 pytest files.
@test "autofix config: test command - every suite found runs, in a fixed order" {
  src
  touch go.mod Cargo.toml pytest.ini
  printf '{\n  "scripts": {\n    "test": "vitest run"\n  }\n}\n' > package.json
  mkdir -p tests && touch tests/x.bats
  [ "$(fi_af_test_command "$TMP")" = "bats tests/ && npm install && npm test && pytest && go test ./... && cargo test" ]
}

@test "autofix config: test command - pytest runs through uv in a uv project" {
  touch conftest.py uv.lock
  src
  [ "$(fi_af_test_command "$TMP")" = "uv run pytest -q" ]
}

@test "autofix config: test command - a pyproject with tests/test_*.py is a pytest suite" {
  printf '[project]\nname = "x"\n' > pyproject.toml
  src
  run fi_af_test_command "$TMP"
  [ "$status" -eq 1 ]
  mkdir -p tests && touch tests/test_runner.py tests/a.bats uv.lock
  [ "$(fi_af_test_command "$TMP")" = "bats tests/ && uv run pytest -q" ]
}

# 3.6.0: a fresh fix worktree has no node_modules, so a bare npm test failed
# at base in every Node repo.
@test "autofix config: test command - a Node suite installs with its lockfile's tool first" {
  printf '{ "scripts": { "test": "vitest run" } }\n' > package.json
  src
  touch package-lock.json
  [ "$(fi_af_test_command "$TMP")" = "npm ci && npm test" ]
  touch yarn.lock
  [ "$(fi_af_test_command "$TMP")" = "yarn install --frozen-lockfile && yarn test" ]
  touch bun.lockb
  [ "$(fi_af_test_command "$TMP")" = "bun install --frozen-lockfile && bun run test" ]
  touch pnpm-lock.yaml
  [ "$(fi_af_test_command "$TMP")" = "pnpm install --frozen-lockfile && pnpm test" ]
}

# 3.6.0: bruhsailer-helper (Gradle) had no test command, and 36 of its
# auto-fix items ended stale.
@test "autofix config: test command - Gradle and Maven, wrapper first" {
  src
  touch build.gradle
  [ "$(fi_af_test_command "$TMP")" = "gradle test -q" ]
  touch gradlew
  [ "$(fi_af_test_command "$TMP")" = "./gradlew test --no-daemon -q" ]
  rm build.gradle gradlew
  touch pom.xml
  [ "$(fi_af_test_command "$TMP")" = "mvn -q test" ]
  touch mvnw
  [ "$(fi_af_test_command "$TMP")" = "./mvnw -q test" ]
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

@test "config validates model names" {
  run "$FI_BIN" config autofix.codexModel 'gpt 6'
  [ "$status" -eq 2 ]
  [[ "$output" == *"takes a Codex model name"* ]]
  run "$FI_BIN" config autofix.codexModel inherit
  [ "$status" -eq 0 ]
  run "$FI_BIN" config autofix.codexVerifierModel gpt-6-astra
  [ "$status" -eq 0 ]
  run "$FI_BIN" config
  echo "$output" | grep -Eq '^found-issues\.autofix\.codexModel +inherit +\(local\)$'
}

@test "config: a model value is refused when it starts with a dash and inherit is normalized to lower case" {
  src
  FI_CFG_KIND=model FI_CFG_KEY=autofix.codexModel FI_CFG_VAL=-x run _fi_cfg_valid
  [ "$status" -eq 1 ]
  [[ "$output" == *"takes a Codex model name"* ]]
  run "$FI_BIN" config autofix.codexModel Inherit
  [ "$status" -eq 0 ]
  [ "$(git config found-issues.autofix.codexModel)" = inherit ]
}

@test "config: the legacy sweepMax can be unset, here and globally, but not set" {
  git config found-issues.autofix.sweepMax 3
  git config --global found-issues.autofix.sweepMax 4
  run "$FI_BIN" config autofix.sweepMax 5
  [ "$status" -eq 2 ]
  [[ "$output" == *"autofix.sweepBatch"* ]]
  [ "$(git config found-issues.autofix.sweepMax)" = 3 ]
  run "$FI_BIN" config autofix.sweepMax --unset
  [ "$status" -eq 0 ]
  [[ "$output" == *"Unset found-issues.autofix.sweepMax (local)"* ]]
  [ "$(git config --local --get found-issues.autofix.sweepMax || true)" = "" ]
  [ "$(git config --global found-issues.autofix.sweepMax)" = 4 ]
  run "$FI_BIN" config autofix.sweepMax --unset --global
  [ "$status" -eq 0 ]
  [ -z "$(git config --get found-issues.autofix.sweepMax || true)" ]
}

@test "config: the listing shows the batch size a legacy sweepMax sets" {
  run "$FI_BIN" config
  echo "$output" | grep -Eq '^found-issues\.autofix\.sweepBatch +8 +\(default\)$'
  git config found-issues.autofix.sweepMax 3
  run "$FI_BIN" config
  echo "$output" | grep -Eq '^found-issues\.autofix\.sweepBatch +3 \(from legacy sweepMax\) +\(local\)$'
  git config found-issues.autofix.sweepBatch 5
  run "$FI_BIN" config
  echo "$output" | grep -Eq '^found-issues\.autofix\.sweepBatch +5 +\(local\)$'
  ! echo "$output" | grep -q 'legacy' || false
}

@test "config: token cap keys are unset by default, validate and fall back to no cap" {
  src
  [ -z "$(fi_af_token_cap)" ]
  run "$FI_BIN" config autofix.codexRunTokens 0
  [ "$status" -eq 2 ]
  git config found-issues.autofix.codexSweepTokens lots
  run fi_af_cap_int codexSweepTokens
  [[ "$output" == *"not a positive integer"* ]]
  [ "${lines[${#lines[@]}-1]}" != lots ]
  AFI_kind=sweep
  [ -z "$(fi_af_token_cap 2>/dev/null)" ]
  git config --unset found-issues.autofix.codexSweepTokens
  run "$FI_BIN" config
  echo "$output" | grep -Eq '^found-issues\.autofix\.codexRunTokens +\(default\)$'
  echo "$output" | grep -Eq '^found-issues\.autofix\.codexSweepTokens +\(default\)$'
}
