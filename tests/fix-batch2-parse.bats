#!/usr/bin/env bats
# Ledger-fix batch 2: git-root-bounded discovery, tail-only counters,
# cross-repo PR annotate skip, nested-ledger wrench count.

load 'helpers'
load 'autofix-helpers'

HOOK="$TEST_REPO_ROOT/hooks/post-bash-dispatch.sh"

setup() { fi_setup_tmp; }
teardown() { fi_teardown_tmp; }

# --- fi_find_issues_file stops at the git toplevel ---

@test "find_issues_file: a git repo without a ledger does not find the parent dir's ledger" {
  fi_source_lib parse-entries
  mkdir -p parent/docs parent/child
  echo "# found-issues" > parent/docs/found-issues.md
  git init -q parent/child
  run fi_find_issues_file "$TMP/parent/child"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "find_issues_file: a non-git child still finds the parent ledger" {
  fi_source_lib parse-entries
  mkdir -p parent/docs parent/child
  echo "# found-issues" > parent/docs/found-issues.md
  run fi_find_issues_file "$TMP/parent/child"
  [ "$status" -eq 0 ]
  [[ "$output" == */parent/docs/found-issues.md ]]
}

@test "find_issues_file: a nested package ledger inside the repo is still found" {
  fi_source_lib parse-entries
  mkdir -p repo/pkg/docs repo/pkg/src
  git init -q repo
  echo "# found-issues" > repo/pkg/docs/found-issues.md
  run fi_find_issues_file "$TMP/repo/pkg/src"
  [ "$status" -eq 0 ]
  [[ "$output" == */repo/pkg/docs/found-issues.md ]]
}

@test "find_issues_file: the repo root ledger is found from a subdirectory of the repo" {
  fi_source_lib parse-entries
  mkdir -p repo/docs repo/a/b
  git init -q repo
  echo "# found-issues" > repo/docs/found-issues.md
  run fi_find_issues_file "$TMP/repo/a/b"
  [ "$status" -eq 0 ]
  [[ "$output" == */repo/docs/found-issues.md ]]
}

@test "find_issues_file: a git file (worktree or submodule) also bounds the walk" {
  fi_source_lib parse-entries
  mkdir -p parent/docs parent/sub
  echo "# found-issues" > parent/docs/found-issues.md
  echo "gitdir: ../.git/modules/sub" > parent/sub/.git
  run fi_find_issues_file "$TMP/parent/sub"
  [ "$status" -ne 0 ]
}

# --- counters read the annotation tail only ---

@test "counters: a PR tag mentioned mid-line is not in_pr and counts as residual" {
  fi_init_git
  mkdir -p docs
  cat > docs/found-issues.md <<'LEDGER'
# found-issues

- [open] 2026-10-09 src/a.sh:1 — see the fix in (PR: org/repo#9) for the pattern (suggested: copy it)
- [open] 2026-10-09 src/b.sh:1 — real bug (PR: org/repo#10)
LEDGER
  run "$FI_BIN" status --format=json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q '"in_pr":1' || false
  printf '%s' "$output" | grep -q '"issues":1' || false
}

@test "counters: a decide tag mentioned mid-line is not a decision, a trailing one is" {
  fi_source_lib parse-entries
  cat > l.md <<'LEDGER'
# found-issues

- [open] 2026-10-09 src/a.sh:1 — docs say (decide: x) is used for choices (suggested: reword)
- [open] 2026-10-09 src/b.sh:1 — pick one (decide: floor or round?)
LEDGER
  [ "$(fi_count_decide l.md)" = 1 ]
}

@test "counters: a CRLF ledger still counts PR and decide tags in the tail" {
  fi_init_git
  mkdir -p docs
  printf '# found-issues\r\n\r\n- [open] 2026-10-09 src/a.sh:1 \xe2\x80\x94 real bug (PR: org/repo#9)\r\n- [open] 2026-10-09 src/b.sh:1 \xe2\x80\x94 open question (decide: which way?)\r\n' > docs/found-issues.md
  run "$FI_BIN" status --format=json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q '"in_pr":1' || false
  printf '%s' "$output" | grep -q '"decisions":1' || false
}

@test "counters: a demoted tag mentioned mid-line is not stale" {
  fi_source_lib parse-entries
  local today
  today="$(date +%Y-%m-%d)"
  cat > l.md <<LEDGER
# found-issues

- [open] $today src/a.sh:1 — the (PR-closed: o/r#3) form is documented here (suggested: none)
- [open] $today src/b.sh:1 — bug (PR-closed: o/r#4)
LEDGER
  [ "$(fi_count_stale l.md 30)" = 1 ]
}

# --- post-bash hook skips a PR opened in another repo ---

@test "pr create: a PR URL for a different repo is not annotated against this repo" {
  fi_init_git
  fi_init_github_repo "org/repo"
  fi_use_gh_shim
  export GH_MOCK_REPO_VIEW='{"nameWithOwner":"org/repo"}'
  export FOUND_ISSUES_BIN="$FI_BIN"
  export CLAUDE_CODE_ENTRYPOINT=cli
  fi_run log "src/foo.py:42 — null check"
  export GH_MOCK_PR_VIEW=$'42\tsrc/foo.py'
  export GH_MOCK_PR_DIFF='diff --git a/src/foo.py b/src/foo.py\n--- a/src/foo.py\n+++ b/src/foo.py\n@@ -40,6 +40,7 @@\n ctx40\n ctx41\n-old42\n+new42\n+added\n ctx43\n ctx44\n ctx45'
  payload="$(jq -nc --arg c 'gh pr create --fill' --arg s 'https://github.com/other/repo/pull/42' \
    '{tool_name:"Bash", tool_input:{command:$c}, tool_response:{stdout:$s, exit_code:"0"}}')"
  run bash -c 'printf "%s" "$1" | "$2"' _ "$payload" "$HOOK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  ! grep -q 'PR-auto' docs/found-issues.md || false
}

@test "pr create: the same slug in a different case is still annotated" {
  fi_init_git
  fi_init_github_repo "org/repo"
  fi_use_gh_shim
  export GH_MOCK_REPO_VIEW='{"nameWithOwner":"org/repo"}'
  export FOUND_ISSUES_BIN="$FI_BIN"
  export CLAUDE_CODE_ENTRYPOINT=cli
  fi_run log "src/foo.py:42 — null check"
  export GH_MOCK_PR_VIEW=$'7\tsrc/foo.py'
  export GH_MOCK_PR_DIFF='diff --git a/src/foo.py b/src/foo.py\n--- a/src/foo.py\n+++ b/src/foo.py\n@@ -40,6 +40,7 @@\n ctx40\n ctx41\n-old42\n+new42\n+added\n ctx43\n ctx44\n ctx45'
  payload="$(jq -nc --arg c 'gh pr create --fill' --arg s 'https://github.com/ORG/Repo/pull/7' \
    '{tool_name:"Bash", tool_input:{command:$c}, tool_response:{stdout:$s, exit_code:"0"}}')"
  run bash -c 'printf "%s" "$1" | "$2"' _ "$payload" "$HOOK"
  [ "$status" -eq 0 ]
  grep -q '(PR-auto: org/repo#7)' docs/found-issues.md
}

# --- wrench count for a nested ledger ---

@test "segment: a nested package ledger shows the wrench count keyed by the git toplevel" {
  fi_af_fixture
  export FOUND_ISSUES_CACHE_DIR="$TMP/cache"
  mkdir -p pkg/docs
  printf '# found-issues\n\n- [open] 2026-10-01 pkg/x.sh:1 — nested bug\n' > pkg/docs/found-issues.md
  mkdir -p "$FOUND_ISSUES_STATE_DIR/autofix/seg"
  printf '2\n' > "$FOUND_ISSUES_STATE_DIR/autofix/seg/${REPO//[^A-Za-z0-9._-]/_}"
  run "$FI_BIN" status --format segment --cwd "$REPO/pkg"
  [[ "$output" == *"🔧2"* ]]
  # and again from the warm fast path
  run "$FI_BIN" status --format segment --cwd "$REPO/pkg"
  [[ "$output" == *"🔧2"* ]]
}
