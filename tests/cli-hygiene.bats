#!/usr/bin/env bats
# CLI hygiene (2026-10-03 audit, fix batch 5): commands that ignored what they
# did not understand, ledger lookup, dedup-key collisions, promote dedup and
# statusline install/uninstall safety.

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
  export HOME="$TMP/home"
  mkdir -p "$HOME/.claude/found-issues" "$HOME/.cache/found-issues"
}
teardown() { fi_teardown_tmp; }

# --- unknown flags are refused, never ignored (cli-5, cli-6, ledger entry lib/archive.sh:36, status-8, status-17) ---

@test "uninstall --help prints usage and deletes nothing (cli-5)" {
  fi_run uninstall --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [ -d "$HOME/.claude/found-issues" ]
  [ -d "$HOME/.cache/found-issues" ]
}

@test "uninstall with an unknown flag exits 2 and deletes nothing (cli-5)" {
  fi_run uninstall --dry-run-typo
  [ "$status" -eq 2 ]
  [ -d "$HOME/.claude/found-issues" ]
}

@test "archive --help and a typo'd flag do not archive (ledger entry lib/archive.sh:36)" {
  mkdir -p docs
  printf -- '- [fixed] 2020-01-01 a.sh:1 — old (fixed: 2020-01-02)\n' > docs/found-issues.md
  fi_run archive --help
  [ "$status" -eq 0 ]
  fi_run archive --dry-runn
  [ "$status" -eq 2 ]
  grep -q '^- \[fixed\]' docs/found-issues.md
  [ ! -f docs/found-issues-archive.md ]
}

@test "promote, install-statusline, uninstall-statusline reject unknown flags (ledger entry lib/archive.sh:36)" {
  fi_run promote --bogus
  [ "$status" -eq 2 ]
  fi_run install-statusline --bogus
  [ "$status" -eq 2 ]
  fi_run uninstall-statusline --bogus
  [ "$status" -eq 2 ]
}

@test "defer: --reason=x and --mute-until=YYYY-MM-DD are honored; unknown flags and a missing value exit 2 (cli-6)" {
  mkdir -p docs
  printf -- '- [open] 2026-10-01 a.sh:1 — one\n- [open] 2026-10-01 b.sh:1 — two\n' > docs/found-issues.md
  fi_run defer a.sh --reason=waiting --mute-until=2099-01-01
  [ "$status" -eq 0 ]
  grep -q 'a.sh:1 — one.*(reason: waiting).*(mute-until: 2099-01-01)' docs/found-issues.md
  fi_run defer b.sh --resaon x
  [ "$status" -eq 2 ]
  fi_run defer b.sh --reason
  [ "$status" -eq 2 ]
  grep -q '^- \[open\].*b.sh:1' docs/found-issues.md
}

@test "resolve: a misspelled --verified is refused, not defaulted to ai (cli-6)" {
  mkdir -p docs
  printf -- '- [open] 2026-10-01 a.sh:1 — one\n' > docs/found-issues.md
  fi_run resolve a.sh --verifed human
  [ "$status" -eq 2 ]
  grep -q '^- \[open\].*a.sh:1' docs/found-issues.md
  fi_run resolve a.sh --verified=human
  [ "$status" -eq 0 ]
  grep -q '(verified: human)' docs/found-issues.md
}

@test "install-statusline --dry-run without --target is refused and writes nothing (status-8)" {
  fi_run install-statusline --dry-run
  [ "$status" -eq 2 ]
  [ ! -e "$HOME/.claude/statusline.sh" ]
}

@test "--target with no path prints usage instead of an unbound-variable crash (status-17)" {
  fi_run install-statusline --target
  [ "$status" -eq 2 ]
  [[ "$output" == *"--target"* ]]
  fi_run uninstall-statusline --target
  [ "$status" -eq 2 ]
}

# --- log input hygiene (cli-16, cli-15) ---

@test "log: a newline in the input is refused (cli-16)" {
  fi_run log $'a.sh:1 — first line\n- [open] 2026-10-01 forged.sh:1 — smuggled'
  [ "$status" -eq 2 ]
  [ ! -s docs/found-issues.md ] || ! grep -q forged docs/found-issues.md
}

@test "log --critical on an already-open entry escalates it (cli-15)" {
  fi_run log "a.sh:1 — boom"
  fi_run log --critical "a.sh:1 — boom"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Escalated"* ]]
  grep -q '^- \[open\] \[!\] .*a.sh:1 — boom' docs/found-issues.md
  [ "$(grep -c 'a.sh:1' docs/found-issues.md)" -eq 1 ]
}

# --- dedup keys (cli-2, cli-3) ---

@test "log: different symptoms that share a prefix before '(' are both logged (cli-3)" {
  fi_run log "src/a.py:10 — parse() returns None"
  fi_run log "src/a.py:10 — parse() raises on unicode"
  [ "$(grep -c 'src/a.py:10' docs/found-issues.md)" -eq 2 ]
}

@test "log: re-logging a repo-prefixed location is deduped (cli-2)" {
  fi_run log "Repo:src/a.go:12 — x"
  fi_run log "Repo:src/a.go:12 — x"
  [ "$(grep -c 'Repo:src/a.go:12' docs/found-issues.md)" -eq 1 ]
}

@test "log: re-logging a path with a space is deduped (cli-2)" {
  fi_run log "docs/my notes.md:12 — stale"
  [ "$status" -eq 0 ]
  fi_run log "docs/my notes.md:12 — stale"
  [ "$(grep -c 'docs/my notes.md:12' docs/found-issues.md)" -eq 1 ]
}

# --- ledger lookup (cli-1) ---

@test "log from a subdirectory uses the repo ledger, not a new nested one (cli-1)" {
  mkdir -p docs sub/dir
  printf '# found-issues\n\n' > .found-issues.md
  rm -rf docs
  git add -A && git commit -q -m init
  cd sub/dir
  fi_run log "x.sh:1 — from a subdir"
  [ "$status" -eq 0 ]
  cd "$TMP"
  grep -q 'from a subdir' .found-issues.md
  [ ! -e docs/found-issues.md ]
}

# --- default branch fallback (cli-13 / ledger-10) ---

@test "sync: a commit on master closes in a repo whose default branch is master (cli-13)" {
  git checkout -q -b master
  mkdir -p src docs && printf 'x\n' > src/a.sh
  git add -A && git commit -q -m base
  sha="$(git rev-parse --short=7 HEAD)"
  fi_seed_entry "src/a.sh:1 — bug (commit: $sha)"
  git branch -D main 2>/dev/null || true
  FOUND_ISSUES_AUTO_ARCHIVE=off fi_run sync
  grep -q '^- \[fixed\].*src/a.sh:1' docs/found-issues.md
}

# --- promote dedups against main + archive (prompt-7 / cli-8) ---

@test "promote --apply does not reopen an entry main already fixed or archived (prompt-7)" {
  mkdir -p docs src
  printf 'x\n' > src/a.sh
  fi_run log "src/a.sh:1 — shared bug"
  fi_run log "src/a.sh:2 — archived bug"
  git add -A && git commit -q -m init
  git checkout -q -b feat/x
  fi_run log "src/a.sh:3 — branch only"
  git add -A && git commit -q -m branch
  git checkout -q main
  # main closes one entry and archives the other
  sed -i.bak 's/^- \[open\] \(.*shared bug\)$/- [fixed] \1 (verified: ai) (fixed: 2026-10-02)/' docs/found-issues.md
  grep -v 'archived bug' docs/found-issues.md > docs/t && mv docs/t docs/found-issues.md
  printf '# found-issues archive\n\n- [fixed] 2026-10-01 src/a.sh:2 — archived bug (verified: ai) (fixed: 2026-10-02)\n' > docs/found-issues-archive.md
  rm -f docs/found-issues.md.bak
  git add -A && git commit -q -m "main closes"
  git checkout -q -b promote/x
  fi_run promote --apply --from feat/x
  [ "$status" -eq 0 ]
  [ "$(grep -c 'shared bug' docs/found-issues.md)" -eq 1 ]
  ! grep -q '^- \[open\].*archived bug' docs/found-issues.md || false
  grep -q '^- \[open\].*branch only' docs/found-issues.md
}

# --- deferred touch (cli-14) ---

@test "a symptom containing [!] does not make a deferred entry critical (cli-14)" {
  mkdir -p docs
  printf -- '- [deferred] 2026-10-01 a.sh:1 — prints [!] banner (reason: later)\n' > docs/found-issues.md
  export FOUND_ISSUES_DEFER_TOUCH_THRESHOLD=1
  fi_run log "a.sh:1 — prints [!] banner"
  [ "$status" -eq 0 ]
  grep -q '^- \[deferred\] 2026-10-01 a.sh:1 — prints \[!\] banner.*(touched: ' docs/found-issues.md
  ! grep -q '^- \[open\]' docs/found-issues.md
}

@test "a deferred touch reports the entry it touched, not a same-prefix neighbour (cli-14)" {
  mkdir -p docs
  # "— foo bar" sorts first and starts with the touched entry's prefix "— foo".
  printf -- '- [deferred] 2026-10-01 a.sh:1 — foo bar (touched: 2026-10-01, 2026-10-02, 2026-10-03)\n- [deferred] 2026-10-01 a.sh:1 — foo (touched: 2026-10-01)\n' > docs/found-issues.md
  export FOUND_ISSUES_DEFER_TOUCH_THRESHOLD=5
  fi_run log "a.sh:1 — foo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2x of 5"* ]]
  [[ "$output" != *"3x of 5"* ]]
}

# --- statusline install/uninstall safety (status-5, status-6, status-7, status-11) ---

@test "uninstall-statusline --target removes the plain console.log concat splice (status-5)" {
  mkdir -p tmp && printf '#!/usr/bin/env node\nconsole.log("x");\n' > tmp/sl.js
  fi_run install-statusline --target tmp/sl.js --apply
  [ "$status" -eq 0 ]
  grep -q '__fiSeg(' tmp/sl.js
  fi_run uninstall-statusline --target tmp/sl.js
  [ "$status" -eq 0 ]
  ! grep -q '__fiSeg' tmp/sl.js || false
  grep -qx 'console.log("x");' tmp/sl.js
}

@test "uninstall-statusline --target removes the plain print() concat splice (status-5)" {
  mkdir -p tmp && printf '#!/usr/bin/env python3\nprint("x")\n' > tmp/sl.py
  fi_run install-statusline --target tmp/sl.py --apply
  [ "$status" -eq 0 ]
  grep -q '_fi_seg(' tmp/sl.py
  fi_run uninstall-statusline --target tmp/sl.py
  [ "$status" -eq 0 ]
  ! grep -q '_fi_seg' tmp/sl.py || false
  grep -qx 'print("x")' tmp/sl.py
}

@test "uninstall-statusline refuses a start marker with no end marker and keeps user lines (status-6)" {
  mkdir -p "$HOME/.claude"
  export FOUND_ISSUES_STATUSLINE_FILE="$HOME/.claude/statusline.sh"
  printf '#!/usr/bin/env bash\n# === found-issues plugin segment ===\nx=1\necho keep-me\n' > "$FOUND_ISSUES_STATUSLINE_FILE"
  fi_run uninstall-statusline
  [ "$status" -ne 0 ]
  grep -q keep-me "$FOUND_ISSUES_STATUSLINE_FILE"
}

@test "uninstall-statusline writes through a symlinked statusline, keeping the link (status-7)" {
  mkdir -p "$HOME/.claude" "$TMP/dotfiles"
  printf '#!/usr/bin/env bash\necho hi\n# === found-issues plugin segment ===\nx=1\n# === end found-issues plugin segment ===\n' > "$TMP/dotfiles/statusline.sh"
  ln -s "$TMP/dotfiles/statusline.sh" "$HOME/.claude/statusline.sh"
  export FOUND_ISSUES_STATUSLINE_FILE="$HOME/.claude/statusline.sh"
  fi_run uninstall-statusline
  [ "$status" -eq 0 ]
  [ -L "$HOME/.claude/statusline.sh" ]
  ! grep -q 'found-issues plugin segment' "$TMP/dotfiles/statusline.sh"
}

@test "install-statusline --target writes through a symlink, keeping the link (status-7)" {
  mkdir -p tmp "$TMP/dotfiles"
  printf '#!/usr/bin/env bash\necho "hi"\n' > "$TMP/dotfiles/sl.sh"
  ln -s "$TMP/dotfiles/sl.sh" tmp/sl.sh
  fi_run install-statusline --target tmp/sl.sh --apply
  [ "$status" -eq 0 ]
  [ -L tmp/sl.sh ]
  grep -q 'found-issues:seg' "$TMP/dotfiles/sl.sh"
}

@test "install-statusline --target splices only the last LINE1 and never a piped or redirected echo (status-11)" {
  mkdir -p tmp && cat > tmp/sl.sh <<'EOS'
#!/usr/bin/env bash
input="$(cat)"
LINE1="a"
LINE1="$LINE1 b"
echo "$input" | jq -r '.x' >/dev/null
echo "debug" >&2
echo "$LINE1"
EOS
  fi_run install-statusline --target tmp/sl.sh --apply
  [ "$status" -eq 0 ]
  [ "$(grep -c 'found-issues:seg' tmp/sl.sh)" -eq 1 ]
  grep -q '^LINE1="\$LINE1 b\${__FI_SEG}"' tmp/sl.sh
}

@test "install-statusline --target skips piped/redirected echo candidates when there is no LINE1 (status-11)" {
  mkdir -p tmp && cat > tmp/sl.sh <<'EOS'
#!/usr/bin/env bash
echo "debug" >&2
echo "$x" | tr a b
echo "out"
EOS
  fi_run install-statusline --target tmp/sl.sh --apply
  [ "$status" -eq 0 ]
  [ "$(grep -c 'found-issues:seg' tmp/sl.sh)" -eq 1 ]
  grep -q '^echo "out\${__FI_SEG}"' tmp/sl.sh
}

@test "install-statusline refuses an unbalanced old block instead of truncating (status-6)" {
  mkdir -p "$HOME/.claude"
  printf '#!/usr/bin/env bash\nLINE1="x"\n# === found-issues plugin segment ===\nFI=$(found-issues status --format=segment)\necho keep-me\n' > "$HOME/.claude/statusline.sh"
  fi_run install-statusline
  [ "$status" -ne 0 ]
  grep -q keep-me "$HOME/.claude/statusline.sh"
}
