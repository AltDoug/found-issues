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

  fi_seed_entry "src/foo.py:1 — bug (commit: deadbeef)"
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

  fi_seed_entry "src/foo.py:1 — bug (commit: deadbeef)"
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

  fi_seed_entry "src/foo.py:1 — bug (commit: $sha)"
  fi_run sync
  grep -q '\[fixed\].*\(commit: '"$sha"'\)' docs/found-issues.md
}

# --- consumer clones (2026-10-29) ---
# A clone that never fetched a commit cannot tell "gone" from "on a branch I
# do not have". Measured on a pull-only clone: sync demoted (commit:) refs to
# (commit-stale:) because the objects were missing locally, the uncommitted
# ledger edit then made `git pull --ff-only` abort, and it recurred every
# session. A missing local object is not evidence; only the remote is.

@test "sync: clone missing a commit that exists upstream leaves (commit:) alone" {
  # Upstream (a plain git remote) holds the commit on a side branch; the
  # clone fetched main only, so the object is absent locally.
  local up="$TMP/up.git"
  git init -q --bare -b main "$up"
  git remote add origin "$up"
  mkdir -p src
  echo "x" > src/foo.py
  git add src/foo.py
  git commit -q -m "init"
  git push -q origin main
  git checkout -q -b side
  echo "y" >> src/foo.py
  git commit -q -am "fix on a side branch"
  local sha
  sha="$(git rev-parse --short=7 HEAD)"
  git push -q origin side
  git checkout -q main
  local clone="$TMP/clone"
  git clone -q --no-local --single-branch -b main "file://$up" "$clone"
  cd "$clone"
  run git cat-file -e "$sha"
  [ "$status" -ne 0 ]

  fi_seed_entry "src/foo.py:1 — bug (commit: $sha)"
  local before
  before="$(cat docs/found-issues.md)"
  fi_run sync
  [ "$status" -eq 0 ]
  [ "$(cat docs/found-issues.md)" = "$before" ]
}

@test "sync: GitHub says the commit exists -> (commit:) left alone" {
  fi_use_gh_shim
  fi_init_github_repo foo/bar main
  mkdir -p src
  echo "x" > src/foo.py
  git add src/foo.py
  git commit -q -m "init"
  export GH_MOCK_COMMITS="a46fa6bb6ce8c0b71d2691c97964fc02cc77717e"

  fi_seed_entry "src/foo.py:1 — bug (commit: a46fa6b)"
  local before
  before="$(cat docs/found-issues.md)"
  fi_run sync
  [ "$status" -eq 0 ]
  [ "$(cat docs/found-issues.md)" = "$before" ]
}

@test "sync: GitHub says no such commit (HTTP 422) -> demotes to (commit-stale:)" {
  fi_use_gh_shim
  fi_init_github_repo foo/bar main
  mkdir -p src
  echo "x" > src/foo.py
  git add src/foo.py
  git commit -q -m "init"
  export GH_MOCK_COMMITS=""

  fi_seed_entry "src/foo.py:1 — bug (commit: deadbeef)"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\].*(commit-stale: deadbeef)' docs/found-issues.md
}

@test "sync: GitHub lookup fails (repo not visible / offline) -> (commit:) left alone" {
  fi_use_gh_shim
  fi_init_github_repo foo/bar main
  mkdir -p src
  echo "x" > src/foo.py
  git add src/foo.py
  git commit -q -m "init"
  export GH_MOCK_COMMITS_API=fail

  fi_seed_entry "src/foo.py:1 — bug (commit: deadbeef)"
  local before
  before="$(cat docs/found-issues.md)"
  fi_run sync
  [ "$status" -eq 0 ]
  [ "$(cat docs/found-issues.md)" = "$before" ]
}
