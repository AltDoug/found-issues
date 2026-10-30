#!/usr/bin/env bats
# Read-only sync for pull-only clones (3.11.0). A clone that only ever pulls
# (a deploy box, measured 2026-10-29) must never get an uncommitted ledger
# edit from sync: git then refuses its next `pull --ff-only`, even when
# upstream made the byte-identical change. `git config found-issues.readonly
# true` (or FOUND_ISSUES_READONLY=1) makes every sync there report what it
# would do and write nothing: no closures, no demotions, no archive.

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

ledger_sum() { cksum < docs/found-issues.md; }

@test "sync readonly: git config found-issues.readonly true writes nothing" {
  fi_seed_archive_bait
  git config found-issues.readonly true
  local before
  before="$(ledger_sum)"
  fi_run sync
  [ "$status" -eq 0 ]
  [ "$(ledger_sum)" = "$before" ]
  [ ! -f docs/found-issues-archive.md ]
  [[ "$output" == *"Read-only clone (found-issues.readonly)"* ]]
  [[ "$output" == *"Closed: 1"* ]]
}

@test "sync readonly: FOUND_ISSUES_READONLY=1 writes nothing without the config key" {
  fi_seed_archive_bait
  local before
  before="$(ledger_sum)"
  FOUND_ISSUES_READONLY=1 fi_run sync
  [ "$status" -eq 0 ]
  [ "$(ledger_sum)" = "$before" ]
  [ ! -f docs/found-issues-archive.md ]
  [[ "$output" == *"Read-only clone"* ]]
}

@test "sync readonly: FOUND_ISSUES_READONLY=0 overrides the config key" {
  fi_seed_archive_bait
  git config found-issues.readonly true
  FOUND_ISSUES_READONLY=0 fi_run sync
  [ "$status" -eq 0 ]
  grep -q 'closure: tombstone' docs/found-issues.md
  [ -f docs/found-issues-archive.md ]
}

@test "sync readonly: found-issues.readonly false keeps normal writes" {
  fi_seed_archive_bait
  git config found-issues.readonly false
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q 'closure: tombstone' docs/found-issues.md
  [[ "$output" != *"Read-only clone"* ]] || false
}

@test "sync readonly: a commit-stale demotion is not written" {
  mkdir -p src
  echo "x" > src/foo.py
  git add src/foo.py
  git commit -q -m "init"
  fi_seed_entry "src/foo.py:1 — bug (commit: deadbeef)"
  git config found-issues.readonly true
  local before
  before="$(ledger_sum)"
  fi_run sync
  [ "$status" -eq 0 ]
  [ "$(ledger_sum)" = "$before" ]
  [[ "$output" == *"Demoted: 1"* ]]
}

@test "sync readonly: SessionStart leaves the ledger untouched and still lists open entries" {
  fi_seed_archive_bait
  git config found-issues.readonly true
  local before
  before="$(ledger_sum)"
  FAKE_HOME="$(mktemp -d)"
  HOME="$FAKE_HOME" FOUND_ISSUES_BIN="$FI_BIN" \
    run bash "${BATS_TEST_DIRNAME}/../hooks/session-start.sh" < /dev/null
  rm -rf "$FAKE_HOME"
  [ "$status" -eq 0 ]
  [ "$(ledger_sum)" = "$before" ]
  [ ! -f docs/found-issues-archive.md ]
  [[ "$output" == *"cites a deleted file"* ]]
}

@test "sync readonly: doctor reports the read-only clone" {
  git config found-issues.readonly true
  fi_run doctor
  [[ "$output" == *"sync is read-only in this clone"* ]]
}
