#!/usr/bin/env bats
# Tests for `found-issues install-fi-alias` / `uninstall-fi-alias`.
#
# Why these subcommands exist (and these tests guard them):
# v0.1.15 setup.md handed the LLM a markdown code block to handcraft
# `~/.claude/commands/fi.md`. The agent dropped `$ARGUMENTS` on a real
# install — alias was created but didn't pass through args. Same failure
# class statusline had pre-v0.1.11 (LLM editing files by hand). v0.1.16
# moves /fi alias to a deterministic CLI path with the literal
# `$ARGUMENTS` baked in.

load 'helpers'

setup() {
  fi_setup_tmp
  export HOME="$TMP/home"
  mkdir -p "$HOME/.claude/commands"
}

teardown() {
  fi_teardown_tmp
}

@test "install-fi-alias: creates fi.md when missing" {
  fi_run install-fi-alias
  [ "$status" -eq 0 ]
  [[ "$output" == *"created"* ]]
  [ -f "$HOME/.claude/commands/fi.md" ]
}

@test "install-fi-alias: preserves literal \$ARGUMENTS (the v0.1.15 bug)" {
  fi_run install-fi-alias
  [ "$status" -eq 0 ]
  # The literal string must include $ARGUMENTS — without it, /fi log foo
  # would expand to `Run /found-issues:` with arguments dropped on the floor.
  grep -Fq 'Run /found-issues:$ARGUMENTS' "$HOME/.claude/commands/fi.md"
}

@test "install-fi-alias: writes a description front-matter" {
  fi_run install-fi-alias
  [ "$status" -eq 0 ]
  grep -Fq 'description:' "$HOME/.claude/commands/fi.md"
}

@test "install-fi-alias: idempotent (second run no-ops)" {
  fi_run install-fi-alias
  [ "$status" -eq 0 ]
  local first_size
  first_size=$(wc -c < "$HOME/.claude/commands/fi.md")

  fi_run install-fi-alias
  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed"* ]]
  local second_size
  second_size=$(wc -c < "$HOME/.claude/commands/fi.md")
  [ "$first_size" -eq "$second_size" ]
}

@test "install-fi-alias: refuses to overwrite a user-authored fi.md" {
  cat > "$HOME/.claude/commands/fi.md" <<'EOF'
---
description: My personal fi command
---

Some custom workflow that has nothing to do with found-issues.
EOF

  fi_run install-fi-alias
  [ "$status" -ne 0 ]
  [[ "$output" == *"not the found-issues alias"* ]]
  # User's content untouched
  grep -Fq "My personal fi command" "$HOME/.claude/commands/fi.md"
}

@test "install-fi-alias: creates parent directory if missing" {
  rm -rf "$HOME/.claude/commands"
  fi_run install-fi-alias
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/commands/fi.md" ]
}

@test "uninstall-fi-alias: removes our file" {
  fi_run install-fi-alias
  [ "$status" -eq 0 ]
  fi_run uninstall-fi-alias
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed"* ]]
  [ ! -f "$HOME/.claude/commands/fi.md" ]
}

@test "uninstall-fi-alias: preserves user-authored fi.md" {
  cat > "$HOME/.claude/commands/fi.md" <<'EOF'
---
description: My personal fi command
---

Some custom workflow.
EOF

  fi_run uninstall-fi-alias
  [ "$status" -eq 0 ]
  [[ "$output" == *"not the found-issues alias"* ]]
  # User's file still there
  [ -f "$HOME/.claude/commands/fi.md" ]
  grep -Fq "My personal fi command" "$HOME/.claude/commands/fi.md"
}

@test "uninstall-fi-alias: no-op when not installed" {
  fi_run uninstall-fi-alias
  [ "$status" -eq 0 ]
  [[ "$output" == *"not installed"* ]]
}

@test "round-trip: install then uninstall leaves directory clean" {
  fi_run install-fi-alias
  [ "$status" -eq 0 ]
  fi_run uninstall-fi-alias
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/.claude/commands/fi.md" ]
}
