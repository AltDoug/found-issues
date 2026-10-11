#!/usr/bin/env bats
# Ledger integrity: lost updates, silent deletes and false closes found by the
# 2026-10-03 audit (docs/audits/2026-10-03-audit, fix batch 1). Each test is
# the runtime repro from runtime-evidence.md turned into an assertion.

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

# Print the inode of $1 (portable: ls -i works on GNU, BSD and Git Bash).
inode_of() { ls -i "$1" | awk '{print $1}'; }

# --- ledger-1: sync must not revert a write that lands during its gh loop ---

@test "sync: a defer landing mid-sync survives (no lost update)" {
  fi_init_github_repo foo/bar main
  mkdir -p docs src
  printf 'x\n' > src/a.sh
  printf 'x\n' > src/c.sh
  printf -- '- [open] 2026-10-01 src/a.sh:1 — first (PR: foo/bar#1)\n- [open] 2026-10-01 src/c.sh:3 — second\n' \
    > docs/found-issues.md
  # A gh wrapper that performs a concurrent inode-replacing write (defer) the
  # first time sync asks about a PR, then answers like the regular shim.
  mkdir -p shim
  cat > shim/gh <<EOF
#!/usr/bin/env bash
if [[ "\$1 \$2" == "pr view" && ! -f "$TMP/.raced" ]]; then
  : > "$TMP/.raced"
  ( cd "$TMP" && "$FI_BIN" defer src/c.sh >/dev/null 2>&1 )
fi
exec "$TEST_REPO_ROOT/tests/bin-shims/gh" "\$@"
EOF
  chmod +x shim/gh
  export PATH="$TMP/shim:$PATH"
  export GH_MOCK_PR_VIEW=$'1\t{"state":"MERGED","baseRefName":"main","mergedAt":"2026-10-02T00:00:00Z","isDraft":false}'

  FOUND_ISSUES_AUTO_ARCHIVE=off fi_run sync
  [ "$status" -eq 0 ]
  [ -f "$TMP/.raced" ]
  grep -q '^- \[deferred\].*src/c.sh:3' docs/found-issues.md
  grep -q '^- \[fixed\].*src/a.sh:1' docs/found-issues.md
}

@test "sync: a no-op pass does not replace the ledger file" {
  mkdir -p docs src
  printf 'x\n' > src/a.sh
  printf -- '- [open] 2026-10-01 src/a.sh:1 — nothing to close\n' > docs/found-issues.md
  before="$(inode_of docs/found-issues.md)"
  FOUND_ISSUES_AUTO_ARCHIVE=off fi_run sync
  [ "$status" -eq 0 ]
  [ "$(inode_of docs/found-issues.md)" = "$before" ]
}

# --- ledger-2 / cli-23: mutations keep the ledger's mode ---

@test "defer: rewritten ledger keeps its original permissions" {
  mkdir -p docs
  printf -- '- [open] 2026-10-01 src/a.sh:1 — thing\n' > docs/found-issues.md
  chmod 644 docs/found-issues.md
  fi_run defer src/a.sh
  [ "$status" -eq 0 ]
  grep -q '^- \[deferred\]' docs/found-issues.md
  [ "$(ls -l docs/found-issues.md | cut -c1-10)" = "-rw-r--r--" ]
  # no temp debris left beside the ledger
  [ -z "$(ls -A docs | grep -v '^found-issues')" ]
}

# --- ledger-3 / ledger-15: archive deletes by line, never by pattern ---

@test "archive: an invalid UTF-8 byte in an [open] entry does not delete open entries" {
  mkdir -p docs
  {
    printf -- '- [fixed] 2020-01-01 a.sh:1 — old (fixed: 2020-01-02)\n'
    printf -- '- [open] 2026-10-01 b.sh:1 — bad \xff byte\n'
    printf -- '- [open] 2026-10-01 c.sh:1 — fine\n'
  } > docs/found-issues.md
  LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 fi_run archive
  [ "$status" -eq 0 ]
  [ "$(grep -c '^- \[open\]' docs/found-issues.md)" -eq 2 ]
  ! grep -q '^- \[fixed\]' docs/found-issues.md || false
  grep -q 'a.sh:1 — old' docs/found-issues-archive.md
}

@test "archive: a [fixed] line ending in a tab is removed from the active file" {
  mkdir -p docs
  printf -- '- [fixed] 2020-01-01 a.sh:1 — old (fixed: 2020-01-02)\t\n- [open] 2026-10-01 c.sh:1 — keep\n' \
    > docs/found-issues.md
  fi_run archive
  [ "$status" -eq 0 ]
  ! grep -q '^- \[fixed\]' docs/found-issues.md || false
  grep -q '^- \[open\].*c.sh:1' docs/found-issues.md
  fi_run archive
  [ "$(grep -c 'a.sh:1 — old' docs/found-issues-archive.md)" -eq 1 ]
}

@test "archive: count rule moves exactly one of two identical [fixed] lines" {
  mkdir -p docs
  today="$(date +%Y-%m-%d)"
  printf -- '- [fixed] %s a.sh:1 — dup (fixed: %s)\n- [fixed] %s a.sh:1 — dup (fixed: %s)\n' \
    "$today" "$today" "$today" "$today" > docs/found-issues.md
  fi_run archive --count 1
  [ "$status" -eq 0 ]
  [ "$(grep -c '^- \[fixed\]' docs/found-issues.md)" -eq 1 ]
  [ "$(grep -c '^- \[fixed\]' docs/found-issues-archive.md)" -eq 1 ]
}

# --- ledger-17: never rewrite a ledger with merge-conflict markers ---

@test "sync and archive: skip a ledger with merge-conflict markers" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
<<<<<<< HEAD
- [open] 2026-10-01 gone/a.sh:1 — ours
=======
- [fixed] 2020-01-01 b.sh:1 — theirs (fixed: 2020-01-02)
>>>>>>> other
EOF
  cp docs/found-issues.md before.md
  fi_run sync
  [[ "$output" == *"conflict"* ]]
  fi_run archive
  [[ "$output" == *"conflict"* ]]
  cmp -s before.md docs/found-issues.md
  [ ! -f docs/found-issues-archive.md ]
}

# --- cli-4: log must not write a closing annotation into the symptom ---

@test "log: rejects a symptom ending in a (commit: <sha>) annotation" {
  git commit -q --allow-empty -m base
  sha="$(git rev-parse --short=7 HEAD)"
  fi_run log "a.sh:5 — regression from (commit: $sha)"
  [ "$status" -eq 2 ]
  [[ "$output" == *"annotate-"* ]]
  [ ! -s docs/found-issues.md ] || ! grep -q 'a.sh:5' docs/found-issues.md
}

@test "log: rejects a symptom ending in a (PR: org/repo#N) annotation" {
  fi_run log "a.sh:5 — broke in (PR: foo/bar#7)"
  [ "$status" -eq 2 ]
}

@test "log: still accepts a trailing (suggested: ...) block" {
  fi_run log "a.sh:5 — leaks (suggested: close the fd)"
  [ "$status" -eq 0 ]
  grep -q 'a.sh:5 — leaks (suggested: close the fd)' docs/found-issues.md
}

# --- ledger-11: no permanent demotion where git cannot see the commit ---

@test "sync: a shallow clone does not demote a (commit:) it cannot resolve" {
  mkdir src && cd src
  fi_init_git
  printf 'x\n' > a.sh
  git add a.sh && git commit -q -m one
  old="$(git rev-parse --short=7 HEAD)"
  printf 'y\n' >> a.sh
  git commit -q -am two
  cd "$TMP"
  git clone -q --depth 1 "file://$TMP/src" shallow
  cd shallow
  [ "$(git rev-parse --is-shallow-repository)" = "true" ]
  mkdir -p docs
  printf -- '- [open] 2026-10-01 a.sh:1 — bug (commit: %s)\n' "$old" > docs/found-issues.md
  FOUND_ISSUES_AUTO_ARCHIVE=off fi_run sync
  [ "$status" -eq 0 ]
  grep -q "(commit: $old)" docs/found-issues.md
  ! grep -q 'commit-stale' docs/found-issues.md
}

# --- ledger-12: rename detection with a non-ASCII filename ---

@test "sync: a renamed non-ASCII file is followed, not tombstoned" {
  mkdir -p docs notes
  printf 'x\n' > "notes/日本.md"
  git add notes && git commit -q -m add
  git mv "notes/日本.md" notes/renamed.md
  git commit -q -m rename
  printf -- '- [open] 2026-10-01 notes/日本.md:1 — stale note\n' > docs/found-issues.md
  FOUND_ISSUES_AUTO_ARCHIVE=off fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\].*notes/renamed.md:1' docs/found-issues.md
  ! grep -q 'tombstone' docs/found-issues.md
}

# --- prompt-2: a bare annotate only SUGGESTS; picks and --all confirm ---

@test "annotate-commit: no flag writes the suggestion form, which sync does not close" {
  mkdir -p src
  printf 'x\n' > src/foo.py
  printf 'x\n' > src/far.py
  git add src && git commit -q -m base
  fi_run log "src/foo.py:900 — unrelated bug"
  printf 'y\n' >> src/foo.py
  git commit -q -am "touch foo"
  short="$(git rev-parse --short=7 HEAD)"
  fi_run annotate-commit
  [ "$status" -eq 0 ]
  grep -q "(commit-auto: $short)" docs/found-issues.md
  ! grep -q "(commit: $short)" docs/found-issues.md || false
  # annot-10: the printed confirm command names the resolved sha, not HEAD
  [[ "$output" == *"annotate-commit $short --pick"* ]]
  [[ "$output" != *"annotate-commit HEAD"* ]]
  FOUND_ISSUES_AUTO_ARCHIVE=off fi_run sync
  grep -q '^- \[open\].*src/foo.py:900' docs/found-issues.md
}

@test "annotate-commit: --pick and --all still write the closing form" {
  mkdir -p src
  printf 'x\n' > src/foo.py
  printf 'x\n' > src/bar.py
  git add src && git commit -q -m base
  fi_run log "src/foo.py:1 — foo bug"
  fi_run log "src/bar.py:1 — bar bug"
  printf 'y\n' >> src/foo.py
  printf 'y\n' >> src/bar.py
  git commit -q -am fix
  short="$(git rev-parse --short=7 HEAD)"
  fi_run annotate-commit HEAD --pick src/foo.py:1
  [ "$status" -eq 0 ]
  grep -q "src/foo.py:1 — foo bug (commit: $short)" docs/found-issues.md
  fi_run annotate-commit HEAD --all
  grep -q "src/bar.py:1 — bar bug (commit: $short)" docs/found-issues.md
}

# --- hook-8: stop-reminder fails open when transcript_path is absent ---

@test "stop-reminder: input without transcript_path exits 0" {
  run bash -c "printf '%s' '{\"session_id\":\"x1\"}' | bash '$TEST_REPO_ROOT/hooks/stop-reminder.sh'"
  [ "$status" -eq 0 ]
}

@test "stop-reminder: input without transcript_path exits 0 even without jq" {
  mkdir -p nojq
  for t in bash cat grep sed head tr printf env; do
    p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "nojq/$t"
  done
  run env PATH="$TMP/nojq" bash -c "printf '%s' '{\"session_id\":\"x1\"}' | bash '$TEST_REPO_ROOT/hooks/stop-reminder.sh'"
  [ "$status" -eq 0 ]
}
