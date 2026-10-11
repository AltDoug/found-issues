#!/usr/bin/env bats
# Review A of ledger batch 4: the STUCK marker clears when the base turns
# green, auto-fix is switched off, or its last base failure is a week old;
# the sweep busy set normalizes paths and covers merge results; a chain skip
# is a machine-readable marker, not display text; a sweep claim clears the
# wait fields a fetch-failure requeue set.

load 'helpers'
load 'autofix-helpers'

setup() { fi_setup_tmp; export PATH="$TEST_REPO_ROOT/bin:$PATH"; export FOUND_ISSUES_CACHE_DIR="$TMP/cache"; }
teardown() { fi_teardown_tmp; }

seg() { "$FI_BIN" status --format=segment --cwd "${1:-$REPO}"; }

# ---- helpers copied from fix-batch4-stuck.bats ----------------------------

stuck_setup() {
  fi_af_fixture
  fi_af_queue_fixture
  ST="$FI_AF_ST"
  RED='echo "not ok 1 needs donor files"; echo "not ok 2 reads local toml"; exit 1'
  git config found-issues.autofix.testCommand "$RED"
  git config found-issues.autofix.dailyFixes 50
  STUCK_FILE="$FI_AF_ROOT/stuck/${REPO//[^A-Za-z0-9._-]/_}"
}

retire_one() {
  local next="${1:-1}" id
  id="$(ls "$ST/queue" | head -1)"
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 5 ]
  "$FI_BIN" log --fix small "test.sh:$((next + 10)) — entry $next" >/dev/null
}

make_stuck() { retire_one 1; retire_one 2; retire_one 3; run seg; [[ "$output" == *"stuck"* ]]; }

# ---- helpers copied from fix-batch4-sweep.bats ----------------------------

sweep_edit() {
  export FI_STANDIN_EDIT='mkdir -p tests; for f in src/f*.sh; do n="${f#src/f}"; n="${n%.sh}"; case "$FI_STANDIN_PROMPT" in *"src/f$n.sh:1"*) sed -i.bak "s/- 1/+ 0/" "$f"; rm -f "$f.bak"; printf "[ \"\$(f%s 2)\" = 2 ]\n" "$n" >> tests/t_f$n.sh ;; esac; done'
}
gh_mock() {
  export GH_MOCK_TRACE="$TMP/gh.trace" GH_MOCK_PR_CREATE_URL=https://github.com/foo/bar/pull/9
  export GH_MOCK_PR_VIEW=$'9\t{"number":9,"state":"OPEN","statusCheckRollup":[]}'
}
queue_cont() { # a continuation item whose skip_files is "$1"
  source "$FI_BIN"; fi_af_context
  QID=20991231-000000-00007
  fi_af_item_write "$FI_AF_ST/queue/$QID" "id=$QID" kind=sweep "root=$REPO" slug=foo/bar loc=sweep \
    engine=claude "queued=$(date +%Y-%m-%dT%H:%M:%S)" crashes=0 cont=2 "cap_day=$(date +%Y-%m-%d)" \
    "skip_files=$1" base=main
  ST="$FI_AF_ST"
}

# ---- helper copied from fix-batch4-sweep2.bats ----------------------------

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

# ===== finding 1: the stuck marker clears ==================================

@test "review a stuck: a base found green clears the marker at once" {
  stuck_setup; make_stuck
  git config found-issues.autofix.testCommand 'true'
  id="$(ls "$ST/queue" | head -1)"
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 0 ]
  [ ! -f "$STUCK_FILE" ]
  run seg
  [[ "$output" != *"stuck"* ]] || false
  run "$FI_BIN" autofix summary
  [[ "$output" != *"STUCK"* ]] || false
}

@test "review a stuck: autofix off clears the marker" {
  stuck_setup; make_stuck
  run "$FI_BIN" autofix off
  [ "$status" -eq 0 ]
  run seg
  [[ "$output" != *"stuck"* ]] || false
  "$FI_BIN" autofix on >/dev/null
  run "$FI_BIN" autofix summary
  [[ "$output" != *"STUCK"* ]] || false
}

@test "review a stuck: config autofix false in this repo clears the marker" {
  stuck_setup; make_stuck
  run "$FI_BIN" config autofix false
  [ "$status" -eq 0 ]
  run seg
  [[ "$output" != *"stuck"* ]] || false
}

@test "review a stuck: a streak whose last base failure is over 7 days old is ignored" {
  stuck_setup; make_stuck
  mkdir -p "${STUCK_FILE%/*}"
  printf '3\nneeds donor files\n%s\n' "$(( $(date +%s) - 8 * 86400 ))" > "$STUCK_FILE"
  run seg
  [[ "$output" != *"stuck"* ]] || false
  run "$FI_BIN" autofix summary
  [[ "$output" != *"STUCK"* ]] || false
}

@test "review a stuck: a streak 6 days old still shows" {
  stuck_setup; make_stuck
  mkdir -p "${STUCK_FILE%/*}"
  printf '3\nneeds donor files\n%s\n' "$(( $(date +%s) - 6 * 86400 ))" > "$STUCK_FILE"
  run seg
  [[ "$output" == *"stuck"* ]]
  run "$FI_BIN" autofix summary
  [[ "$output" == *"STUCK"* ]]
}

@test "review a stuck: a failure after an aged-out streak starts the count again" {
  stuck_setup
  mkdir -p "${STUCK_FILE%/*}"
  printf '5\nold names\n%s\n' "$(( $(date +%s) - 9 * 86400 ))" > "$STUCK_FILE"
  retire_one 1
  run seg
  [[ "$output" != *"stuck"* ]] || false
  [ "$(sed -n 1p "$STUCK_FILE")" = 1 ]
}

# ===== finding 2: the busy set =============================================

busy_fixture() {
  fi_af_sweep_fixture 4
  source "$FI_BIN"; fi_af_context; AFI_root="$REPO"; AFI_base=main
  printf '# busy\n' >> src/f2.sh
}

@test "review a busy: a ./-prefixed or dotted path matches like the pathspec did" {
  busy_fixture
  _fi_af_busy_set
  _fi_af_in_busy_set src/f2.sh
  _fi_af_in_busy_set ./src/f2.sh
  _fi_af_in_busy_set src/../src/f2.sh
  ! _fi_af_in_busy_set src/f1.sh || false
}

@test "review a busy: a case-insensitive checkout matches a differently cased path" {
  busy_fixture
  git config core.ignorecase true
  _fi_af_busy_set
  _fi_af_in_busy_set SRC/F2.sh
}

@test "review a busy: a path git would C-quote is still found" {
  busy_fixture
  printf 'x\n' > 'src/we"ird.sh'
  printf 'x\n' > "$(printf 'src/ta\tb.sh')"
  git add 'src/we"ird.sh' && git add -- "$(printf 'src/ta\tb.sh')"
  _fi_af_busy_set
  _fi_af_in_busy_set 'src/we"ird.sh'
  _fi_af_in_busy_set "$(printf 'src/ta\tb.sh')"
}

@test "review a busy: the result of a merge commit counts as unpushed work" {
  busy_fixture
  git checkout -q -- src/f2.sh
  git checkout -q -b side
  printf 'side\n' > side.sh; git add side.sh; git commit -q -m side
  git checkout -q main
  git merge -q --no-ff --no-commit side
  printf 'evil\n' > evil.sh; git add evil.sh
  git commit -q -m "merge side with an extra file"
  _fi_af_busy_set
  _fi_af_in_busy_set evil.sh
  _fi_af_in_busy_set side.sh
}

# ===== finding 3: chain skips ==============================================

@test "review a chain: a long touched path does not hide the skipped entry from the next batch" {
  fi_af_sweep_fixture 6; fi_use_standins; sweep_edit; gh_mock
  git config found-issues.autofix.sweepBatch 2
  long="shared_$(printf 'x%.0s' $(seq 1 150)).txt"
  export FI_STANDIN_EDIT="$FI_STANDIN_EDIT"'; case "$FI_STANDIN_PROMPT" in *"src/f1.sh:1"*) echo "shared" >> '"$long"' ;; esac'
  queue_cont "$long"
  "$FI_BIN" autofix run "$QID" --engine claude
  grep -q "^src/f1.sh:1	skipped	" "$ST/sweeps/$QID.outcomes"
  c="$(grep -l '^cont=3' "$ST"/done/*)"
  skip="$(sed -n 's/^skip_files=//p' "$c")"
  [[ ":$skip:" == *":$long:"* ]]
  [[ ":$skip:" == *":src/f1.sh:"* ]]
  held="$(sed -n 's/^held_files=//p' "$c")"
  [[ ":$held:" == *":src/f1.sh:"* ]]
}

@test "review a chain: a file held back only because an entry on it was skipped is logged as that" {
  fi_af_sweep_fixture 6; fi_use_standins; sweep_edit; gh_mock
  git config found-issues.autofix.sweepBatch 2
  export FI_STANDIN_EDIT="$FI_STANDIN_EDIT"'; case "$FI_STANDIN_PROMPT" in *"src/f1.sh:1"*) echo "shared" >> shared.txt ;; esac'
  queue_cont shared.txt
  "$FI_BIN" autofix run "$QID" --engine claude
  c="$(grep -l '^cont=3' "$ST"/done/*)"; cid="${c##*/}"
  log="$FI_AF_RUNS/$cid.log"
  grep -q "sweep: skip src/f1.sh:1 (held back" "$log" || { cat "$log"; false; }
  ! grep -q "sweep: skip src/f1.sh:1 (file in an earlier batch's PR)" "$log" || false
}

# ===== finding 4: a sweep claim clears the wait fields =====================

@test "review a wait: a sweep claim after a fetch-failure requeue clears waiting and wait_next" {
  fi_af_sweep_fixture 5; fi_use_standins
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  SID="$(printf '%s\n' "$output" | sed -n 's/^AUTOFIX-SWEEP-DUE //p')"
  ST="$FOUND_ISSUES_STATE_DIR/autofix/foo__bar"
  [ -n "$SID" ]
  _git_stub; export STUB_FETCH_FAIL=1
  rc=0; "$FI_BIN" autofix claim "$SID" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 8 ]
  grep -q '^waiting=git fetch failed$' "$ST/queue/$SID"
  unset STUB_FETCH_FAIL
  rc=0; "$FI_BIN" autofix claim "$SID" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ]
  ! grep -q '^waiting=.' "$ST/running/$SID" || false
  ! grep -q '^wait_next=.' "$ST/running/$SID" || false
  ! grep -q '^wt_retries=.' "$ST/running/$SID" || false
}
