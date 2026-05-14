#!/usr/bin/env bats
# Tests for hooks/session-start.sh — v1.4.x auto-migration logic

load 'helpers'

setup() {
  fi_setup_tmp
}

teardown() {
  fi_teardown_tmp
}

@test "session-start: does not auto-migrate canonical bash statusline (bash shim was always correct)" {
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/.claude"
  cat > "$FAKE_HOME/.claude/statusline.sh" <<'EOF'
#!/usr/bin/env bash
# === found-issues plugin segment ===
FI_SEG="$(found-issues status --format=segment 2>/dev/null || true)"
# === end found-issues plugin segment ===
LINE1="repo | main${FI_SEG}"
echo "$LINE1"
EOF
  HOME="$FAKE_HOME" run bash "${BATS_TEST_DIRNAME}/../hooks/session-start.sh" < /dev/null
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "migrating v1.4.x"
  rm -rf "$FAKE_HOME"
}

@test "session-start: auto-migrates v1.4.x POSIX-only marker in custom Node statusline" {
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/.claude"
  cat > "$FAKE_HOME/custom.js" <<'EOF'
#!/usr/bin/env node
// === found-issues plugin segment ===
let __fiSeg = '';
try {
  const { execSync } = require('child_process');
  const cacheGlob = process.env.HOME + '/.claude/plugins/cache';
  execSync('command -v found-issues');
} catch (e) {}
// === end found-issues plugin segment ===
console.log(`repo${__fiSeg}`);  // found-issues:seg
EOF
  cat > "$FAKE_HOME/.claude/settings.json" <<EOF
{"statusLine": {"command": "node $FAKE_HOME/custom.js"}}
EOF
  HOME="$FAKE_HOME" run bash "${BATS_TEST_DIRNAME}/../hooks/session-start.sh" < /dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "v1.4.x"
  ls "$FAKE_HOME"/custom.js.fi-bak-* >/dev/null 2>&1
  ! grep -q "process.env.HOME" "$FAKE_HOME/custom.js"
  grep -q "os.homedir" "$FAKE_HOME/custom.js"
  rm -rf "$FAKE_HOME"
}

@test "session-start: respects FOUND_ISSUES_AUTO_MIGRATE=off" {
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/.claude"
  cat > "$FAKE_HOME/custom.js" <<'EOF'
#!/usr/bin/env node
// === found-issues plugin segment ===
let __fiSeg = '';
try { require('child_process').execSync('command -v found-issues'); } catch(e) {}
const homePath = process.env.HOME;
// === end found-issues plugin segment ===
console.log(`repo${__fiSeg}`);  // found-issues:seg
EOF
  cat > "$FAKE_HOME/.claude/settings.json" <<EOF
{"statusLine": {"command": "node $FAKE_HOME/custom.js"}}
EOF
  HOME="$FAKE_HOME" FOUND_ISSUES_AUTO_MIGRATE=off run bash "${BATS_TEST_DIRNAME}/../hooks/session-start.sh" < /dev/null
  [ "$status" -eq 0 ]
  grep -q "process.env.HOME" "$FAKE_HOME/custom.js"
  ! ls "$FAKE_HOME"/custom.js.fi-bak-* 2>/dev/null
  rm -rf "$FAKE_HOME"
}

@test "session-start: skips migration when target file is a symlink" {
  # Probe symlink capability before the test: on Windows Git Bash without
  # SeCreateSymbolicLinkPrivilege, `ln -s` silently creates a copy and
  # [[ -L ... ]] is false — the hook's symlink branch is never taken.
  local _probe_target _probe_link
  _probe_target="$(mktemp)"
  _probe_link="${_probe_target}.link"
  ln -s "$_probe_target" "$_probe_link" 2>/dev/null
  if [[ ! -L "$_probe_link" ]]; then
    rm -f "$_probe_target" "$_probe_link"
    skip "filesystem does not support symlinks (typical on Windows without SeCreateSymbolicLinkPrivilege)"
  fi
  rm -f "$_probe_target" "$_probe_link"

  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/.claude" "$FAKE_HOME/dotfiles"
  cat > "$FAKE_HOME/dotfiles/custom.js" <<'EOF'
#!/usr/bin/env node
// === found-issues plugin segment ===
let __fiSeg = '';
try { require('child_process').execSync('command -v found-issues'); } catch(e) {}
const homePath = process.env.HOME;
// === end found-issues plugin segment ===
console.log(`repo${__fiSeg}`);  // found-issues:seg
EOF
  ln -s "$FAKE_HOME/dotfiles/custom.js" "$FAKE_HOME/custom.js"
  cat > "$FAKE_HOME/.claude/settings.json" <<EOF
{"statusLine": {"command": "node $FAKE_HOME/custom.js"}}
EOF
  HOME="$FAKE_HOME" run bash "${BATS_TEST_DIRNAME}/../hooks/session-start.sh" < /dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "symlink"
  grep -q "process.env.HOME" "$FAKE_HOME/dotfiles/custom.js"
  rm -rf "$FAKE_HOME"
}
