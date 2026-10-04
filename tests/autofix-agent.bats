#!/usr/bin/env bats
# The launcher B plugin agent (spec §4.2; plugin agents support name,
# description, model, effort, maxTurns, tools, background and ignore
# permissionMode/hooks/mcpServers — Claude Code docs, re-checked 2026-10-03).

load 'helpers'

AGENT="$TEST_REPO_ROOT/agents/found-issues-fixer.md"

fm() { awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {exit} f' "$AGENT"; }

@test "agent: fixer frontmatter uses only supported fields" {
  [ -f "$AGENT" ]
  fm | grep -qx 'name: found-issues-fixer'
  fm | grep -qx 'model: sonnet'
  fm | grep -qx 'background: true'
  fm | grep -Eqx 'maxTurns: [0-9]+'
  fm | grep -qx 'tools: Read, Edit, Write, Glob, Grep, Bash'
  if fm | grep -Eq '^(permissionMode|hooks|mcpServers|initialPrompt|isolation):'; then false; fi
}

@test "agent: every command the fixer is told to run is a found-issues autofix call" {
  [ -f "$AGENT" ]
  cmds="$(grep -Eo '`[^`]+`' "$AGENT" | tr -d '`')"
  if printf '%s\n' "$cmds" | grep -Eq '^(git|gh|cd|bash|sh|rm|bats|npm)( |$)'; then false; fi
  grep -q 'found-issues autofix claim <id>' "$AGENT"
  grep -q 'found-issues autofix brief <id>' "$AGENT"
}

SWEEPER="$TEST_REPO_ROOT/agents/found-issues-sweeper.md"

@test "agent: sweeper frontmatter uses only supported fields" {
  [ -f "$SWEEPER" ]
  AGENT="$SWEEPER"
  fm | grep -qx 'name: found-issues-sweeper'
  fm | grep -qx 'model: sonnet'
  fm | grep -qx 'background: true'
  fm | grep -Eqx 'maxTurns: [0-9]+'
  fm | grep -qx 'tools: Read, Edit, Write, Glob, Grep, Bash'
  if fm | grep -Eq '^(permissionMode|hooks|mcpServers|initialPrompt|isolation):'; then false; fi
}

@test "agent: every command the sweeper is told to run is a found-issues autofix call" {
  [ -f "$SWEEPER" ]
  cmds="$(grep -Eo '`[^`]+`' "$SWEEPER" | tr -d '`')"
  if printf '%s\n' "$cmds" | grep -Eq '^(git|gh|cd|bash|sh|rm|bats|npm)( |$)'; then false; fi
  grep -q 'found-issues autofix claim <id>' "$SWEEPER"
  grep -q 'found-issues autofix brief <id>' "$SWEEPER"
}
