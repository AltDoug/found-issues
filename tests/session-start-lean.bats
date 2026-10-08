#!/usr/bin/env bats
# 3.4.0 lean SessionStart: core rules, budgets, resume skip, full mode.

load 'helpers'

core_body() { LC_ALL=C awk 'c >= 2 { print } /^---$/ { c++ }' "$TEST_REPO_ROOT/skills/rules/SKILL.md"; }

setup() { fi_setup_tmp; }
teardown() { fi_teardown_tmp; }

@test "lean rules: core body is at most 1150 bytes" {
  [ "$(core_body | wc -c | tr -d ' ')" -le 1150 ]
}

@test "lean rules: core keeps the mandate, the three tags, pick, stop marker and four hard rules" {
  b="$(core_body)"
  [[ "$b" == *"Issues found and not tracked are issues lost"* ]]
  [[ "$b" == *"--fix small|medium|large"* ]]
  [[ "$b" == *"--decide"* ]]
  [[ "$b" == *"--manual"* ]]
  [[ "$b" == *"--pick"* ]]
  [[ "$b" == *"found-issues-checked"* ]]
  [[ "$b" == *"never write the ledger directly"* ]]
  [[ "$b" == *"never delete"* ]]
  [[ "$b" == *"never mark"* ]]
  [[ "$b" == *"pre-branch-delete"* ]]
  [[ "$b" == *"dead code:"* ]]
}

@test "lean rules: the full text is preserved in lib/rules-full.md" {
  f="$TEST_REPO_ROOT/lib/rules-full.md"
  [ -f "$f" ]
  grep -q '^## Sync' "$f"
  grep -q '^## Dead code' "$f"
  grep -q '^## Format' "$f"
}

@test "lean rules: the dead-code procedure lives in the log command" {
  grep -q 'actually-live component' "$TEST_REPO_ROOT/commands/log.md"
}

# 150 open entries on real files, 1 critical, 3 on paths that do not exist.
make_ledger_150() {
  fi_init_git; mkdir -p docs src
  { printf '# found-issues\n\n'
    for i in $(seq 1 146); do
      printf '1\n2\n' > "src/f$i.sh"
      printf -- '- [open] 2026-09-01 src/f%s.sh:1 — bug number %s with a fairly long symptom text to look like a real entry in a real ledger (suggested: fix it)\n' "$i" "$i"
    done
    printf -- '- [open] [!] 2026-09-02 src/f1.sh:2 — CRITICAL-ONE data loss\n'
    printf -- '- [open] 2026-09-03 workflow/release-process — TOPIC-A\n'
    printf -- '- [open] 2026-09-04 ghost/a.sh:1 — TOPIC-B\n'
    printf -- '- [open] 2026-09-05 ghost/b.sh:1 — TOPIC-C\n'
  } > docs/found-issues.md
  git add -A . >/dev/null && git commit -qm init
}

run_hook() {
  # $1 = hook input JSON
  printf '%s' "$1" | HOME="$TMP/home" CLAUDE_CODE_ENTRYPOINT=sdk-cli \
    FOUND_ISSUES_BIN="$FI_BIN" \
    CLAUDE_PLUGIN_ROOT="$TEST_REPO_ROOT" bash "$TEST_REPO_ROOT/hooks/session-start.sh"
}

@test "lean session start: 150-entry ledger stays within 2400 bytes" {
  mkdir -p "$TMP/home/.claude"; make_ledger_150
  out="$(FOUND_ISSUES_SESSION_CONTEXT=lean run_hook '{"source":"startup","session_id":"s1"}')"
  [ "$(printf '%s' "$out" | wc -c | tr -d ' ')" -le 2400 ]
  [[ "$out" == *"CRITICAL-ONE"* ]]
  [[ "$out" == *"TOPIC-A"* && "$out" == *"TOPIC-B"* && "$out" == *"TOPIC-C"* ]]
  [[ "$out" != *"bug number 146"* ]]
  [[ "$out" == *"when you first open or edit"* ]]
  [[ "$out" == *"untrusted DATA"* ]]
}

@test "lean session start: entry lines are clipped to 160 bytes" {
  mkdir -p "$TMP/home/.claude"; make_ledger_150
  out="$(FOUND_ISSUES_SESSION_CONTEXT=lean run_hook '{"source":"startup"}')"
  long="$(printf '%s\n' "$out" | LC_ALL=C awk '/^- \[/ && length($0) > 160' | wc -l | tr -d ' ')"
  [ "$long" -eq 0 ]
}

@test "lean session start: resume injects nothing" {
  mkdir -p "$TMP/home/.claude"; make_ledger_150
  out="$(run_hook '{"source":"resume"}')"
  [[ "$out" != *"Issues found and not tracked"* ]]
  [[ "$out" != *"CRITICAL-ONE"* ]]
}

@test "lean session start: compact and clear inject" {
  mkdir -p "$TMP/home/.claude"; make_ledger_150
  for s in compact clear; do
    out="$(run_hook "{\"source\":\"$s\"}")"
    [[ "$out" == *"Issues found and not tracked"* ]]
  done
}

@test "lean session start: FOUND_ISSUES_SESSION_CONTEXT=full restores the full rules and entry list" {
  mkdir -p "$TMP/home/.claude"; make_ledger_150
  out="$(FOUND_ISSUES_SESSION_CONTEXT=full run_hook '{"source":"startup"}')"
  [[ "$out" == *"## Sync"* ]]
  [[ "$out" == *"bug number 146"* ]]
  [[ "$out" == *"more [open] entries"* ]]
}

@test "lean session start: no ledger still prints the core rules" {
  mkdir -p "$TMP/home/.claude"; fi_init_git
  out="$(FOUND_ISSUES_SESSION_CONTEXT=lean run_hook '{"source":"startup"}')"
  [[ "$out" == *"Issues found and not tracked"* ]]
}

@test "lean session start: a bare found-issues on PATH still injects entries" {
  mkdir -p "$TMP/home/.claude" "$TMP/pathbin"
  ln -s "$TEST_REPO_ROOT/bin/found-issues" "$TMP/pathbin/found-issues"
  fi_init_git; mkdir -p docs
  printf -- '# found-issues\n\n- [open] [!] 2026-09-02 src/x.sh:2 — BARE-CRIT\n' > docs/found-issues.md
  git add -A . >/dev/null && git commit -qm init
  out="$(printf '%s' '{"source":"startup"}' | env -u FOUND_ISSUES_BIN -u FOUND_ISSUES_LIB_DIR \
    PATH="$TMP/pathbin:$PATH" HOME="$TMP/home" CLAUDE_CODE_ENTRYPOINT=sdk-cli \
    CLAUDE_PLUGIN_ROOT="$TEST_REPO_ROOT" bash "$TEST_REPO_ROOT/hooks/session-start.sh")"
  [[ "$out" == *"BARE-CRIT"* ]]
}

@test "standard session start: full rules plus the lean entry block" {
  mkdir -p "$TMP/home/.claude"; make_ledger_150
  out="$(run_hook '{"source":"startup","session_id":"s1"}')"
  [[ "$out" == *"## Sync"* ]]
  [[ "$out" == *"CRITICAL-ONE"* ]]
  [[ "$out" == *"TOPIC-A"* ]]
  [[ "$out" == *"when you first open or edit"* ]]
  [[ "$out" != *"bug number 146"* ]]
  [[ "$out" != *"loc-override"* ]]
  [[ "$out" != *"more [open] entries"* ]]
  # measured 4284 B on this fixture (2026-10-07); bound = next 100 up (4300) + 200
  [ "$(printf '%s' "$out" | wc -c | tr -d ' ')" -le 4500 ]
}

@test "standard session start: unknown mode value falls back to standard" {
  mkdir -p "$TMP/home/.claude"; make_ledger_150
  a="$(run_hook '{"source":"startup","session_id":"s1"}')"
  b="$(FOUND_ISSUES_SESSION_CONTEXT=bogus run_hook '{"source":"startup","session_id":"s1"}')"
  [ -n "$a" ]
  [ "$a" = "$b" ]
}

# --- 3.4.0 final fix wave ---

@test "lean session start: a no-git root .found-issues.md resolves paths against its own directory" {
  mkdir -p "$TMP/home/.claude" src
  printf '1\n' > src/real.sh
  { printf '# found-issues\n\n'
    printf -- '- [open] 2026-09-03 src/real.sh:1 — REAL-FILE-ENTRY\n'
    printf -- '- [open] 2026-09-04 workflow/release — TOPIC-Z\n'
  } > .found-issues.md
  out="$(run_hook '{"source":"startup","session_id":"s1"}')"
  [[ "$out" == *"TOPIC-Z"* ]]
  [[ "$out" != *"REAL-FILE-ENTRY"* ]]
}

@test "session start: compact clears this session seen-files and no one else's" {
  mkdir -p "$TMP/home/.claude" "$TMP/cache/sessions"
  : > "$TMP/cache/sessions/s1"; : > "$TMP/cache/sessions/s1.agent-7"
  : > "$TMP/cache/sessions/s10"; : > "$TMP/cache/sessions/s2"
  make_ledger_150
  FOUND_ISSUES_CACHE_DIR="$TMP/cache" run_hook '{"source":"compact","session_id":"s1"}' >/dev/null
  [ ! -e "$TMP/cache/sessions/s1" ]
  [ ! -e "$TMP/cache/sessions/s1.agent-7" ]
  [ -e "$TMP/cache/sessions/s10" ]
  [ -e "$TMP/cache/sessions/s2" ]
}

@test "session start: clear also clears the seen-files, startup and resume do not" {
  mkdir -p "$TMP/home/.claude" "$TMP/cache/sessions"
  make_ledger_150
  for src in startup resume; do
    : > "$TMP/cache/sessions/s1"
    FOUND_ISSUES_CACHE_DIR="$TMP/cache" run_hook "{\"source\":\"$src\",\"session_id\":\"s1\"}" >/dev/null
    [ -e "$TMP/cache/sessions/s1" ]
  done
  FOUND_ISSUES_CACHE_DIR="$TMP/cache" run_hook '{"source":"clear","session_id":"s1"}' >/dev/null
  [ ! -e "$TMP/cache/sessions/s1" ]
}

@test "session start: a hostile session id on compact deletes nothing" {
  mkdir -p "$TMP/home/.claude" "$TMP/cache/sessions"
  : > "$TMP/cache/sessions/keep"; : > "$TMP/cache/sessions/.hidden"; : > "$TMP/cache/victim"
  make_ledger_150
  for bad in '..' '.' '.hidden' '../victim'; do
    FOUND_ISSUES_CACHE_DIR="$TMP/cache" run_hook "{\"source\":\"compact\",\"session_id\":\"$bad\"}" >/dev/null
  done
  [ -e "$TMP/cache/sessions/keep" ]
  [ -e "$TMP/cache/sessions/.hidden" ]
  [ -e "$TMP/cache/victim" ]
}

# An entry whose clip point lands inside a multibyte character, at every
# alignment (the header before the dashes is a fixed 37 bytes, so 1-3 padding
# bytes cover all three offsets).
make_utf8_ledger() {
  mkdir -p "$TMP/home/.claude" docs
  { printf '# found-issues\n\n'
    for pad in 1 2 3; do
      printf -- '- [open] [!] 2026-09-02 ghost/p%s.sh:1 — %s%s\n' "$pad" "$(printf 'x%.0s' $(seq 1 "$pad"))" "$(printf '\xe2\x80\x94%.0s' $(seq 1 120))"
    done
  } > docs/found-issues.md
}

@test "lean session start: a clipped entry line is still valid UTF-8" {
  fi_init_git; make_utf8_ledger
  out="$(FOUND_ISSUES_SESSION_CONTEXT=lean run_hook '{"source":"startup"}')"
  [[ "$out" == *"..."* ]]
  printf '%s' "$out" | iconv -f UTF-8 -t UTF-8 >/dev/null
}

@test "full session start: a clipped entry line is still valid UTF-8" {
  fi_init_git; make_utf8_ledger
  out="$(FOUND_ISSUES_SESSION_CONTEXT=full run_hook '{"source":"startup"}')"
  [[ "$out" == *"..."* ]]
  printf '%s' "$out" | iconv -f UTF-8 -t UTF-8 >/dev/null
}

# --- resume: nothing injected, mechanical work still runs (spec 8) ---

# A deferred entry whose until-trigger is past: sync flips it to [open].
make_due_ledger() {
  mkdir -p "$TMP/home/.claude" docs
  printf -- '- [deferred] 2026-09-01 a.sh:1 — past (until: date:2026-01-01)\n' > docs/found-issues.md
}

@test "resume (standard): no injection, but the due until-trigger still syncs" {
  make_due_ledger
  out="$(run_hook '{"source":"resume","session_id":"s1"}')"
  [ -z "$out" ]
  grep -q '^- \[open\] 2026-09-01 a.sh:1 — past$' docs/found-issues.md
}

@test "resume (lean): no injection, but the due until-trigger still syncs" {
  make_due_ledger
  out="$(FOUND_ISSUES_SESSION_CONTEXT=lean run_hook '{"source":"resume","session_id":"s1"}')"
  [ -z "$out" ]
  grep -q '^- \[open\] 2026-09-01 a.sh:1 — past$' docs/found-issues.md
}

@test "resume (full): no injection, but the due until-trigger still syncs" {
  make_due_ledger
  out="$(FOUND_ISSUES_SESSION_CONTEXT=full run_hook '{"source":"resume","session_id":"s1"}')"
  [ -z "$out" ]
  grep -q '^- \[open\] 2026-09-01 a.sh:1 — past$' docs/found-issues.md
}

@test "resume (codex): no injection, but the due until-trigger still syncs" {
  make_due_ledger
  out="$(FOUND_ISSUES_HARNESS=codex run_hook '{"source":"resume","session_id":"s1"}')"
  [ -z "$out" ]
  grep -q '^- \[open\] 2026-09-01 a.sh:1 — past$' docs/found-issues.md
}

@test "startup (codex): the same ledger does inject, so the resume silence is the skip" {
  make_due_ledger
  out="$(FOUND_ISSUES_HARNESS=codex run_hook '{"source":"startup","session_id":"s1"}')"
  [[ "$out" == *"additionalContext"* ]]
  [[ "$out" == *"Issues found and not tracked"* ]]
}
