#!/usr/bin/env bats
# Tests for `found-issues install-statusline` / `uninstall-statusline`

load 'helpers'

setup() {
  fi_setup_tmp
  # Use a fake $HOME so we don't touch the real ~/.claude/statusline.sh
  export HOME="$TMP/home"
  mkdir -p "$HOME/.claude"
}

teardown() {
  fi_teardown_tmp
}

@test "install-statusline: errors when statusline.sh missing" {
  fi_run install-statusline
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "install-statusline: appends marker block to existing statusline" {
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
set -euo pipefail
input=$(cat)
echo "repo | branch"
SL
  fi_run install-statusline
  [ "$status" -eq 0 ]
  [[ "$output" == *"appended found-issues segment"* ]]
  grep -Fq "# === found-issues plugin segment ===" "$HOME/.claude/statusline.sh"
  grep -Fq "# === end found-issues plugin segment ===" "$HOME/.claude/statusline.sh"
  grep -Fq "|| true" "$HOME/.claude/statusline.sh"
}

@test "install-statusline: idempotent (second run no-ops)" {
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
echo "test"
SL
  fi_run install-statusline
  [ "$status" -eq 0 ]
  local first_size
  first_size=$(wc -c < "$HOME/.claude/statusline.sh")

  fi_run install-statusline
  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed"* ]]
  local second_size
  second_size=$(wc -c < "$HOME/.claude/statusline.sh")
  [ "$first_size" -eq "$second_size" ]
}

@test "install-statusline: appended block doesn't break a set -e statusline" {
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
set -euo pipefail
echo "BEFORE"
SL
  fi_run install-statusline
  [ "$status" -eq 0 ]

  # Ensure the file is still syntactically valid
  bash -n "$HOME/.claude/statusline.sh"

  # Run it: the BEFORE line should still output even though
  # `found-issues` isn't on PATH inside the bash subshell here
  # (bats inherits PATH but the user's plugin auto-PATH won't apply
  # in this raw shell context).
  run env PATH="/usr/bin:/bin" bash "$HOME/.claude/statusline.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BEFORE"* ]]
}

@test "uninstall-statusline: removes the marker block cleanly" {
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
echo "BEFORE"
SL
  fi_run install-statusline
  [ "$status" -eq 0 ]
  fi_run uninstall-statusline
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed found-issues segment"* ]]
  ! grep -Fq "found-issues plugin segment" "$HOME/.claude/statusline.sh"
  grep -Fq 'echo "BEFORE"' "$HOME/.claude/statusline.sh"
}

@test "uninstall-statusline: no-op when not installed" {
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
echo "test"
SL
  fi_run uninstall-statusline
  [ "$status" -eq 0 ]
  [[ "$output" == *"not installed"* ]]
}

@test "uninstall-statusline: errors when statusline.sh missing" {
  fi_run uninstall-statusline
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "install-then-uninstall: file is byte-identical to original" {
  local orig_content='#!/usr/bin/env bash
set -euo pipefail
input=$(cat)
echo "repo | branch | tokens"
'
  printf '%s' "$orig_content" > "$HOME/.claude/statusline.sh"
  local orig_hash
  orig_hash=$(shasum "$HOME/.claude/statusline.sh" | awk '{print $1}')

  fi_run install-statusline
  [ "$status" -eq 0 ]
  fi_run uninstall-statusline
  [ "$status" -eq 0 ]

  local new_hash
  new_hash=$(shasum "$HOME/.claude/statusline.sh" | awk '{print $1}')
  [ "$orig_hash" = "$new_hash" ]
}
