#!/usr/bin/env bats
# Ledger-fix batch 3: install-codex-hooks checks hook scripts exist;
# fi_repo_id lives in lib/repo-id.sh and the pr-create hook uses it.

load 'helpers'
load 'autofix-helpers'

HOOK="$TEST_REPO_ROOT/hooks/post-bash-dispatch.sh"

setup() { fi_setup_tmp; }
teardown() { fi_teardown_tmp; }

# --- install-codex-hooks: wired hook scripts must exist ---

@test "install-codex-hooks: a missing hook script fails and names its path" {
  CODEX_HOME="$TMP/codex-home"
  copy_root="$TMP/root"
  mkdir -p "$copy_root"
  cp -R "$TEST_REPO_ROOT/bin" "$TEST_REPO_ROOT/lib" "$TEST_REPO_ROOT/hooks" "$copy_root/"
  chmod +x "$copy_root/bin/found-issues"
  rm "$copy_root/hooks/stop-reminder.sh"
  run "$copy_root/bin/found-issues" install-codex-hooks --codex-home "$CODEX_HOME"
  [ "$status" -ne 0 ]
  [[ "$output" == *"hooks/stop-reminder.sh"* ]]
  [ ! -f "$CODEX_HOME/hooks.json" ] || ! jq -e '.hooks.Stop' "$CODEX_HOME/hooks.json" >/dev/null 2>&1
}

@test "install-codex-hooks: non-executable but present hook scripts still install" {
  CODEX_HOME="$TMP/codex-home"
  copy_root="$TMP/root"
  mkdir -p "$copy_root"
  cp -R "$TEST_REPO_ROOT/bin" "$TEST_REPO_ROOT/lib" "$TEST_REPO_ROOT/hooks" "$copy_root/"
  chmod +x "$copy_root/bin/found-issues"
  chmod -x "$copy_root/hooks/session-start.sh"
  run "$copy_root/bin/found-issues" install-codex-hooks --codex-home "$CODEX_HOME"
  [ "$status" -eq 0 ]
}

# --- fi_repo_id in its own lib; hook agrees with the CLI ---

@test "repo-id: lib/repo-id.sh defines fi_repo_id and the CLI sources it" {
  [ -f "$TEST_REPO_ROOT/lib/repo-id.sh" ]
  grep -q '^fi_repo_id()' "$TEST_REPO_ROOT/lib/repo-id.sh"
  ! grep -q '^fi_repo_id()' "$TEST_REPO_ROOT/bin/found-issues" || false
  grep -q 'repo-id.sh' "$TEST_REPO_ROOT/bin/found-issues"
}

@test "repo-id: fi_repo_id handles ssh form with trailing slash and .git" {
  git init -q .
  git remote add origin 'git@github.com:Org/my.repo.git/'
  fi_source_lib repo-id
  run fi_repo_id
  [ "$status" -eq 0 ]
  [ "$output" = "Org/my.repo" ]
}

@test "pr create hook: an edge remote with extra path segments skips another repo's PR" {
  fi_init_git
  fi_init_github_repo "org/repo"
  git remote set-url origin 'https://github.com/org/repo/tree/main/'
  [ "$(fi_run status >/dev/null; bash -c "source '$FI_LIB_DIR/repo-id.sh'; fi_repo_id")" = "org/repo" ]
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

@test "pr create hook: ssh remote with trailing slash still annotates the same repo's PR" {
  fi_init_git
  fi_init_github_repo "org/repo"
  git remote set-url origin 'git@github.com:org/repo.git/'
  fi_use_gh_shim
  export GH_MOCK_REPO_VIEW='{"nameWithOwner":"org/repo"}'
  export FOUND_ISSUES_BIN="$FI_BIN"
  export CLAUDE_CODE_ENTRYPOINT=cli
  fi_run log "src/foo.py:42 — null check"
  export GH_MOCK_PR_VIEW=$'7\tsrc/foo.py'
  export GH_MOCK_PR_DIFF='diff --git a/src/foo.py b/src/foo.py\n--- a/src/foo.py\n+++ b/src/foo.py\n@@ -40,6 +40,7 @@\n ctx40\n ctx41\n-old42\n+new42\n+added\n ctx43\n ctx44\n ctx45'
  payload="$(jq -nc --arg c 'gh pr create --fill' --arg s 'https://github.com/org/repo/pull/7' \
    '{tool_name:"Bash", tool_input:{command:$c}, tool_response:{stdout:$s, exit_code:"0"}}')"
  run bash -c 'printf "%s" "$1" | "$2"' _ "$payload" "$HOOK"
  [ "$status" -eq 0 ]
  grep -q '(PR-auto: org/repo#7)' docs/found-issues.md
}
