#!/usr/bin/env bats
# 3.4.1 (ledger lib/autofix-queue.sh:313): autofix.worktreeFiles copies the
# listed gitignored local files into each fresh fix worktree.

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_fixture; fi_af_queue_fixture; ST="$FI_AF_ST"
  # The repo ignores its local config, like kh2-midgar does.
  printf 'tools/config.local.toml\n.claude/worktrees/\n' > .gitignore
  git add .gitignore && git commit -q -m ignore && git push -q origin main
  mkdir -p tools
  printf 'secret = 1\n' > tools/config.local.toml
  fi_af_item_read "$QITEM"
}
teardown() { fi_teardown_tmp; }

runlog() { cat "$FI_AF_RUNS/$ID.log" 2>/dev/null || true; }

@test "worktreeFiles: a listed gitignored file is copied into the fix worktree" {
  git config found-issues.autofix.worktreeFiles tools/config.local.toml
  fi_af_worktree_add
  [ -f "$AFI_wt/tools/config.local.toml" ]
  [ "$(cat "$AFI_wt/tools/config.local.toml")" = "secret = 1" ]
  runlog | grep -q 'worktreeFiles: copied tools/config.local.toml'
}

@test "worktreeFiles: nothing is copied when the setting is unset" {
  fi_af_worktree_add
  [ ! -e "$AFI_wt/tools/config.local.toml" ]
}

@test "worktreeFiles: spaces and commas both separate paths" {
  printf 'a=1\n' > extra.local
  printf 'extra.local\n' >> .gitignore
  git add .gitignore && git commit -q -m ignore2 && git push -q origin main
  git config found-issues.autofix.worktreeFiles 'tools/config.local.toml, extra.local'
  fi_af_worktree_add
  [ -f "$AFI_wt/tools/config.local.toml" ]
  [ -f "$AFI_wt/extra.local" ]
}

@test "worktreeFiles: a linked-worktree source falls back to the main worktree's copy" {
  git worktree add -q -b linked "$TMP/linked" main
  [ ! -e "$TMP/linked/tools/config.local.toml" ]
  git config found-issues.autofix.worktreeFiles tools/config.local.toml
  AFI_root="$TMP/linked" AFI_base=main
  fi_af_worktree_add
  [ "$AFI_wt" = "$TMP/linked/.claude/worktrees/fi-autofix-$ID" ]
  [ -f "$AFI_wt/tools/config.local.toml" ]
  [ "$(cat "$AFI_wt/tools/config.local.toml")" = "secret = 1" ]
}

@test "worktreeFiles: the linked worktree's own copy wins over the main worktree's" {
  git worktree add -q -b linked "$TMP/linked" main
  mkdir -p "$TMP/linked/tools"
  printf 'secret = linked\n' > "$TMP/linked/tools/config.local.toml"
  git config found-issues.autofix.worktreeFiles tools/config.local.toml
  AFI_root="$TMP/linked" AFI_base=main
  fi_af_worktree_add
  [ "$(cat "$AFI_wt/tools/config.local.toml")" = "secret = linked" ]
}

@test "worktreeFiles: a tracked or non-ignored path is not copied and the log says why" {
  printf 'loose\n' > loose.txt
  git config found-issues.autofix.worktreeFiles 'loose.txt test.sh'
  fi_af_worktree_add
  [ ! -e "$AFI_wt/loose.txt" ]
  runlog | grep -q 'worktreeFiles: loose.txt is not gitignored'
  runlog | grep -q 'worktreeFiles: test.sh is not gitignored'
  # test.sh is tracked: the fix worktree's own checkout stays untouched.
  cmp -s test.sh "$AFI_wt/test.sh"
}

@test "worktreeFiles: parent-dir, absolute and empty entries are rejected and nothing escapes" {
  printf 'outside\n' > "$TMP/x"
  git config found-issues.autofix.worktreeFiles '../x /etc/hosts a/../../x ,, C:/x'
  run fi_af_worktree_add
  [ "$status" -eq 0 ]
  wt="$REPO/.claude/worktrees/fi-autofix-$ID"
  [ -d "$wt" ]
  [ ! -e "$REPO/.claude/worktrees/x" ]
  [ ! -e "$wt/x" ]
  [ ! -e "$wt/hosts" ]
  [ ! -e "$wt/etc/hosts" ]
  [ "$(cat "$TMP/x")" = outside ]
  runlog | grep -q 'worktreeFiles: ../x rejected (must be a path inside the repo)'
  runlog | grep -q 'worktreeFiles: /etc/hosts rejected (must be a path inside the repo)'
  runlog | grep -q 'worktreeFiles: a/../../x rejected (must be a path inside the repo)'
  runlog | grep -q 'worktreeFiles: C:/x rejected (must be a path inside the repo)'
  ! runlog | grep -q 'copied' || false
}

@test "worktreeFiles: a missing file is logged and the run continues" {
  git config found-issues.autofix.worktreeFiles 'tools/nope.toml tools/config.local.toml'
  run fi_af_worktree_add
  [ "$status" -eq 0 ]
  runlog | grep -q "worktreeFiles: tools/nope.toml not found in $REPO — not copied"
  runlog | grep -q 'worktreeFiles: copied tools/config.local.toml'
}

@test "worktreeFiles: the helper returns 0 even when every entry is bad" {
  git config found-issues.autofix.worktreeFiles '../x nope'
  fi_af_worktree_add
  run fi_af_copy_worktree_files
  [ "$status" -eq 0 ]
}

@test "worktreeFiles: the file survives the base-test reset and clean" {
  git config found-issues.autofix.worktreeFiles tools/config.local.toml
  git config found-issues.autofix.testCommand 'echo litter > litter.txt; sh test.sh'
  fi_af_worktree_add
  run fi_af_base_tests "$ID"
  [ "$status" -eq 0 ]
  [ -f "$AFI_wt/tools/config.local.toml" ]
  [ ! -e "$AFI_wt/litter.txt" ]
}

@test "worktreeFiles: a suite that needs the ignored file is green at base when listed" {
  git config found-issues.autofix.testCommand '[ -f tools/config.local.toml ]'
  git config found-issues.autofix.worktreeFiles tools/config.local.toml
  fi_af_worktree_add
  run fi_af_base_tests "$ID"
  [ "$status" -eq 0 ]
}

@test "worktreeFiles: the same suite is red at base when the setting is unset" {
  git config found-issues.autofix.testCommand '[ -f tools/config.local.toml ]'
  fi_af_worktree_add
  run fi_af_base_tests "$ID"
  [ "$status" -eq 1 ]
  runlog | grep -q 'tests fail at base'
}

@test "worktreeFiles: claim retires stale without the setting and proceeds with it" {
  git config found-issues.autofix.testCommand '[ -f tools/config.local.toml ]'
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 5 ]
  grep -q '^result=stale: tests fail at base$' "$ST/done/$ID"
}

@test "worktreeFiles: claim with the setting gets a green base run" {
  git config found-issues.autofix.testCommand '[ -f tools/config.local.toml ]'
  git config found-issues.autofix.worktreeFiles tools/config.local.toml
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 0 ]
  [ -f "$ST/running/$ID" ]
}

@test "worktreeFiles: the copied file is not staged by git add -A in the fix worktree" {
  git config found-issues.autofix.worktreeFiles tools/config.local.toml
  fi_af_worktree_add
  [ -f "$AFI_wt/tools/config.local.toml" ]
  printf 'x\n' > "$AFI_wt/src/new.sh"
  git -C "$AFI_wt" add -A
  [ "$(git -C "$AFI_wt" diff --cached --name-only)" = "src/new.sh" ]
}

@test "worktreeFiles: sweeps get the copy too" {
  git config found-issues.autofix.worktreeFiles tools/config.local.toml
  AFI_kind=sweep
  fi_af_worktree_add
  [[ "$AFI_wt" == *"/fi-sweep-"* ]]
  [ -f "$AFI_wt/tools/config.local.toml" ]
}

@test "worktreeFiles: config sets it and the listing shows it" {
  run "$FI_BIN" config autofix.worktreeFiles "a b"
  [ "$status" -eq 0 ]
  [ "$(git config --local --get found-issues.autofix.worktreeFiles)" = "a b" ]
  run "$FI_BIN" config autofix.worktreeFiles
  [ "$output" = "a b" ]
  run "$FI_BIN" config
  [[ "$output" == *"found-issues.autofix.worktreeFiles"*"a b"*"(local)"* ]]
}

@test "worktreeFiles: the listing shows it as a default when unset" {
  run "$FI_BIN" config
  [[ "$output" == *"found-issues.autofix.worktreeFiles"*"(default)"* ]]
}

@test "worktreeFiles: doctor names the files only when the setting is set" {
  run "$FI_BIN" doctor
  [[ "$output" != *"copied into fix worktrees"* ]]
  git config found-issues.autofix.worktreeFiles tools/config.local.toml
  run "$FI_BIN" doctor
  [[ "$output" == *"copied into fix worktrees: tools/config.local.toml (local)"* ]]
}
