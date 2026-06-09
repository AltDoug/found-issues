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
  # Inherit the test's PATH (instead of restricting to /usr/bin:/bin) — on Git
  # Bash for Windows jq lives at the chocolatey/winget path, NOT /usr/bin, and
  # without jq the segment falls back to no-cd behavior and renders empty.
  # Prepend the found-issues bin dir so the CLI resolves without needing the
  # cache-glob fallback.
  local fi_bin_dir
  fi_bin_dir=$(dirname "$FI_BIN")

  local rendered
  rendered=$(echo "{\"workspace\":{\"current_dir\":\"$project\"}}" | \
             env PATH="$fi_bin_dir:$PATH" bash "$HOME/.claude/statusline.sh")
  # Should contain the count "3 issues" — proves segment ran from $project.
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

# === v1.0.3: --cwd flag, classifier, self-heal install, doctor-statusline ===

@test "status: --cwd PATH locates issues file in arbitrary directory" {
  # Set up fake project elsewhere
  local proj="$TMP/elsewhere"
  mkdir -p "$proj/docs"
  local today; today=$(date +%Y-%m-%d)
  cat > "$proj/docs/found-issues.md" <<EOF
# found-issues
- [open] $today src/foo.py:1 — bug
EOF

  # CWD is $TMP (no found-issues there). Without --cwd, status is empty.
  cd "$TMP"
  fi_run status --format=plain
  [ "$status" -eq 0 ]
  [[ -z "$output" ]]

  # With --cwd, locates the issues file and reports counts.
  fi_run status --format=plain --cwd "$proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 issue"* ]]
}

@test "status: CLAUDE_PROJECT_DIR env var fallback when no --cwd" {
  local proj="$TMP/with-claude-dir"
  mkdir -p "$proj/docs"
  local today; today=$(date +%Y-%m-%d)
  cat > "$proj/docs/found-issues.md" <<EOF
# found-issues
- [open] $today src/foo.py:1 — bug
EOF

  cd "$TMP"
  CLAUDE_PROJECT_DIR="$proj" fi_run status --format=plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 issue"* ]]
}

@test "status: --cwd beats CLAUDE_PROJECT_DIR (v1.5.6 statusline cwd fix)" {
  # The statusline subprocess inherits CLAUDE_PROJECT_DIR = where the SESSION
  # started (often $HOME), while the workspace dir tracks where work happens.
  # --cwd must win or the segment scopes to the wrong root.
  local session_start="$TMP/session-start"
  local workspace="$TMP/workspace"
  mkdir -p "$session_start" "$workspace/docs"
  local today; today=$(date +%Y-%m-%d)
  cat > "$workspace/docs/found-issues.md" <<EOF
# found-issues
- [open] $today src/a.py:1 — bug one
- [open] $today src/b.py:2 — bug two
EOF

  cd "$TMP"
  # Env points at a dir with NO issues file; --cwd points at the workspace.
  CLAUDE_PROJECT_DIR="$session_start" fi_run status --format=plain --cwd "$workspace"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 issues"* ]]
}

@test "doctor-statusline: reports NOT INSTALLED when statusline lacks integration" {
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
echo "no fi here"
SL
  fi_run doctor-statusline
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOT INSTALLED"* ]]
  [[ "$output" == *"State: none"* ]]
}

@test "doctor-statusline: reports OK after fresh install" {
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
LINE1="repo"
LINE1="$LINE1 | branch"
echo "$LINE1"
SL
  fi_run install-statusline
  [ "$status" -eq 0 ]
  fi_run doctor-statusline
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
  [[ "$output" == *"State: installed-fixed"* ]]
}

@test "doctor-statusline: detects pre-v0.1.7 handwritten snippet (legacy-handwritten)" {
  # The exact 3-line snippet from pre-v0.1.7 setup.md — and what every
  # dogfood-era user has in their statusline.sh today.
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
input=$(cat)
LINE1="repo"
LINE1="$LINE1 | branch"
# found-issues plugin segment (|| true guards against set -e when CLI isn't on PATH)
FI_SEG=$(found-issues status --format=segment 2>/dev/null || true)
[[ -n "$FI_SEG" ]] && LINE1="$LINE1 | $FI_SEG"
echo "$LINE1"
SL
  fi_run doctor-statusline
  [ "$status" -eq 0 ]
  [[ "$output" == *"State: legacy-handwritten"* ]]
  [[ "$output" == *"BROKEN"* ]]
  # v1.0.4: doctor's recommended fix is plain `install-statusline` (auto-migrates).
  [[ "$output" == *"install-statusline"* ]]
  [[ "$output" != *"--migrate"* ]]
}

@test "doctor-statusline: detects v1.0.0/1.0.1 marker block missing cwd handling (installed-broken)" {
  # Synthesize the broken marker-bracketed block that v1.0.0/1.0.1 installed.
  # Critically: contains the markers but NOT __FI_DIR.
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
LINE1="repo"
# === found-issues plugin segment ===
__FI_CLI=""
if command -v found-issues >/dev/null 2>&1; then
  __FI_CLI=found-issues
fi
__FI_SEG=""
[[ -n "$__FI_CLI" ]] && __FI_SEG=$("$__FI_CLI" status --format=segment 2>/dev/null || true)
[[ -n "$__FI_SEG" ]] && LINE1="$LINE1$__FI_SEG"
# === end found-issues plugin segment ===
echo "$LINE1"
SL
  fi_run doctor-statusline
  [ "$status" -eq 0 ]
  [[ "$output" == *"State: installed-broken"* ]]
  [[ "$output" == *"BROKEN"* ]]
}

@test "doctor-statusline: detects v1.0.2-v1.5.5 cd-only block without --cwd (installed-broken)" {
  # Synthesize the v1.0.2–v1.5.5 block: has __FI_DIR + cd, but no --cwd.
  # An inherited CLAUDE_PROJECT_DIR silently overrides the cd in cmd_status's
  # search-root priority → empty segment. v1.5.6 classifies this as broken.
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
input=$(cat)
LINE1="repo"
# === found-issues plugin segment ===
__FI_CLI=found-issues
__FI_DIR=""
if [[ -n "${input:-}" ]] && command -v jq >/dev/null 2>&1; then
  __FI_DIR=$(echo "$input" | jq -r '.workspace.current_dir // ""' 2>/dev/null || true)
fi
__FI_SEG=""
if [[ -n "$__FI_CLI" ]]; then
  if [[ -n "$__FI_DIR" ]]; then
    __FI_SEG=$( cd "$__FI_DIR" 2>/dev/null && "$__FI_CLI" status --format=segment 2>/dev/null || true )
  else
    __FI_SEG=$("$__FI_CLI" status --format=segment 2>/dev/null || true)
  fi
fi
[[ -n "$__FI_SEG" ]] && LINE1="$LINE1$__FI_SEG"
# === end found-issues plugin segment ===
echo "$LINE1"
SL
  fi_run doctor-statusline
  [ "$status" -eq 0 ]
  [[ "$output" == *"State: installed-broken"* ]]
}

@test "install-statusline: auto-rewrites v1.0.2-v1.5.5 cd-only block to include --cwd" {
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
input=$(cat)
LINE1="repo"
LINE1="$LINE1 | branch"
# === found-issues plugin segment ===
__FI_CLI=found-issues
__FI_DIR=""
if [[ -n "${input:-}" ]] && command -v jq >/dev/null 2>&1; then
  __FI_DIR=$(echo "$input" | jq -r '.workspace.current_dir // ""' 2>/dev/null || true)
fi
__FI_SEG=""
if [[ -n "$__FI_CLI" && -n "$__FI_DIR" ]]; then
  __FI_SEG=$( cd "$__FI_DIR" 2>/dev/null && "$__FI_CLI" status --format=segment 2>/dev/null || true )
fi
[[ -n "$__FI_SEG" ]] && LINE1="$LINE1$__FI_SEG"
# === end found-issues plugin segment ===
echo "$LINE1"
SL
  fi_run install-statusline
  [ "$status" -eq 0 ]
  [[ "$output" == *"rewriting in place"* ]]
  # Rewritten block carries the explicit --cwd flag
  grep -Fq -- '--cwd "$__FI_DIR"' "$HOME/.claude/statusline.sh"
  # Single marker block (no duplicates)
  local count
  count=$(grep -cF "# === found-issues plugin segment ===" "$HOME/.claude/statusline.sh")
  [ "$count" -eq 1 ]
  # Second run is a no-op — the rewritten block must classify installed-fixed
  fi_run install-statusline
  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed"* ]]
}

@test "install-statusline: auto-migrates legacy-handwritten by default (v1.0.4)" {
  # v1.0.3 required `--migrate` for safety, but the AI-driven setup flow
  # bailed silently in practice. v1.0.4 flips the default — auto-migrate
  # with a timestamped backup. See CHANGELOG 1.0.4.
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
input=$(cat)
LINE1="repo"
# found-issues plugin segment
FI_SEG=$(found-issues status --format=segment 2>/dev/null || true)
[[ -n "$FI_SEG" ]] && LINE1="$LINE1 | $FI_SEG"
echo "$LINE1"
SL
  fi_run install-statusline
  [ "$status" -eq 0 ]
  # Migration happened — legacy lines stripped, canonical block added.
  ! grep -Fq 'FI_SEG=$(found-issues status' "$HOME/.claude/statusline.sh"
  grep -Fq "# === found-issues plugin segment ===" "$HOME/.claude/statusline.sh"
  grep -Fq 'cd "$__FI_DIR"' "$HOME/.claude/statusline.sh"
  # Backup file was saved next to the statusline (pattern: statusline.sh.fi-bak-<ts>).
  ls "$HOME/.claude/statusline.sh".fi-bak-* >/dev/null 2>&1
  # Backup contains the original (pre-migration) legacy snippet.
  local backup
  backup=$(ls "$HOME/.claude/statusline.sh".fi-bak-* | head -1)
  grep -Fq 'FI_SEG=$(found-issues status' "$backup"
}

@test "install-statusline --no-migrate: refuses to touch legacy-handwritten (v1.0.3 strict opt-out)" {
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
input=$(cat)
LINE1="repo"
# found-issues plugin segment
FI_SEG=$(found-issues status --format=segment 2>/dev/null || true)
[[ -n "$FI_SEG" ]] && LINE1="$LINE1 | $FI_SEG"
echo "$LINE1"
SL
  fi_run install-statusline --no-migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *"--no-migrate"* ]]
  # Original file unchanged (no markers added, no migration)
  ! grep -Fq "# === found-issues plugin segment ===" "$HOME/.claude/statusline.sh"
  grep -Fq 'FI_SEG=$(found-issues status' "$HOME/.claude/statusline.sh"
  # No backup file should exist (we bailed before touching anything)
  ! ls "$HOME/.claude/statusline.sh".fi-bak-* >/dev/null 2>&1
}

@test "install-statusline --migrate: surgically removes handwritten lines and inserts canonical block" {
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
input=$(cat)
LINE1="repo"
LINE1="$LINE1 | branch"
# found-issues plugin segment (|| true guards against set -e when CLI isn't on PATH)
FI_SEG=$(found-issues status --format=segment 2>/dev/null || true)
[[ -n "$FI_SEG" ]] && LINE1="$LINE1 | $FI_SEG"
echo "$LINE1"
SL
  fi_run install-statusline --migrate
  [ "$status" -eq 0 ]
  [[ "$output" == *"migrating pre-v0.1.7 handwritten"* ]]
  # Legacy lines gone
  ! grep -Fq 'FI_SEG=$(found-issues status --format=segment' "$HOME/.claude/statusline.sh"
  ! grep -Fq '$FI_SEG' "$HOME/.claude/statusline.sh"
  # Canonical block present, with cwd handling
  grep -Fq "# === found-issues plugin segment ===" "$HOME/.claude/statusline.sh"
  grep -Fq 'cd "$__FI_DIR"' "$HOME/.claude/statusline.sh"
  # Surrounding code preserved
  grep -Fq 'LINE1="repo"' "$HOME/.claude/statusline.sh"
  grep -Fq 'echo "$LINE1"' "$HOME/.claude/statusline.sh"
}

@test "install-statusline: auto-rewrites installed-broken (v1.0.0/1.0.1) without --migrate flag" {
  # No --migrate needed: marker boundaries make the rewrite safe.
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
LINE1="repo"
LINE1="$LINE1 | branch"
# === found-issues plugin segment ===
__FI_CLI=""
if command -v found-issues >/dev/null 2>&1; then
  __FI_CLI=found-issues
fi
__FI_SEG=""
[[ -n "$__FI_CLI" ]] && __FI_SEG=$("$__FI_CLI" status --format=segment 2>/dev/null || true)
[[ -n "$__FI_SEG" ]] && LINE1="$LINE1$__FI_SEG"
# === end found-issues plugin segment ===
echo "$LINE1"
SL
  fi_run install-statusline
  [ "$status" -eq 0 ]
  [[ "$output" == *"detected v1.0.0/1.0.1"* ]] || [[ "$output" == *"rewriting in place"* ]]
  # Now contains cwd handling
  grep -Fq '__FI_DIR' "$HOME/.claude/statusline.sh"
  grep -Fq 'cd "$__FI_DIR"' "$HOME/.claude/statusline.sh"
  # Single marker block (no duplicates)
  local count
  count=$(grep -cF "# === found-issues plugin segment ===" "$HOME/.claude/statusline.sh")
  [ "$count" -eq 1 ]
}

@test "install-statusline: auto-migrates legacy-and-installed (both legacy AND markers, v1.0.4)" {
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
LINE1="repo"
LINE1="$LINE1 | branch"
# Old handwritten block
FI_SEG=$(found-issues status --format=segment 2>/dev/null || true)
[[ -n "$FI_SEG" ]] && LINE1="$LINE1 | $FI_SEG"
# === found-issues plugin segment ===
__FI_CLI=found-issues
__FI_SEG=$("$__FI_CLI" status --format=segment 2>/dev/null || true)
[[ -n "$__FI_SEG" ]] && LINE1="$LINE1$__FI_SEG"
# === end found-issues plugin segment ===
echo "$LINE1"
SL

  # Default behavior (no flag): cleans up both, saves backup.
  fi_run install-statusline
  [ "$status" -eq 0 ]
  ! grep -Fq 'FI_SEG=$(found-issues status' "$HOME/.claude/statusline.sh"
  # Exactly one marker block remains
  local count
  count=$(grep -cF "# === found-issues plugin segment ===" "$HOME/.claude/statusline.sh")
  [ "$count" -eq 1 ]
  # And it has cwd handling
  grep -Fq 'cd "$__FI_DIR"' "$HOME/.claude/statusline.sh"
  # Backup saved
  ls "$HOME/.claude/statusline.sh".fi-bak-* >/dev/null 2>&1
}

@test "install-statusline --no-migrate: refuses legacy-and-installed (v1.0.3 strict opt-out)" {
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
LINE1="repo"
# Old handwritten block
FI_SEG=$(found-issues status --format=segment 2>/dev/null || true)
[[ -n "$FI_SEG" ]] && LINE1="$LINE1 | $FI_SEG"
# === found-issues plugin segment ===
__FI_CLI=found-issues
__FI_SEG=$("$__FI_CLI" status --format=segment 2>/dev/null || true)
[[ -n "$__FI_SEG" ]] && LINE1="$LINE1$__FI_SEG"
# === end found-issues plugin segment ===
echo "$LINE1"
SL
  fi_run install-statusline --no-migrate
  [ "$status" -ne 0 ]
  [[ "$output" == *"--no-migrate"* ]]
  # Legacy snippet still present, not stripped
  grep -Fq 'FI_SEG=$(found-issues status' "$HOME/.claude/statusline.sh"
}

@test "install-statusline: idempotent after migration (second --migrate call no-ops)" {
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
input=$(cat)
LINE1="repo"
LINE1="$LINE1 | branch"
# found-issues plugin segment
FI_SEG=$(found-issues status --format=segment 2>/dev/null || true)
[[ -n "$FI_SEG" ]] && LINE1="$LINE1 | $FI_SEG"
echo "$LINE1"
SL
  fi_run install-statusline --migrate
  [ "$status" -eq 0 ]
  local first_hash
  first_hash=$(shasum "$HOME/.claude/statusline.sh" | awk '{print $1}')

  # Second run: state is now installed-fixed → no-op
  fi_run install-statusline --migrate
  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed"* ]]
  local second_hash
  second_hash=$(shasum "$HOME/.claude/statusline.sh" | awk '{print $1}')
  [ "$first_hash" = "$second_hash" ]
}

@test "install-statusline --migrate: e2e counter renders after legacy snippet rewritten" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"

  local today; today=$(date +%Y-%m-%d)
  local project="$TMP/proj"
  mkdir -p "$project/docs"
  cat > "$project/docs/found-issues.md" <<EOF
# found-issues
- [open] $today src/a.py:1 — bug
- [open] $today src/b.py:1 — bug
EOF

  # Statusline starts with the legacy handwritten snippet (broken).
  cat > "$HOME/.claude/statusline.sh" <<'SL'
#!/usr/bin/env bash
set -euo pipefail
input=$(cat)
LINE1="repo"
LINE1="$LINE1 | branch"
# found-issues plugin segment (|| true guards against set -e when CLI isn't on PATH)
FI_SEG=$(found-issues status --format=segment 2>/dev/null || true)
[[ -n "$FI_SEG" ]] && LINE1="$LINE1 | $FI_SEG"
echo "$LINE1"
SL

  # Pre-migration: counter is empty (this is the bug).
  local fi_bin_dir
  fi_bin_dir=$(dirname "$FI_BIN")
  local pre
  pre=$(echo "{\"workspace\":{\"current_dir\":\"$project\"}}" | \
        env PATH="$fi_bin_dir:$PATH" bash "$HOME/.claude/statusline.sh")
  [[ "$pre" != *"2 issues"* ]]

  # Migrate.
  fi_run install-statusline --migrate
  [ "$status" -eq 0 ]

  # Post-migration: counter renders.
  local post
  post=$(echo "{\"workspace\":{\"current_dir\":\"$project\"}}" | \
         env PATH="$fi_bin_dir:$PATH" bash "$HOME/.claude/statusline.sh")
  [[ "$post" == *"2 issues"* ]]
}
