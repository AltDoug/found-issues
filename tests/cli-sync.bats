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

@test "sync: auto-archives old fixed entries by default" {
  local old
  old="$(date -v-45d +%Y-%m-%d 2>/dev/null || date -d '45 days ago' +%Y-%m-%d)"
  mkdir -p docs
  cat > docs/found-issues.md <<EOF
# found-issues

- [fixed] $old src/foo.py:1 — old bug (PR: org/repo#1) (fixed: $old)
- [open] 2026-05-09 src/bar.py:1 — new bug
EOF

  fi_run sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"moved 1 entries"* ]]
  [ -f docs/found-issues-archive.md ]
  grep -Fq "$old" docs/found-issues-archive.md
  ! grep -Fq "$old" docs/found-issues.md
}

@test "sync: respects FOUND_ISSUES_AUTO_ARCHIVE=off" {
  local old
  old="$(date -v-45d +%Y-%m-%d 2>/dev/null || date -d '45 days ago' +%Y-%m-%d)"
  mkdir -p docs
  cat > docs/found-issues.md <<EOF
# found-issues

- [fixed] $old src/foo.py:1 — old bug (PR: org/repo#1) (fixed: $old)
- [open] 2026-05-09 src/bar.py:1 — new bug
EOF

  FOUND_ISSUES_AUTO_ARCHIVE=off fi_run sync
  [ "$status" -eq 0 ]
  [[ "$output" != *"moved"* ]]
  [ ! -f docs/found-issues-archive.md ]
  grep -Fq "$old" docs/found-issues.md
}

@test "sync: silent when no archive needed (no spurious output)" {
  fi_run log "src/missing.py:1 — bug"
  fi_run sync
  [ "$status" -eq 0 ]
  [[ "$output" != *"moved"* ]]
  [[ "$output" != *"Hint"* ]]
}

# === home-relative / env-var locations must never tombstone (2026-07-20) ===
# A ledger can legitimately cite machine state outside the repo
# (~/.claude.json, $HOME/.config/...). Probing those as repo-relative
# literals ($repo_root/~/.claude.json) always misses, so sync tombstoned
# them on every run — reproduced live in agent-config: four false closures
# of the same ~-path entry in one day, each hand-repair lost within
# seconds to the next post-bash dispatcher fire.

@test "sync: never tombstones a ~-prefixed (home-relative) location" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues

- [open] 2026-07-20 ~/.claude.json someFlag (recurrence) — flag reset by an update (suggested: post-update check)
EOF
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\] 2026-07-20 ~/.claude.json' docs/found-issues.md
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

@test "sync: never tombstones a \$VAR-prefixed location" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues

- [open] 2026-07-20 $HOME/.config/tool/config.json — drift outside the repo (suggested: doctor check)
EOF
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\] 2026-07-20 \$HOME/.config' docs/found-issues.md
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

# === annotation tokens inside symptom text must not drive flips ===

@test "sync: commit annotation form inside SYMPTOM text does not flip the entry" {
  mkdir -p src
  echo "x" > src/foo.py
  git add src/foo.py
  git commit -q -m "add foo"
  short_sha="$(git rev-parse --short=7 HEAD)"

  # The canonical form appears mid-symptom (narrating another entry's fix),
  # followed by more symptom text — it is NOT a trailing annotation.
  mkdir -p docs
  cat > docs/found-issues.md <<EOF
# found-issues

- [open] 2026-07-20 src/foo.py:1 — earlier repair shipped as (commit: $short_sha) but this symptom persists (suggested: real fix)
EOF
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\] 2026-07-20 src/foo.py:1' docs/found-issues.md
}

@test "sync: tombstone never probes paths with .. components (path traversal)" {
  # Regression (2026-07-09 audit, critical): entry paths are attacker-
  # controlled (committed found-issues.md in any cloned repo) and were
  # joined to repo_root verbatim — a ../-laden path made sync stat and
  # wc -l files OUTSIDE the repo (existence/line-count oracle), and
  # SessionStart auto-runs sync with no user action.
  # Layout: the git repo is a SUBDIR of $TMP so ../outside.txt escapes it.
  mkdir -p repo && cd repo && git init -q -b main
  printf 'one line\n' > ../outside.txt   # exists, 1 line — outside the repo
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues

- [open] 2020-01-01 ../outside.txt:999999 — traversal probe
- [open] 2020-01-01 ../../../../../../../../etc/hosts:999999 — deep traversal probe
EOF
  fi_run sync
  [ "$status" -eq 0 ]
  # Old behavior: both flipped to [fixed] (closure: tombstone) because the
  # out-of-repo probe found a file shorter than the entry line. New
  # behavior: traversal paths are skipped — entries stay [open], untouched.
  [ "$(grep -c '^- \[open\]' docs/found-issues.md)" -eq 2 ]
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

@test "sync: tombstone never probes absolute entry paths" {
  mkdir -p docs src
  printf 'one line\n' > src/real.py
  cat > docs/found-issues.md <<'EOF'
# found-issues

- [open] 2020-01-01 /etc/hosts:999999 — absolute-path probe
EOF
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\] 2020-01-01 /etc/hosts:999999' docs/found-issues.md
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

@test "sync: entry on last line of file without trailing newline is NOT tombstoned" {
  mkdir -p src
  printf 'line1\nline2\nline3' > src/nonewline.py  # 3 lines, no trailing \n
  fi_run log "src/nonewline.py:3 — bug on the unterminated last line"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\].*src/nonewline.py:3' docs/found-issues.md
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

@test "sync: line-past-end tombstone still fires on file without trailing newline" {
  mkdir -p src
  printf 'line1\nline2' > src/nonewline2.py  # 2 lines, no trailing \n
  fi_run log "src/nonewline2.py:3 — cites a line past EOF"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '\[fixed\].*closure: tombstone' docs/found-issues.md
}

@test "sync: glob-style location tokens are never tombstone-probed" {
  # The widened location charset lets glob/brace tokens parse as paths;
  # probing them as literal filenames false-flipped the entries at every
  # SessionStart sync.
  fi_run log "tests/*.bats — every bats file hardcodes the fixture date"
  fi_run log "config/{dev,prod}.yml — duplicated keys drift"
  fi_run sync
  [ "$status" -eq 0 ]
  ! grep -q 'closure: tombstone' docs/found-issues.md
  [ "$(grep -c '^- \[open\]' docs/found-issues.md)" -eq 2 ]
}

# === directory paths must never tombstone (agent-config 2026-07-27) ===
# An entry can cite a directory (.git/worktrees, src/utils). The probe used
# [[ ! -f ]], so an EXISTING directory read as "file missing" and sync
# tombstoned the entry on every pass — reproduced live in agent-config:
# a fresh .git/worktrees entry false-closed twice within minutes of landing.

@test "sync: never tombstones an entry whose path is an existing directory" {
  mkdir -p .git/worktrees
  fi_run log ".git/worktrees — orphaned worktree registration left by ended session"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\].*\.git/worktrees' docs/found-issues.md
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

@test "sync: existing directory cited with a line number is not line-probed" {
  mkdir -p src/utils
  fi_run log "src/utils:3 — dead module tree"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\].*src/utils:3' docs/found-issues.md
  ! grep -q 'closure: tombstone' docs/found-issues.md
}
