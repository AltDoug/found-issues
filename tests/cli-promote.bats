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

# === promote --apply (#124) ===
# promote.md step 5 instructed "Append the entries to docs/found-issues.md
# (use `Edit` or `Write`)" — an unserialized direct write, the exact thing the
# CLI exists to prevent. `--apply` is the transactional import path.
#
# It runs on the TARGET branch (freshly cut from the default branch) and reads
# the source branch's ledger with `git show`, because by step 5 of the promote
# workflow the operator has already left the source branch behind.
#
# Entries are copied VERBATIM. Re-logging them with `log` would stamp today's
# date, which resets entry age and corrupts the stale-entry counts.

@test "promote --apply: copies branch-only [open] entries verbatim onto the current branch" {
  mkdir -p docs src
  printf 'a\n' > src/foo.py
  printf '# found-issues\n\n' > docs/found-issues.md
  printf -- '- [open] 2026-01-05 src/foo.py:1 — entry already on main\n' >> docs/found-issues.md
  git add -A && git commit -q -m base

  git checkout -q -b feature/x
  printf -- '- [open] 2026-02-09 src/foo.py:2 — branch-only entry\n' >> docs/found-issues.md
  git add -A && git commit -q -m "branch entry"

  git checkout -q main
  git checkout -q -b chore/promote-x

  fi_run promote --apply --from feature/x
  [ "$status" -eq 0 ]
  # verbatim: the ORIGINAL 2026-02-09 date survives, not today's
  grep -q '^- \[open\] 2026-02-09 src/foo.py:2 — branch-only entry$' docs/found-issues.md
  # and the pre-existing entry is untouched, exactly once
  [ "$(grep -c 'entry already on main' docs/found-issues.md)" -eq 1 ]
}

@test "promote --apply: is idempotent and re-running adds nothing" {
  mkdir -p docs src
  printf 'a\n' > src/foo.py
  printf '# found-issues\n\n' > docs/found-issues.md
  git add -A && git commit -q -m base

  git checkout -q -b feature/y
  printf -- '- [open] 2026-02-09 src/foo.py:2 — branch-only entry\n' >> docs/found-issues.md
  git add -A && git commit -q -m "branch entry"

  git checkout -q main
  git checkout -q -b chore/promote-y
  fi_run promote --apply --from feature/y
  [ "$status" -eq 0 ]
  fi_run promote --apply --from feature/y
  [ "$status" -eq 0 ]
  [ "$(grep -c 'branch-only entry' docs/found-issues.md)" -eq 1 ]
}

@test "promote --apply: requires --from and exits 2 without it" {
  mkdir -p docs
  printf '# found-issues\n\n' > docs/found-issues.md
  git add -A && git commit -q -m base
  git checkout -q -b chore/promote-z

  fi_run promote --apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"--from"* ]]
}

@test "promote --apply: exits 2 on an unknown source branch" {
  mkdir -p docs
  printf '# found-issues\n\n' > docs/found-issues.md
  git add -A && git commit -q -m base
  git checkout -q -b chore/promote-w

  fi_run promote --apply --from no/such/branch
  [ "$status" -eq 2 ]
  [[ "$output" == *"no/such/branch"* ]]
}

@test "promote --apply: does not copy [fixed] or [deferred] entries" {
  mkdir -p docs src
  printf 'a\n' > src/foo.py
  printf '# found-issues\n\n' > docs/found-issues.md
  git add -A && git commit -q -m base

  git checkout -q -b feature/mixed
  printf -- '- [fixed] 2026-02-09 src/foo.py:3 — already fixed (fixed: 2026-02-09)\n' >> docs/found-issues.md
  printf -- '- [deferred] 2026-02-09 src/foo.py:4 — parked (reason: later)\n' >> docs/found-issues.md
  printf -- '- [open] 2026-02-09 src/foo.py:5 — the only one that should move\n' >> docs/found-issues.md
  git add -A && git commit -q -m "mixed entries"

  git checkout -q main
  git checkout -q -b chore/promote-mixed
  fi_run promote --apply --from feature/mixed
  [ "$status" -eq 0 ]
  grep -q 'the only one that should move' docs/found-issues.md
  run grep -q 'already fixed' docs/found-issues.md
  [ "$status" -ne 0 ]
  run grep -q 'parked' docs/found-issues.md
  [ "$status" -ne 0 ]
}
