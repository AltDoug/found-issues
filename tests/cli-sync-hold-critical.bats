#!/usr/bin/env bats
# `sync` must never auto-close a [!] CRITICAL entry (#161).
#
# Severity is parsed in lib/parse-entries.sh and then discarded by sync, so a
# critical closed by an INFERRED signal -- a tombstone, or an annotation whose
# ref merely landed -- is a blind closure. It happens unattended (SessionStart
# runs sync) and it is permanent (no supported command reopens a [fixed]
# entry). The control entry in each test is the same defect at the same
# location WITHOUT [!], so these tests pin the hold, not a broken tombstone.

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

# Commit a file, then remove it: the tombstone precondition (absent from HEAD,
# present in history) that fi_git_confirms_removed requires (#151).
seed_removed_file() {
  mkdir -p src
  printf 'export const gone = 1;\n' > src/gone.ts
  git add src/gone.ts
  git commit -q -m "add gone.ts"
  git rm -q src/gone.ts
  git commit -q -m "delete gone.ts"
}

@test "sync: holds a [!] critical tombstone closure while closing the plain twin" {
  seed_removed_file
  fi_run log --critical "src/gone.ts:1 — critical defect in a file that later gets deleted"
  [ "$status" -eq 0 ]
  fi_run log "src/gone.ts:1 — plain defect in a file that later gets deleted"
  [ "$status" -eq 0 ]

  fi_run sync
  [ "$status" -eq 0 ]

  # The critical entry stays open and is marked for a human.
  grep -q '^- \[open\] \[!\].*critical defect' docs/found-issues.md
  grep -q 'critical defect.*(needs human verify)' docs/found-issues.md
  ! grep -q '^- \[fixed\] \[!\]' docs/found-issues.md

  # The plain control entry still closes: the tombstone mechanism is intact.
  grep -q '^- \[fixed\].*plain defect' docs/found-issues.md
  grep -q 'plain defect.*closure: tombstone' docs/found-issues.md

  # The held entry is not counted as closed, and the hold is reported.
  [[ "$output" == *"Closed: 1 (0 PR + 0 commit + 1 tombstone)"* ]]
  [[ "$output" == *"Held: 1 critical entry left [open]"* ]]
}

@test "sync: says nothing about holds when no critical entry was in scope" {
  seed_removed_file
  fi_run log "src/gone.ts:1 — plain defect only"
  fi_run sync
  [ "$status" -eq 0 ]
  [[ "$output" != *"Held:"* ]]
  grep -q '^- \[fixed\].*plain defect only' docs/found-issues.md
}

@test "sync: the marker is appended exactly once across repeated runs" {
  seed_removed_file
  fi_run log --critical "src/gone.ts:1 — critical defect held twice"
  fi_run sync
  fi_run sync
  [ "$status" -eq 0 ]
  run grep -c 'needs human verify' docs/found-issues.md
  [ "$output" -eq 1 ]
  grep -q '^- \[open\] \[!\]' docs/found-issues.md
}

@test "sync --dry-run reports the hold without writing the ledger" {
  seed_removed_file
  fi_run log --critical "src/gone.ts:1 — critical defect under dry run"
  local before
  before="$(cat docs/found-issues.md)"
  fi_run sync --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Held: 1 critical entry left [open]"* ]]
  [ "$before" = "$(cat docs/found-issues.md)" ]
}
