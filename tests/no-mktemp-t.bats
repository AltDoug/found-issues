#!/usr/bin/env bats
# Regression guard for issue #174: `mktemp -t <template>` fails on macOS under a
# sandboxed shell (the per-user temp dir is not writable there). Every temp file
# is created with an explicit "${TMPDIR:-/tmp}/<name>.XXXXXX" template or beside
# the file it will replace. Uses grep on purpose: CI has no ripgrep.

load 'helpers'

@test "no mktemp -t in lib hooks or bin (issue 174)" {
  cd "$TEST_REPO_ROOT"
  # Code lines only: comments that explain why -t was dropped are fine.
  run bash -c "grep -rnE 'mktemp[[:space:]]+-[A-Za-z]*t' lib hooks bin | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "mktemp -t reintroduced:"; echo "$output"; false; }
}
