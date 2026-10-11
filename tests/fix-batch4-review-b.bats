#!/usr/bin/env bats
# Review B of batch 4: the merge guard has its own long horizon and is
# single-instance per PR; the verifier's watchdog timeout is detected by
# FI_AF_CHILD_TIMEDOUT, never by a bare exit 124; fix ship validates its
# suite timeout; the Stop fallback no longer forks an origin check.

load 'helpers'
load 'autofix-helpers'

HOOK="$TEST_REPO_ROOT/hooks/post-bash-dispatch.sh"
STOP="$TEST_REPO_ROOT/hooks/stop-reminder.sh"

setup() {
  fi_setup_tmp; fi_af_fixture; fi_use_standins
  export PATH="$TEST_REPO_ROOT/bin:$PATH"
  export GH_MOCK_TRACE="$TMP/gh.trace" FOUND_ISSUES_AUTOFIX_MERGE_SLEEP=0 FOUND_ISSUES_AUTOFIX_MERGE_POLLS=2
  export GH_MOCK_PR_VIEW=$'7\t{"number":7,"state":"OPEN","statusCheckRollup":[{"conclusion":"","status":"IN_PROGRESS"}]}'
  : >"$GH_MOCK_TRACE"
}
teardown() {
  # Only the guards this file started.
  local p
  for p in ${GUARD_PIDS:-}; do kill -9 "$p" 2>/dev/null || true; done
  fi_teardown_tmp
}

# A gh that reports the PR OPEN with <n> pending-check looks first, then MERGED.
seq_gh() {
  local n="$1"
  mkdir -p "$TMP/seqbin"
  cat >"$TMP/seqbin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_MOCK_TRACE"
if [[ "$1 $2" == "pr view" ]]; then
  c=0; [[ -f "$SEQ_COUNT" ]] && c="$(cat "$SEQ_COUNT")"
  c=$((c + 1)); printf '%s' "$c" >"$SEQ_COUNT"
  jq_filter=""; prev=""
  for a in "$@"; do [[ "$prev" == --jq ]] && jq_filter="$a"; prev="$a"; done
  if (( c > SEQ_OPEN_LOOKS )); then st=MERGED; else st=OPEN; fi
  printf '{"state":"%s","mergeable":"MERGEABLE","baseRefName":"main","headRefName":"x","statusCheckRollup":[{"conclusion":"","status":"IN_PROGRESS"}]}' "$st" | jq -r "$jq_filter"
  exit 0
fi
exec "$SEQ_SHIM" "$@"
SH
  chmod +x "$TMP/seqbin/gh"
  export SEQ_SHIM="$TEST_REPO_ROOT/tests/bin-shims/gh" SEQ_COUNT="$TMP/seq.count" SEQ_OPEN_LOOKS="$n"
  export PATH="$TMP/seqbin:$PATH"
}

views() { grep -c '^pr view' "$GH_MOCK_TRACE" || true; }

# ---- 1. guard horizon and single instance ----

@test "b4 review guard: --guard polls for its own horizon, not the merge-when-green window" {
  export FOUND_ISSUES_AUTOFIX_GUARD_POLLS=5
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar --guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"still pending after 5 checks"* ]]
  [ "$(views)" -eq 5 ]
}

@test "b4 review guard: a PR whose CI outlasts the merge window is still watched until it merges" {
  seq_gh 6
  unset FOUND_ISSUES_AUTOFIX_GUARD_POLLS   # the default horizon, not the fixture's short one
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar --guard
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #7 is already MERGED"* ]]
  [ "$(cat "$SEQ_COUNT")" -eq 7 ]
}

@test "b4 review guard: the plain merge-when-green window is unchanged by the guard horizon" {
  export FOUND_ISSUES_AUTOFIX_GUARD_POLLS=9
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 1 ]
  [[ "$output" == *"still pending after 2 checks"* ]]
}

@test "b4 review guard: a second guard for the same PR exits 0 at once while the first is alive" {
  export FOUND_ISSUES_AUTOFIX_GUARD_POLLS=60 FOUND_ISSUES_AUTOFIX_MERGE_SLEEP=1
  "$FI_BIN" autofix merge-when-green 7 --repo foo/bar --guard >"$TMP/g1.out" 2>&1 3>&- &
  GUARD_PIDS="$!"
  for _ in $(seq 1 40); do [ "$(views)" -ge 1 ] && break; sleep 0.25; done
  [ "$(views)" -ge 1 ]
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar --guard
  [ "$status" -eq 0 ]
  [[ "$output" == *"already guarded"* ]]
  kill -0 "$GUARD_PIDS"
}

@test "b4 review guard: a guard for another PR is not blocked by the first" {
  export FOUND_ISSUES_AUTOFIX_GUARD_POLLS=60 FOUND_ISSUES_AUTOFIX_MERGE_SLEEP=1
  "$FI_BIN" autofix merge-when-green 7 --repo foo/bar --guard >"$TMP/g1.out" 2>&1 3>&- &
  GUARD_PIDS="$!"
  for _ in $(seq 1 40); do [ "$(views)" -ge 1 ] && break; sleep 0.25; done
  export GH_MOCK_PR_VIEW=$'8\t{"state":"MERGED","statusCheckRollup":[]}'
  run "$FI_BIN" autofix merge-when-green 8 --repo foo/bar --guard
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #8 is already MERGED"* ]]
}

@test "b4 review guard: the lock of a dead guard does not block the next one" {
  export FOUND_ISSUES_AUTOFIX_GUARD_POLLS=60 FOUND_ISSUES_AUTOFIX_MERGE_SLEEP=1
  "$FI_BIN" autofix merge-when-green 7 --repo foo/bar --guard >"$TMP/g1.out" 2>&1 3>&- &
  GUARD_PIDS="$!"
  for _ in $(seq 1 40); do [ "$(views)" -ge 1 ] && break; sleep 0.25; done
  kill -9 "$GUARD_PIDS"; wait "$GUARD_PIDS" 2>/dev/null || true
  export FOUND_ISSUES_AUTOFIX_GUARD_POLLS=2 FOUND_ISSUES_AUTOFIX_MERGE_SLEEP=0
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar --guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"still pending after 2 checks"* ]]
}

@test "b4 review guard: a finished guard releases the PR so a later one runs" {
  export FOUND_ISSUES_AUTOFIX_GUARD_POLLS=2
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar --guard
  [ "$status" -eq 1 ]
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar --guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"still pending after 2 checks"* ]]
}

# ---- 2. verifier watchdog timeout ----

@test "b4 review verifier: a watchdog kill is an outage named as a timeout" {
  export FI_STANDIN_EDIT="sed -i.bak 's/ - / + /' src/calc.sh && rm -f src/calc.sh.bak"
  export FI_STANDIN_VERIFIER_HANG=30 FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS=1
  fi_af_queue_fixture; ST="$FI_AF_ST"
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 7 ]
  grep -q 'requeued: engine error: claude verifier exited 124 (timed out)' "$FI_AF_RUNS/$ID.log"
}

@test "b4 review verifier: a verifier that exits 124 by itself is a plain crash, not the watchdog" {
  export FI_STANDIN_EDIT="sed -i.bak 's/ - / + /' src/calc.sh && rm -f src/calc.sh.bak"
  export FI_STANDIN_VERIFIER_CRASH=124
  fi_af_queue_fixture; ST="$FI_AF_ST"
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 7 ]
  grep -q 'requeued: engine error: claude verifier exited 124$' "$FI_AF_RUNS/$ID.log"
  ! grep -q 'timed out' "$FI_AF_RUNS/$ID.log" || false
}

@test "b4 review verifier: a self-exit 124 that left an error_max subtype is still a reject" {
  export FI_STANDIN_EDIT="sed -i.bak 's/ - / + /' src/calc.sh && rm -f src/calc.sh.bak"
  export FI_STANDIN_VERIFIER_LIMIT=error_max_turns FI_STANDIN_VERIFIER_RC=124
  fi_af_queue_fixture; ST="$FI_AF_ST"
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '^result=failed: verifier rejected: ' "$ST/done/$ID"
}

@test "b4 review verifier: a codex watchdog kill is an outage named as a timeout" {
  export FI_STANDIN_EDIT="sed -i.bak 's/ - / + /' src/calc.sh && rm -f src/calc.sh.bak"
  export FI_STANDIN_VERIFIER_HANG=30 FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS=1
  fi_af_queue_fixture; ST="$FI_AF_ST"
  run "$FI_BIN" autofix run "$ID" --engine codex
  [ "$status" -eq 7 ]
  grep -q 'requeued: engine error: codex verifier exited 124 (timed out)' "$FI_AF_RUNS/$ID.log"
}

# ---- 3. fix ship timeout validation ----

ship_setup() {
  export GH_MOCK_PR_CREATE_URL=https://github.com/foo/bar/pull/11
  export GH_MOCK_PR_VIEW=$'11\t{"number":11,"state":"OPEN","files":[]}'
  out="$("$FI_BIN" fix workspace)"
  WT="$(printf '%s\n' "$out" | sed -n 's/^worktree=//p')"
  sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"
  git -C "$WT" commit -qam "fix: add subtracts (found-issues src/calc.sh:1)"
  printf 'b\n' > "$TMP/body"
}

@test "b4 review ship: a non-numeric FOUND_ISSUES_FIX_SHIP_TIMEOUT_SECS warns and uses the default" {
  ship_setup
  export FOUND_ISSUES_FIX_SHIP_TIMEOUT_SECS=60m
  run "$FI_BIN" fix ship "$WT" --title "fix: add" --body-file "$TMP/body" --pick src/calc.sh:1
  [ "$status" -eq 0 ]
  [[ "$output" == *"FOUND_ISSUES_FIX_SHIP_TIMEOUT_SECS"* ]]
  [[ "$output" == *"3600"* ]]
  [[ "$output" == *"PR #11"* ]]
}

@test "b4 review ship: a zero timeout is invalid too" {
  ship_setup
  export FOUND_ISSUES_FIX_SHIP_TIMEOUT_SECS=0
  run "$FI_BIN" fix ship "$WT" --title "fix: add" --body-file "$TMP/body" --pick src/calc.sh:1
  [ "$status" -eq 0 ]
  [[ "$output" == *"FOUND_ISSUES_FIX_SHIP_TIMEOUT_SECS"* ]]
}

@test "b4 review ship: a valid timeout is used silently" {
  ship_setup
  export FOUND_ISSUES_FIX_SHIP_TIMEOUT_SECS=120
  run "$FI_BIN" fix ship "$WT" --title "fix: add" --body-file "$TMP/body" --pick src/calc.sh:1
  [ "$status" -eq 0 ]
  [[ "$output" != *"FOUND_ISSUES_FIX_SHIP_TIMEOUT_SECS"* ]]
}

# ---- 4. Stop fallback: no origin fork ----

stop() { # $1 cwd
  jq -cn --arg c "$1" '{session_id:"s1",hook_event_name:"Stop",cwd:$c,stop_hook_active:false}' | "$STOP"
}
stop_setup() {
  fi_af_queue_fixture; ST="$FI_AF_ST"
  mkdir -p "$TMP/fake"
  printf '#!/usr/bin/env bash\nprintf "%%s|%%s\\n" "$PWD" "$*" >>"%s/spawned"\n' "$TMP" >"$TMP/fake/found-issues"
  chmod +x "$TMP/fake/found-issues"
  export FOUND_ISSUES_BIN="$TMP/fake/found-issues" FOUND_ISSUES_STOP_REMINDER=off CLAUDE_CODE_ENTRYPOINT=cli
  unset FOUND_ISSUES_HARNESS
}

@test "b4 review stop: an item with no slug is skipped without a spawn" {
  stop_setup
  fi_af_item_set "$QITEM" slug ""
  run stop "$REPO"
  [ "$status" -eq 0 ]
  sleep 0.5
  [ ! -e "$TMP/spawned" ]
}

@test "b4 review stop: a queued item launches without any origin lookup" {
  stop_setup
  local real; real="$(command -v git)"
  mkdir -p "$TMP/gitshim"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/gitlog"\nexec "%s" "$@"\n' "$TMP" "$real" >"$TMP/gitshim/git"
  chmod +x "$TMP/gitshim/git"
  export PATH="$TMP/gitshim:$PATH"
  : >"$TMP/gitlog"
  run stop "$REPO"
  [ "$status" -eq 0 ]
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/spawned" ] && break; sleep 0.3; done
  [ -s "$TMP/spawned" ]
  ! grep -q 'remote' "$TMP/gitlog" || false
  ! grep -q 'url' "$TMP/gitlog" || false
}
