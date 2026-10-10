#!/usr/bin/env bats
# Regression tests for the batch-2 ledger fixes in lib/sync.sh and
# lib/uninstall.sh: rename substitution with glob/& characters, CRLF ledger
# closure, swallowed auto-archive failures, and uninstall removing the Codex
# hook entries install-codex-hooks wrote.

bats_require_minimum_version 1.5.0
load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

@test "sync: rename to a target containing & is substituted literally" {
  # bash 5.2 expands & in an unquoted ${x/pat/rep} replacement to the match.
  # (Glob metacharacters in the source never get here: the sync guard skips
  # such locations, so only the replacement side is reachable.)
  printf 'x\n' > old.sh
  git add old.sh
  git commit -q -m "add old.sh"
  mkdir -p docs
  printf '# found-issues\n\n- [open] 2026-10-01 old.sh:3 — bug\n' > docs/found-issues.md
  git add docs
  git commit -q -m "ledger"

  git mv old.sh 'b&c.sh'
  git commit -q -m "rename"

  fi_run sync
  [ "$status" -eq 0 ]
  grep -Fq 'b&c.sh:3' docs/found-issues.md
  grep -Fq '(renamed-from: old.sh)' docs/found-issues.md
}

@test "sync: closing an entry on a CRLF ledger leaves no mid-line CR" {
  printf 'x\n' > gone.sh
  git add gone.sh
  git commit -q -m "add gone.sh"
  mkdir -p docs
  printf '# found-issues\r\n\r\n- [open] 2026-10-01 gone.sh:1 — bug\r\n' > docs/found-issues.md
  git add docs
  git commit -q -m "ledger"
  git rm -q gone.sh
  git commit -q -m "delete"

  fi_run sync
  [ "$status" -eq 0 ]
  local closed
  closed="$(grep -F '[fixed]' docs/found-issues.md)"
  [[ "$closed" == *"closure: tombstone"* ]]
  # Exactly one CR in the line, and it is the last byte.
  [ "$(printf '%s\n' "$closed" | tr -cd '\r' | wc -c | tr -d ' ')" -eq 1 ]
  [[ "$closed" == *$'\r' ]]
}

@test "sync: renaming an entry on a CRLF ledger keeps the CR at the end only" {
  printf 'x\n' > old.sh
  git add old.sh
  git commit -q -m "add old.sh"
  mkdir -p docs
  printf '# found-issues\r\n\r\n- [open] 2026-10-01 old.sh:1 — bug\r\n' > docs/found-issues.md
  git add docs
  git commit -q -m "ledger"
  git mv old.sh new.sh
  git commit -q -m "rename"

  fi_run sync
  [ "$status" -eq 0 ]
  local line
  line="$(grep -F 'new.sh:1' docs/found-issues.md)"
  [[ "$line" == *"(renamed-from: old.sh)"* ]]
  [ "$(printf '%s\n' "$line" | tr -cd '\r' | wc -c | tr -d ' ')" -eq 1 ]
  [[ "$line" == *$'\r' ]]
}

@test "sync: a failing auto-archive is reported on stderr" {
  local old
  old="$(date -v-45d +%Y-%m-%d 2>/dev/null || date -d '45 days ago' +%Y-%m-%d)"
  mkdir -p docs
  cat > docs/found-issues.md <<EOF2
# found-issues

- [fixed] $old src/foo.py:1 — old bug (PR: org/repo#1) (fixed: $old)
- [open] 2026-05-09 src/bar.py:1 — new bug
EOF2
  # An awk that fails only for archive's line-drop rewrite.
  mkdir -p "$TMP/shim"
  cat > "$TMP/shim/awk" <<'EOF2'
#!/bin/sh
for a in "$@"; do
  case "$a" in *'drop[$1]'*) exit 1 ;; esac
done
exec /usr/bin/awk "$@"
EOF2
  chmod +x "$TMP/shim/awk"

  PATH="$TMP/shim:$PATH" run --separate-stderr "$FI_BIN" sync
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"archive: could not rewrite"* ]]
}

@test "sync: an unwritable archive file keeps the closed entries in the active ledger" {
  local old
  old="$(date -v-45d +%Y-%m-%d 2>/dev/null || date -d '45 days ago' +%Y-%m-%d)"
  mkdir -p docs
  cat > docs/found-issues.md <<EOF2
# found-issues

- [fixed] $old src/foo.py:1 — old bug (PR: org/repo#1) (fixed: $old)
- [open] 2026-05-09 src/bar.py:1 — new bug
EOF2
  printf '# found-issues archive\n\n' > docs/found-issues-archive.md
  chmod 444 docs/found-issues-archive.md

  run --separate-stderr "$FI_BIN" sync
  chmod 644 docs/found-issues-archive.md
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"auto-archive failed"* ]]
  grep -Fq "src/foo.py:1 — old bug" docs/found-issues.md
  ! grep -Fq "src/foo.py:1" docs/found-issues-archive.md || false
  # The failed archive leaves no ledger-sized temp copy behind in docs/.
  ! ls docs/.found-issues.tmp.* >/dev/null 2>&1 || false
}

@test "uninstall: points at Codex hook entries but leaves them wired" {
  export HOME="$TMP/home"
  mkdir -p "$HOME/.claude/commands" "$HOME/.cache"
  export FOUND_ISSUES_CODEX_HOME="$TMP/codex"
  fi_run install-codex-hooks
  [ "$status" -eq 0 ]
  grep -Fq 'env FOUND_ISSUES_HARNESS=codex ' "$FOUND_ISSUES_CODEX_HOME/hooks.json"
  [ -d "$FOUND_ISSUES_CODEX_HOME/found-issues" ]

  fi_run uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"Codex hook entries are still wired"* ]]
  [[ "$output" == *"found-issues uninstall-codex-hooks"* ]]
  [[ "$output" == *"codex plugin remove found-issues"* ]]
  # A Claude-side uninstall must not break a Codex install the user keeps.
  grep -Fq 'env FOUND_ISSUES_HARNESS=codex ' "$FOUND_ISSUES_CODEX_HOME/hooks.json"
  [ -d "$FOUND_ISSUES_CODEX_HOME/found-issues" ]
}

@test "uninstall: output has no Codex lines when no Codex hooks exist" {
  export HOME="$TMP/home"
  mkdir -p "$HOME/.claude/commands" "$HOME/.cache"
  export FOUND_ISSUES_CODEX_HOME="$TMP/codex-none"

  fi_run uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to clean"* ]]
  [[ "$output" != *"Codex"* ]] || false
  [[ "$output" != *"codex"* ]] || false
  [ ! -e "$FOUND_ISSUES_CODEX_HOME" ]
}
