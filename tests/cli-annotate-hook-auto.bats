#!/usr/bin/env bats
# Tests for annotate-pr/annotate-commit --hook-auto (line-matched gate, cap, exit 3)

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
  fi_init_github_repo "org/repo"
  fi_use_gh_shim
  export GH_MOCK_REPO_VIEW='{"nameWithOwner":"org/repo"}'
}

teardown() { fi_teardown_tmp; }

# Diff fixture helper: one file, old-side hunk covering lines 40-45
mk_pr_mocks() {
  export GH_MOCK_PR_VIEW=$'7\tsrc/foo.py'
  export GH_MOCK_PR_DIFF='--- a/src/foo.py\n+++ b/src/foo.py\n@@ -40,6 +40,7 @@\n context'
}

@test "hook-auto: annotates entry whose cited line is inside a changed hunk" {
  fi_run log "src/foo.py:42 — null check missing"
  mk_pr_mocks
  fi_run annotate-pr 7 --hook-auto
  [ "$status" -eq 0 ]
  grep -q 'src/foo.py:42.*(PR: org/repo#7)' docs/found-issues.md
}

@test "hook-auto: file-touched but line outside hunks becomes candidate, exit 3" {
  fi_run log "src/foo.py:99 — wrong cast"
  mk_pr_mocks
  fi_run annotate-pr 7 --hook-auto
  [ "$status" -eq 3 ]
  ! grep -q '(PR: org/repo#7)' docs/found-issues.md
  [[ "$output" == *"src/foo.py:99"* ]]
  [[ "$output" == *"--pick"* ]]
}

@test "hook-auto: line-less abstract entry never auto-annotates" {
  fi_run log "workflow/shutdown — sigterm kills sessions"
  export GH_MOCK_PR_VIEW=$'7\tworkflow/shutdown'
  export GH_MOCK_PR_DIFF='--- a/workflow/shutdown\n+++ b/workflow/shutdown\n@@ -1,5 +1,5 @@\n x'
  fi_run annotate-pr 7 --hook-auto
  [ "$status" -eq 3 ]
  ! grep -q '(PR:' docs/found-issues.md
}

@test "hook-auto: mass-touch cap sends everything to candidates" {
  export FOUND_ISSUES_AUTO_ANNOTATE_MAX=2
  fi_run log "src/a.py:1 — bug a"
  fi_run log "src/b.py:1 — bug b"
  fi_run log "src/c.py:1 — bug c"
  export GH_MOCK_PR_VIEW=$'7\tsrc/a.py\\nsrc/b.py\\nsrc/c.py'
  export GH_MOCK_PR_DIFF='--- a/src/a.py\n+++ b/src/a.py\n@@ -1,2 +1,2 @@\n x\n--- a/src/b.py\n+++ b/src/b.py\n@@ -1,2 +1,2 @@\n x\n--- a/src/c.py\n+++ b/src/c.py\n@@ -1,2 +1,2 @@\n x'
  fi_run annotate-pr 7 --hook-auto
  [ "$status" -eq 3 ]
  ! grep -q '(PR:' docs/found-issues.md
}

@test "hook-auto: no matches at all stays silent-clean, exit 0" {
  fi_run log "src/other.py:5 — unrelated"
  mk_pr_mocks
  fi_run annotate-pr 7 --hook-auto
  [ "$status" -eq 0 ]
  [[ "$output" == *"no [open] entries match"* ]]
}

@test "manual ambiguous list now exits 3 (was 0)" {
  fi_run log "src/foo.py:10 — bug one"
  fi_run log "src/foo.py:20 — bug two"
  export GH_MOCK_PR_VIEW=$'7\tsrc/foo.py'
  fi_run annotate-pr 7
  [ "$status" -eq 3 ]
  [[ "$output" == *"--pick"* ]]
}

@test "annotate-commit --hook-auto: line-matched entry annotates from git show" {
  mkdir -p src
  printf 'l1\nl2\nl3\nl4\nl5\n' > src/foo.py
  git add -A && git commit -q -m "seed"
  fi_run log "src/foo.py:3 — bug at line 3"
  printf 'l1\nl2\nFIXED\nl4\nl5\n' > src/foo.py
  git add -A && git commit -q -m "fix"
  short_sha="$(git rev-parse --short=7 HEAD)"
  fi_run annotate-commit HEAD --hook-auto
  [ "$status" -eq 0 ]
  grep -q "src/foo.py:3.*(commit: $short_sha)" docs/found-issues.md
}
