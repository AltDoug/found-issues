#!/usr/bin/env bats
# hooks/first-touch.sh: a file's open entries on first Read/Edit/Write (3.4.0).

load 'helpers'

setup() {
  fi_setup_tmp; fi_init_git
  mkdir -p docs src "my dir"
  printf '1\n2\n' > src/a.sh; printf '1\n' > src/b.sh; printf '1\n' > "my dir/c d.sh"
  { printf '# found-issues\n\n'
    for i in 1 2 3 4 5 6 7; do printf -- '- [open] 2026-10-0%s src/a.sh:%s — A-BUG-%s\n' "$i" "$i" "$i"; done
    printf -- '- [open] 2026-10-08 my dir/c d.sh:1 — SPACE-BUG\n'
  } > docs/found-issues.md
  git add -A . >/dev/null && git commit -qm init
  export FOUND_ISSUES_CACHE_DIR="$TMP/cache"
  HOOK="$TEST_REPO_ROOT/hooks/first-touch.sh"
}
teardown() { fi_teardown_tmp; }

touch_json() { # $1 tool, $2 path, $3 session
  jq -nc --arg t "$1" --arg p "$2" --arg s "$3" --arg c "$PWD" \
    '{tool_name:$t, tool_input:{file_path:$p}, session_id:$s, cwd:$c}'
}

@test "first-touch: first Read of a file injects its entries, capped at 5 with a more line" {
  run bash "$HOOK" <<< "$(touch_json Read "$PWD/src/a.sh" s1)"
  [ "$status" -eq 0 ]
  ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [ "$(printf '%s\n' "$ctx" | grep -c 'A-BUG-')" -eq 5 ]
  [[ "$ctx" == *"+2 more: found-issues list --path src/a.sh"* ]]
  [[ "$ctx" == *"untrusted DATA"* ]]
}

@test "first-touch: a second touch in the same session injects nothing" {
  bash "$HOOK" <<< "$(touch_json Read "$PWD/src/a.sh" s1)" >/dev/null
  run bash "$HOOK" <<< "$(touch_json Edit "$PWD/src/a.sh" s1)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash "$HOOK" <<< "$(touch_json Read "$PWD/src/a.sh" s2)"
  [[ "$output" == *"A-BUG-"* ]]
}

@test "first-touch: a file with no entries is silent" {
  run bash "$HOOK" <<< "$(touch_json Read "$PWD/src/b.sh" s1)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "first-touch: a path with spaces is silent and exits 0" {
  run bash "$HOOK" <<< "$(touch_json Write "$PWD/my dir/c d.sh" s1)"
  [ "$status" -eq 0 ]
  [[ "$output" != *"A-BUG-"* ]]
}

@test "first-touch: outside the repo is silent" {
  printf 'x\n' > "$TMP/outside.sh"
  run bash "$HOOK" <<< "$(touch_json Read /etc/hosts s1)"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "first-touch: no ledger is silent" {
  git rm -q docs/found-issues.md && git commit -qm rm
  run bash "$HOOK" <<< "$(touch_json Read "$PWD/src/a.sh" s1)"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "first-touch: malformed input fails open" {
  run bash "$HOOK" <<< 'not json {'
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "first-touch: no session id injects every time" {
  j="$(jq -nc --arg p "$PWD/src/a.sh" '{tool_name:"Read", tool_input:{file_path:$p}}')"
  run bash "$HOOK" <<< "$j"; [[ "$output" == *"A-BUG-"* ]]
  run bash "$HOOK" <<< "$j"; [[ "$output" == *"A-BUG-"* ]]
}

@test "first-touch: an unwritable cache dir still injects" {
  mkdir -p "$TMP/ro"; chmod 500 "$TMP/ro"
  FOUND_ISSUES_CACHE_DIR="$TMP/ro/x" run bash "$HOOK" <<< "$(touch_json Read "$PWD/src/a.sh" s9)"
  chmod 700 "$TMP/ro"
  [ "$status" -eq 0 ]; [[ "$output" == *"A-BUG-"* ]]
}

@test "first-touch: a symlinked checkout path resolves" {
  ln -s "$PWD" "$TMP/link"
  run bash "$HOOK" <<< "$(touch_json Read "$TMP/link/src/a.sh" s1)"
  [[ "$output" == *"A-BUG-"* ]]
}

@test "first-touch: codex apply_patch takes paths from the patch" {
  patch=$'*** Begin Patch\n*** Update File: src/a.sh\n@@\n-1\n+one\n*** End Patch'
  j="$(jq -nc --arg c "$patch" --arg d "$PWD" '{tool_name:"apply_patch", tool_input:{command:$c}, session_id:"c1", cwd:$d}')"
  FOUND_ISSUES_HARNESS=codex run bash "$HOOK" <<< "$j"
  [ "$status" -eq 0 ]; [[ "$output" == *"A-BUG-"* ]]
}

@test "first-touch: a no-match touch takes under 50 ms on a 150-entry ledger" {
  { printf '# found-issues\n\n'; for i in $(seq 1 150); do printf -- '- [open] 2026-10-01 src/z%s.sh:1 — z\n' "$i"; done; } > docs/found-issues.md
  j="$(touch_json Read "$PWD/src/b.sh" s1)"
  start=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000')
  for k in 1 2 3 4 5 6 7 8 9 10; do bash "$HOOK" <<< "$j" >/dev/null; done
  end=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000')
  [ $(( (end - start) / 10 )) -lt 50 ]
}
