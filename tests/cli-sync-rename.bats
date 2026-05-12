#!/usr/bin/env bats
load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

@test "sync: renamed file gets path auto-corrected with (renamed-from: ...)" {
  mkdir -p src
  echo "content" > src/old.py
  git add src/old.py
  git commit -q -m "add old.py"

  fi_run log "src/old.py:1 — bug"

  git mv src/old.py src/new.py
  git commit -q -m "rename old → new"

  fi_run sync
  [ "$status" -eq 0 ]
  # Entry stays [open] but path updated
  grep -q '^- \[open\].*src/new.py:1.*(renamed-from: src/old.py)' docs/found-issues.md
  # Entry is NOT [fixed]
  ! grep -qE '^- \[fixed\].*src/(old|new).py' docs/found-issues.md
}

@test "sync: file deleted (not renamed) still flips to [fixed] tombstone" {
  mkdir -p src
  echo "content" > src/gone.py
  git add src/gone.py
  git commit -q -m "add gone.py"

  fi_run log "src/gone.py:1 — bug"

  git rm src/gone.py
  git commit -q -m "delete gone.py"

  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '\[fixed\].*closure: tombstone' docs/found-issues.md
}

@test "sync: rename then delete fires tombstone on new path (correctly)" {
  mkdir -p src
  echo "content" > src/a.py
  git add src/a.py
  git commit -q -m "add a"

  fi_run log "src/a.py:1 — bug"

  git mv src/a.py src/b.py
  git commit -q -m "rename a → b"

  fi_run sync  # Should auto-correct path to b.py
  grep -q '^- \[open\].*src/b.py.*renamed-from: src/a.py' docs/found-issues.md

  git rm src/b.py
  git commit -q -m "delete b"

  fi_run sync  # Now b.py is gone, tombstone fires
  grep -q '\[fixed\].*closure: tombstone' docs/found-issues.md
}
