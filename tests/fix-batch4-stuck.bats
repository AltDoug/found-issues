#!/usr/bin/env bats
# Ledger batch 4: auto-fix STUCK marker after repeated "tests fail at base"
# retires (lib/autofix-queue.sh:345), and the wrench count of a local-mode
# ledger nested under a repo not being inherited (lib/segment-cache.sh:119).

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_fixture
  export PATH="$TEST_REPO_ROOT/bin:$PATH"
  export FOUND_ISSUES_CACHE_DIR="$TMP/cache"
  fi_af_queue_fixture
  ST="$FI_AF_ST"
  RED='echo "not ok 1 needs donor files"; echo "not ok 2 reads local toml"; exit 1'
  git config found-issues.autofix.testCommand "$RED"
  git config found-issues.autofix.dailyFixes 50
}
teardown() { fi_teardown_tmp; }

seg() { "$FI_BIN" status --format=segment --cwd "${1:-$REPO}"; }

# Claim the oldest queued item (it retires stale at base), then queue another.
retire_one() {
  local next="${1:-1}"
  local id
  id="$(ls "$ST/queue" | head -1)"
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 5 ]
  "$FI_BIN" log --fix small "test.sh:$((next + 10)) — entry $next" >/dev/null
}

@test "stuck: two base failures in a row do not mark the repo" {
  retire_one 1
  retire_one 2
  run seg
  [[ "$output" != *"stuck"* ]] || false
  run "$FI_BIN" autofix summary
  [[ "$output" != *"STUCK"* ]] || false
}

@test "stuck: three base failures in a row put a stuck marker in the statusline segment" {
  seg >/dev/null; seg >/dev/null          # warm the segment cache first
  retire_one 1; retire_one 2; retire_one 3
  run seg
  [[ "$output" == *"🔧stuck"* ]]
  # and again with the cache warm
  run seg
  [[ "$output" == *"🔧stuck"* ]]
}

@test "stuck: any other outcome resets the streak" {
  retire_one 1; retire_one 2; retire_one 3
  run seg
  [[ "$output" == *"stuck"* ]]
  git config found-issues.autofix.testCommand 'true'
  id="$(ls "$ST/queue" | head -1)"
  "$FI_BIN" autofix claim "$id" >/dev/null
  "$FI_BIN" autofix release "$id" --failed "x" >/dev/null
  run seg
  [[ "$output" != *"stuck"* ]] || false
  # the count starts again from zero: two more red items are not stuck
  git config found-issues.autofix.testCommand "$RED"
  "$FI_BIN" log --fix small 'test.sh:40 — after reset' >/dev/null
  retire_one 4; retire_one 5
  run seg
  [[ "$output" != *"stuck"* ]] || false
}

@test "stuck: the marker is per repo root" {
  retire_one 1; retire_one 2; retire_one 3
  mkdir -p "$TMP/other" && cd "$TMP/other" && fi_init_git
  mkdir -p docs && printf '# found-issues\n\n- [open] 2026-10-01 a.sh:1 — x\n' > docs/found-issues.md
  run seg "$TMP/other"
  [[ "$output" != *"stuck"* ]] || false
}

@test "stuck: the summary names the first failing tests and the worktreeFiles hint" {
  retire_one 1; retire_one 2; retire_one 3
  run "$FI_BIN" autofix summary
  [[ "$output" == *"Auto-fix is STUCK"* ]]
  [[ "$output" == *"needs donor files, reads local toml"* ]]
  [[ "$output" == *"found-issues.autofix.worktreeFiles"* ]]
  # state, not news: it shows again on the next call
  run "$FI_BIN" autofix summary
  [[ "$output" == *"Auto-fix is STUCK"* ]]
}

@test "stuck: the SessionStart hook carries the stuck line" {
  retire_one 1; retire_one 2; retire_one 3
  run env CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_ROOT="$TEST_REPO_ROOT" FOUND_ISSUES_BIN="$FI_BIN" \
    bash "$TEST_REPO_ROOT/hooks/session-start.sh" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Auto-fix is STUCK"* ]]
  [[ "$output" == *"needs donor files"* ]]
}

@test "stuck: the marker follows its state file on a warm segment cache, not the cache" {
  retire_one 1; retire_one 2; retire_one 3
  run seg
  [[ "$output" == *"stuck"* ]]
  rm -f "$FI_AF_ROOT/stuck/"*
  run seg
  [[ "$output" != *"stuck"* ]] || false
}

# --- ledger lib/segment-cache.sh:119 ---

@test "wrench: a local-mode ledger nested under a repo does not inherit its wrench count" {
  mkdir -p "$FOUND_ISSUES_STATE_DIR/autofix/seg" "$REPO/notes"
  printf '2\n' > "$FOUND_ISSUES_STATE_DIR/autofix/seg/${REPO//[^A-Za-z0-9._-]/_}"
  printf '# found-issues\n\n- [open] 2026-10-01 n.sh:1 — nested note\n' > "$REPO/notes/.found-issues.md"
  run seg "$REPO/notes"
  [[ "$output" == *"issue"* ]]
  [[ "$output" != *"🔧"* ]] || false
  # the repo's own ledger still shows it
  run seg "$REPO"
  [[ "$output" == *"🔧2"* ]]
}

@test "wrench: FOUND_ISSUES_MODE=local never inherits the toplevel wrench count" {
  mkdir -p "$FOUND_ISSUES_STATE_DIR/autofix/seg" "$REPO/pkg/docs"
  printf '2\n' > "$FOUND_ISSUES_STATE_DIR/autofix/seg/${REPO//[^A-Za-z0-9._-]/_}"
  printf '# found-issues\n\n- [open] 2026-10-01 pkg/x.sh:1 — nested bug\n' > "$REPO/pkg/docs/found-issues.md"
  FOUND_ISSUES_MODE=local run seg "$REPO/pkg"
  [[ "$output" != *"🔧"* ]] || false
}

@test "wrench: a git-mode nested package ledger still inherits the toplevel count" {
  mkdir -p "$FOUND_ISSUES_STATE_DIR/autofix/seg" "$REPO/pkg/docs"
  printf '2\n' > "$FOUND_ISSUES_STATE_DIR/autofix/seg/${REPO//[^A-Za-z0-9._-]/_}"
  printf '# found-issues\n\n- [open] 2026-10-01 pkg/x.sh:1 — nested bug\n' > "$REPO/pkg/docs/found-issues.md"
  run seg "$REPO/pkg"
  [[ "$output" == *"🔧2"* ]]
}
