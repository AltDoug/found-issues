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
  [ -z "$output" ]
}

@test "first-touch: outside the repo is silent" {
  # $TMP is the repo root here, so the outside file lives in its own mktemp -d.
  outside="$(cd "$(mktemp -d)" && pwd -P)"
  printf 'x\n' > "$outside/outside.sh"
  printf -- '- [open] 2026-10-08 %s/outside.sh:1 — OUTSIDE-BUG\n' "$outside" >> docs/found-issues.md
  run bash "$HOOK" <<< "$(touch_json Read "$outside/outside.sh" s1)"
  rm -rf "$outside"
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

@test "first-touch: a pre-check hit with no open entry is silent, recorded, and fast" {
  { printf '# found-issues\n\n'; for i in $(seq 1 150); do printf -- '- [open] 2026-10-01 src/z%s.sh:1 — z\n' "$i"; done
    printf -- '- [fixed] 2026-10-01 src/old.sh:3 — OLD-BUG\n'; } > docs/found-issues.md
  printf '1\n' > src/old.sh
  j="$(touch_json Read "$PWD/src/old.sh" s1)"
  run bash "$HOOK" <<< "$j"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  grep -Fxq 'src/old.sh' "$TMP/cache/sessions/s1"
  start=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000')
  for k in 1 2 3 4 5 6 7 8 9 10; do bash "$HOOK" <<< "$j" >/dev/null; done
  end=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000')
  [ $(( (end - start) / 10 )) -lt 50 ]
}

@test "first-touch: the slow path itself stays cheap on a 150-entry ledger" {
  { printf '# found-issues\n\n'; for i in $(seq 1 150); do printf -- '- [open] 2026-10-01 src/z%s.sh:1 — z\n' "$i"; done
    printf -- '- [fixed] 2026-10-01 src/old.sh:3 — OLD-BUG\n'; } > docs/found-issues.md
  printf '1\n' > src/old.sh
  start=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000')
  for k in 1 2 3 4 5 6 7 8 9 10; do bash "$HOOK" <<< "$(touch_json Read "$PWD/src/old.sh" "u$k")" >/dev/null; done
  end=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000')
  [ $(( (end - start) / 10 )) -lt 50 ]
}

@test "first-touch: an entry whose location ends the line matches" {
  printf -- '- [open] 2026-10-02 src/eol.sh\n' >> docs/found-issues.md
  printf '1\n' > src/eol.sh
  run bash "$HOOK" <<< "$(touch_json Read "$PWD/src/eol.sh" s1)"
  [ "$status" -eq 0 ]; [[ "$output" == *"src/eol.sh"* ]]
}

@test "first-touch: a prefix-lookalike path does not match" {
  printf -- '- [open] 2026-10-02 src/a.shx:1 — LOOKALIKE\n' >> docs/found-issues.md
  run bash "$HOOK" <<< "$(touch_json Read "$PWD/src/a.sh" s1)"
  [[ "$output" == *"A-BUG-"* ]]
  [[ "$output" != *"LOOKALIKE"* ]]
}

@test "first-touch: no HOME and no cache vars still exits 0" {
  run env -u HOME -u XDG_CACHE_HOME -u FOUND_ISSUES_CACHE_DIR bash "$HOOK" <<< "$(touch_json Read "$PWD/src/a.sh" s1)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"A-BUG-"* ]]
}

# --- 3.4.0 final fix wave ---

@test "first-touch: a root .found-issues.md ledger is found" {
  git rm -q docs/found-issues.md
  { printf '# found-issues\n\n'; printf -- '- [open] 2026-10-08 src/a.sh:1 — DOT-LEDGER-BUG\n'; } > .found-issues.md
  run bash "$HOOK" <<< "$(touch_json Read "$PWD/src/a.sh" s1)"
  [ "$status" -eq 0 ]; [[ "$output" == *"DOT-LEDGER-BUG"* ]]
}

@test "first-touch: docs/found-issues.md wins over a root .found-issues.md" {
  printf -- '- [open] 2026-10-08 src/b.sh:1 — DOT-LOSES\n' > .found-issues.md
  printf -- '- [open] 2026-10-08 src/b.sh:1 — DOCS-WINS\n' >> docs/found-issues.md
  run bash "$HOOK" <<< "$(touch_json Read "$PWD/src/b.sh" s1)"
  [[ "$output" == *"DOCS-WINS"* ]]
  [[ "$output" != *"DOT-LOSES"* ]]
}

@test "first-touch: a no-git local-mode directory with .found-issues.md works" {
  local_dir="$(mktemp -d)"
  mkdir -p "$local_dir/src"; printf '1\n' > "$local_dir/src/a.sh"
  printf -- '- [open] 2026-10-08 src/a.sh:1 — LOCAL-MODE-BUG\n' > "$local_dir/.found-issues.md"
  cd "$local_dir"
  run bash "$HOOK" <<< "$(touch_json Read "$local_dir/src/a.sh" s1)"
  cd "$TMP"; rm -rf "$local_dir"
  [ "$status" -eq 0 ]; [[ "$output" == *"LOCAL-MODE-BUG"* ]]
}

@test "first-touch: a subagent touch does not consume the main thread injection" {
  sub="$(jq -nc --arg p "$PWD/src/a.sh" --arg c "$PWD" '{tool_name:"Read", tool_input:{file_path:$p}, session_id:"s1", agent_id:"agent-7", cwd:$c}')"
  run bash "$HOOK" <<< "$sub"; [[ "$output" == *"A-BUG-"* ]]
  run bash "$HOOK" <<< "$sub"; [ -z "$output" ]
  run bash "$HOOK" <<< "$(touch_json Read "$PWD/src/a.sh" s1)"
  [[ "$output" == *"A-BUG-"* ]]
  [ -f "$TMP/cache/sessions/s1.agent-7" ]
  [ -f "$TMP/cache/sessions/s1" ]
}

@test "first-touch: a hostile agent_id is ignored and never escapes the sessions dir" {
  for bad in '../x' '.' '..' 'a/b'; do
    j="$(jq -nc --arg p "$PWD/src/a.sh" --arg c "$PWD" --arg a "$bad" '{tool_name:"Read", tool_input:{file_path:$p}, session_id:"sh", agent_id:$a, cwd:$c}')"
    run bash "$HOOK" <<< "$j"
    [ "$status" -eq 0 ]
    [[ "$output" == *"A-BUG-"* ]]
    rm -f "$TMP/cache/sessions/sh"
  done
  [ ! -e "$TMP/cache/x" ]
  [ ! -e "$TMP/cache/sessions/sh..x" ]
  [ -z "$(ls "$TMP/cache/sessions" | grep '^sh\.' || true)" ]
}

@test "first-touch: a session id of dot-dot or a leading dot records nothing" {
  for bad in '..' '.hidden'; do
    run bash "$HOOK" <<< "$(touch_json Read "$PWD/src/a.sh" "$bad")"
    [[ "$output" == *"A-BUG-"* ]]
    run bash "$HOOK" <<< "$(touch_json Read "$PWD/src/a.sh" "$bad")"
    [[ "$output" == *"A-BUG-"* ]]
  done
  [ -z "$(ls -A "$TMP/cache/sessions" 2>/dev/null)" ]
}

@test "first-touch: a clipped entry never ends in a split multibyte character" {
  long="$(printf 'e\xcc\x81%.0s' $(seq 1 100))"
  printf -- '- [open] 2026-10-08 src/b.sh:1 — %s\n' "$long" >> docs/found-issues.md
  for pad in 0 1 2; do
    pre="$(printf 'x%.0s' $(seq 1 $((pad + 1))))"
    printf -- '- [open] 2026-10-08 src/pad%s.sh:1 — %s%s\n' "$pad" "$pre" "$(printf '\xe2\x80\x94%.0s' $(seq 1 120))" >> docs/found-issues.md
    printf '1\n' > "src/pad$pad.sh"
    run bash "$HOOK" <<< "$(touch_json Read "$PWD/src/pad$pad.sh" "u$pad")"
    [ "$status" -eq 0 ]
    ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    printf '%s' "$ctx" | iconv -f UTF-8 -t UTF-8 >/dev/null
    # jq turns a split character into U+FFFD, so a clean clip has none.
    [[ "$ctx" != *$'\xef\xbf\xbd'* ]]
    [[ "$ctx" == *"..."* ]]
  done
}
