#!/usr/bin/env bats
# Tests for lib/detect-mode.sh
#
# Limited scope: tests modes that don't require live `gh` auth.
# `github-pr` / `github-direct` distinction is exercised manually
# during smoke testing since it requires real GitHub state.

load 'helpers'

setup() {
  fi_source_lib detect-mode
  fi_setup_tmp
}

teardown() {
  fi_teardown_tmp
  unset FOUND_ISSUES_MODE
}

@test "detect_mode: env var override wins" {
  export FOUND_ISSUES_MODE=local
  result="$(fi_detect_mode)"
  [ "$result" = "local" ]

  export FOUND_ISSUES_MODE=github-pr
  result="$(fi_detect_mode)"
  [ "$result" = "github-pr" ]
}

@test "detect_mode: returns 'local' when not in a git repo" {
  result="$(fi_detect_mode)"
  [ "$result" = "local" ]
}

@test "detect_mode: returns 'git' when in git repo with no remote" {
  fi_init_git
  result="$(fi_detect_mode)"
  [ "$result" = "git" ]
}

@test "detect_mode: returns 'git' when remote is non-GitHub" {
  fi_init_git
  git remote add origin https://gitlab.com/foo/bar.git
  result="$(fi_detect_mode)"
  [ "$result" = "git" ]
}

@test "invalidate_mode_cache: removes cached mode" {
  # Without GitHub remote, no cache is written. Just ensure the function exits cleanly.
  fi_init_git
  run fi_invalidate_mode_cache
  [ "$status" -eq 0 ]
}
