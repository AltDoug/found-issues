#!/usr/bin/env bats
# Batch 6: an older found-issues CLI that rejects --hook-auto (rc 2) no
# longer swallows the post-bash annotation routes silently; the hook falls
# back to the manual prompt and says why (ledger hooks/post-bash-dispatch.sh:232).

load 'helpers'

HOOK="$TEST_REPO_ROOT/hooks/post-bash-dispatch.sh"

setup() {
  fi_setup_tmp
  fi_init_git
  fi_init_github_repo "org/repo"
  fi_use_gh_shim
  export GH_MOCK_REPO_VIEW='{"nameWithOwner":"org/repo"}'
  export CLAUDE_CODE_ENTRYPOINT=cli
  # An old CLI: annotate-pr / annotate-commit reject --hook-auto with rc 2,
  # everything else is the real CLI.
  mkdir -p "$TMP/oldbin"
  cat >"$TMP/oldbin/found-issues" <<EOF
#!/usr/bin/env bash
case "\$1 \$*" in
  annotate-*--hook-auto*) echo "\$1: unknown flag: --hook-auto" >&2; exit 2 ;;
esac
exec "$FI_BIN" "\$@"
EOF
  chmod +x "$TMP/oldbin/found-issues"
  export FOUND_ISSUES_BIN="$TMP/oldbin/found-issues"
}
teardown() { fi_teardown_tmp; }

payload() { # $1=command $2=stdout
  jq -nc --arg c "$1" --arg s "$2" \
    '{tool_name:"Bash", tool_input:{command:$c}, tool_response:{stdout:$s, exit_code:"0"}}'
}
run_hook() { payload "$1" "${2:-}" | "$HOOK"; }

@test "b6 skew: pr create with a CLI that rejects --hook-auto falls back to the manual prompt" {
  "$FI_BIN" log "src/foo.py:42 — null check" >/dev/null
  export GH_MOCK_PR_VIEW=$'7\tsrc/foo.py'
  run run_hook 'gh pr create --fill' 'https://github.com/org/repo/pull/7'
  [ "$status" -eq 0 ]
  [[ "$output" == *"/found-issues:annotate-pr 7"* ]]
  [[ "$output" == *"--hook-auto"* ]]
  [[ "$output" == *"$TMP/oldbin/found-issues"* ]]
  run grep -q '(PR' docs/found-issues.md
  [ "$status" -ne 0 ]
}

@test "b6 skew: git commit with a CLI that rejects --hook-auto falls back to the manual prompt" {
  mkdir -p src
  printf 'l1\nl2\nl3\n' > src/foo.py
  git add -A && git commit -q -m seed
  "$FI_BIN" log "src/foo.py:2 — bug" >/dev/null
  printf 'l1\nFIX\nl3\n' > src/foo.py
  git add -A && git commit -q -m fix
  run run_hook 'git commit -m fix' ''
  [ "$status" -eq 0 ]
  [[ "$output" == *"/found-issues:annotate-commit"* ]]
  [[ "$output" == *"--hook-auto"* ]]
  run grep -q '(commit' docs/found-issues.md
  [ "$status" -ne 0 ]
}

@test "b6 skew: a CLI that supports --hook-auto never gets the skew note" {
  export FOUND_ISSUES_BIN="$FI_BIN"
  "$FI_BIN" log "src/foo.py:99 — wrong cast" >/dev/null
  export GH_MOCK_PR_VIEW=$'7\tsrc/foo.py'
  export GH_MOCK_PR_DIFF='diff --git a/src/foo.py b/src/foo.py\n--- a/src/foo.py\n+++ b/src/foo.py\n@@ -40,6 +40,7 @@\n ctx40\n-old42\n+new42\n ctx43'
  run run_hook 'gh pr create' 'https://github.com/org/repo/pull/7'
  [ "$status" -eq 0 ]
  [[ "$output" == *"found-issues annotate-pr 7 --pick"* ]]
  [[ "$output" != *"rejected --hook-auto"* ]]
}
