#!/usr/bin/env bats
# Tests for `found-issues annotate-pr` and `annotate-commit`

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

# === annotate-commit ===

@test "annotate-commit: adds (commit: <sha>) to matching entry" {
  mkdir -p src
  echo "x" > src/foo.py
  fi_run log "src/foo.py:1 — bug"
  git add -A
  git commit -q -m "fix foo"
  short_sha="$(git rev-parse --short=7 HEAD)"

  fi_run annotate-commit HEAD
  [ "$status" -eq 0 ]
  grep -q "src/foo.py:1.*\(commit: $short_sha\)" docs/found-issues.md
}

@test "annotate-commit: defaults to HEAD" {
  mkdir -p src
  echo "x" > src/foo.py
  fi_run log "src/foo.py:1 — bug"
  git add -A
  git commit -q -m "fix"
  short_sha="$(git rev-parse --short=7 HEAD)"

  fi_run annotate-commit
  [ "$status" -eq 0 ]
  grep -q "(commit: $short_sha)" docs/found-issues.md
}

@test "annotate-commit: no-op when commit doesn't touch logged paths" {
  mkdir -p src
  echo "x" > src/foo.py
  fi_run log "src/foo.py:1 — bug"
  echo "y" > src/other.py
  git add src/other.py
  git commit -q -m "unrelated"

  fi_run annotate-commit HEAD
  [ "$status" -eq 0 ]
  [[ "$output" == *"no [open] entries match"* ]]
  ! grep -q '(commit:' docs/found-issues.md
}

@test "annotate-commit: idempotent (same SHA twice doesn't double-annotate)" {
  mkdir -p src
  echo "x" > src/foo.py
  fi_run log "src/foo.py:1 — bug"
  git add -A
  git commit -q -m "fix"

  fi_run annotate-commit HEAD
  fi_run annotate-commit HEAD

  # Should have exactly one (commit: ...) annotation
  count="$(grep -oE '\(commit: [a-f0-9]+\)' docs/found-issues.md | wc -l | tr -d ' ')"
  [ "$count" = "1" ]
}

@test "annotate-commit: rejects invalid SHA" {
  fi_run annotate-commit zzznotasha
  [ "$status" -ne 0 ]
}

# === annotate-pr ===

@test "annotate-pr: errors gracefully without GitHub remote" {
  fi_run log "src/foo.py:1 — bug"
  fi_run annotate-pr 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"not in a GitHub repo"* ]] || [[ "$output" == *"not in a GitHub"* ]]
}

@test "annotate-pr: rejects non-numeric PR" {
  fi_run annotate-pr abc
  [ "$status" -ne 0 ]
  [[ "$output" == *"numeric"* ]]
}

@test "annotate-pr: preserves dotted repo names in the annotation" {
  git commit --allow-empty -q -m init
  git remote add origin "https://github.com/vercel/next.js.git"
  fi_use_gh_shim
  export GH_MOCK_PR_VIEW=$'7\tsrc/foo.py'
  mkdir -p src && echo x > src/foo.py
  fi_run log "src/foo.py:1 — bug"
  fi_run annotate-pr 7
  [ "$status" -eq 0 ]
  grep -q '(PR: vercel/next.js#7)' docs/found-issues.md
  unset GH_MOCK_PR_VIEW
}

# === annotate-pr multi-match selection (v1.6.0) ===
#
# File-level matching alone over-annotates: a PR touching a hot file gets
# every entry citing that file annotated, and sync then false-flips them all
# to [fixed] on merge. When several entries share one touched file the CLI
# now lists candidates and requires --pick (or --all).

_setup_pr_repo() {
  git commit --allow-empty -q -m init
  git remote add origin "https://github.com/org/repo.git"
  fi_use_gh_shim
}

@test "annotate-pr: multiple entries on one touched file are NOT auto-annotated" {
  _setup_pr_repo
  export GH_MOCK_PR_VIEW=$'9\tsrc/hot.py'
  mkdir -p src && echo x > src/hot.py
  fi_run log "src/hot.py:1 — first bug"
  fi_run log "src/hot.py:2 — second bug"
  fi_run annotate-pr 9
  [ "$status" -eq 3 ]
  ! grep -q '(PR: org/repo#9)' docs/found-issues.md
  [[ "$output" == *"src/hot.py:1"* ]]
  [[ "$output" == *"src/hot.py:2"* ]]
  [[ "$output" == *"--pick"* ]]
  unset GH_MOCK_PR_VIEW
}

@test "annotate-pr: --pick annotates only the selected entry" {
  _setup_pr_repo
  export GH_MOCK_PR_VIEW=$'9\tsrc/hot.py'
  mkdir -p src && echo x > src/hot.py
  fi_run log "src/hot.py:1 — first bug"
  fi_run log "src/hot.py:2 — second bug"
  fi_run annotate-pr 9 --pick src/hot.py:2
  [ "$status" -eq 0 ]
  grep -q 'src/hot.py:2 — second bug (PR: org/repo#9)' docs/found-issues.md
  ! grep -q 'src/hot.py:1 — first bug (PR:' docs/found-issues.md
  unset GH_MOCK_PR_VIEW
}

@test "annotate-pr: --pick accepts comma-separated locations" {
  _setup_pr_repo
  export GH_MOCK_PR_VIEW=$'9\tsrc/hot.py'
  mkdir -p src && echo x > src/hot.py
  fi_run log "src/hot.py:1 — first bug"
  fi_run log "src/hot.py:2 — second bug"
  fi_run log "src/hot.py:3 — third bug"
  fi_run annotate-pr 9 --pick src/hot.py:1,src/hot.py:3
  [ "$status" -eq 0 ]
  grep -q 'first bug (PR: org/repo#9)' docs/found-issues.md
  ! grep -q 'second bug (PR:' docs/found-issues.md
  grep -q 'third bug (PR: org/repo#9)' docs/found-issues.md
  unset GH_MOCK_PR_VIEW
}

@test "annotate-pr: --all annotates every matching entry" {
  _setup_pr_repo
  export GH_MOCK_PR_VIEW=$'9\tsrc/hot.py'
  mkdir -p src && echo x > src/hot.py
  fi_run log "src/hot.py:1 — first bug"
  fi_run log "src/hot.py:2 — second bug"
  fi_run annotate-pr 9 --all
  [ "$status" -eq 0 ]
  [ "$(grep -c '(PR: org/repo#9)' docs/found-issues.md)" -eq 2 ]
  unset GH_MOCK_PR_VIEW
}

@test "annotate-pr: mixed PR auto-annotates unambiguous file, lists ambiguous one" {
  _setup_pr_repo
  export GH_MOCK_PR_VIEW=$'9\tsrc/hot.py\\nsrc/cold.py'
  mkdir -p src && echo x > src/hot.py && echo x > src/cold.py
  fi_run log "src/hot.py:1 — first bug"
  fi_run log "src/hot.py:2 — second bug"
  fi_run log "src/cold.py:5 — lone bug"
  fi_run annotate-pr 9
  [ "$status" -eq 3 ]
  grep -q 'lone bug (PR: org/repo#9)' docs/found-issues.md
  ! grep -q 'first bug (PR:' docs/found-issues.md
  [[ "$output" == *"src/hot.py:1"* ]]
  [[ "$output" == *"--pick"* ]]
  unset GH_MOCK_PR_VIEW
}

@test "annotate-pr: --pick warns on a location matching no open entry" {
  _setup_pr_repo
  export GH_MOCK_PR_VIEW=$'9\tsrc/hot.py'
  mkdir -p src && echo x > src/hot.py
  fi_run log "src/hot.py:1 — first bug"
  fi_run annotate-pr 9 --pick src/nope.py:9
  [ "$status" -ne 0 ]
  [[ "$output" == *"src/nope.py:9"* ]]
  unset GH_MOCK_PR_VIEW
}

@test "annotate-pr: --pick skips an already-annotated entry idempotently" {
  _setup_pr_repo
  export GH_MOCK_PR_VIEW=$'9\tsrc/hot.py'
  mkdir -p src && echo x > src/hot.py
  fi_run log "src/hot.py:1 — first bug"
  fi_run annotate-pr 9 --pick src/hot.py:1
  fi_run annotate-pr 9 --pick src/hot.py:1
  [ "$status" -eq 0 ]
  [ "$(grep -c '(PR: org/repo#9)' docs/found-issues.md)" -eq 1 ]
  unset GH_MOCK_PR_VIEW
}

@test "annotate-pr: repo id survives trailing slash after .git in remote URL" {
  git commit --allow-empty -q -m init
  git remote add origin "https://github.com/org/repo.git/"
  fi_use_gh_shim
  export GH_MOCK_PR_VIEW=$'7\tsrc/foo.py'
  mkdir -p src && echo x > src/foo.py
  fi_run log "src/foo.py:1 — bug"
  fi_run annotate-pr 7
  [ "$status" -eq 0 ]
  grep -q '(PR: org/repo#7)' docs/found-issues.md
  unset GH_MOCK_PR_VIEW
}

# === v1.6.0 review hardening: guard defeat paths ===

@test "annotate-pr: entry matching several touched files shares groups correctly (no first-match split)" {
  _setup_pr_repo
  export GH_MOCK_PR_VIEW=$'9\tapp/util.py\\nsrc/util.py'
  mkdir -p app src && echo x > app/util.py && echo x > src/util.py
  fi_run log "util.py:5 — bare-filename entry matching both copies"
  fi_run log "src/util.py:9 — entry on the src copy"
  fi_run annotate-pr 9
  [ "$status" -eq 3 ]
  # Both entries suffix-share src/util.py — neither may auto-annotate
  ! grep -q '(PR: org/repo#9)' docs/found-issues.md
  [[ "$output" == *"util.py:5"* ]]
  [[ "$output" == *"src/util.py:9"* ]]
  unset GH_MOCK_PR_VIEW
}

@test "annotate-pr: plain re-run after --pick does not auto-annotate the excluded entry" {
  _setup_pr_repo
  export GH_MOCK_PR_VIEW=$'9\tsrc/hot.py'
  mkdir -p src && echo x > src/hot.py
  fi_run log "src/hot.py:1 — first bug"
  fi_run log "src/hot.py:2 — second bug"
  fi_run annotate-pr 9 --pick src/hot.py:1
  fi_run annotate-pr 9
  [ "$status" -eq 3 ]
  # The deliberately-unpicked entry must stay un-annotated (listed, not tagged)
  ! grep -q 'second bug (PR:' docs/found-issues.md
  [[ "$output" == *"src/hot.py:2"* ]]
  unset GH_MOCK_PR_VIEW
}

@test "annotate-pr: pick matching several co-located entries is refused" {
  _setup_pr_repo
  export GH_MOCK_PR_VIEW=$'9\tsrc/hot.py'
  mkdir -p src && echo x > src/hot.py
  fi_run log "src/hot.py:2 — null deref crash"
  fi_run log "src/hot.py:2 — race condition on write"
  fi_run annotate-pr 9 --pick src/hot.py:2
  [ "$status" -ne 0 ]
  ! grep -q '(PR: org/repo#9)' docs/found-issues.md
  [[ "$output" == *"null deref crash"* ]]
  [[ "$output" == *"race condition on write"* ]]
  unset GH_MOCK_PR_VIEW
}

@test "annotate-pr: extended pick with symptom fragment selects one co-located entry" {
  _setup_pr_repo
  export GH_MOCK_PR_VIEW=$'9\tsrc/hot.py'
  mkdir -p src && echo x > src/hot.py
  fi_run log "src/hot.py:2 — null deref crash"
  fi_run log "src/hot.py:2 — race condition on write"
  fi_run annotate-pr 9 --pick "src/hot.py:2 — null deref"
  [ "$status" -eq 0 ]
  grep -q 'null deref crash (PR: org/repo#9)' docs/found-issues.md
  ! grep -q 'race condition on write (PR:' docs/found-issues.md
  unset GH_MOCK_PR_VIEW
}

@test "annotate-pr: --pick applies even when the touched-files fetch is empty" {
  _setup_pr_repo
  export GH_MOCK_PR_VIEW=$'9\t'
  mkdir -p src && echo x > src/hot.py
  fi_run log "src/hot.py:1 — first bug"
  fi_run annotate-pr 9 --pick src/hot.py:1
  [ "$status" -eq 0 ]
  grep -q 'first bug (PR: org/repo#9)' docs/found-issues.md
  unset GH_MOCK_PR_VIEW
}

# === v1.6.0 review hardening: annotate-commit gets the same guard ===

@test "annotate-commit: multiple entries on one touched file are NOT auto-annotated" {
  mkdir -p src
  echo "x" > src/hot.py
  fi_run log "src/hot.py:1 — first bug"
  fi_run log "src/hot.py:2 — second bug"
  git add src/hot.py
  git commit -q -m "touch hot"
  fi_run annotate-commit HEAD
  [ "$status" -eq 3 ]
  ! grep -q '(commit:' docs/found-issues.md
  [[ "$output" == *"src/hot.py:1"* ]]
  [[ "$output" == *"--pick"* ]]
}

@test "annotate-commit: --pick annotates only the selected entry" {
  mkdir -p src
  echo "x" > src/hot.py
  fi_run log "src/hot.py:1 — first bug"
  fi_run log "src/hot.py:2 — second bug"
  git add src/hot.py
  git commit -q -m "touch hot"
  short_sha="$(git rev-parse --short=7 HEAD)"
  fi_run annotate-commit HEAD --pick src/hot.py:2
  [ "$status" -eq 0 ]
  grep -q "second bug (commit: $short_sha)" docs/found-issues.md
  ! grep -q "first bug (commit:" docs/found-issues.md
}

@test "annotate-commit: --all annotates every matching entry" {
  mkdir -p src
  echo "x" > src/hot.py
  fi_run log "src/hot.py:1 — first bug"
  fi_run log "src/hot.py:2 — second bug"
  git add src/hot.py
  git commit -q -m "touch hot"
  fi_run annotate-commit HEAD --all
  [ "$status" -eq 0 ]
  [ "$(grep -c '(commit:' docs/found-issues.md)" -eq 2 ]
}

# === annotate-pr cross-repo refs (v2.1.0) ===
#
# An entry fixed by a PR in a DIFFERENT repo (e.g. an upstream plugin fix
# for a consumer-ledger entry) was previously un-annotatable: the CLI
# accepted only a numeric PR and resolved org/repo from CWD — yet sync
# fully supports reading org/repo#N refs. Cross-repo refs require --pick:
# file-level auto-matching is meaningless against another repo's tree.

@test "annotate-pr: org/repo#N ref with --pick writes the given canonical ref" {
  fi_use_gh_shim
  export GH_MOCK_PR_VIEW=$'12\tupstream/file.sh'
  export GH_MOCK_TRACE="$PWD/gh-trace.txt"
  mkdir -p src && echo x > src/foo.py
  fi_run log "src/foo.py:1 — bug fixed upstream"
  fi_run annotate-pr "acme/upstream#12" --pick src/foo.py:1
  [ "$status" -eq 0 ]
  grep -q '(PR: acme/upstream#12)' docs/found-issues.md
  grep -q -- '--repo acme/upstream' "$GH_MOCK_TRACE"
  unset GH_MOCK_PR_VIEW GH_MOCK_TRACE
}

@test "annotate-pr: cross-repo ref without --pick is refused with guidance" {
  fi_use_gh_shim
  export GH_MOCK_PR_VIEW=$'12\tupstream/file.sh'
  mkdir -p src && echo x > src/foo.py
  fi_run log "src/foo.py:1 — bug"
  fi_run annotate-pr "acme/upstream#12"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--pick"* ]]
  # run + status, not bare `! grep` — bats swallows mid-function `!` failures
  run grep -q '(PR: acme/upstream#12)' docs/found-issues.md
  [ "$status" -ne 0 ]
  unset GH_MOCK_PR_VIEW
}

@test "annotate-pr: malformed org/repo ref is rejected" {
  fi_run annotate-pr "acme/upstream#12x"
  [ "$status" -ne 0 ]
}
