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

@test "install-statusline: appends standalone segment when no LINE1 pattern" {
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
set -euo pipefail
input=$(cat)
echo "repo | branch"
SL
  fi_run install-statusline
  [ "$status" -eq 0 ]
  [[ "$output" == *"appended standalone segment"* ]]
  grep -Fq "# === found-issues plugin segment ===" "$HOME/.claude/statusline.sh"
  grep -Fq "# === end found-issues plugin segment ===" "$HOME/.claude/statusline.sh"
  grep -Fq "|| true" "$HOME/.claude/statusline.sh"
  # Standalone form echoes the segment
  grep -Fq 'echo "$__FI_SEG"' "$HOME/.claude/statusline.sh"
}

@test "install-statusline: inserts inline when LINE1 assembly detected" {
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
set -euo pipefail
input=$(cat)
LINE1="repo"
LINE1="$LINE1 | branch"
echo "$LINE1"
SL
  fi_run install-statusline
  [ "$status" -eq 0 ]
  [[ "$output" == *"inserted inline LINE1 segment"* ]]
  grep -Fq "# === found-issues plugin segment ===" "$HOME/.claude/statusline.sh"
  # Inline form updates LINE1
  grep -Fq 'LINE1="$LINE1$__FI_SEG"' "$HOME/.claude/statusline.sh"
  # Standalone echo should NOT be present in inline mode
  ! grep -Fq 'echo "$__FI_SEG"' "$HOME/.claude/statusline.sh"
}

@test "install-statusline: emits PATH-robust fallback with sort -V (semver-correct)" {
  # Both standalone and inline forms must include the fallback that globs
  # ~/.claude/plugins/cache/*/found-issues/*/bin/found-issues when the CLI
  # isn't on PATH. Must use sort -V — byte-wise glob order picks 0.1.9 as
  # latest when 0.1.10/0.1.11 are present (regression bug from v0.1.12).
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
echo "test"
SL
  fi_run install-statusline
  [ "$status" -eq 0 ]
  grep -Fq 'command -v found-issues' "$HOME/.claude/statusline.sh"
  grep -Fq '.claude/plugins/cache/*/found-issues/*/bin/found-issues' "$HOME/.claude/statusline.sh"
  grep -Fq 'sort -V' "$HOME/.claude/statusline.sh"

  # Same check for inline form
  rm "$HOME/.claude/statusline.sh"
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
LINE1="repo"
LINE1="$LINE1 | branch"
echo "$LINE1"
SL
  fi_run install-statusline
  [ "$status" -eq 0 ]
  grep -Fq 'command -v found-issues' "$HOME/.claude/statusline.sh"
  grep -Fq '.claude/plugins/cache/*/found-issues/*/bin/found-issues' "$HOME/.claude/statusline.sh"
  grep -Fq 'sort -V' "$HOME/.claude/statusline.sh"
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

@test "install-statusline: generated segment block contains cwd handling (the v1.0.1 bug)" {
  # Both standalone and inline forms must extract workspace dir from $input
  # and cd before invoking the CLI. Without this, the statusline subprocess
  # runs `found-issues status` from $HOME and never finds docs/found-issues.md.
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
echo "test"
SL
  fi_run install-statusline
  [ "$status" -eq 0 ]
  # Standalone form: must include $input parsing and cd
  grep -Fq 'jq -r' "$HOME/.claude/statusline.sh"
  grep -Fq '.workspace.current_dir' "$HOME/.claude/statusline.sh"
  grep -Fq 'cd "$__FI_DIR"' "$HOME/.claude/statusline.sh"

  # Same for inline form
  rm "$HOME/.claude/statusline.sh"
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
input=$(cat)
LINE1="repo"
LINE1="$LINE1 | branch"
echo "$LINE1"
SL
  fi_run install-statusline
  [ "$status" -eq 0 ]
  grep -Fq 'jq -r' "$HOME/.claude/statusline.sh"
  grep -Fq '.workspace.current_dir' "$HOME/.claude/statusline.sh"
  grep -Fq 'cd "$__FI_DIR"' "$HOME/.claude/statusline.sh"
}

@test "install-statusline: e2e segment renders count when given workspace JSON (regression)" {
  # The actual scenario: a multi-line statusline that uses `git -C "$DIR"`
  # rather than cd, runs from $HOME, gets JSON input including workspace.current_dir.
  # Before v1.0.2 this returned empty because `found-issues status` was called
  # from $HOME and never found docs/found-issues.md. v1.0.2 should cd first.

  # Skip if jq isn't available — segment falls back to no-cd behavior, can't test.
  command -v jq >/dev/null 2>&1 || skip "jq not available"

  # Set up a fake project with known issues. Use TODAY so no "stale" bucket
  # confuses the assertion, and no [!] so all 3 land in the plain "issues"
  # bucket (critical entries would split into a separate "1 critical" segment).
  local today
  today=$(date +%Y-%m-%d)
  local project="$TMP/proj"
  mkdir -p "$project/docs"
  cat > "$project/docs/found-issues.md" <<EOF
# found-issues

- [open] $today src/foo.py:42 — null check missing (suggested: add guard)
- [open] $today src/auth.ts:88 — leaks token (suggested: redact)
- [open] $today src/queue.py:12 — race on flush
EOF

  # Statusline that builds LINE1 with branch info (triggers inline insertion)
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
set -euo pipefail
input=$(cat)
LINE1="repo"
LINE1="$LINE1 | branch"
echo "$LINE1"
SL
  fi_run install-statusline
  [ "$status" -eq 0 ]
  [[ "$output" == *"inserted inline"* ]]

  # Pipe Claude-Code-style JSON input where workspace.current_dir is the project.
  # Use a clean PATH to ensure the segment falls back to the cache glob —
  # but our cache glob looks under $HOME, so we need the test to find found-issues.
  # Easiest: make sure found-issues is on PATH for the subshell.
  local fi_bin_dir
  fi_bin_dir=$(dirname "$FI_BIN")

  local rendered
  rendered=$(echo "{\"workspace\":{\"current_dir\":\"$project\"}}" | \
             env PATH="$fi_bin_dir:/usr/bin:/bin" bash "$HOME/.claude/statusline.sh")
  # Should contain the count "3 issues" (or similar) — proves segment ran from $project
  [[ "$rendered" == *"3 issues"* ]]
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

@test "install-statusline: preserves executable permission" {
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
LINE1="repo"
LINE1="$LINE1 | branch"
echo "$LINE1"
SL
  chmod 755 "$HOME/.claude/statusline.sh"

  fi_run install-statusline
  [ "$status" -eq 0 ]
  [[ -x "$HOME/.claude/statusline.sh" ]]
}

@test "uninstall-statusline: preserves executable permission" {
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
LINE1="repo"
LINE1="$LINE1 | branch"
echo "$LINE1"
SL
  chmod 755 "$HOME/.claude/statusline.sh"

  fi_run install-statusline
  [ "$status" -eq 0 ]
  fi_run uninstall-statusline
  [ "$status" -eq 0 ]
  [[ -x "$HOME/.claude/statusline.sh" ]]
}
