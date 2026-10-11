#!/usr/bin/env bats
# Ledger batch 4 (sweep/queue/classify): a sweep claim finds busy files once
# per claim instead of once per candidate, a failed fetch at the worktree cut
# waits (sweep claims and topic spot items too) and spends no daily slot, and
# the classifier lists entries it has not been shown before the ones it has.

load 'helpers'
load 'autofix-helpers'

setup() { fi_setup_tmp; export PATH="$TEST_REPO_ROOT/bin:$PATH"; }
teardown() { fi_teardown_tmp; }

# A git on PATH that logs every call's arguments to $TMP/git.calls and, with
# STUB_FETCH_FAIL=1, fails every fetch; with STUB_FETCH_OK=<n> it fails every
# fetch after the first n (the spot claim's wait check is call 1).
_git_stub() {
  local real; real="$(command -v git)"
  mkdir -p "$TMP/stubbin"
  cat > "$TMP/stubbin/git" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMP/git.calls"
case " \$* " in
  *" fetch "*)
    [ "\${STUB_FETCH_FAIL:-}" = 1 ] && exit 1
    if [ -n "\${STUB_FETCH_OK:-}" ]; then
      n=\$(cat "$TMP/fetchcount" 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n >"$TMP/fetchcount"
      [ \$n -gt \$STUB_FETCH_OK ] && exit 1
    fi ;;
esac
exec "$real" "\$@"
STUB
  chmod +x "$TMP/stubbin/git"
  export PATH="$TMP/stubbin:$PATH"
}

# 6 fixable files plus src/f7.sh (untracked, so not on origin). src/f2.sh has
# an uncommitted edit, src/f3.sh a local commit no remote branch has. Queues
# the sweep; sets SID and ST.
_busy_fixture() {
  fi_af_sweep_fixture 6; fi_use_standins
  printf '# busy\n' >> src/f2.sh
  printf '# unpushed\n' >> src/f3.sh
  git add src/f3.sh && git commit -q -m "local f3"
  printf 'g\n' > src/f7.sh
  printf -- '- [open] 2026-10-05 src/f7.sh:1 — f7 is not pushed (fix: medium)\n' >> docs/found-issues.md
  source "$FI_BIN"; fi_af_context; AFI_root="$REPO"
  fi_af_sweep_check >/dev/null
  SID="$(ls "$FI_AF_ST/queue" | head -1)"
  ST="$FI_AF_ST"
  [ -n "$SID" ]
}

# ---- lib/autofix-sweep.sh:274: busy files are listed once per claim ------

@test "batch4 sweep2 ready: no per-candidate git call, same entries kept" {
  _busy_fixture
  _git_stub
  run "$FI_BIN" autofix claim "$SID"
  [ "$status" -eq 0 ]
  # busy (f2), unpushed (f3) and not-on-origin (f7) entries are left out
  e="$ST/sweeps/$SID.entries"
  for n in 1 4 5 6; do grep -q "src/f$n.sh:1" "$e"; done
  for n in 2 3 7; do ! grep -q "src/f$n.sh:1" "$e" || false; done
  fi_af_context
  log="$FI_AF_RUNS/$SID.log"
  grep -q 'sweep: skip src/f2.sh:1 (busy)' "$log"
  grep -q 'sweep: skip src/f3.sh:1 (busy)' "$log"
  grep -q 'sweep: skip src/f7.sh:1 (not on origin/main)' "$log" || { cat "$log"; false; }
  # no git process was given a candidate's path (cat-file, diff or rev-list
  # per candidate): the busy set and the origin tree are read once
  [ -f "$TMP/git.calls" ]
  ! grep -q 'src/f[0-9]' "$TMP/git.calls" || false
}

# ---- lib/autofix-sweep.sh:246: a failed fetch at the worktree cut waits ---

@test "batch4 sweep2 wait: a sweep claim whose fetch fails requeues and waits" {
  fi_af_sweep_fixture 5; fi_use_standins
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  SID="$(printf '%s\n' "$output" | sed -n 's/^AUTOFIX-SWEEP-DUE //p')"
  ST="$FOUND_ISSUES_STATE_DIR/autofix/foo__bar"
  [ -n "$SID" ]
  _git_stub; export STUB_FETCH_FAIL=1
  rc=0; "$FI_BIN" autofix claim "$SID" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 8 ]
  [ -f "$ST/queue/$SID" ]
  [ ! -f "$ST/done/$SID" ]
  grep -q '^wt_retries=1$' "$ST/queue/$SID"
  grep -q '^waiting=git fetch failed$' "$ST/queue/$SID"
  grep -q '^wait_next=[0-9][0-9]*$' "$ST/queue/$SID"
  [ ! -d "$ST/lock" ]
  ! grep -q 'autofix-failed' docs/found-issues.md || false
  [ ! -s "$ST/day/$(date +%Y-%m-%d).sweep" ]
  # the network is back: the same item claims normally
  unset STUB_FETCH_FAIL
  rc=0; "$FI_BIN" autofix claim "$SID" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ]
  [ -s "$ST/day/$(date +%Y-%m-%d).sweep" ]
}

@test "batch4 sweep2 wait: a sweep whose fetch keeps failing fails after 3 requeues" {
  fi_af_sweep_fixture 5; fi_use_standins
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  SID="$(printf '%s\n' "$output" | sed -n 's/^AUTOFIX-SWEEP-DUE //p')"
  ST="$FOUND_ISSUES_STATE_DIR/autofix/foo__bar"
  [ -n "$SID" ]
  _git_stub; export STUB_FETCH_FAIL=1
  for i in 1 2 3; do
    rc=0; "$FI_BIN" autofix claim "$SID" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 8 ]
    grep -q "^wt_retries=$i\$" "$ST/queue/$SID"
  done
  rc=0; "$FI_BIN" autofix claim "$SID" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 6 ]
  [ ! -f "$ST/queue/$SID" ]
  grep -q '^result=failed: git fetch failed' "$ST/done/$SID"
  [ ! -s "$ST/day/$(date +%Y-%m-%d).sweep" ]
}

@test "batch4 sweep2 wait: a topic spot item whose fetch fails requeues, no slot spent" {
  fi_af_fixture
  source "$FI_BIN"; fi_af_context
  printf -- '- [open] 2026-10-05 environment (agent PATH) — topic bug (fix: small)\n' >> docs/found-issues.md
  fi_af_queue_spot "$(grep -m1 'topic bug' docs/found-issues.md)" >/dev/null
  ID="$(ls "$FI_AF_ST/queue" | head -1)"; ST="$FI_AF_ST"
  _git_stub; export STUB_FETCH_FAIL=1
  rc=0; "$FI_BIN" autofix claim "$ID" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 8 ]
  [ -f "$ST/queue/$ID" ]
  grep -q '^wt_retries=1$' "$ST/queue/$ID"
  [ ! -s "$ST/day/$(date +%Y-%m-%d).spot" ]
}

@test "batch4 sweep2 slot: a spot item whose cut fetch fails after the wait check spends no slot, even after the last retry" {
  fi_af_fixture; fi_af_queue_fixture; ST="$FI_AF_ST"
  _git_stub; export STUB_FETCH_OK=1
  for i in 1 2 3; do
    rm -f "$TMP/fetchcount"
    rc=0; "$FI_BIN" autofix claim "$ID" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 8 ]
    [ ! -s "$ST/day/$(date +%Y-%m-%d).spot" ]
  done
  rm -f "$TMP/fetchcount"
  rc=0; "$FI_BIN" autofix claim "$ID" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 6 ]
  grep -q '^result=failed: git fetch failed' "$ST/done/$ID"
  [ ! -s "$ST/day/$(date +%Y-%m-%d).spot" ]
}

# ---- lib/autofix-classify.sh:21: unseen entries are listed first ---------

@test "batch4 classify list: entries not yet offered come before offered ones, capped at 20" {
  fi_af_fixture; source "$FI_BIN"; fi_af_context
  AFI_root="$REPO"
  { printf '# found-issues\n\n'
    for i in $(seq 1 25); do printf -- '- [open] 2026-10-01 src/calc.sh:%s — untagged number %s\n' "$i" "$i"; done
  } > docs/found-issues.md
  # entries 1-20 were offered on an earlier sweep
  mkdir -p "$FI_AF_ST"
  for i in $(seq 1 20); do
    fi_entry_dedup_key_v "- [open] 2026-10-01 src/calc.sh:$i — untagged number $i" "$REPO"
    printf '%s\n' "$FI_KEY" >>"$FI_AF_ST/classify-offered"
  done
  _fi_af_classify_list docs/found-issues.md "$TMP/list"
  [ "$(grep -c '^U' "$TMP/list")" -eq 20 ]
  # the five unseen entries lead the list
  for i in 21 22 23 24 25; do
    n=$((i - 20))
    sed -n "${n}p" "$TMP/list" | grep -q "^U$n	.*untagged number $i\$"
  done
  # the rest of the cap is filled with offered entries, in ledger order
  sed -n 6p "$TMP/list" | grep -q "^U6	.*untagged number 1\$"
  sed -n 20p "$TMP/list" | grep -q "^U20	.*untagged number 15\$"
}

@test "batch4 classify list: with nothing offered yet the list is unchanged (first 20)" {
  fi_af_fixture; source "$FI_BIN"; fi_af_context
  AFI_root="$REPO"
  { printf '# found-issues\n\n'
    for i in $(seq 1 25); do printf -- '- [open] 2026-10-01 src/calc.sh:%s — untagged number %s\n' "$i" "$i"; done
  } > docs/found-issues.md
  _fi_af_classify_list docs/found-issues.md "$TMP/list"
  [ "$(grep -c '^U' "$TMP/list")" -eq 20 ]
  sed -n 1p "$TMP/list" | grep -q "^U1	.*untagged number 1\$"
  sed -n 20p "$TMP/list" | grep -q "^U20	.*untagged number 20\$"
}
