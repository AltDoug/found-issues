#!/usr/bin/env bats
# Tests for hooks/pre-branch-delete.sh

load 'helpers'

HOOK="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/hooks/pre-branch-delete.sh"

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
  unset FOUND_ISSUES_PROMOTE_GUARD
}

@test "pre-branch-delete: passes through non-delete commands" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "pre-branch-delete: passes when target branch has no [open] entries" {
  fi_run log "src/foo.py:1 — main entry"
  git add -A; git commit -q -m "init"
  git checkout -q -b feat/clean
  git add -A; git commit -q --allow-empty -m "branch (no entries)"
  git checkout -q main

  input='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git branch -d feat/clean"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "pre-branch-delete: blocks when branch has unpromoted [open] entries" {
  fi_run log "src/foo.py:1 — main entry"
  git add -A; git commit -q -m "init"
  git checkout -q -b feat/test
  fi_run log "src/branch_only.py:1 — branch-only"
  git add -A; git commit -q -m "branch entry"
  git checkout -q main

  input='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git branch -d feat/test"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unpromoted"* ]] || [[ "$output" == *"not yet promoted"* ]]
}

@test "pre-branch-delete: catches 'git branch -D' (force delete)" {
  fi_run log "src/foo.py:1 — main"
  git add -A; git commit -q -m "init"
  git checkout -q -b feat/test
  fi_run log "src/x.py:1 — branch-only"
  git add -A; git commit -q -m "x"
  git checkout -q main

  input='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git branch -D feat/test"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 2 ]
}

@test "pre-branch-delete: catches 'git push origin --delete <branch>'" {
  fi_run log "src/foo.py:1 — main"
  git add -A; git commit -q -m "init"
  git checkout -q -b feat/test
  fi_run log "src/x.py:1 — branch-only"
  git add -A; git commit -q -m "x"

  input='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git push origin --delete feat/test"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 2 ]
}

@test "pre-branch-delete: respects FOUND_ISSUES_PROMOTE_GUARD=off" {
  export FOUND_ISSUES_PROMOTE_GUARD=off
  fi_run log "src/foo.py:1 — main"
  git add -A; git commit -q -m "init"
  git checkout -q -b feat/test
  fi_run log "src/x.py:1 — branch"
  git add -A; git commit -q -m "x"

  input='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git branch -d feat/test"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "pre-branch-delete: ignores attempts to delete the default branch" {
  input='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git branch -d main"}}'
  run bash -c "echo '$input' | '$HOOK'"
  # Skip on default branch (we don't enforce promote-before-delete-of-main)
  [ "$status" -eq 0 ]
}

@test "pre-branch-delete: allows delete when branch [open] was promoted as [fixed]+annotations on main (dedup-key match)" {
  # Regression for the 2026-05-10 surprise: a feature branch's [open] entry
  # gets annotated (PR:..) and merged into main; sync flips it to [fixed]
  # with (fixed:..) appended. The branch's verbatim [open] line is no
  # longer on main, but the dedup key is. Pre-v1.0.6 line-equality blocked
  # the delete; dedup-key matching should allow it.
  git commit -q --allow-empty -m "init"

  git checkout -q -b feat/work
  fi_run log "src/foo.py:42 — null check missing"
  git add -A; git commit -q -m "log entry"

  git checkout -q main
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues

Test fixture.

- [fixed] 2026-05-08 src/foo.py:42 — null check missing (PR: org/repo#5) (fixed: 2026-05-10)
EOF
  git add -A; git commit -q -m "sync flip"

  input='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git branch -d feat/work"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "pre-branch-delete: allows delete when branch [open] was promoted as [deferred] on main (dedup-key match)" {
  # Sibling of the [fixed] case: same dedup-key matching, but main has the
  # entry in [deferred] state (e.g. promoted then deferred). Branch's
  # [open] should still be considered promoted.
  git commit -q --allow-empty -m "init"

  git checkout -q -b feat/work
  fi_run log "src/bar.py:99 — race on shutdown"
  git add -A; git commit -q -m "log entry"

  git checkout -q main
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues

Test fixture.

- [deferred] 2026-05-08 src/bar.py:99 — race on shutdown (reason: blocked on legal)
EOF
  git add -A; git commit -q -m "promote-then-defer"

  input='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git branch -d feat/work"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "pre-branch-delete: still blocks when branch [open] has no dedup-key match on main" {
  # Confirms the new matching doesn't over-allow: a branch entry whose
  # dedup key is truly absent from main is still flagged as unpromoted.
  fi_run log "src/main_only.py:1 — main entry"
  git add -A; git commit -q -m "init"

  git checkout -q -b feat/work
  fi_run log "src/branch_only.py:1 — branch-only entry"
  git add -A; git commit -q -m "branch entry"

  git checkout -q main

  input='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git branch -d feat/work"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"branch_only.py"* ]]
}

@test "pre-branch-delete: allows delete when default branch does not track the issues file (untracked-on-main)" {
  # Scenario: repo transitioned docs/found-issues.md from tracked → gitignored.
  # Old feature branches still carry the tracked file with [open] entries.
  # Main has the file present in working tree (gitignored) but NOT in its
  # committed tree, so the guard's "promote to main" prescription is
  # incoherent. Expect: exit 0 with a "promote-guard skipped" note on stderr.
  git commit -q --allow-empty -m "init (main: no committed issues file)"

  git checkout -q -b feat/work
  fi_run log "src/branch_only.py:1 — branch-only entry"
  git add -A; git commit -q -m "branch entry"

  git checkout -q main
  # Recreate the file locally without committing — mimics gitignored-present
  # state on main. Ensures the hook picks docs/found-issues.md as rel_path
  # rather than falling through to .found-issues.md.
  mkdir -p docs
  : > docs/found-issues.md

  input='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git branch -d feat/work"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"promote-guard skipped"* ]] || [[ "$output" == *"does not track"* ]]
}

@test "pre-branch-delete: respects inline FOUND_ISSUES_PROMOTE_GUARD=off prefix in the command string" {
  # Regression for the 2026-05-20 footgun: docs/configuration.md advertises
  # `FOUND_ISSUES_PROMOTE_GUARD=off git branch -D foo` as a one-shot bypass,
  # but Claude Code's PreToolUse hook subprocess doesn't inherit per-command
  # env from the command string — the prefix only takes effect when bash
  # executes the inner git command. The hook should parse a leading
  # `FOUND_ISSUES_PROMOTE_GUARD=off ` from the command itself.
  fi_run log "src/main.py:1 — main entry"
  git add -A; git commit -q -m "init"

  git checkout -q -b feat/work
  fi_run log "src/branch_only.py:1 — branch-only entry"
  git add -A; git commit -q -m "branch entry"

  git checkout -q main

  input='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"FOUND_ISSUES_PROMOTE_GUARD=off git branch -D feat/work"}}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}
