#!/usr/bin/env bats
# Tests for hooks/post-bash-dispatch.sh — the plugin's single PostToolUse(Bash)
# hook, replacing post-pr-create.sh, post-git-commit.sh, and post-pr-state.sh.
# Routes: gh pr create / git commit (auto-annotate via --hook-auto, surfacing
# only judgment-needed candidates) and gh pr merge|close|reopen (background
# sync, unchanged from the retired post-pr-state.sh).
#
# This file also ports every assertion from the retired
# tests/post-pr-state.bats (prefixed "post-pr-state:" below) so the
# merge/close/reopen route keeps full coverage under the new dispatcher.

load 'helpers'

HOOK="$TEST_REPO_ROOT/hooks/post-bash-dispatch.sh"

setup() {
  fi_setup_tmp
  fi_init_git
  fi_init_github_repo "org/repo"
  fi_use_gh_shim
  export GH_MOCK_REPO_VIEW='{"nameWithOwner":"org/repo"}'
  export FOUND_ISSUES_BIN="$FI_BIN"
  export CLAUDE_CODE_ENTRYPOINT=cli
}

teardown() { fi_teardown_tmp; }

# Build a synthetic PostToolUse(Bash) payload.
#
# NOTE ON A DESIGN-DOC BUG: the design doc sketches this as
# `run bash -c "$(payload ...) | '$HOOK'"`. That does NOT work — jq's
# default output is pretty-printed (multi-line), so once the command
# substitution splices it into the `bash -c "..."` string, bash parses the
# JSON's own tokens (`tool_name:`, `{`, ...) as shell script text instead of
# piping it to the hook as stdin data; the hook then reads empty stdin and
# every test would pass vacuously. Fixed here by calling the builder as a
# real shell function and piping its output directly (`payload | "$HOOK"`),
# with `-c` for compact single-line JSON (irrelevant to the bug but tidier
# to eyeball on failure).
payload() { # $1=command $2=stdout
  jq -nc --arg c "$1" --arg s "$2" \
    '{tool_name:"Bash", tool_input:{command:$c}, tool_response:{stdout:$s, exit_code:"0"}}'
}

run_hook() { # $1=command $2=stdout(optional)
  payload "$1" "${2:-}" | "$HOOK"
}

# For payloads that don't fit the Bash-only shape above (e.g. a non-Bash
# tool_name), pipe raw JSON straight through.
run_hook_raw() { # $1=raw json
  printf '%s' "$1" | "$HOOK"
}

@test "pr create: line-matched entry auto-annotates, one-line report" {
  fi_run log "src/foo.py:42 — null check"
  export GH_MOCK_PR_VIEW=$'7\tsrc/foo.py'
  export GH_MOCK_PR_DIFF='diff --git a/src/foo.py b/src/foo.py\n--- a/src/foo.py\n+++ b/src/foo.py\n@@ -40,6 +40,7 @@\n ctx40\n ctx41\n-old42\n+new42\n+added\n ctx43\n ctx44\n ctx45'
  run run_hook 'gh pr create --fill' 'https://github.com/org/repo/pull/7'
  [ "$status" -eq 0 ]
  grep -q '(PR: org/repo#7)' docs/found-issues.md
  [[ "$output" == *"auto-annotated"* ]]
  [[ "$output" != *"--pick"* ]]
}

@test "pr create: unmatched-line candidates surface with pick instruction" {
  fi_run log "src/foo.py:99 — wrong cast"
  export GH_MOCK_PR_VIEW=$'7\tsrc/foo.py'
  export GH_MOCK_PR_DIFF='diff --git a/src/foo.py b/src/foo.py\n--- a/src/foo.py\n+++ b/src/foo.py\n@@ -40,6 +40,7 @@\n ctx40\n ctx41\n-old42\n+new42\n+added\n ctx43\n ctx44\n ctx45'
  run run_hook 'gh pr create' 'https://github.com/org/repo/pull/7'
  [ "$status" -eq 0 ]
  [[ "$output" == *"found-issues annotate-pr 7 --pick"* ]]
  run grep -q '(PR:' docs/found-issues.md
  [ "$status" -ne 0 ]
}

@test "pr create: FOUND_ISSUES_AUTO_ANNOTATE=off falls back to legacy prompt" {
  export FOUND_ISSUES_AUTO_ANNOTATE=off
  fi_run log "src/foo.py:42 — null check"
  export GH_MOCK_PR_VIEW=$'7\tsrc/foo.py'
  run run_hook 'gh pr create' 'https://github.com/org/repo/pull/7'
  [ "$status" -eq 0 ]
  [[ "$output" == *"/found-issues:annotate-pr 7"* ]]
  run grep -q '(PR:' docs/found-issues.md
  [ "$status" -ne 0 ]
}

@test "git commit: line-matched entry auto-annotates" {
  mkdir -p src
  printf 'l1\nl2\nl3\n' > src/foo.py
  git add -A && git commit -q -m seed
  fi_run log "src/foo.py:2 — bug"
  printf 'l1\nFIX\nl3\n' > src/foo.py
  git add -A && git commit -q -m fix
  run run_hook 'git commit -m fix' ''
  [ "$status" -eq 0 ]
  grep -q '(commit:' docs/found-issues.md
}

@test "git commit: message mentioning gh pr create still triggers commit route" {
  # Regression test for the route-shadow finding: the pr-create route used
  # to match ANY command containing the substring "gh pr create" (even one
  # sitting inside a git commit message) and exit early, so the commit
  # route below it never ran. The routes are now evaluated independently.
  mkdir -p src
  printf 'l1\nl2\nl3\n' > src/foo.py
  git add -A && git commit -q -m seed
  fi_run log "src/foo.py:2 — bug"
  printf 'l1\nFIX\nl3\n' > src/foo.py
  git add -A && git commit -q -m "add gh pr create hook"
  run run_hook 'git commit -m "add gh pr create hook"' ''
  [ "$status" -eq 0 ]
  grep -q '(commit:' docs/found-issues.md
}

@test "chained git commit and gh pr create: both routes annotate independently" {
  mkdir -p src
  printf 'l1\nl2\nl3\n' > src/foo.py
  git add -A && git commit -q -m seed
  fi_run log "src/foo.py:2 — bug"
  fi_run log "src/bar.py:42 — wrong cast"
  printf 'l1\nFIX\nl3\n' > src/foo.py
  git add -A && git commit -q -m fix
  export GH_MOCK_PR_VIEW=$'7\tsrc/bar.py'
  export GH_MOCK_PR_DIFF='diff --git a/src/bar.py b/src/bar.py\n--- a/src/bar.py\n+++ b/src/bar.py\n@@ -40,6 +40,7 @@\n ctx40\n ctx41\n-old42\n+new42\n+added\n ctx43\n ctx44\n ctx45'
  run run_hook 'git commit -m fix && gh pr create' 'https://github.com/org/repo/pull/7'
  [ "$status" -eq 0 ]
  grep -q 'src/foo.py:2 .*(commit:' docs/found-issues.md
  grep -q 'src/bar.py:42 .*(PR: org/repo#7)' docs/found-issues.md
}

@test "merge route non-exclusive: chained git commit and gh pr merge both fire" {
  # Regression test for the second route-shadow finding: the merge/close/
  # reopen route used to exit early (its own `exit 0`) BEFORE the pr-create
  # and git-commit routes, so a chained `git commit -m fix && gh pr merge 7`
  # never reached the commit-annotation route below it. The merge route is
  # now evaluated LAST and no longer exits early, so both the commit
  # annotation and the background sync fire from one combined command.
  mkdir -p src
  printf 'l1\nl2\nl3\n' > src/foo.py
  git add -A && git commit -q -m seed
  fi_run log "src/foo.py:2 — bug"
  printf 'l1\nFIX\nl3\n' > src/foo.py
  git add -A && git commit -q -m fix
  marker="$TMP/sync-ran"
  export FOUND_ISSUES_AUTOSYNC_CMD="touch '$marker'"
  run run_hook 'git commit -m fix && gh pr merge 7 --squash' ''
  [ "$status" -eq 0 ]
  grep -q 'src/foo.py:2 .*(commit:' docs/found-issues.md
  for i in 1 2 3 4 5; do [ -f "$marker" ] && break; sleep 1; done
  [ -f "$marker" ]
}

@test "merge route ordering: autosync snapshot already contains the commit annotation" {
  # Proves the merge route's background sync is spawned AFTER the
  # synchronous commit-annotation route has already written to the ledger,
  # rather than racing it: FOUND_ISSUES_AUTOSYNC_CMD snapshots
  # docs/found-issues.md into a separate file the moment it runs, and that
  # snapshot already shows the (commit:) annotation.
  mkdir -p src
  printf 'l1\nl2\nl3\n' > src/foo.py
  git add -A && git commit -q -m seed
  fi_run log "src/foo.py:2 — bug"
  printf 'l1\nFIX\nl3\n' > src/foo.py
  git add -A && git commit -q -m fix
  snap="$TMP/snap.md"
  export FOUND_ISSUES_AUTOSYNC_CMD="cp '$TMP/docs/found-issues.md' '$snap'"
  run run_hook 'git commit -m fix && gh pr merge 7 --squash' ''
  [ "$status" -eq 0 ]
  for i in 1 2 3 4 5; do [ -f "$snap" ] && break; sleep 1; done
  [ -f "$snap" ]
  grep -q 'src/foo.py:2 .*(commit:' "$snap"
}

@test "missing harness lib: hook exits 0 and still emits plain text" {
  # Fail-open regression test: harness.sh (and thus fi_emit_post_context)
  # is missing from the resolved lib dir, but the default auto-annotate
  # path still needs every lib file bin/found-issues sources for itself —
  # so this copies the real lib dir minus harness.sh, rather than pointing
  # at a truly empty directory, which would also break the found-issues
  # binary the hook shells out to.
  #
  # Copy-all-then-remove rather than naming the survivors: the CLI's source
  # list grows as the tracked cmd_* extraction moves groups into lib/, and a
  # hand-maintained list turns each of those moves into an unrelated failure
  # here (v2.2.5 statusline extraction was the first).
  fi_run log "src/foo.py:99 — wrong cast"
  export GH_MOCK_PR_VIEW=$'7\tsrc/foo.py'
  export GH_MOCK_PR_DIFF='diff --git a/src/foo.py b/src/foo.py\n--- a/src/foo.py\n+++ b/src/foo.py\n@@ -40,6 +40,7 @@\n ctx40\n ctx41\n-old42\n+new42\n+added\n ctx43\n ctx44\n ctx45'
  local libcopy="$TMP/lib-no-harness"
  mkdir -p "$libcopy"
  cp "$FI_LIB_DIR"/*.sh "$libcopy"/
  rm -f "$libcopy/harness.sh"
  export FOUND_ISSUES_LIB_DIR="$libcopy"
  run run_hook 'gh pr create' 'https://github.com/org/repo/pull/7'
  [ "$status" -eq 0 ]
  [[ "$output" == *"found-issues annotate-pr 7 --pick"* ]]
}

@test "unrelated bash command: silent exit 0" {
  run run_hook 'ls -la' ''
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pr merge: dispatches background sync via FOUND_ISSUES_AUTOSYNC_CMD" {
  marker="$TMP/sync-ran"
  export FOUND_ISSUES_AUTOSYNC_CMD="touch '$marker'"
  run run_hook 'gh pr merge 7 --squash' ''
  [ "$status" -eq 0 ]
  for i in 1 2 3 4 5; do [ -f "$marker" ] && break; sleep 1; done
  [ -f "$marker" ]
}

@test "codex harness: candidate surface is additionalContext JSON" {
  unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
  export PLUGIN_DATA="$TMP/plugdata"
  fi_run log "src/foo.py:99 — wrong cast"
  export GH_MOCK_PR_VIEW=$'7\tsrc/foo.py'
  export GH_MOCK_PR_DIFF='diff --git a/src/foo.py b/src/foo.py\n--- a/src/foo.py\n+++ b/src/foo.py\n@@ -40,6 +40,7 @@\n ctx40\n ctx41\n-old42\n+new42\n+added\n ctx43\n ctx44\n ctx45'
  run run_hook 'gh pr create' 'https://github.com/org/repo/pull/7'
  [ "$status" -eq 0 ]
  # Verified against Codex 0.144.5's PostToolUse hook-output schema (Task 11):
  # additionalContext nests under hookSpecificOutput with hookEventName.
  printf '%s' "$output" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')" = "PostToolUse" ]
}

# --- ported from the retired tests/post-pr-state.bats ---

@test "post-pr-state: fires sync on 'gh pr merge'" {
  marker="$TMP/sync-marker"
  export FOUND_ISSUES_AUTOSYNC_CMD="touch '$marker'"
  run run_hook 'gh pr merge 42 --squash' ''
  [ "$status" -eq 0 ]
  for i in 1 2 3 4 5; do [ -f "$marker" ] && break; sleep 1; done
  [ -f "$marker" ]
}

@test "post-pr-state: fires sync on 'gh pr close'" {
  marker="$TMP/sync-marker"
  export FOUND_ISSUES_AUTOSYNC_CMD="touch '$marker'"
  run run_hook 'gh pr close 7' ''
  [ "$status" -eq 0 ]
  for i in 1 2 3 4 5; do [ -f "$marker" ] && break; sleep 1; done
  [ -f "$marker" ]
}

@test "post-pr-state: fires sync on 'gh pr reopen'" {
  marker="$TMP/sync-marker"
  export FOUND_ISSUES_AUTOSYNC_CMD="touch '$marker'"
  run run_hook 'gh pr reopen 7' ''
  [ "$status" -eq 0 ]
  for i in 1 2 3 4 5; do [ -f "$marker" ] && break; sleep 1; done
  [ -f "$marker" ]
}

@test "post-pr-state: fires sync when 'gh pr merge' appears after '&&'" {
  marker="$TMP/sync-marker"
  export FOUND_ISSUES_AUTOSYNC_CMD="touch '$marker'"
  run run_hook 'git push && gh pr merge --auto' ''
  [ "$status" -eq 0 ]
  for i in 1 2 3 4 5; do [ -f "$marker" ] && break; sleep 1; done
  [ -f "$marker" ]
}

@test "post-pr-state: does NOT fire on 'gh pr create'" {
  # gh pr create is the annotate route's territory; the merge/close/reopen
  # route should ignore it so we don't double-spawn sync.
  marker="$TMP/sync-marker"
  export FOUND_ISSUES_AUTOSYNC_CMD="touch '$marker'"
  run run_hook 'gh pr create --title foo' ''
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
}

@test "post-pr-state: does NOT fire on unrelated Bash" {
  marker="$TMP/sync-marker"
  export FOUND_ISSUES_AUTOSYNC_CMD="touch '$marker'"
  run run_hook 'ls -la' ''
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
}

@test "post-pr-state: does NOT fire on 'git push'" {
  marker="$TMP/sync-marker"
  export FOUND_ISSUES_AUTOSYNC_CMD="touch '$marker'"
  run run_hook 'git push origin main' ''
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
}

@test "post-pr-state: substring match avoids false positives ('mergeable' in another arg)" {
  marker="$TMP/sync-marker"
  export FOUND_ISSUES_AUTOSYNC_CMD="touch '$marker'"
  run run_hook "echo 'mergeable status'" ''
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
}

@test "post-pr-state: respects FOUND_ISSUES_POST_PR_STATE=off" {
  marker="$TMP/sync-marker"
  export FOUND_ISSUES_AUTOSYNC_CMD="touch '$marker'"
  export FOUND_ISSUES_POST_PR_STATE=off
  run run_hook 'gh pr merge 42' ''
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
}

@test "post-pr-state: ignores non-Bash tool events" {
  marker="$TMP/sync-marker"
  export FOUND_ISSUES_AUTOSYNC_CMD="touch '$marker'"
  run run_hook_raw '{"hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"foo"}}'
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
}

@test "post-pr-state: default dispatch survives a CLI path containing a space" {
  marker="$TMP/sync-marker"
  mkdir -p "$TMP/spaced dir"
  cat > "$TMP/spaced dir/fi-mock" <<MOCK
#!/usr/bin/env bash
[[ "\$1" == "sync" ]] && touch "$marker"
MOCK
  chmod +x "$TMP/spaced dir/fi-mock"
  export FOUND_ISSUES_BIN="$TMP/spaced dir/fi-mock"
  run run_hook 'gh pr merge 12 --squash' ''
  [ "$status" -eq 0 ]
  for i in 1 2 3 4 5; do [ -f "$marker" ] && break; sleep 1; done
  [ -f "$marker" ]
}
