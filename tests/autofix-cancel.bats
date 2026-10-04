#!/usr/bin/env bats
# autofix cancel (spec §8; phase 5 ruling 6).

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_fixture; fi_use_standins; fi_af_queue_fixture
  ST="$FI_AF_ST"
  export GH_MOCK_TRACE="$TMP/gh.trace"
}
# A failing cancel must not leave the stand-in sleeping for an hour.
teardown() { pkill -f 'sleep 471[34]' 2>/dev/null || true; fi_teardown_tmp; }

@test "autofix cancel: a queued item is retired and the ledger is untouched" {
  before="$(cat docs/found-issues.md)"
  run "$FI_BIN" autofix cancel "$ID"
  [ "$status" -eq 0 ]
  grep -q '^result=cancelled: ' "$ST/done/$ID"
  [ "$(cat docs/found-issues.md)" = "$before" ]
}

@test "autofix cancel: a B-claimed item loses its worktree and the lock" {
  wt="$("$FI_BIN" autofix claim "$ID")"
  [ -d "$wt" ]
  run "$FI_BIN" autofix cancel "$ID"
  [ "$status" -eq 0 ]
  [ ! -d "$wt" ]
  [ ! -d "$ST/lock" ]
  run "$FI_BIN" autofix brief "$ID"
  [ "$status" -ne 0 ]
}

@test "autofix cancel: an A run and its engine child are stopped" {
  export FI_STANDIN_SLEEP=4713
  "$FI_BIN" autofix run "$ID" --engine claude >/dev/null 2>&1 &
  rpid=$!
  for _ in $(seq 1 40); do grep -q '^cpgid=' "$ST/running/$ID" 2>/dev/null && break; sleep 0.25; done
  cpgid="$(sed -n 's/^cpgid=//p' "$ST/running/$ID")"
  [ -n "$cpgid" ]
  run "$FI_BIN" autofix cancel "$ID"
  [ "$status" -eq 0 ]
  wait "$rpid" || true
  ! kill -0 "$rpid" 2>/dev/null || false
  ! kill -0 -- "-$cpgid" 2>/dev/null || false
  grep -q '^result=cancelled: ' "$ST/done/$ID"
  ! grep -q 'autofix-failed' docs/found-issues.md || false
}

@test "autofix cancel: of a done item exits 1 and leaves its result" {
  "$FI_BIN" autofix cancel "$ID" >/dev/null
  cp "$ST/done/$ID" "$TMP/before"
  run "$FI_BIN" autofix cancel "$ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"already finished"* ]]
  cmp -s "$TMP/before" "$ST/done/$ID"
}

@test "autofix cancel: a pid that is not an autofix run is never signalled" {
  sleep 4714 & spid=$!
  wt="$("$FI_BIN" autofix claim "$ID")"
  printf 'pid=%s\n' "$spid" >>"$ST/running/$ID"
  run "$FI_BIN" autofix cancel "$ID"
  [ "$status" -eq 0 ]
  kill -0 "$spid"
  kill "$spid"
}

@test "autofix cancel: a stale running item never signals the run that moved on" {
  export FI_STANDIN_SLEEP=4713
  "$FI_BIN" autofix run "$ID" --engine claude >/dev/null 2>&1 &
  rpid=$!
  for _ in $(seq 1 40); do grep -q '^cpgid=' "$ST/running/$ID" 2>/dev/null && break; sleep 0.25; done
  cpgid="$(sed -n 's/^cpgid=//p' "$ST/running/$ID")"
  [ -n "$cpgid" ]
  # An item the drain already left: same run pid and engine group, no lock.
  sed -e 's/^id=.*/id=stale1/' -e '/^wt=/d' -e '/^branch=/d' "$ST/running/$ID" > "$ST/running/stale1"
  run "$FI_BIN" autofix cancel stale1
  [ "$status" -eq 0 ]
  kill -0 "$rpid"
  kill -0 -- "-$cpgid"
  [ -f "$ST/running/$ID" ]
  grep -q '^result=cancelled: ' "$ST/done/stale1"
  "$FI_BIN" autofix cancel "$ID" >/dev/null
  wait "$rpid" || true
}

@test "autofix cancel: an item whose PR is already open is refused and names it" {
  "$FI_BIN" autofix claim "$ID" >/dev/null
  fi_af_item_set "$ST/running/$ID" pr 42
  run "$FI_BIN" autofix cancel "$ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PR #42"* ]]
  [ -f "$ST/running/$ID" ]
}

@test "autofix run: the PR number is on the item before auto-merge is armed" {
  mkdir -p "$TMP/wrap"
  cat > "$TMP/wrap/gh" <<SH
#!/usr/bin/env bash
[[ "\$1 \$2" == "pr merge" ]] && cp "$ST/running/$ID" "$TMP/at-merge"
exec "$TEST_REPO_ROOT/tests/bin-shims/gh" "\$@"
SH
  chmod +x "$TMP/wrap/gh"
  export GH_MOCK_PR_VIEW=$'7\t{"number":7,"state":"OPEN","statusCheckRollup":[]}'
  export FI_STANDIN_EDIT="sed -i.bak 's/ - / + /' src/calc.sh && rm -f src/calc.sh.bak"
  PATH="$TMP/wrap:$PATH" run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '^pr=7$' "$TMP/at-merge"
}

@test "autofix cancel: a claim landing mid-cancel is cancelled as a claimed item" {
  # The race: a claim moves the item between cancel's queued check and its
  # move. Fired from whichever of the two cancel reaches first.
  race() {
    [[ -n "${RACED:-}" ]] && return 0
    RACED=1
    "$FI_BIN" autofix claim "$ID" > "$TMP/wt"
  }
  eval "orig_item_read() $(declare -f fi_af_item_read | tail -n +2)"
  fi_af_item_read() { [[ "$1" == "$QITEM" ]] && race; orig_item_read "$@"; }
  mv() { [[ "$1" == "$QITEM" ]] && race; command mv "$@"; }
  run fi_af_cancel "$ID"
  [ "$status" -eq 0 ]
  wt="$(cat "$TMP/wt")"
  [ -n "$wt" ]
  grep -q '^result=cancelled: ' "$ST/done/$ID"
  [ ! -d "$wt" ]
  [ ! -d "$ST/lock" ]
}
