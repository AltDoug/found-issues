#!/usr/bin/env bats
load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

@test "sync: unresolvable commit SHA demotes to (commit-stale: ...)" {
  mkdir -p src
  echo "x" > src/foo.py
  git add src/foo.py
  git commit -q -m "init"

  fi_run log "src/foo.py:1 — bug (commit: deadbeef)"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\].*\(commit-stale: deadbeef\)' docs/found-issues.md
  ! grep -qE '\(commit: deadbeef\)' docs/found-issues.md
}

@test "sync: commit-stale demotion is idempotent" {
  mkdir -p src
  echo "x" > src/foo.py
  git add src/foo.py
  git commit -q -m "init"

  fi_run log "src/foo.py:1 — bug (commit: deadbeef)"
  fi_run sync
  local snapshot
  snapshot="$(cat docs/found-issues.md)"
  fi_run sync
  diff <(echo "$snapshot") docs/found-issues.md
}

@test "sync: existing reachable commit still flips to [fixed] (unchanged behavior)" {
  mkdir -p src
  echo "x" > src/foo.py
  git add src/foo.py
  git commit -q -m "add foo"
  local sha
  sha="$(git rev-parse --short=7 HEAD)"

  fi_run log "src/foo.py:1 — bug (commit: $sha)"
  fi_run sync
  grep -q '\[fixed\].*\(commit: '"$sha"'\)' docs/found-issues.md
}
