#!/usr/bin/env bash
# tests/autofix-helpers.bash — GitHub-shaped fixtures for the v3 auto-fix tests.
# Load after helpers: `load 'helpers'; load 'autofix-helpers'`.

# A repo whose origin is https://github.com/foo/bar.git, served by a local
# bare repo through url.insteadOf (fi_repo_id still reads foo/bar). It has
# one bug (add subtracts), a test command that sees it, a committed ledger
# entry tagged (fix: small), and auto-fix enabled locally. cwd = the repo.
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
  printf '. ./src/calc.sh\n[ "$(add 2 3)" = 5 ]\n' > test.sh
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
