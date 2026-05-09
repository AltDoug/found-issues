#!/usr/bin/env bats
# Tests for `found-issues uninstall` — the cleanup command for plugin-private state.

load 'helpers'

setup() {
  fi_setup_tmp
  export HOME="$TMP/home"
  mkdir -p "$HOME/.claude/commands"
  mkdir -p "$HOME/.cache"
}

teardown() {
  fi_teardown_tmp
}

@test "uninstall: no-op when nothing is installed" {
  fi_run uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to clean"* ]]
  [[ "$output" == *"/plugin uninstall found-issues"* ]]
}

@test "uninstall: removes onboarding marker dir" {
  mkdir -p "$HOME/.claude/found-issues"
  touch "$HOME/.claude/found-issues/.onboarded"

  fi_run uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"onboarding state"* ]]
  [ ! -d "$HOME/.claude/found-issues" ]
}

@test "uninstall: removes mode detection cache" {
  mkdir -p "$HOME/.cache/found-issues"
  echo "github-pr" > "$HOME/.cache/found-issues/mode_org_repo"

  fi_run uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode-detection cache"* ]]
  [ ! -d "$HOME/.cache/found-issues" ]
}

@test "uninstall: removes /fi alias when ours" {
  cat > "$HOME/.claude/commands/fi.md" <<'EOF'
---
description: Shorthand for /found-issues commands
---

Run /found-issues:$ARGUMENTS
EOF

  fi_run uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"/fi alias"* ]]
  [ ! -f "$HOME/.claude/commands/fi.md" ]
}

@test "uninstall: preserves user's own /fi command (no Run /found-issues line)" {
  cat > "$HOME/.claude/commands/fi.md" <<'EOF'
---
description: My personal fi command
---

Some custom workflow that has nothing to do with found-issues.
EOF

  fi_run uninstall
  [ "$status" -eq 0 ]
  # User's command should be untouched
  [ -f "$HOME/.claude/commands/fi.md" ]
  grep -Fq "My personal fi command" "$HOME/.claude/commands/fi.md"
}

@test "uninstall: removes statusline segment block (preserves rest of file)" {
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
LINE1="repo"
LINE1="$LINE1 | branch"
echo "$LINE1"
SL
  chmod 755 "$HOME/.claude/statusline.sh"

  fi_run install-statusline
  [ "$status" -eq 0 ]
  grep -Fq "=== found-issues plugin segment ===" "$HOME/.claude/statusline.sh"

  fi_run uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"statusline segment"* ]]
  ! grep -Fq "=== found-issues plugin segment ===" "$HOME/.claude/statusline.sh"
  # Original content preserved
  grep -Fq 'LINE1="repo"' "$HOME/.claude/statusline.sh"
  # Executable preserved
  [[ -x "$HOME/.claude/statusline.sh" ]]
}

@test "uninstall: prints next-steps reminder for /plugin uninstall" {
  fi_run uninstall
  [[ "$output" == *"/plugin uninstall found-issues"* ]]
  [[ "$output" == *"/plugin marketplace remove"* ]]
}

@test "uninstall: cleans all 4 leftover types in one go" {
  mkdir -p "$HOME/.claude/found-issues" && touch "$HOME/.claude/found-issues/.onboarded"
  mkdir -p "$HOME/.cache/found-issues" && echo "x" > "$HOME/.cache/found-issues/mode_a_b"
  cat > "$HOME/.claude/commands/fi.md" <<'EOF'
Run /found-issues:$ARGUMENTS
EOF
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
LINE1="repo"
LINE1="$LINE1 | branch"
echo "$LINE1"
SL
  chmod 755 "$HOME/.claude/statusline.sh"
  fi_run install-statusline
  [ "$status" -eq 0 ]

  fi_run uninstall
  [ "$status" -eq 0 ]

  [ ! -d "$HOME/.claude/found-issues" ]
  [ ! -d "$HOME/.cache/found-issues" ]
  [ ! -f "$HOME/.claude/commands/fi.md" ]
  ! grep -Fq "=== found-issues plugin segment ===" "$HOME/.claude/statusline.sh"
}
