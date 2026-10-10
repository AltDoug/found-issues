#!/usr/bin/env bats
# Queue fixes: a requeued item starts clean, a failed ls-remote is not "gone",
# a lock whose mtime cannot be read is not stale.

load 'helpers'
load 'autofix-helpers'

setup() { fi_setup_tmp; fi_af_fixture; }
teardown() { fi_teardown_tmp; }

# Claim the fixture item, then leave it carrying a prior B run's counters.
_dirty_running_item() {
  fi_af_queue_fixture
  ST="$FI_AF_ST"
  "$FI_BIN" autofix claim "$ID" >/dev/null
  fi_af_item_set "$ST/running/$ID" attempts 1
  fi_af_item_set "$ST/running/$ID" verdict reject
  fi_af_item_set "$ST/running/$ID" verdict_reason "wrong tree"
  fi_af_item_set "$ST/running/$ID" verdict_tree x
}

_assert_clean_counters() {
  grep -q '^attempts=0$' "$1"
  ! grep -q '^verdict=.\+' "$1" || false
  ! grep -q '^verdict_reason=.\+' "$1" || false
  ! grep -q '^verdict_tree=.\+' "$1" || false
}

@test "queue fixes: a reaped crash clears attempts and the verdict fields" {
  _dirty_running_item
  fi_af_item_set "$ST/running/$ID" pid 999999
  fi_af_reap
  [ -f "$ST/queue/$ID" ]
  _assert_clean_counters "$ST/queue/$ID"
}

@test "queue fixes: a requeued claim clears attempts and the verdict fields" {
  _dirty_running_item
  fi_af_requeue "$ID" "engine outage"
  [ -f "$ST/queue/$ID" ]
  _assert_clean_counters "$ST/queue/$ID"
}

# A git on PATH that answers ls-remote with exit <rc> and runs everything else.
_git_lsremote_rc() {
  local real; real="$(command -v git)"
  mkdir -p "$TMP/stubbin"
  cat > "$TMP/stubbin/git" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = ls-remote ] && exit $1; done
exec "$real" "\$@"
STUB
  chmod +x "$TMP/stubbin/git"
  export PATH="$TMP/stubbin:$PATH"
}

@test "queue fixes: a failing ls-remote keeps the tracked branch as the base" {
  fi_af_remote_branch gsd/phase-01
  source "$FI_BIN"; fi_af_context; AFI_root="$REPO"
  _git_lsremote_rc 128
  fi_af_landing_branch
  [ "$AFI_base" = gsd/phase-01 ]
  [[ "$AFI_base_why" == *"ls-remote failed"* ]]
}

@test "queue fixes: ls-remote exit 2 still means the branch is gone" {
  fi_af_remote_branch gsd/phase-01
  source "$FI_BIN"; fi_af_context; AFI_root="$REPO"
  fi_use_gh_shim
  export GH_MOCK_PR_LIST='[]'
  _git_lsremote_rc 2
  fi_af_landing_branch
  [ "$AFI_base" = main ]
  [ "$AFI_base_why" = "gsd/phase-01 gone, base unknown" ]
}

@test "queue fixes: a lock whose mtime reads 0 is not broken from a live owner" {
  source "$FI_BIN"; fi_af_context; ST="$FI_AF_ST"
  mkdir -p "$ST/running" "$ST/lock"
  printf 'owner-x\n' > "$ST/lock/owner"
  fi_af_item_write "$ST/running/owner-x" "id=owner-x" "pid=$$"
  fi_file_mtime() { echo 0; }
  run fi_af_lock newrun
  [ "$status" -eq 1 ]
  [ "$(cat "$ST/lock/owner")" = owner-x ]
}
