#!/usr/bin/env bats
# Tests never touch the real home directory (ledger tests/helpers.bash:25).
# A suite run on 2026-10-29 rewrote the operator's ~/.cache/found-issues/
# mode_foo_bar: tests that kept the real HOME wrote the CLI's caches there,
# and under bats --jobs those files were shared between tests running side
# by side.

load 'helpers'

# The account's home from the password database, whatever $HOME says.
real_home() { eval printf '%s' "~$(id -un)"; }

setup() {
  fi_setup_tmp
  fi_init_git
  LEAK_SLUG="fileakcheck/t$$"
  LEAK_FILE="$(real_home)/.cache/found-issues/mode_fileakcheck_t$$"
}

teardown() {
  # Only this test's own uniquely named file, if a leak put it there.
  rm -f "$LEAK_FILE"
  fi_teardown_tmp
}

@test "isolation: HOME is a per-test directory, not the real home" {
  [ "$HOME" != "$(real_home)" ]
  [[ "$HOME" == "$BATS_TEST_TMPDIR"/* ]]
}

@test "isolation: a CLI cache write lands in the test HOME, not the real one" {
  fi_source_lib detect-mode
  fi_use_gh_shim
  git remote add origin "https://github.com/$LEAK_SLUG.git"
  export GH_MOCK_PR_LIST='[]'
  unset FOUND_ISSUES_MODE
  fi_detect_mode >/dev/null
  [ -f "$HOME/.cache/found-issues/mode_fileakcheck_t$$" ]
  [ ! -e "$LEAK_FILE" ]
}

@test "isolation: git commits still work in the per-test HOME" {
  git config --unset user.name
  git config --unset user.email
  git commit --allow-empty -q -m "no local identity"
  [ "$(git log -1 --format=%ae)" = "test@example.com" ]
}
