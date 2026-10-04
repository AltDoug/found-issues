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
