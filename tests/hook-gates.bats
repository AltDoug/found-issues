#!/usr/bin/env bats
# Tests for lib/hook-gate.sh — the zero-fork relevance gates in front of
# hooks/pre-branch-delete.sh and hooks/post-bash-dispatch.sh.
#
# Two properties:
#   1. Early exit: a command no route cares about leaves the hook before its
#      first external command (a jq shim on PATH records any call).
#   2. Zero behaviour change: for every command in the corpora below, the hook
#      with gates ON and with FOUND_ISSUES_HOOK_GATES=off gives the same exit
#      code, stdout and stderr, and (post hook) dispatches the same CLI calls.

load 'helpers'

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
PRE="$REPO_ROOT/hooks/pre-branch-delete.sh"
POST="$REPO_ROOT/hooks/post-bash-dispatch.sh"

setup() {
  fi_setup_tmp
  fi_init_git
  # jq shim: records every call, then runs the real jq.
  REAL_JQ="$(command -v jq)"
  mkdir -p "$TMP/shim"
  printf '#!/usr/bin/env bash\necho jq >>"%s/jq-calls"\nexec "%s" "$@"\n' "$TMP" "$REAL_JQ" >"$TMP/shim/jq"
  chmod +x "$TMP/shim/jq"
  export PATH="$TMP/shim:$PATH"
}

teardown() {
  unset FOUND_ISSUES_HOOK_GATES FOUND_ISSUES_BIN FOUND_ISSUES_AUTOSYNC_CMD
  fi_teardown_tmp
}

# payload <event> <command> [stdout] — a Claude Code shaped hook payload.
payload() {
  if [[ "$1" == pre ]]; then
    "$REAL_JQ" -cn --arg c "$2" \
      '{session_id:"s",cwd:"/x",hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c,description:"d"}}'
  else
    "$REAL_JQ" -cn --arg c "$2" --arg o "${3:-}" \
      '{session_id:"s",cwd:"/x",hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$c,description:"d"},tool_response:{stdout:$o,stderr:"",interrupted:false}}'
  fi
}

# run_hook <hook> <payload-file> <label> — stdout/stderr/rc into $TMP/<label>.*
run_hook() {
  local rc=0
  bash "$1" <"$2" >"$TMP/$3.out" 2>"$TMP/$3.err" || rc=$?
  echo "$rc" >"$TMP/$3.rc"
}

# A repo where feat/x carries an [open] entry main does not have, so every
# real delete of feat/x blocks (exit 2).
seed_unpromoted_branch() {
  fi_run log "src/foo.py:1 — main entry"
  git add -A; git commit -q -m init
  git checkout -q -b feat/x
  fi_run log "src/branch_only.py:1 — branch-only"
  git add -A; git commit -q -m entry
  git checkout -q main
}

@test "hook-gate: pre-branch-delete exits before jq for commands that cannot delete a branch" {
  local c
  for c in 'ls -la' 'git status' 'rg -n foo src/' 'git push origin feat/x' \
           'git branch' 'git branch -a' 'git log --oneline -5' 'echo push'; do
    rm -f "$TMP/jq-calls"
    payload pre "$c" >"$TMP/p.json"
    run_hook "$PRE" "$TMP/p.json" pre
    [ "$(cat "$TMP/pre.rc")" -eq 0 ]
    [ ! -s "$TMP/pre.out" ] && [ ! -s "$TMP/pre.err" ]
    if [ -e "$TMP/jq-calls" ]; then echo "jq reached for: $c"; false; fi
  done
}

@test "hook-gate: pre-branch-delete reaches the full path for delete shapes, incl. quote-spliced words" {
  local c
  for c in 'git branch -D feat/x' 'git push origin --delete feat/x' 'git push origin :feat/x' \
           "git bra''nch -D feat/x" 'git bra""nch -D feat/x' "git push origin -''d feat/x" \
           "git branch -'D' feat/x" 'git push origin "--delete" feat/x' 'git -C . branch -fD feat/x' \
           'gh api -X DELETE repos/o/r/git/refs/heads/feat/x'; do
    rm -f "$TMP/jq-calls"
    payload pre "$c" >"$TMP/p.json"
    run_hook "$PRE" "$TMP/p.json" pre
    if [ ! -e "$TMP/jq-calls" ]; then echo "gate skipped: $c"; false; fi
  done
}

@test "hook-gate: a \\u escape in the payload disables the gate (full path runs)" {
  seed_unpromoted_branch
  # b is "b": the decoded command is `git branch -D feat/x`.
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git branch -D feat/x"}}' >"$TMP/p.json"
  run_hook "$PRE" "$TMP/p.json" pre
  [ "$(cat "$TMP/pre.rc")" -eq 2 ]
  grep -q "branch deletion blocked" "$TMP/pre.err"
}

@test "hook-gate: an AUTOFIX-QUEUED marker in the output reaches the full path" {
  rm -f "$TMP/jq-calls"
  payload post 'found-issues log --fix small "a:1 — b"' 'AUTOFIX-QUEUED 20261003-000000-00001' >"$TMP/p.json"
  run_hook "$POST" "$TMP/p.json" post
  [ -e "$TMP/jq-calls" ]
}

@test "hook-gate: FOUND_ISSUES_HOOK_GATES=off runs the full path" {
  export FOUND_ISSUES_HOOK_GATES=off
  payload pre 'ls -la' >"$TMP/p.json"
  run_hook "$PRE" "$TMP/p.json" pre
  [ -e "$TMP/jq-calls" ]
}

@test "hook-gate: pre-branch-delete is identical with gates on and off (differential corpus)" {
  seed_unpromoted_branch
  local -a corpus=(
    'git status' 'ls -la' 'git push origin feat/x' 'git push origin --delete feat/x'
    'git push -d origin feat/x' 'git push origin :feat/x' 'git branch -D feat/x'
    'git branch --delete feat/x' 'git branch -d main feat/x' "git bra''nch -D feat/x"
    'git bra"x"nch -D feat/x' 'git bra""nch -D feat/x' "git branch -'D' feat/x" "printf 'git branch -D feat/x' | cat"
    'git -C . branch -D feat/x' 'git -c a=b branch -df feat/x' 'git push origin "--delete" feat/x'
    'for b in feat/x; do git branch -D "$b"; done' 'git branch --show-current' 'git branch --merged main'
    'git push origin -fd feat/x' $'git bra\
nch -D feat/x' 
    'echo "git push origin --delete feat/x"' 'gh api -X DELETE repos/o/r/git/refs/heads/feat/x'
    'git br\anch -D feat/x' $'git\tbranch\t-D\tfeat/x' $'git status\ngit branch -D feat/x'
    'FOUND_ISSUES_PROMOTE_GUARD=off git branch -D feat/x' 'git push origin main && git push origin --delete feat/x'
    'git branch -D nonexistent' 'git checkout -b push-delete-branch' 'cat refs/heads/x # DELETE'
  )
  local c i=0
  for c in "${corpus[@]}"; do
    i=$((i + 1))
    payload pre "$c" >"$TMP/p.json"
    FOUND_ISSUES_HOOK_GATES=off run_hook "$PRE" "$TMP/p.json" off
    run_hook "$PRE" "$TMP/p.json" on
    for k in rc out err; do
      if ! cmp -s "$TMP/off.$k" "$TMP/on.$k"; then echo "differs ($k) on #$i: $c"; false; fi
    done
  done
  # The corpus really exercises both outcomes.
  payload pre 'git bra""nch -D feat/x' >"$TMP/p.json"
  run_hook "$PRE" "$TMP/p.json" on
  [ "$(cat "$TMP/on.rc")" -eq 2 ]
}

@test "hook-gate: post-bash-dispatch exits before jq for commands no route handles" {
  local c
  for c in 'ls -la' 'git status' 'npm test' 'gh pr view 3' 'gh pr checks 3 --watch' 'git log -5'; do
    rm -f "$TMP/jq-calls"
    payload post "$c" "nothing to commit, working tree clean" >"$TMP/p.json"
    run_hook "$POST" "$TMP/p.json" post
    [ "$(cat "$TMP/post.rc")" -eq 0 ]
    [ ! -s "$TMP/post.out" ]
    if [ -e "$TMP/jq-calls" ]; then echo "jq reached for: $c"; false; fi
  done
}

@test "hook-gate: post-bash-dispatch routes identically with gates on and off (differential corpus)" {
  # Stub CLI + autosync marker: the comparison is WHICH routes fired.
  printf '#!/usr/bin/env bash\necho "CLI $*" >>"%s/calls"\n' "$TMP" >"$TMP/stub-cli"
  chmod +x "$TMP/stub-cli"
  export FOUND_ISSUES_BIN="$TMP/stub-cli"
  export FOUND_ISSUES_AUTOSYNC_CMD="echo SYNC >>'$TMP/calls'"
  local -a corpus=(
    'ls -la' 'git status' 'npm test' 'git commit -m "x"' 'git commit --amend --no-edit'
    'git commit-tree HEAD^{tree}' 'echo commit' 'git log --grep=commit' 'gh pr create --fill'
    'gh pr merge 7 --squash' 'gh pr close 7' 'gh pr reopen 7' $'gh  pr\tmerge 7'
    'git commit -m x && gh pr create --fill' 'gh pr view 7' 'ghx pr merge 7' 'gh pr merged'
  )
  local c i=0
  for c in "${corpus[@]}"; do
    i=$((i + 1))
    payload post "$c" "https://github.com/o/r/pull/7" >"$TMP/p.json"
    for mode in off on; do
      rm -f "$TMP/calls"
      if [[ "$mode" == off ]]; then
        FOUND_ISSUES_HOOK_GATES=off run_hook "$POST" "$TMP/p.json" off
      else
        run_hook "$POST" "$TMP/p.json" on
      fi
      sleep 0.2   # the merge route's sync is detached
      if [ -e "$TMP/calls" ]; then sort "$TMP/calls" >"$TMP/$mode.calls"; else : >"$TMP/$mode.calls"; fi
    done
    for k in rc out err calls; do
      if ! cmp -s "$TMP/off.$k" "$TMP/on.$k"; then echo "differs ($k) on #$i: $c"; false; fi
    done
  done
}
