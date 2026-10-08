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
