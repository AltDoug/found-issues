#!/usr/bin/env bats
# Guard bypasses found by the 2026-10-03 audit (fix batch 2): the branch-delete
# promote guard and the ledger format enforcer, including both guards being
# inert when the hook runs without CLAUDE_PLUGIN_ROOT (every Codex hook).

load 'helpers'

PBD="$TEST_REPO_ROOT/hooks/pre-branch-delete.sh"
FE="$TEST_REPO_ROOT/hooks/format-enforcer.sh"

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

# A repo whose main tracks the ledger and whose feat/test branch carries one
# [open] entry main has never seen.
seed_unpromoted() {
  fi_run log "src/foo.py:1 — main entry"
  git add -A; git commit -q -m init
  git checkout -q -b feat/test
  fi_run log "src/x.py:1 — branch-only entry"
  git add -A; git commit -q -m "branch entry"
  git checkout -q main
}

# A PATH with system tools and jq but no found-issues CLI — what a Codex-only
# install looks like (the hook cannot find its lib through the CLI).
bare_path() { printf '/usr/bin:/bin:%s' "$(dirname "$(command -v jq)")"; }

# Run the branch-delete hook on a command; JSON-encodes it with jq.
pbd() {
  local cmd="$1"
  jq -cn --arg c "$cmd" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}' > "$TMP/p.json"
  run bash -c "'$PBD' < '$TMP/p.json'"
}

@test "pbd: git -C <repo> branch -D from another directory is blocked" {
  seed_unpromoted
  mkdir -p "$TMP/elsewhere"
  jq -cn --arg c "git -C $TMP branch -D feat/test" '{tool_name:"Bash",tool_input:{command:$c}}' > "$TMP/p.json"
  run bash -c "cd '$TMP/elsewhere' && '$PBD' < '$TMP/p.json'"
  [ "$status" -eq 2 ]
}

@test "pbd: git -c key=value branch -D is blocked" {
  seed_unpromoted
  pbd "git -c core.pager=cat branch -D feat/test"
  [ "$status" -eq 2 ]
}

@test "pbd: bundled short flags -df / push -fd are blocked" {
  seed_unpromoted
  pbd "git branch -df feat/test"
  [ "$status" -eq 2 ]
  pbd "git push origin -fd feat/test"
  [ "$status" -eq 2 ]
}

@test "pbd: a quoted branch operand is blocked" {
  seed_unpromoted
  pbd 'git branch -D "feat/test"'
  [ "$status" -eq 2 ]
  pbd "git branch -D 'feat/test'"
  [ "$status" -eq 2 ]
}

@test "pbd: a quoted delete flag is blocked" {
  seed_unpromoted
  pbd 'git push origin "--delete" feat/test'
  [ "$status" -eq 2 ]
  pbd "git push origin -'d' feat/test"
  [ "$status" -eq 2 ]
}

@test "pbd: an unresolvable \$variable operand is blocked with a literal-name hint" {
  seed_unpromoted
  pbd 'for b in feat/test; do git branch -D "$b"; done'
  [ "$status" -eq 2 ]
  [[ "$output" == *'$b'* ]]
}

@test "pbd: deletion verbs inside a quoted string or echo stay inert" {
  seed_unpromoted
  pbd "printf 'git branch -D feat/test' | pbcopy"
  [ "$status" -eq 0 ]
  pbd 'echo "git push origin --delete feat/test"'
  [ "$status" -eq 0 ]
  pbd "git branch --show-current"
  [ "$status" -eq 0 ]
}

@test "pbd: block message gives the promote sequence and no bypass hint" {
  seed_unpromoted
  pbd "git branch -D feat/test"
  [ "$status" -eq 2 ]
  [[ "$output" == *"found-issues promote"* ]]
  [[ "$output" != *"FOUND_ISSUES_PROMOTE_GUARD"* ]]
}

@test "pbd: blocks without CLAUDE_PLUGIN_ROOT or FOUND_ISSUES_LIB_DIR (Codex hook env)" {
  seed_unpromoted
  jq -cn '{tool_name:"Bash",tool_input:{command:"git branch -D feat/test"}}' > "$TMP/p.json"
  run env -u FOUND_ISSUES_LIB_DIR -u CLAUDE_PLUGIN_ROOT -u FOUND_ISSUES_BIN FOUND_ISSUES_HARNESS=codex PATH="$(bare_path)" \
    bash -c "'$PBD' < '$TMP/p.json'"
  [ "$status" -eq 2 ]
}

# --- format-enforcer ---

fe_edit() {
  jq -cn --arg f "$TMP/docs/found-issues.md" --arg o "$1" --arg n "$2" \
    '{tool_name:"Edit",tool_input:{file_path:$f,old_string:$o,new_string:$n}}' > "$TMP/e.json"
  run bash -c "'$FE' < '$TMP/e.json'"
}

@test "fe: a sub-line Edit that flips [open] to [fixed] without a token is blocked" {
  export FOUND_ISSUES_MODE=github-direct
  mkdir -p docs
  printf -- '- [open] 2026-09-01 lib/x.sh:4 — real bug\n' > docs/found-issues.md
  fe_edit "[open] 2026-09-01 lib/x.sh:4" "[fixed] 2026-09-01 lib/x.sh:4"
  [ "$status" -eq 2 ]
  [[ "$output" == *"verification token"* ]]
}

@test "fe: a sub-line Edit of an unrelated line ignores grandfathered lines elsewhere" {
  export FOUND_ISSUES_MODE=github-direct
  mkdir -p docs
  printf -- '- [open] 2026-01-01 old.sh:1 — legacy note about PR #5\n- [open] 2026-09-01 lib/x.sh:4 — real bug\n' \
    > docs/found-issues.md
  fe_edit "real bug" "real bug in the parser"
  [ "$status" -eq 0 ]
}

@test "fe: blocks a bad Write without CLAUDE_PLUGIN_ROOT or FOUND_ISSUES_LIB_DIR (Codex hook env)" {
  mkdir -p docs
  git remote add origin https://github.com/o/r.git
  jq -cn --arg f "$TMP/docs/found-issues.md" \
    '{tool_name:"Write",tool_input:{file_path:$f,content:"- [OPEN] 2026-05-08 src/foo.py:42 — bug"}}' > "$TMP/w.json"
  run env -u FOUND_ISSUES_LIB_DIR -u CLAUDE_PLUGIN_ROOT -u FOUND_ISSUES_BIN \
    FOUND_ISSUES_HARNESS=codex FOUND_ISSUES_MODE=github-direct PATH="$(bare_path)" bash -c "'$FE' < '$TMP/w.json'"
  [ "$status" -eq 2 ]
}

# --- hook-18: say so when jq is missing ---

@test "doctor: reports that the blocking guards are inactive without jq" {
  mkdir -p nojq
  for t in bash sh cat grep sed awk head tail tr cut date git dirname basename mktemp rm mkdir ls wc sort uname readlink printf env find stat cksum cmp mv chmod touch id; do
    p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "nojq/$t"
  done
  run env PATH="$TMP/nojq" bash "$FI_BIN" doctor
  [[ "$output" == *"jq"* ]]
  [[ "$output" == *"guard"* ]]
}

@test "session-start: says once per day that the guards are off without jq" {
  mkdir -p nojq home
  for t in bash sh cat grep sed awk head tail tr cut date git dirname basename mktemp rm mkdir ls wc sort uname readlink printf env find stat cksum cmp mv chmod touch id; do
    p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "nojq/$t"
  done
  run env HOME="$TMP/home" PATH="$TMP/nojq" CLAUDE_PLUGIN_ROOT="$TEST_REPO_ROOT" bash "$TEST_REPO_ROOT/hooks/session-start.sh" </dev/null
  [[ "$output" == *"jq is not installed"* ]]
  run env HOME="$TMP/home" PATH="$TMP/nojq" CLAUDE_PLUGIN_ROOT="$TEST_REPO_ROOT" bash "$TEST_REPO_ROOT/hooks/session-start.sh" </dev/null
  [[ "$output" != *"jq is not installed"* ]]
}

@test "fe: MultiEdit edits chain - a flip by the second edit is caught" {
  export FOUND_ISSUES_MODE=github-direct
  mkdir -p docs
  printf -- '- [open] 2026-09-01 lib/x.sh:4 — real bug\n' > docs/found-issues.md
  jq -cn --arg f "$TMP/docs/found-issues.md" \
    '{tool_name:"MultiEdit",tool_input:{file_path:$f,edits:[{old_string:"real bug",new_string:"real parser bug"},{old_string:"[open] 2026-09-01 lib/x.sh:4 — real parser",new_string:"[fixed] 2026-09-01 lib/x.sh:4 — real parser"}]}}' > "$TMP/m.json"
  run bash -c "'$FE' < '$TMP/m.json'"
  [ "$status" -eq 2 ]
}

@test "pbd: a delete at the end of a payload over the 16 KB gate limit is still blocked" {
  seed_unpromoted
  big="$(awk 'BEGIN { for (i = 0; i < 700; i++) print "echo filler line number " i " with some padding text" }')"
  pbd "$big"$'\n'"git branch -D feat/test"
  [ "$status" -eq 2 ]
}
