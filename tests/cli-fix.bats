#!/usr/bin/env bats
# found-issues fix workspace|test|ship — /found-issues:fix on the shared
# auto-fix plumbing (spec §6; audit prompt-8, prompt-9, prompt-10).

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_fixture
  export PATH="$TEST_REPO_ROOT/tests/bin-shims:$PATH"
  export GH_MOCK_TRACE="$TMP/gh.trace" GH_MOCK_PR_CREATE_URL=https://github.com/foo/bar/pull/11
  export GH_MOCK_PR_VIEW=$'11\t{"number":11,"state":"OPEN","files":[]}'
}
teardown() { fi_teardown_tmp; }

ws() { out="$("$FI_BIN" fix workspace)"; WT="$(printf '%s\n' "$out" | sed -n 's/^worktree=//p')"; }

@test "fix workspace: a fresh worktree from origin on a unique branch" {
  ws
  [ -d "$WT" ]
  br="$(git -C "$WT" rev-parse --abbrev-ref HEAD)"
  [[ "$br" == fix/found-issues-$(date +%Y%m%d)-* ]]
  [ "$(git -C "$WT" rev-parse HEAD)" = "$(git rev-parse origin/main)" ]
  [[ "$out" == *"test=sh test.sh"* ]]
  [[ "$out" == *"source=$REPO"* ]]
  [[ "$out" == *"base=main"* ]]
  out1="$out"; ws
  [ "$out" != "$out1" ]
}

@test "fix workspace: outside a git repo it fails cleanly" {
  mkdir -p "$TMP/plain" && cd "$TMP/plain"
  run "$FI_BIN" fix workspace
  [ "$status" -eq 1 ]
}

@test "fix test: runs the detected command in the worktree" {
  ws
  run "$FI_BIN" fix test "$WT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"tests: fail"* ]]
  sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"
  run "$FI_BIN" fix test "$WT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tests: pass"* ]]
}

@test "fix ship: refuses a branch with no commits, then a dirty worktree" {
  ws
  printf 'b\n' > "$TMP/body"
  run "$FI_BIN" fix ship "$WT" --title t --body-file "$TMP/body" --pick src/calc.sh:1
  [ "$status" -eq 1 ]
  [[ "$output" == *"no commits"* ]]
  sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"
  git -C "$WT" commit -qam "fix: add"
  printf 'x\n' > "$WT/stray.txt"
  run "$FI_BIN" fix ship "$WT" --title t --body-file "$TMP/body" --pick src/calc.sh:1
  [ "$status" -eq 1 ]
  [[ "$output" == *"uncommitted"* ]]
  ! grep -q '^pr create' "$GH_MOCK_TRACE" 2>/dev/null || false
}

@test "fix ship: refuses red tests" {
  ws
  printf '# note\n' >> "$WT/src/calc.sh"
  git -C "$WT" commit -qam "not a fix"
  printf 'b\n' > "$TMP/body"
  run "$FI_BIN" fix ship "$WT" --title t --body-file "$TMP/body" --pick src/calc.sh:1
  [ "$status" -eq 1 ]
  [[ "$output" == *"tests fail"* ]]
}

@test "fix ship: pushes, opens the PR, annotates source and branch ledgers, never merges" {
  ws
  sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"
  git -C "$WT" commit -qam "fix: add subtracts (found-issues src/calc.sh:1)"
  printf 'b\n' > "$TMP/body"
  run "$FI_BIN" fix ship "$WT" --title "fix: add" --body-file "$TMP/body" --pick src/calc.sh:1
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #11"* ]]
  grep -q '(PR: foo/bar#11)' docs/found-issues.md
  br="$(git -C "$WT" rev-parse --abbrev-ref HEAD)"
  git -C "$TMP/remote.git" show "$br:docs/found-issues.md" | grep -q '(PR: foo/bar#11)'
  [ -z "$(git -C "$WT" status --porcelain)" ]
  ! grep -q '^pr merge' "$GH_MOCK_TRACE" || false
}

@test "fix.md: no bats-only allowed-tools, workspace/test/ship plumbing, resolve not sync" {
  f="$TEST_REPO_ROOT/commands/fix.md"
  ! grep -q 'Bash(bats:' "$f" || false
  grep -q 'found-issues fix workspace' "$f"
  grep -q 'found-issues fix test' "$f"
  grep -q 'found-issues fix ship' "$f"
  grep -q -- 'list --json --cwd' "$f"
  grep -q 'resolve ".*" --verified ai' "$f"
  ! grep -q 'run `/found-issues:sync`' "$f" || false
  grep -q 'line_end' "$f"
}

@test "fix.md: already-fixed annotate-commit uses --force after git show evidence" {
  f="$TEST_REPO_ROOT/commands/fix.md"
  grep -q 'annotate-commit <sha> --force --pick' "$f"
  grep -q 'git show <sha> -- <path>' "$f"
}

linked_session() { # the session runs in a linked worktree of the repo
  git worktree add -q -b side "$TMP/linked" origin/main
  cd "$TMP/linked"
  LINKED="$(pwd -P)"
}

@test "fix ship: from a linked-worktree session it annotates that session's ledger" {
  linked_session; ws
  [[ "$out" == *"source=$LINKED"* ]]
  sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"
  git -C "$WT" commit -qam "fix: add subtracts (found-issues src/calc.sh:1)"
  printf 'b\n' > "$TMP/body"
  run "$FI_BIN" fix ship "$WT" --title "fix: add" --body-file "$TMP/body" --pick src/calc.sh:1
  [ "$status" -eq 0 ]
  grep -q '(PR: foo/bar#11)' "$LINKED/docs/found-issues.md"
  ! grep -q '(PR: foo/bar#11)' "$REPO/docs/found-issues.md" || false
}

@test "fix ship: --source names the ledger to annotate" {
  linked_session; ws
  sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"
  git -C "$WT" commit -qam "fix: add subtracts (found-issues src/calc.sh:1)"
  printf 'b\n' > "$TMP/body"
  cd "$REPO"
  run "$FI_BIN" fix ship "$WT" --source "$LINKED" --title "fix: add" --body-file "$TMP/body" --pick src/calc.sh:1
  [ "$status" -eq 0 ]
  grep -q '(PR: foo/bar#11)' "$LINKED/docs/found-issues.md"
  ! grep -q '(PR: foo/bar#11)' "$REPO/docs/found-issues.md" || false
}

@test "fix.md: fix ship passes --source from fix workspace" {
  grep -q 'found-issues fix ship <worktree> --source <source>' "$TEST_REPO_ROOT/commands/fix.md"
}
