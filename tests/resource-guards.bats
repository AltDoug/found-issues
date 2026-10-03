#!/usr/bin/env bats
# Behavior pinned by the 2026-10-03 audit's resource batch (fix batch 4). The
# process-count wins themselves are measured, not unit-tested (see the PR);
# these are the observable behaviors that changed along the way.

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

# gh stub that records every invocation; answers per GH_STUB_* vars.
gh_stub() {
  mkdir -p "$TMP/stubbin"
  cat > "$TMP/stubbin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_STUB_LOG"
case "$*" in
  "auth status"*) exit 0 ;;
  "repo view"*) [[ -n "${GH_STUB_REPO:-}" ]] && { printf '%s\n' "$GH_STUB_REPO"; exit 0; }; exit 1 ;;
  "pr view"*) printf '%s\n' "${GH_STUB_PR:-}"; [[ -n "${GH_STUB_PR:-}" ]] ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$TMP/stubbin/gh"
  export GH_STUB_LOG="$TMP/gh.log"
  : > "$GH_STUB_LOG"
}

@test "sync: a merged PR closes the entry on a machine with gh but no jq (ledger-7)" {
  fi_init_github_repo foo/bar main
  gh_stub
  # The stub answers the --jq form sync now asks for (fields \x1f-joined).
  export GH_STUB_PR=$'MERGED\x1fmain\x1f2026-10-01T00:00:00Z'
  mkdir -p docs src nojq
  printf 'x\n' > src/a.sh
  fi_seed_entry "src/a.sh:1 — bug (PR: foo/bar#3)"
  for t in bash sh cat grep sed awk head tail tr cut date git dirname basename mktemp rm mkdir ls wc sort uname readlink printf env stat cksum cmp mv chmod touch find paste; do
    p="$(command -v "$t" 2>/dev/null)" && [ -x "$p" ] && ln -sf "$p" "nojq/$t"
  done
  ln -sf "$TMP/stubbin/gh" nojq/gh
  run env PATH="$TMP/nojq" FOUND_ISSUES_AUTO_ARCHIVE=off bash "$FI_BIN" sync
  [ "$status" -eq 0 ]
  grep -q '^- \[fixed\].*src/a.sh:1' docs/found-issues.md
}

@test "sync: asks gh about each distinct PR once per run (ledger-8b)" {
  fi_init_github_repo foo/bar main
  gh_stub
  export GH_STUB_PR=$'OPEN\x1fmain\x1f'
  export PATH="$TMP/stubbin:$PATH"
  mkdir -p src
  printf 'x\n' > src/a.sh; printf 'x\n' > src/b.sh
  fi_seed_entry "src/a.sh:1 — one (PR: foo/bar#3)"
  fi_seed_entry "src/b.sh:1 — two (PR: foo/bar#3)"
  FOUND_ISSUES_AUTO_ARCHIVE=off fi_run sync
  [ "$status" -eq 0 ]
  [ "$(grep -c '^pr view 3 ' "$GH_STUB_LOG")" -eq 1 ]
}

@test "default branch: a failed gh lookup is not retried on the next sync (ledger-8c)" {
  git commit -q --allow-empty -m init
  git remote add origin https://github.com/foo/bar.git
  export FOUND_ISSUES_MODE=github-pr
  gh_stub
  export PATH="$TMP/stubbin:$PATH" XDG_CACHE_HOME="$TMP/xdg"
  mkdir -p src && printf 'x\n' > src/a.sh
  fi_seed_entry "src/a.sh:1 — bug (commit: abcdef1)"
  FOUND_ISSUES_AUTO_ARCHIVE=off fi_run sync
  FOUND_ISSUES_AUTO_ARCHIVE=off fi_run sync
  [ "$(grep -c '^repo view' "$GH_STUB_LOG")" -eq 1 ]
}

@test "annotate-commit --hook-auto does not look up the default branch (annot-13)" {
  git commit -q --allow-empty -m init
  git remote add origin https://github.com/foo/bar.git
  gh_stub
  export PATH="$TMP/stubbin:$PATH" XDG_CACHE_HOME="$TMP/xdg"
  git checkout -q -b feat/x
  mkdir -p src && printf 'x\n' > src/a.sh
  fi_run log "src/a.sh:1 — bug"
  printf 'y\n' >> src/a.sh
  git add -A && git commit -q -m fix
  fi_run annotate-commit HEAD --hook-auto
  ! grep -q '^repo view' "$GH_STUB_LOG"
}

@test "session-start: no sync when the ledger has nothing [open] (hook-11)" {
  mkdir -p docs
  printf -- '- [fixed] 2026-01-01 a.sh:1 — done (verified: ai) (fixed: 2026-01-02)\n' > docs/found-issues.md
  mkdir -p bin
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/cli.log"\n' "$TMP" > bin/found-issues
  chmod +x bin/found-issues
  run env FOUND_ISSUES_BIN="$TMP/bin/found-issues" CLAUDE_CODE_ENTRYPOINT=cli \
    CLAUDE_PLUGIN_ROOT="$TEST_REPO_ROOT" HOME="$TMP" bash "$TEST_REPO_ROOT/hooks/session-start.sh" </dev/null
  [ ! -s "$TMP/cli.log" ] || ! grep -q '^sync' "$TMP/cli.log"
}

@test "session-start: criticals are capped by FOUND_ISSUES_SESSION_INJECT_MAX and long lines are cut (hook-20)" {
  mkdir -p docs
  long="$(printf 'x%.0s' $(seq 1 400))"
  for i in 1 2 3 4 5; do
    printf -- '- [open] [!] 2026-10-01 c%d.sh:1 — crit %d %s\n' "$i" "$i" "$long" >> docs/found-issues.md
  done
  run env FOUND_ISSUES_SESSION_INJECT_MAX=2 CLAUDE_CODE_ENTRYPOINT=cli \
    CLAUDE_PLUGIN_ROOT="$TEST_REPO_ROOT" HOME="$TMP" bash "$TEST_REPO_ROOT/hooks/session-start.sh" </dev/null
  [ "$(printf '%s\n' "$output" | grep -c '^- \[open\] \[!\]')" -eq 2 ]
  [[ "$output" == *"3 more CRITICAL"* ]]
  ! printf '%s\n' "$output" | grep '^- \[open\]' | awk 'length($0) > 240 { bad = 1 } END { exit !bad }'
}

@test "segment autosync: each ledger keeps its own stamp (status-2)" {
  unset FOUND_ISSUES_SEGMENT_AUTOSYNC
  export FOUND_ISSUES_CACHE_DIR="$TMP/cache" FOUND_ISSUES_AUTOSYNC_CMD="echo \$PWD >> '$TMP/synced'"
  mkdir -p r1/docs r2/docs
  printf -- '- [open] 2026-10-01 a.sh:1 — one\n' > r1/docs/found-issues.md
  printf -- '- [open] 2026-10-01 a.sh:1 — two\n' > r2/docs/found-issues.md
  fi_run status --format=segment --cwd "$TMP/r1"
  fi_run status --format=segment --cwd "$TMP/r2"
  for _ in $(seq 1 20); do [ "$(wc -l < "$TMP/synced" 2>/dev/null || echo 0)" -ge 2 ] && break; sleep 0.05; done
  [ "$(wc -l < "$TMP/synced")" -ge 2 ]
}

@test "segment autosync: the spawned sync runs in the rendered repo (status-3)" {
  unset FOUND_ISSUES_SEGMENT_AUTOSYNC
  export FOUND_ISSUES_CACHE_DIR="$TMP/cache" FOUND_ISSUES_AUTOSYNC_CMD="pwd > '$TMP/where'"
  mkdir -p repo/docs elsewhere
  printf -- '- [open] 2026-10-01 a.sh:1 — one\n' > repo/docs/found-issues.md
  cd elsewhere
  fi_run status --format=segment --cwd "$TMP/repo"
  for _ in $(seq 1 20); do [ -s "$TMP/where" ] && break; sleep 0.05; done
  [ "$(cd "$TMP/repo" && pwd)" = "$(cat "$TMP/where")" ]
}

@test "segment autosync: no spawn when the stamp cannot be written (status-1)" {
  unset FOUND_ISSUES_SEGMENT_AUTOSYNC
  mkdir -p docs ro
  printf -- '- [open] 2026-10-01 a.sh:1 — one\n' > docs/found-issues.md
  chmod 500 ro
  export FOUND_ISSUES_CACHE_DIR="$TMP/ro/cache" FOUND_ISSUES_AUTOSYNC_CMD="touch '$TMP/synced'"
  fi_run status --format=segment --cwd "$TMP"
  sleep 0.3
  chmod 700 ro
  [ ! -e "$TMP/synced" ]
}
