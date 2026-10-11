#!/usr/bin/env bats
# Batch 3 queue fixes: pid reuse (start time), wait-free claim move, lock-break
# mutex, worktree failures requeue (bounded), cancel signals only its own run.

load 'helpers'
load 'autofix-helpers'

setup() { fi_setup_tmp; fi_af_fixture; }
teardown() { fi_teardown_tmp; }

_pstart_works() { [ -n "$(ps -o lstart= -p $$ 2>/dev/null)" ]; }

# A git on PATH that fails `worktree add`, or fails `fetch` after the first N
# fetch calls (the claim's wait check is call 1, the worktree cut call 2).
_git_stub() {
  local real; real="$(command -v git)"
  mkdir -p "$TMP/stubbin"
  cat > "$TMP/stubbin/git" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *" worktree add "*) [ "\${STUB_FAIL_WT:-}" = 1 ] && exit 1 ;;
  *" fetch "*)
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

# ---- entry 1: pid reuse -------------------------------------------------

@test "batch3 pid: setting a pid also stamps the process start time" {
  _pstart_works || skip "ps has no lstart here"
  source "$FI_BIN"
  fi_af_item_write "$TMP/item" "id=x"
  fi_af_item_set "$TMP/item" pid $$
  grep -q '^pstart=.\+' "$TMP/item"
  fi_af_item_set "$TMP/item" pid ""
  ! grep -q '^pstart=.\+' "$TMP/item" || false
}

@test "batch3 pid: a live pid with another start time is a crash and gets reaped" {
  fi_af_queue_fixture; ST="$FI_AF_ST"
  "$FI_BIN" autofix claim "$ID" >/dev/null
  fi_af_item_set "$ST/running/$ID" pid $$
  fi_af_item_set "$ST/running/$ID" pstart "Mon Jan  1 00:00:00 1990"
  fi_af_reap
  [ -f "$ST/queue/$ID" ]
  [ ! -f "$ST/running/$ID" ]
}

@test "batch3 pid: a lock owned by a reused pid is breakable at once" {
  source "$FI_BIN"; fi_af_context; ST="$FI_AF_ST"
  mkdir -p "$ST/running" "$ST/lock"
  printf 'owner-x\n' > "$ST/lock/owner"
  fi_af_item_write "$ST/running/owner-x" "id=owner-x" "pid=$$" "pstart=Mon Jan  1 00:00:00 1990"
  run fi_af_lock newrun
  [ "$status" -eq 0 ]
  [ "$(cat "$ST/lock/owner")" = newrun ]
}

@test "batch3 pid: a live pid with the recorded start time still holds its lock" {
  _pstart_works || skip "ps has no lstart here"
  source "$FI_BIN"; fi_af_context; ST="$FI_AF_ST"
  mkdir -p "$ST/running" "$ST/lock"
  printf 'owner-x\n' > "$ST/lock/owner"
  fi_af_item_write "$ST/running/owner-x" "id=owner-x" "pid=$$"
  fi_af_item_set "$ST/running/owner-x" pid $$
  run fi_af_lock newrun
  [ "$status" -eq 1 ]
  [ "$(cat "$ST/lock/owner")" = owner-x ]
}

# ---- entry 2: transient failures requeue, bounded ------------------------

@test "batch3 worktree: a failed worktree add requeues the item with a counter" {
  fi_af_queue_fixture; ST="$FI_AF_ST"
  _git_stub; export STUB_FAIL_WT=1
  rc=0; "$FI_BIN" autofix claim "$ID" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 8 ]
  [ -f "$ST/queue/$ID" ]
  [ ! -f "$ST/done/$ID" ]
  grep -q '^wt_retries=1$' "$ST/queue/$ID"
  [ ! -d "$ST/lock" ]
  ! grep -q 'autofix-failed' docs/found-issues.md || false
  # the daily slot is not spent by a claim that never got a worktree
  [ ! -s "$ST/day/$(date +%Y-%m-%d).spot" ] || [ "$(wc -l <"$ST/day/$(date +%Y-%m-%d).spot")" -eq 0 ]
}

@test "batch3 worktree: a failed fetch requeues, and after 3 requeues it fails as before" {
  fi_af_queue_fixture; ST="$FI_AF_ST"
  _git_stub; export STUB_FETCH_OK=1
  for i in 1 2 3; do
    rm -f "$TMP/fetchcount"
    rc=0; "$FI_BIN" autofix claim "$ID" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 8 ]
    [ -f "$ST/queue/$ID" ]
    grep -q "^wt_retries=$i\$" "$ST/queue/$ID"
  done
  rm -f "$TMP/fetchcount"
  rc=0; "$FI_BIN" autofix claim "$ID" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 6 ]
  [ ! -f "$ST/queue/$ID" ]
  grep -q '^result=failed: git fetch failed' "$ST/done/$ID"
  grep -q 'autofix-failed' docs/found-issues.md
}

@test "batch3 worktree: a requeue on a ship retry keeps its attempts" {
  fi_af_queue_fixture; ST="$FI_AF_ST"
  fi_af_item_set "$ST/queue/$ID" ship_tries 1
  fi_af_item_set "$ST/queue/$ID" attempts 2
  _git_stub; export STUB_FAIL_WT=1
  rc=0; "$FI_BIN" autofix claim "$ID" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 8 ]
  grep -q '^attempts=2$' "$ST/queue/$ID"
  grep -q '^ship_tries=1$' "$ST/queue/$ID"
}

# ---- entry 3: claim moves the file before stamping it --------------------

@test "batch3 claim: a cancel between the check and the stamp cannot revive the item" {
  fi_af_queue_fixture; ST="$FI_AF_ST"
  # Emulate fi_af_item_set losing the race on the QUEUE file: its tmp copy is
  # built, a cancel moves the item to done/, then the tmp lands on queue/.
  eval "_orig_item_set() $(declare -f fi_af_item_set | sed '1d')"
  fi_af_item_set() {
    if [[ "$1" == "$ST/queue/"* && "$2" == pid ]]; then
      cp "$1" "$1.race"
      mv "$1" "$ST/done/${1##*/}"
      mv "$1.race" "$1"
      return 0
    fi
    _orig_item_set "$@"
  }
  rc=0; fi_af_claim "$ID" >/dev/null 2>&1 || rc=$?
  [ ! -f "$ST/done/$ID" ]
  [ -f "$ST/running/$ID" ]
  grep -q '^launcher=B$' "$ST/running/$ID"
}

# ---- entry 4: breaking a stale lock is mutually exclusive ----------------

@test "batch3 lock: a contender whose stale verdict was overtaken does not steal the new lock" {
  source "$FI_BIN"; fi_af_context; ST="$FI_AF_ST"
  mkdir -p "$ST/running" "$ST/lock"
  printf 'dead1\n' > "$ST/lock/owner"
  fi_af_item_write "$ST/running/dead1" "id=dead1" "pid=999999"
  # Between this contender's verdict (dead owner) and its break, another
  # contender broke the lock and took it.
  eval "_orig_field() $(declare -f _fi_af_field | sed '1d')"
  _fi_af_field() {
    local v rc=0
    v="$(_orig_field "$@")" || rc=$?
    if [[ "$1" == "$ST/running/dead1" && ! -f "$TMP/raced" ]]; then
      : >"$TMP/raced"
      rm -rf "$ST/lock"; mkdir "$ST/lock"; printf 'winner\n' > "$ST/lock/owner"
    fi
    printf '%s' "$v"; return $rc
  }
  run fi_af_lock loser
  [ "$status" -eq 1 ]
  [ "$(cat "$ST/lock/owner")" = winner ]
  [ ! -d "$ST/lock.break" ]
}

@test "batch3 lock: a dead owner is still broken and taken" {
  source "$FI_BIN"; fi_af_context; ST="$FI_AF_ST"
  mkdir -p "$ST/running" "$ST/lock"
  printf 'dead1\n' > "$ST/lock/owner"
  fi_af_item_write "$ST/running/dead1" "id=dead1" "pid=999999"
  run fi_af_lock next
  [ "$status" -eq 0 ]
  [ "$(cat "$ST/lock/owner")" = next ]
  [ ! -d "$ST/lock.break" ]
}

# ---- entry 5: cancel signals only the run it recorded ---------------------

_fake_run() { (exec -a "found-issues autofix run $1" sleep 4716) & fpid=$!; }

@test "batch3 cancel: a run-shaped process with no recorded start time is stopped (the pid decides)" {
  _pstart_works || skip "ps has no lstart here"
  fi_af_queue_fixture; ST="$FI_AF_ST"
  "$FI_BIN" autofix claim "$ID" >/dev/null
  _fake_run x
  sleep 0.3
  [[ "$(ps -o command= -p "$fpid")" == *"autofix run"* ]]
  printf 'pid=%s\n' "$fpid" >>"$ST/running/$ID"
  printf 'pstart=\n' >>"$ST/running/$ID"
  printf '%s\n' "$ID" >"$ST/lock/owner"
  run "$FI_BIN" autofix cancel "$ID"
  [ "$status" -eq 0 ]
  ! kill -0 "$fpid" 2>/dev/null || false
}

@test "batch3 cancel: a run-shaped process with a different start time is not signalled" {
  _pstart_works || skip "ps has no lstart here"
  fi_af_queue_fixture; ST="$FI_AF_ST"
  "$FI_BIN" autofix claim "$ID" >/dev/null
  _fake_run y
  sleep 0.3
  printf 'pid=%s\n' "$fpid" >>"$ST/running/$ID"
  printf 'pstart=Mon Jan  1 00:00:00 1990\n' >>"$ST/running/$ID"
  printf '%s\n' "$ID" >"$ST/lock/owner"
  run "$FI_BIN" autofix cancel "$ID"
  [ "$status" -eq 0 ]
  kill -0 "$fpid"
  kill "$fpid"
}

@test "batch3 cancel: a run-shaped process with the recorded start time is stopped" {
  _pstart_works || skip "ps has no lstart here"
  fi_af_queue_fixture; ST="$FI_AF_ST"
  "$FI_BIN" autofix claim "$ID" >/dev/null
  _fake_run z
  sleep 0.3
  printf 'pid=%s\n' "$fpid" >>"$ST/running/$ID"
  _fi_af_pstart "$fpid"
  printf 'pstart=%s\n' "$FI_AF_PSTART" >>"$ST/running/$ID"
  printf '%s\n' "$ID" >"$ST/lock/owner"
  run "$FI_BIN" autofix cancel "$ID"
  [ "$status" -eq 0 ]
  ! kill -0 "$fpid" 2>/dev/null || false
}
