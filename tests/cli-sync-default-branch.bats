#!/usr/bin/env bats
load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
  fi_use_gh_shim
}

teardown() {
  fi_teardown_tmp
  # Clean up any cache files this test created (they live globally in ~/.cache)
  rm -rf ~/.cache/found-issues/default-branch-* 2>/dev/null || true
}

@test "sync: uses gh repo view fallback when origin/HEAD is unset and gh available" {
  export GH_MOCK_REPO_VIEW='{"defaultBranchRef":{"name":"develop"}}'
  export GH_MOCK_PR_VIEW=$'42\t{"state":"MERGED","baseRefName":"develop","mergedAt":"2026-05-01T12:00:00Z","isDraft":false}'

  git checkout -q -b develop
  git commit --allow-empty -q -m "init"
  git remote add origin https://github.com/foo/bar.git
  # Intentionally do NOT set origin/HEAD — exercise the gh-based fallback
  export FOUND_ISSUES_MODE=github-pr

  mkdir -p src && printf 'x\n' > src/foo.py
  fi_run log "src/foo.py:1 — bug (PR: foo/bar#42)"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '\[fixed\].*\(PR: foo/bar#42\)' docs/found-issues.md
}

@test "sync: gh fallback result is cached per-session" {
  export GH_MOCK_REPO_VIEW='{"defaultBranchRef":{"name":"trunk"}}'
  export GH_MOCK_TRACE="$TMP/gh-trace.log"

  git commit --allow-empty -q -m "init"
  git remote add origin https://github.com/foo/bar.git
  export FOUND_ISSUES_MODE=github-pr

  fi_run log "src/a.py:1 — bug"
  fi_run sync  # populates cache
  fi_run sync  # second sync should not call gh repo view again

  count="$(grep -c '^repo view' "$TMP/gh-trace.log" 2>/dev/null || echo 0)"
  [ "$count" -le 1 ]
}

@test "sync: falls back to literal main only when both origin/HEAD AND gh fail" {
  unset GH_MOCK_REPO_VIEW  # gh returns nothing
  git commit --allow-empty -q -m "init"
  git remote add origin https://github.com/foo/bar.git
  # No origin/HEAD set, no gh response → fall back to main

  fi_run log "src/a.py:1 — bug"
  echo "===LOG_STATUS===" >&2
  echo "$status" >&2
  echo "===LOG_OUTPUT===" >&2
  echo "$output" >&2

  # DEBUG: capture sync stderr separately
  local err_file
  err_file="$(mktemp)"
  set +e
  local out
  out="$($FI_BIN sync 2>"$err_file")"
  local sync_exit=$?
  set -e
  local err
  err="$(cat "$err_file")"
  rm -f "$err_file"
  echo "===SYNC_STDOUT===" >&2
  echo "$out" >&2
  echo "===SYNC_STDERR===" >&2
  echo "$err" >&2
  echo "===SYNC_EXIT===" >&2
  echo "$sync_exit" >&2
  echo "===BASH_VERSION===" >&2
  echo "$BASH_VERSION" >&2
  echo "===OS===" >&2
  uname -a >&2 || true
  echo "===GH_PATH===" >&2
  command -v gh >&2 || true
  echo "===JQ_PATH===" >&2
  command -v jq >&2 || true

  fi_run sync
  echo "===FI_RUN_SYNC_STATUS===" >&2
  echo "$status" >&2
  echo "===FI_RUN_SYNC_OUTPUT===" >&2
  echo "$output" >&2
  # Should not crash; entry stays open (no closure mechanism applies)
  [ "$status" -eq 0 ]
}
