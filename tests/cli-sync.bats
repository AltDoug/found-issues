#!/usr/bin/env bats
# Tests for `found-issues sync` — annotation flips + tombstone

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

@test "sync: no-op when nothing to close" {
  # Create the referenced file so tombstone doesn't fire
  mkdir -p src
  printf 'line1\nline2\nline3\n' > src/foo.py
  fi_run log "src/foo.py:1 — bug"
  fi_run sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to close"* ]]
}

@test "sync: tombstone closes entry when file is missing" {
  fi_run log "src/missing.py:1 — bug in nonexistent file"
  fi_run sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"tombstone"* ]] || [[ "$output" == *"1"* ]]
  grep -q '\[fixed\]' docs/found-issues.md
  grep -q 'closure: tombstone' docs/found-issues.md
}

@test "sync: tombstone closes entry when line is past file end" {
  mkdir -p src
  printf 'line1\n' > src/short.py  # 1 line file
  fi_run log "src/short.py:99 — line 99 doesn't exist"
  fi_run sync
  grep -q '\[fixed\].*closure: tombstone' docs/found-issues.md
}

@test "sync: leaves entries with present file alone" {
  mkdir -p src
  printf 'line1\nline2\n' > src/here.py
  fi_run log "src/here.py:2 — bug at line 2"
  fi_run sync
  # Entry stays [open] because file/line still exists, no annotation
  grep -q '^- \[open\].*src/here.py:2' docs/found-issues.md
}

@test "sync: commits annotation flips entry when commit is on default branch" {
  mkdir -p src
  echo "x" > src/foo.py
  git add src/foo.py
  git commit -q -m "add foo"
  short_sha="$(git rev-parse --short=7 HEAD)"

  # Log against an existing file/line, then manually annotate with the commit
  fi_run log "src/foo.py:1 — bug"
  # Edit the entry to add the commit annotation
  sed -i.bak "s|src/foo.py:1 — bug|src/foo.py:1 — bug (commit: $short_sha)|" docs/found-issues.md
  rm -f docs/found-issues.md.bak

  fi_run sync
  grep -q '\[fixed\]' docs/found-issues.md
  grep -q "(commit: $short_sha)" docs/found-issues.md
}

@test "sync: appends (fixed: <date>) on closure" {
  fi_run log "src/missing.py:1 — bug"
  fi_run sync
  grep -qE '\(fixed: [0-9]{4}-[0-9]{2}-[0-9]{2}\)' docs/found-issues.md
}
