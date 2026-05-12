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

  fi_run log "src/foo.py:1 — bug (PR: foo/bar#42)"
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

  fi_run log "src/foo.py:1 — bug (PR: foo/bar#99)"
  fi_run sync
  [ "$status" -eq 0 ]
  # Entry stays [open] with original annotation (no demotion, no flip)
  grep -q '^- \[open\].*src/foo.py:1.*\(PR: foo/bar#99\)' docs/found-issues.md
  # Warning surfaced via stderr (bats's `run` captures both stdout+stderr into $output)
  [[ "$output" == *"could not be fetched"* ]]
  [[ "$output" == *"foo/bar#99"* ]]
}
