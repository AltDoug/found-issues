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

# Diff fixture helper: one file whose hunk spans old-side lines 40-45 but
# REMOVES only line 42 — so line 42 line-matches while a nearby context line
# (e.g. 40 or 43) does not. Realistic body (diff --git header + context/-/+
# lines) so fi_diff_old_ranges parses hunk bodies, not just @@ headers.
mk_pr_mocks() {
  export GH_MOCK_PR_VIEW=$'7\tsrc/foo.py'
  export GH_MOCK_PR_DIFF='diff --git a/src/foo.py b/src/foo.py\n--- a/src/foo.py\n+++ b/src/foo.py\n@@ -40,6 +40,7 @@\n ctx40\n ctx41\n-old42\n+new42\n+added\n ctx43\n ctx44\n ctx45'
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
  [[ "$output" == *"src/foo.py:99"* ]]
  [[ "$output" == *"--pick"* ]]
  run grep -q '(PR: org/repo#7)' docs/found-issues.md
  [ "$status" -ne 0 ]
}

@test "hook-auto: line-less abstract entry never auto-annotates" {
  fi_run log "workflow/shutdown — sigterm kills sessions"
  export GH_MOCK_PR_VIEW=$'7\tworkflow/shutdown'
  export GH_MOCK_PR_DIFF='diff --git a/workflow/shutdown b/workflow/shutdown\n--- a/workflow/shutdown\n+++ b/workflow/shutdown\n@@ -1,3 +1,3 @@\n ctx1\n-old2\n+new2\n ctx3'
  fi_run annotate-pr 7 --hook-auto
  [ "$status" -eq 3 ]
  run grep -q '(PR:' docs/found-issues.md
  [ "$status" -ne 0 ]
}

@test "hook-auto: mass-touch cap sends everything to candidates" {
  export FOUND_ISSUES_AUTO_ANNOTATE_MAX=2
  fi_run log "src/a.py:1 — bug a"
  fi_run log "src/b.py:1 — bug b"
  fi_run log "src/c.py:1 — bug c"
  export GH_MOCK_PR_VIEW=$'7\tsrc/a.py\\nsrc/b.py\\nsrc/c.py'
  export GH_MOCK_PR_DIFF='diff --git a/src/a.py b/src/a.py\n--- a/src/a.py\n+++ b/src/a.py\n@@ -1,2 +1,2 @@\n-old1\n+new1\n ctx2\ndiff --git a/src/b.py b/src/b.py\n--- a/src/b.py\n+++ b/src/b.py\n@@ -1,2 +1,2 @@\n-old1\n+new1\n ctx2\ndiff --git a/src/c.py b/src/c.py\n--- a/src/c.py\n+++ b/src/c.py\n@@ -1,2 +1,2 @@\n-old1\n+new1\n ctx2'
  fi_run annotate-pr 7 --hook-auto
  [ "$status" -eq 3 ]
  run grep -q '(PR:' docs/found-issues.md
  [ "$status" -ne 0 ]
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

@test "hook-auto: a pure-addition commit adjacent to the cited line does NOT auto-annotate" {
  # Regression: an insertion next to the cited line touches the file but
  # removes nothing on the old side — fi_diff_old_ranges emits no range, so
  # the entry must surface as a candidate (exit 3), never auto-annotate.
  mkdir -p src
  printf 'l1\nl2\nl3\nl4\nl5\n' > src/foo.py
  git add -A && git commit -q -m "seed"
  fi_run log "src/foo.py:3 — bug at line 3"
  printf 'l1\nl2\nINSERTED\nl3\nl4\nl5\n' > src/foo.py
  git add -A && git commit -q -m "insert above line 3"
  fi_run annotate-commit HEAD --hook-auto
  [ "$status" -eq 3 ]
  [[ "$output" == *"src/foo.py:3"* ]]
  run grep -q '(commit:' docs/found-issues.md
  [ "$status" -ne 0 ]
}

@test "hook-auto: a commit modifying a line 3 rows below the cited line does NOT auto-annotate" {
  # Regression for the whole-hunk-range bug: line 3 sits in the leading
  # context of the hunk that edits line 6, but is never removed. The body
  # parser must exclude it — only line 6 is a removal range.
  mkdir -p src
  printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n' > src/foo.py
  git add -A && git commit -q -m "seed"
  fi_run log "src/foo.py:3 — bug at line 3"
  printf 'l1\nl2\nl3\nl4\nl5\nFIX6\nl7\nl8\nl9\nl10\n' > src/foo.py
  git add -A && git commit -q -m "fix line 6"
  fi_run annotate-commit HEAD --hook-auto
  [ "$status" -eq 3 ]
  [[ "$output" == *"src/foo.py:3"* ]]
  run grep -q '(commit:' docs/found-issues.md
  [ "$status" -ne 0 ]
}

# === line-range entries vs hunk overlap (v2.2.4) ===
#
# v2.2.3 (#137) split `:23-49` into a numeric start plus line_end, and
# fi_line_matched kept testing the START alone. A range whose start sits
# outside every changed hunk while its BODY overlaps one therefore never
# auto-annotated. Overlap is `start <= hunk_end && end >= hunk_start`.

# Removes old-side line 35 only, so the sole removal range is 35-35.
mk_mid_hunk_mocks() {
  export GH_MOCK_PR_VIEW=$'7\tsrc/foo.py'
  export GH_MOCK_PR_DIFF='diff --git a/src/foo.py b/src/foo.py\n--- a/src/foo.py\n+++ b/src/foo.py\n@@ -33,5 +33,5 @@\n ctx33\n ctx34\n-old35\n+new35\n ctx36\n ctx37'
}

@test "hook-auto: range entry whose body overlaps a hunk annotates though its start does not" {
  mkdir -p docs
  printf '# found-issues\n\n' > docs/found-issues.md
  printf -- '- [open] 2026-08-11 src/foo.py:23-49 — handler drops errors\n' >> docs/found-issues.md
  mk_mid_hunk_mocks
  fi_run annotate-pr 7 --hook-auto
  [ "$status" -eq 0 ]
  grep -q 'src/foo.py:23-49 .*(PR: org/repo#7)' docs/found-issues.md
}

@test "hook-auto: range entry ending before every hunk still becomes a candidate, exit 3" {
  mkdir -p docs
  printf '# found-issues\n\n' > docs/found-issues.md
  printf -- '- [open] 2026-08-11 src/foo.py:5-10 — early bug\n' >> docs/found-issues.md
  mk_mid_hunk_mocks
  fi_run annotate-pr 7 --hook-auto
  [ "$status" -eq 3 ]
  [[ "$output" == *"src/foo.py:5-10"* ]]
  run grep -q '(PR: org/repo#7)' docs/found-issues.md
  [ "$status" -ne 0 ]
}

@test "hook-auto: range entry starting after every hunk still becomes a candidate, exit 3" {
  mkdir -p docs
  printf '# found-issues\n\n' > docs/found-issues.md
  printf -- '- [open] 2026-08-11 src/foo.py:60-70 — late bug\n' >> docs/found-issues.md
  mk_mid_hunk_mocks
  fi_run annotate-pr 7 --hook-auto
  [ "$status" -eq 3 ]
  [[ "$output" == *"src/foo.py:60-70"* ]]
  run grep -q '(PR: org/repo#7)' docs/found-issues.md
  [ "$status" -ne 0 ]
}

@test "hook-auto: range entry whose start is inside a hunk still annotates" {
  mkdir -p docs
  printf '# found-issues\n\n' > docs/found-issues.md
  printf -- '- [open] 2026-08-11 src/foo.py:35-40 — starts on the changed line\n' >> docs/found-issues.md
  mk_mid_hunk_mocks
  fi_run annotate-pr 7 --hook-auto
  [ "$status" -eq 0 ]
  grep -q 'src/foo.py:35-40 .*(PR: org/repo#7)' docs/found-issues.md
}

@test "hook-auto: a deleted '-- comment' before a second same-file hunk annotates the right entry" {
  # Regression for the '^--- ' body misparse: a deleted SQL comment renders
  # as '--- old comment' in the diff and used to be read as a file header,
  # stealing the SECOND hunk's path so its removal range never matched.
  fi_run log "db/schema.sql:51 — wrong default"
  export GH_MOCK_PR_VIEW=$'7\tdb/schema.sql'
  export GH_MOCK_PR_DIFF='diff --git a/db/schema.sql b/db/schema.sql\n--- a/db/schema.sql\n+++ b/db/schema.sql\n@@ -10,3 +10,3 @@\n ctx10\n--- old comment\n+-- new comment\n ctx12\n@@ -50,3 +50,3 @@\n ctx50\n-old51\n+new51\n ctx52'
  fi_run annotate-pr 7 --hook-auto
  [ "$status" -eq 0 ]
  grep -q 'db/schema.sql:51 .*(PR: org/repo#7)' docs/found-issues.md
}
