#!/usr/bin/env bats
# Batch 8: a repo root whose sanitized name is longer than a file name may be
# (~255 bytes) no longer aborts a retire and wedges the lock
# (ledger lib/autofix-status.sh:231).

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp
  TMP_TOP="$TMP"
}
teardown() { TMP="$TMP_TOP"; fi_teardown_tmp; }

long_dir() { printf "$1%.0s" $(seq 1 100); }

@test "b8 root key: a short root keeps its sanitized name" {
  source "$TEST_REPO_ROOT/lib/segment-cache.sh"
  fi_af_root_key "/Users/me/projects/repo"
  [ "$FI_AF_KEY" = "_Users_me_projects_repo" ]
}

@test "b8 root key: a long root gets a bounded key that tells roots apart" {
  source "$TEST_REPO_ROOT/lib/segment-cache.sh"
  base="/x/$(long_dir a)/$(long_dir b)/$(long_dir c)"
  fi_af_root_key "$base/one"; k1="$FI_AF_KEY"
  fi_af_root_key "$base/two"; k2="$FI_AF_KEY"
  fi_af_root_key "$base/one"; k3="$FI_AF_KEY"
  [ "${#k1}" -le 200 ]
  [ "$k1" != "$k2" ]
  [ "$k1" = "$k3" ]
  [[ "$k1" =~ ^[A-Za-z0-9._-]+$ ]]
}

@test "b8 cancel: a claimed item under a root longer than 255 bytes is cancelled and unlocks" {
  TMP="$TMP/$(long_dir a)/$(long_dir b)/$(long_dir c)"
  mkdir -p "$TMP"
  fi_af_fixture; fi_use_standins; fi_af_queue_fixture
  [ "${#PWD}" -gt 255 ]
  wt="$("$FI_BIN" autofix claim "$ID")"
  run "$FI_BIN" autofix cancel "$ID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cancelled $ID."* ]]
  [ ! -d "$FI_AF_ST/lock" ]
  grep -q '^result=cancelled: ' "$FI_AF_ST/done/$ID"
}
