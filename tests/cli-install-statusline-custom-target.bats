#!/usr/bin/env bats
# Tests for `found-issues install-statusline --target <path>`
# (custom-statusline auto-integration; canonical-path tests live in cli-statusline.bats)

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

@test "install-statusline --target: errors when path does not exist" {
  fi_run install-statusline --target /nonexistent/path.sh --dry-run
  [ "$status" -eq 12 ]  # target_not_found
  [[ "$output" == *"not found"* || "$output" == *"does not exist"* ]]
}
