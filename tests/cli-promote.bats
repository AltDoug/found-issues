#!/usr/bin/env bats
# Tests for `found-issues promote`

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

@test "promote: refuses on default branch" {
  fi_run log "src/foo.py:1 — bug"
  git add -A; git commit -q -m "init"
  fi_run promote
  [ "$status" -ne 0 ]
  [[ "$output" == *"already on"* ]]
}

@test "promote: refuses outside git repo" {
  cd /tmp
  TMP2="$(mktemp -d -t fi-nogit.XXXXXX)"
  cd "$TMP2"
  fi_run promote
  [ "$status" -ne 0 ]
  cd /tmp
  rm -rf "$TMP2"
}

@test "promote: lists branch-only entries" {
  fi_run log "src/foo.py:1 — entry on main"
  git add -A; git commit -q -m "init"

  git checkout -q -b feat/test
  fi_run log "src/bar.py:1 — branch-only entry"
  git add -A; git commit -q -m "branch entry"

  fi_run promote
  [ "$status" -eq 0 ]
  [[ "$output" == *"src/bar.py:1"* ]]
  [[ "$output" != *"src/foo.py:1"* ]]
}

@test "promote: shows 'no entries to promote' when branch is in sync" {
  fi_run log "src/foo.py:1 — entry"
  git add -A; git commit -q -m "init"
  git checkout -q -b feat/test
  fi_run promote
  [[ "$output" == *"none"* ]] || [[ "$output" == *"in sync"* ]]
}

@test "promote: singular 'entry needs' when count=1" {
  fi_run log "src/foo.py:1 — main entry"
  git add -A; git commit -q -m "init"
  git checkout -q -b feat/test
  fi_run log "src/bar.py:1 — branch entry"
  fi_run promote
  [[ "$output" == *"1 entry needs"* ]]
}

@test "promote: plural 'entries need' when count>=2" {
  fi_run log "src/foo.py:1 — main"
  git add -A; git commit -q -m "init"
  git checkout -q -b feat/test
  fi_run log "src/a.py:1 — A"
  fi_run log "src/b.py:1 — B"
  fi_run promote
  [[ "$output" == *"2 entries need"* ]]
}

@test "promote: prints rel_path 'docs/found-issues.md' (not absolute)" {
  fi_run log "src/foo.py:1 — main"
  git add -A; git commit -q -m "init"
  git checkout -q -b feat/test
  fi_run log "src/bar.py:1 — branch"
  fi_run promote
  [[ "$output" == *"docs/found-issues.md"* ]]
  [[ "$output" != */tmp/* ]] && [[ "$output" != */var/folders/* ]]
}
