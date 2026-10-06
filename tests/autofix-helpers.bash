#!/usr/bin/env bash
# tests/autofix-helpers.bash — GitHub-shaped fixtures for the v3 auto-fix tests.
# Load after helpers: `load 'helpers'; load 'autofix-helpers'`.

# A repo whose origin is https://github.com/foo/bar.git, served by a local
# bare repo through url.insteadOf (fi_repo_id still reads foo/bar). It has
# one bug (add subtracts), a test command that sees it, a committed ledger
# entry tagged (fix: small), and auto-fix enabled locally. cwd = the repo.
# Like a real repo the suite passes at base (3.2.1 runs it there first): the
# bug's test stands in for the one a fixer adds, so it runs only once src/
# holds a change: uncommitted, or in a commit no remote branch has yet.
fi_af_fixture() {
  export FOUND_ISSUES_STATE_DIR="$TMP/state"
  export HOME="$TMP/home"; mkdir -p "$HOME"
  export FOUND_ISSUES_MODE=github-pr
  unset FOUND_ISSUES_AUTOFIX FOUND_ISSUES_AUTOFIX_CHILD CLAUDECODE
  git init -q --bare -b main "$TMP/remote.git"
  mkdir -p "$TMP/repo" && cd "$TMP/repo"
  fi_init_git
  git remote add origin https://github.com/foo/bar.git
  git config url."$TMP/remote.git".insteadOf https://github.com/foo/bar.git
  mkdir -p src docs
  printf 'add() { echo $(( $1 - $2 )); }\n' > src/calc.sh
  printf '. ./src/calc.sh\n[ -z "$(git status --porcelain -- src)$(git rev-list HEAD --not --remotes -- src)" ] && exit 0\n[ "$(add 2 3)" = 5 ]\n' > test.sh
  printf '# found-issues\n\n- [open] 2026-10-01 src/calc.sh:1 — add subtracts (fix: small)\n' > docs/found-issues.md
  git add -A && git commit -q -m init
  git push -q -u origin main
  git fetch -q origin && git remote set-head origin main >/dev/null
  git config found-issues.autofix true
  git config found-issues.autofix.testCommand 'sh test.sh'
  REPO="$(pwd -P)"
}

# Queue the fixture's entry as a spot item; sets ID and QITEM.
fi_af_queue_fixture() {
  source "$FI_BIN"
  fi_af_context
  fi_af_queue_spot "$(grep -m1 '^- \[open\]' docs/found-issues.md)" >/dev/null
  ID="$(ls "$FI_AF_ST/queue" | head -1)"
  QITEM="$FI_AF_ST/queue/$ID"
}

# Put the stand-in claude/codex (and the gh shim) first on PATH.
fi_use_standins() {
  export PATH="$TEST_REPO_ROOT/tests/standins:$TEST_REPO_ROOT/tests/bin-shims:$PATH"
  export FI_STANDIN_TRACE="$TMP/standin.trace"
}

# A ledger with <n> fixable (fix: medium) entries on separate files. Like a
# real repo, the suite passes at base (no test sees the bugs); each fix adds
# its own test. The spot fixture's add bug stays in src/calc.sh, untested,
# and its entry is dropped so nothing spot-queues. cwd = the repo; sets REPO.
fi_af_sweep_fixture() {
  local n="${1:-5}" i
  fi_af_fixture
  printf '# found-issues\n\n' > docs/found-issues.md
  printf '. ./src/calc.sh\n' > test.sh
  for (( i = 1; i <= n; i++ )); do
    printf 'f%s() { echo $(( $1 - 1 )); }\n' "$i" > "src/f$i.sh"
    printf '. ./src/f%s.sh\n' "$i" >> test.sh
    printf -- '- [open] 2026-10-0%s src/f%s.sh:1 — f%s subtracts one (fix: medium)\n' "$i" "$i" "$i" >> docs/found-issues.md
  done
  printf 'true\n' >> test.sh
  git add -A && git commit -q -m "sweep fixture" && git push -q origin main
}

# Push a branch <name> to the fixture's remote with one commit adding <file>,
# leaving the checkout on <name> tracking origin/<name>. cwd = the repo.
fi_af_remote_branch() {
  local name="$1" file="${2:-src/$1.sh}"
  git switch -q -c "$name"
  mkdir -p "$(dirname "$file")"
  printf 'echo %s\n' "$name" > "$file"
  git add -A && git commit -q -m "$name"
  git push -q -u origin "$name"
}
