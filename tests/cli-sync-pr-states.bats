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

@test "sync: MERGED PR on default branch flips entry to [fixed]" {
  fi_init_github_repo foo/bar main
  export GH_MOCK_PR_VIEW=$'42\t{"state":"MERGED","baseRefName":"main","mergedAt":"2026-05-01T12:00:00Z","isDraft":false}'

  # Create the file so tombstone doesn't pre-empt the PR-check path
  mkdir -p src
  printf 'x\n' > src/foo.py

  fi_seed_entry "src/foo.py:1 — bug (PR: foo/bar#42)"
  fi_run sync
  [ "$status" -eq 0 ]
  # Entry flipped to [fixed] via PR-merge path (not tombstone)
  grep -q '^- \[fixed\].*src/foo.py:1.*\(PR: foo/bar#42\)' docs/found-issues.md
  # Negative assertion: tombstone closure must NOT be the mechanism
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

@test "sync: gh-empty PR triggers warning but does not mutate" {
  fi_init_github_repo foo/bar main
  export GH_MOCK_PR_VIEW=""  # no mocks → shim exits 1 → CLI sees empty

  # Create the file so tombstone doesn't pre-empt
  mkdir -p src
  printf 'x\n' > src/foo.py

  fi_seed_entry "src/foo.py:1 — bug (PR: foo/bar#99)"
  fi_run sync
  [ "$status" -eq 0 ]
  # Entry stays [open] with original annotation (no demotion, no flip)
  grep -q '^- \[open\].*src/foo.py:1.*\(PR: foo/bar#99\)' docs/found-issues.md
  # Warning surfaced via stderr (bats's `run` captures both stdout+stderr into $output)
  [[ "$output" == *"could not be fetched"* ]]
  [[ "$output" == *"foo/bar#99"* ]]
}

@test "sync: CLOSED-without-merge PR demotes to (PR-closed: ...)" {
  fi_init_github_repo foo/bar main
  export GH_MOCK_PR_VIEW=$'42\t{"state":"CLOSED","baseRefName":"main","mergedAt":null,"isDraft":false}'
  mkdir -p src && printf 'x\n' > src/foo.py

  fi_seed_entry "src/foo.py:1 — bug (PR: foo/bar#42)"
  fi_run sync
  [ "$status" -eq 0 ]
  # Entry stays [open], but annotation demoted
  grep -q '^- \[open\].*\(PR-closed: foo/bar#42\)' docs/found-issues.md
  ! grep -qE '\(PR: foo/bar#42\)' docs/found-issues.md
}

@test "sync: PR-closed demotion is idempotent (second sync is no-op)" {
  fi_init_github_repo foo/bar main
  export GH_MOCK_PR_VIEW=$'42\t{"state":"CLOSED","baseRefName":"main","mergedAt":null,"isDraft":false}'
  mkdir -p src && printf 'x\n' > src/foo.py

  fi_seed_entry "src/foo.py:1 — bug (PR: foo/bar#42)"
  fi_run sync
  local snapshot
  snapshot="$(cat docs/found-issues.md)"
  fi_run sync
  [ "$status" -eq 0 ]
  # Second sync should produce identical file content
  diff <(echo "$snapshot") docs/found-issues.md
}

# A PR merged into a release branch (stacked or release-train workflow)
# lands on main only when that branch does. Sync closes the entry once a
# merged PR from that branch into the default branch exists, merged after it.
release_pr() { # mergedAt of PR 42 into release/v3
  export GH_MOCK_PR_VIEW=$'42\t{"state":"MERGED","baseRefName":"release/v3","mergedAt":"'"$1"'","isDraft":false}'
}

@test "sync: a PR merged into a release branch that later reached main flips to fixed" {
  fi_init_github_repo foo/bar main
  release_pr 2026-10-04T06:00:00Z
  export GH_MOCK_PR_LIST='[{"mergedAt":"2026-10-04T09:00:00Z"}]'
  export GH_MOCK_TRACE="$TMP/gh.trace"
  mkdir -p src && printf 'x\n' > src/foo.py
  fi_seed_entry "src/foo.py:1 — bug (PR: foo/bar#42)"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[fixed\].*(PR: foo/bar#42)' docs/found-issues.md
  grep -q '^pr list --repo foo/bar --head release/v3 --base main --state merged' "$TMP/gh.trace"
}

@test "sync: a PR merged into a branch that never reached main stays open" {
  fi_init_github_repo foo/bar main
  release_pr 2026-10-04T06:00:00Z
  export GH_MOCK_PR_LIST='[]'
  mkdir -p src && printf 'x\n' > src/foo.py
  fi_seed_entry "src/foo.py:1 — bug (PR: foo/bar#42)"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\].*(PR: foo/bar#42)' docs/found-issues.md
}

@test "sync: a release branch merge to main older than the PR leaves it open" {
  fi_init_github_repo foo/bar main
  release_pr 2026-10-04T06:00:00Z
  export GH_MOCK_PR_LIST='[{"mergedAt":"2026-10-01T09:00:00Z"}]'
  mkdir -p src && printf 'x\n' > src/foo.py
  fi_seed_entry "src/foo.py:1 — bug (PR: foo/bar#42)"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\].*(PR: foo/bar#42)' docs/found-issues.md
}

@test "sync: a gh answer that is not a timestamp never counts as reaching main" {
  fi_init_github_repo foo/bar main
  release_pr 2026-10-04T06:00:00Z
  export GH_MOCK_PR_LIST='[{"mergedAt":"[not a date]"}]'
  mkdir -p src && printf 'x\n' > src/foo.py
  fi_seed_entry "src/foo.py:1 — bug (PR: foo/bar#42)"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\].*(PR: foo/bar#42)' docs/found-issues.md
}

@test "sync: release branch promotion is looked up once per base branch" {
  fi_init_github_repo foo/bar main
  export GH_MOCK_PR_VIEW=$'42\t{"state":"MERGED","baseRefName":"release/v3","mergedAt":"2026-10-04T06:00:00Z","isDraft":false}\n43\t{"state":"MERGED","baseRefName":"release/v3","mergedAt":"2026-10-04T07:00:00Z","isDraft":false}'
  export GH_MOCK_PR_LIST='[{"mergedAt":"2026-10-04T09:00:00Z"}]'
  export GH_MOCK_TRACE="$TMP/gh.trace"
  mkdir -p src && printf 'x\n' > src/foo.py && printf 'y\n' > src/bar.py
  fi_seed_entry "src/foo.py:1 — bug (PR: foo/bar#42)"
  fi_seed_entry "src/bar.py:1 — other bug (PR: foo/bar#43)"
  fi_run sync
  [ "$status" -eq 0 ]
  [ "$(grep -c '^- \[fixed\]' docs/found-issues.md)" = 2 ]
  [ "$(grep -c '^pr list' "$TMP/gh.trace")" = 1 ]
}
