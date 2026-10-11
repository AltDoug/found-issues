#!/usr/bin/env bats
# Review C of batch 4 (the 3.8.0 pre-ship /code-review): a failed cut's
# debris is removed before the requeue; a fixer that hits its run limit is a
# counted attempt, not an outage; a requeued sweep continuation keeps its
# chain's base; only a green base resets the STUCK streak, which every linked
# worktree of a repo shares; the merge guard keeps watching through a failed
# check.

load 'helpers'
load 'autofix-helpers'

setup() { fi_setup_tmp; export PATH="$TEST_REPO_ROOT/bin:$PATH"; export FOUND_ISSUES_CACHE_DIR="$TMP/cache"; }
teardown() { fi_teardown_tmp; }

seg() { "$FI_BIN" status --format=segment --cwd "${1:-$REPO}"; }

_git_stub() {
  local real; real="$(command -v git)"
  mkdir -p "$TMP/stubbin"
  cat > "$TMP/stubbin/git" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *" fetch "*) [ "\${STUB_FETCH_FAIL:-}" = 1 ] && exit 1 ;;
esac
exec "$real" "\$@"
STUB
  chmod +x "$TMP/stubbin/git"
  export PATH="$TMP/stubbin:$PATH"
}

stuck_setup() {
  fi_af_fixture
  fi_af_queue_fixture
  ST="$FI_AF_ST"
  RED='echo "not ok 1 needs donor files"; exit 1'
  git config found-issues.autofix.testCommand "$RED"
  git config found-issues.autofix.dailyFixes 50
}

retire_one() {
  local next="${1:-1}" id
  id="$(ls "$ST/queue" | head -1)"
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 5 ]
  "$FI_BIN" log --fix small "test.sh:$((next + 10)) — entry $next" >/dev/null
}

# ===== a failed cut's leftovers go before the requeue =======================

@test "b4 review c cut: a leftover branch from a failed cut is removed, so the retry succeeds" {
  fi_af_fixture; fi_af_queue_fixture; ST="$FI_AF_ST"
  br="fi/autofix/src-calc-sh-1-$ID"
  git branch "$br"                      # the debris a half-done cut leaves
  rc=0; "$FI_BIN" autofix claim "$ID" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 8 ]
  grep -q '^waiting=git worktree add failed$' "$ST/queue/$ID"
  ! git show-ref --verify --quiet "refs/heads/$br" || false
  rc=0; "$FI_BIN" autofix claim "$ID" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ]
  [ -f "$ST/running/$ID" ]
}

# ===== a fixer's run limit is a counted attempt, not an outage ==============

@test "b4 review c fixer: error_max_turns from the fixer is no outage and never re-runs free" {
  fi_af_fixture; fi_use_standins
  export GH_MOCK_TRACE="$TMP/gh.trace"
  export FI_STANDIN_FIXER_LIMIT=error_max_turns
  fi_af_queue_fixture; ST="$FI_AF_ST"
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  [ ! -f "$ST/queue/$ID" ]
  [ -f "$ST/done/$ID" ]
  ! grep -q '^outages=' "$ST/done/$ID" || false
  ! grep -q 'engine error' "$FI_AF_RUNS/$ID.log" || false
  ! grep -q 'claude exited 1' "$FI_AF_RUNS/$ID.log" || false
}

# ===== a requeued continuation keeps its chain's base =======================

@test "b4 review c sweep: a fetch-failure requeue of a continuation keeps its base" {
  fi_af_sweep_fixture 5; fi_use_standins
  fi_af_remote_branch feat
  git switch -q main
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  SID="$(printf '%s\n' "$output" | sed -n 's/^AUTOFIX-SWEEP-DUE //p')"
  ST="$FOUND_ISSUES_STATE_DIR/autofix/foo__bar"
  [ -n "$SID" ]
  q="$ST/queue/$SID"
  sed -i.bak '/^cont=/d; /^base=/d' "$q" && rm -f "$q.bak"
  printf 'cont=2\nbase=feat\n' >>"$q"
  _git_stub; export STUB_FETCH_FAIL=1
  rc=0; "$FI_BIN" autofix claim "$SID" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 8 ]
  grep -q '^base=feat$' "$q"
}

@test "b4 review c sweep: a fetch-failure requeue of a first batch still resolves its base fresh" {
  fi_af_sweep_fixture 5; fi_use_standins
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  SID="$(printf '%s\n' "$output" | sed -n 's/^AUTOFIX-SWEEP-DUE //p')"
  ST="$FOUND_ISSUES_STATE_DIR/autofix/foo__bar"
  [ -n "$SID" ]
  _git_stub; export STUB_FETCH_FAIL=1
  rc=0; "$FI_BIN" autofix claim "$SID" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 8 ]
  ! grep -q '^base=.' "$ST/queue/$SID" || false
}

# ===== only a green base resets the STUCK streak ============================

@test "b4 review c stuck: a no-longer-eligible retire between base failures neither counts nor resets" {
  stuck_setup
  retire_one 1; retire_one 2
  id="$(ls "$ST/queue" | head -1)"
  "$FI_BIN" resolve "entry 2" --verified ai >/dev/null 2>&1
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 5 ]
  ! grep -q '^result=stale: tests fail at base' "$ST/done/$id" || false
  "$FI_BIN" log --fix small 'test.sh:30 — after the stale retire' >/dev/null
  run seg
  [[ "$output" != *"stuck"* ]] || false
  retire_one 3
  run seg
  [[ "$output" == *"🔧stuck"* ]]
}

# ===== linked worktrees share the repo's streak =============================

@test "b4 review c stuck: a linked worktree of the repo shows the repo's stuck marker" {
  stuck_setup
  retire_one 1; retire_one 2; retire_one 3
  git worktree add -q "$TMP/linked" -b linked-wt
  run seg "$TMP/linked"
  [[ "$output" == *"🔧stuck"* ]]
  cd "$TMP/linked"
  run "$FI_BIN" autofix summary
  [[ "$output" == *"Auto-fix is STUCK"* ]]
}

@test "b4 review c stuck: base failures from different worktrees add up to one streak" {
  stuck_setup
  retire_one 1; retire_one 2
  git worktree add -q "$TMP/linked" -b linked-wt
  cd "$TMP/linked"
  "$FI_BIN" log --fix small 'test.sh:50 — from the linked worktree' >/dev/null
  id="$(grep -l "^root=$TMP/linked\$\|^root=$(cd "$TMP/linked" && pwd -P)\$" "$ST"/queue/* | head -1)"
  id="$(basename "$id")"
  [ -n "$id" ]
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 5 ]
  run seg "$REPO"
  [[ "$output" == *"🔧stuck"* ]]
}

# ===== the guard watches through a failed check ============================

@test "b4 review c guard: a failed check does not end the guard; it still exits on MERGED" {
  fi_af_fixture
  export GH_MOCK_TRACE="$TMP/gh.trace"; : >"$GH_MOCK_TRACE"
  mkdir -p "$TMP/seqbin"
  cat >"$TMP/seqbin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_MOCK_TRACE"
if [[ "$1 $2" == "pr view" ]]; then
  c=0; [[ -f "$SEQ_COUNT" ]] && c="$(cat "$SEQ_COUNT")"
  c=$((c + 1)); printf '%s' "$c" >"$SEQ_COUNT"
  jq_filter=""; prev=""
  for a in "$@"; do [[ "$prev" == --jq ]] && jq_filter="$a"; prev="$a"; done
  if (( c > 2 )); then st=MERGED; else st=OPEN; fi
  printf '{"state":"%s","mergeable":"MERGEABLE","baseRefName":"main","headRefName":"x","statusCheckRollup":[{"conclusion":"FAILURE","status":"COMPLETED"}]}' "$st" | jq -r "$jq_filter"
  exit 0
fi
exit 0
SH
  chmod +x "$TMP/seqbin/gh"
  export SEQ_COUNT="$TMP/seq.count" PATH="$TMP/seqbin:$PATH" FOUND_ISSUES_AUTOFIX_GUARD_POLLS=5
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar --guard
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #7 is already MERGED"* ]]
  [ "$(cat "$SEQ_COUNT")" -eq 3 ]
}

@test "b4 review c guard: a plain merge-when-green still stops at a failed check" {
  fi_af_fixture
  export GH_MOCK_TRACE="$TMP/gh.trace"
  export GH_MOCK_PR_VIEW=$'7\t{"number":7,"state":"OPEN","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"FAILURE","status":"COMPLETED"}]}'
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 1 ]
  [[ "$output" == *"checks failed"* ]]
}
