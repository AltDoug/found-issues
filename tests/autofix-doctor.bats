#!/usr/bin/env bats
# doctor: the auto-fix section (spec §8; phase 5 ruling 9).

load 'helpers'
load 'autofix-helpers'

setup() { fi_setup_tmp; fi_af_fixture; fi_use_standins; }
teardown() { fi_teardown_tmp; }

@test "doctor auto-fix: on, with test command source, caps and the auto-merge sentence" {
  git config found-issues.autofix.dailyFixes 2
  git config found-issues.autofix.sweepMax 3
  run "$FI_BIN" doctor
  [[ "$output" == *"== Auto-fix =="* ]]
  [[ "$output" == *"Auto-fix: on"* ]]
  [[ "$output" == *"Test command: sh test.sh (local)"* ]]
  [[ "$output" == *"2 spot fixes/day"* ]]
  [[ "$output" == *"3 fixes per PR"* ]]
  [[ "$output" == *"Fix PRs merge themselves"* ]]
  [[ "$output" == *"claude:"* ]]
}

@test "doctor auto-fix: unset caps read as no cap" {
  run "$FI_BIN" doctor
  [[ "$output" == *"no dollar cap per run"* ]]
  [[ "$output" == *"no dollar cap per sweep"* ]]
  git config found-issues.autofix.runBudget 3
  run "$FI_BIN" doctor
  [[ "$output" == *'$3 per run'* ]]
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

@test "doctor auto-fix: codex models per role and the token caps" {
  git config found-issues.autofix.codexVerifierModel inherit
  mkdir -p "$TMP/codexhome"; printf 'model = "gpt-6-astra"\n' > "$TMP/codexhome/config.toml"
  CODEX_HOME="$TMP/codexhome" run "$FI_BIN" doctor
  [[ "$output" == *"Codex models: fixer gpt-6.1-sol (medium), verifier inherit (~/.codex/config.toml: gpt-6-astra), classifier gpt-6.1-sol (low)"* ]]
  [[ "$output" == *"no token cap per run"* ]]
  git config found-issues.autofix.codexRunTokens 600000
  CODEX_HOME="$TMP/codexhome" run "$FI_BIN" doctor
  [[ "$output" == *"600000 Codex tokens per run"* ]]
}

@test "doctor auto-fix: warns when the last codex child failed on its model" {
  fi_af_queue_fixture
  export FI_STANDIN_CODEX_FAIL=workspace-write
  "$FI_BIN" autofix run "$ID" --engine codex >/dev/null || true
  run "$FI_BIN" doctor
  [[ "$output" == *"Last Codex run failed on its model"* ]]
  [[ "$output" == *"found-issues config autofix.codexModel"* ]]
}
