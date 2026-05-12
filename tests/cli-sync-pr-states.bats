#!/usr/bin/env bats
# Tests for sync's PR-state classification and demotion behavior.
load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
  fi_use_gh_shim
}

teardown() {
  fi_teardown_tmp
}

@test "gh shim: returns mocked JSON for known PR" {
  export GH_MOCK_PR_VIEW=$'42\t{"state":"MERGED","baseRefName":"main","mergedAt":"2026-05-01T12:00:00Z","isDraft":false}'
  run gh pr view 42 --repo foo/bar --json state,baseRefName,mergedAt,isDraft
  [ "$status" -eq 0 ]
  [[ "$output" == *"MERGED"* ]]
  [[ "$output" == *"main"* ]]
}

@test "gh shim: exits 1 for unknown PR" {
  export GH_MOCK_PR_VIEW=$'42\t{"state":"MERGED"}'
  run gh pr view 99 --repo foo/bar --json state
  [ "$status" -eq 1 ]
}
