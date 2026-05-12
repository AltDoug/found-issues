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
  fi_run sync
  # Should not crash; entry stays open (no closure mechanism applies)
  [ "$status" -eq 0 ]
}
