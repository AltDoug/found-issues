#!/usr/bin/env bats
# Integration tests for /found-issues:setup's custom-statusline detection branch.
# Simulates the detection logic + install-statusline --target invocation that
# setup.md orchestrates; the AI-driven picker + Edit tool flow is tested
# manually (no headless harness for Claude Code's AskUserQuestion in bats).

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

@test "setup flow: STATUSLINE_CUSTOM_ELSEWHERE detection identifies bash target via settings.json" {
  # Simulate the settings.json detection that setup.md describes (lines 99-125)
  mkdir -p custom-home/.claude
  cat > custom-home/.claude/statusline-custom.sh <<'EOF'
#!/bin/bash
echo "custom statusline"
EOF
  cat > custom-home/.claude/settings.json <<EOF
{
  "statusLine": {
    "command": "\$HOME/.claude/statusline-custom.sh"
  }
}
EOF
  # Run the detection logic exactly as setup.md specifies
  result="$(HOME="$PWD/custom-home" bash -c '
    custom_cmd=""
    if [[ -f "$HOME/.claude/settings.json" ]] && command -v jq >/dev/null 2>&1; then
      custom_cmd="$(jq -r ".statusLine.command // empty" "$HOME/.claude/settings.json" 2>/dev/null || true)"
    fi
    custom_cmd_local=""
    if [[ -f "$HOME/.claude/settings.local.json" ]] && command -v jq >/dev/null 2>&1; then
      custom_cmd_local="$(jq -r ".statusLine.command // empty" "$HOME/.claude/settings.local.json" 2>/dev/null || true)"
    fi
    [[ -n "$custom_cmd_local" ]] && custom_cmd="$custom_cmd_local"

    custom_cmd_expanded="${custom_cmd/#\~/$HOME}"
    convention="$HOME/.claude/statusline.sh"

    if [[ -n "$custom_cmd_expanded" && "$custom_cmd_expanded" != "$convention" ]]; then
      echo "STATUSLINE_CUSTOM_ELSEWHERE: $custom_cmd_expanded"
    elif [[ -f "$convention" ]]; then
      echo "STATUSLINE_AT_CONVENTION"
    else
      echo "STATUSLINE_DEFAULT"
    fi
  ')"
  [[ "$result" == STATUSLINE_CUSTOM_ELSEWHERE:* ]]
  [[ "$result" == *"statusline-custom.sh" ]]
}

@test "setup flow: STATUSLINE_AT_CONVENTION when convention path exists" {
  mkdir -p custom-home/.claude
  cat > custom-home/.claude/statusline.sh <<'EOF'
#!/bin/bash
echo "convention statusline"
EOF
  result="$(HOME="$PWD/custom-home" bash -c '
    custom_cmd=""
    if [[ -f "$HOME/.claude/settings.json" ]] && command -v jq >/dev/null 2>&1; then
      custom_cmd="$(jq -r ".statusLine.command // empty" "$HOME/.claude/settings.json" 2>/dev/null || true)"
    fi
    custom_cmd_local=""
    if [[ -f "$HOME/.claude/settings.local.json" ]] && command -v jq >/dev/null 2>&1; then
      custom_cmd_local="$(jq -r ".statusLine.command // empty" "$HOME/.claude/settings.local.json" 2>/dev/null || true)"
    fi
    [[ -n "$custom_cmd_local" ]] && custom_cmd="$custom_cmd_local"

    custom_cmd_expanded="${custom_cmd/#\~/$HOME}"
    convention="$HOME/.claude/statusline.sh"

    if [[ -n "$custom_cmd_expanded" && "$custom_cmd_expanded" != "$convention" ]]; then
      echo "STATUSLINE_CUSTOM_ELSEWHERE: $custom_cmd_expanded"
    elif [[ -f "$convention" ]]; then
      echo "STATUSLINE_AT_CONVENTION"
    else
      echo "STATUSLINE_DEFAULT"
    fi
  ')"
  [[ "$result" == "STATUSLINE_AT_CONVENTION" ]]
}

@test "setup flow: STATUSLINE_DEFAULT when no statusline exists" {
  mkdir -p custom-home/.claude
  result="$(HOME="$PWD/custom-home" bash -c '
    custom_cmd=""
    if [[ -f "$HOME/.claude/settings.json" ]] && command -v jq >/dev/null 2>&1; then
      custom_cmd="$(jq -r ".statusLine.command // empty" "$HOME/.claude/settings.json" 2>/dev/null || true)"
    fi
    custom_cmd_local=""
    if [[ -f "$HOME/.claude/settings.local.json" ]] && command -v jq >/dev/null 2>&1; then
      custom_cmd_local="$(jq -r ".statusLine.command // empty" "$HOME/.claude/settings.local.json" 2>/dev/null || true)"
    fi
    [[ -n "$custom_cmd_local" ]] && custom_cmd="$custom_cmd_local"

    custom_cmd_expanded="${custom_cmd/#\~/$HOME}"
    convention="$HOME/.claude/statusline.sh"

    if [[ -n "$custom_cmd_expanded" && "$custom_cmd_expanded" != "$convention" ]]; then
      echo "STATUSLINE_CUSTOM_ELSEWHERE: $custom_cmd_expanded"
    elif [[ -f "$convention" ]]; then
      echo "STATUSLINE_AT_CONVENTION"
    else
      echo "STATUSLINE_DEFAULT"
    fi
  ')"
  [[ "$result" == "STATUSLINE_DEFAULT" ]]
}

@test "setup flow: install-statusline --target on custom bash file produces valid diff" {
  mkdir -p custom-home/.claude
  cat > custom-home/.claude/sl.sh <<'EOF'
#!/bin/bash
REPO=$(basename "$PWD")
BRANCH=$(git branch --show-current 2>/dev/null)
LINE1="$REPO | $BRANCH"
echo "$LINE1"
EOF
  fi_run install-statusline --target "$PWD/custom-home/.claude/sl.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"@@"* ]]  # unified diff header (@@...)
  [[ "$output" == *"__FI_SEG"* ]]  # marker should appear in diff
}

@test "setup flow: settings.local.json statusLine.command takes precedence over settings.json" {
  mkdir -p custom-home/.claude
  cat > custom-home/.claude/statusline-custom.sh <<'EOF'
#!/bin/bash
echo "custom"
EOF
  cat > custom-home/.claude/statusline-local.sh <<'EOF'
#!/bin/bash
echo "local override"
EOF
  cat > custom-home/.claude/settings.json <<EOF
{
  "statusLine": {
    "command": "\$HOME/.claude/statusline-custom.sh"
  }
}
EOF
  cat > custom-home/.claude/settings.local.json <<EOF
{
  "statusLine": {
    "command": "\$HOME/.claude/statusline-local.sh"
  }
}
EOF
  result="$(HOME="$PWD/custom-home" bash -c '
    custom_cmd=""
    if [[ -f "$HOME/.claude/settings.json" ]] && command -v jq >/dev/null 2>&1; then
      custom_cmd="$(jq -r ".statusLine.command // empty" "$HOME/.claude/settings.json" 2>/dev/null || true)"
    fi
    custom_cmd_local=""
    if [[ -f "$HOME/.claude/settings.local.json" ]] && command -v jq >/dev/null 2>&1; then
      custom_cmd_local="$(jq -r ".statusLine.command // empty" "$HOME/.claude/settings.local.json" 2>/dev/null || true)"
    fi
    [[ -n "$custom_cmd_local" ]] && custom_cmd="$custom_cmd_local"

    custom_cmd_expanded="${custom_cmd/#\~/$HOME}"
    convention="$HOME/.claude/statusline.sh"

    if [[ -n "$custom_cmd_expanded" && "$custom_cmd_expanded" != "$convention" ]]; then
      echo "STATUSLINE_CUSTOM_ELSEWHERE: $custom_cmd_expanded"
    elif [[ -f "$convention" ]]; then
      echo "STATUSLINE_AT_CONVENTION"
    else
      echo "STATUSLINE_DEFAULT"
    fi
  ')"
  [[ "$result" == STATUSLINE_CUSTOM_ELSEWHERE:* ]]
  [[ "$result" == *"statusline-local.sh" ]]
}

@test "setup flow: tilde expansion in statusLine.command is handled correctly" {
  mkdir -p custom-home/.claude
  cat > custom-home/.claude/my-statusline.sh <<'EOF'
#!/bin/bash
echo "tilde test"
EOF
  cat > custom-home/.claude/settings.json <<EOF
{
  "statusLine": {
    "command": "~/.claude/my-statusline.sh"
  }
}
EOF
  result="$(HOME="$PWD/custom-home" bash -c '
    custom_cmd=""
    if [[ -f "$HOME/.claude/settings.json" ]] && command -v jq >/dev/null 2>&1; then
      custom_cmd="$(jq -r ".statusLine.command // empty" "$HOME/.claude/settings.json" 2>/dev/null || true)"
    fi
    custom_cmd_local=""
    if [[ -f "$HOME/.claude/settings.local.json" ]] && command -v jq >/dev/null 2>&1; then
      custom_cmd_local="$(jq -r ".statusLine.command // empty" "$HOME/.claude/settings.local.json" 2>/dev/null || true)"
    fi
    [[ -n "$custom_cmd_local" ]] && custom_cmd="$custom_cmd_local"

    custom_cmd_expanded="${custom_cmd/#\~/$HOME}"
    convention="$HOME/.claude/statusline.sh"

    if [[ -n "$custom_cmd_expanded" && "$custom_cmd_expanded" != "$convention" ]]; then
      echo "STATUSLINE_CUSTOM_ELSEWHERE: $custom_cmd_expanded"
    elif [[ -f "$convention" ]]; then
      echo "STATUSLINE_AT_CONVENTION"
    else
      echo "STATUSLINE_DEFAULT"
    fi
  ')"
  [[ "$result" == STATUSLINE_CUSTOM_ELSEWHERE:* ]]
  # Verify tilde was expanded to absolute path
  [[ "$result" == "$PWD/custom-home/.claude/my-statusline.sh" ]] || [[ "$result" == *"/custom-home/.claude/my-statusline.sh" ]]
}
