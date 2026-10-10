#!/usr/bin/env bats
# Statusline fix batch 2: runtime probe must require the segment, the probe's
# statusline path parsing must handle quotes / $HOME / ~, and the append
# install must land before a trailing exit/exec.

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
  mkdir -p tmp/.claude
  # Fake $HOME so the append tests never touch the real ~/.claude/statusline.sh
  export HOME="$TMP/home"
  mkdir -p "$HOME/.claude"
  # The installed statusline block resolves found-issues from PATH; CI has
  # none, and the probe now requires the segment itself to render.
  export PATH="${TEST_REPO_ROOT}/bin:$PATH"
}

teardown() {
  fi_teardown_tmp
}

# --- entry 1: probe requires the found-issues segment ---

_hello_statusline() {
  cat > tmp/hello.sh <<'SH'
#!/usr/bin/env bash
cat >/dev/null
echo "hello"
SH
  cat > tmp/.claude/settings.json <<EOF
{"statusLine": {"command": "bash $(pwd)/tmp/hello.sh"}}
EOF
}

@test "probe: statusline printing only hello FAILS when the ledger has open entries" {
  printf -- '- [open] 2026-05-13 a.ts:1 - entry\n' > .found-issues.md
  _hello_statusline
  HOME="$(pwd)/tmp" fi_run doctor-statusline-runtime
  echo "$output" | grep -q "did NOT render"
  ! echo "$output" | grep -q "Segment rendered" || false
}

@test "probe: statusline printing only hello reports a clean ledger when nothing is expected" {
  : > .found-issues.md
  _hello_statusline
  HOME="$(pwd)/tmp" fi_run doctor-statusline-runtime
  echo "$output" | grep -qi "ledger is clean"
  ! echo "$output" | grep -q "did NOT render" || false
}

@test "probe: a statusline that strips the segment's colors still counts as rendered" {
  printf -- '- [open] 2026-05-13 a.ts:1 - entry\n' > .found-issues.md
  export FI_TEST_BIN="$FI_BIN" FI_TEST_CWD="$(pwd)"
  cat > tmp/plain.sh <<'SH'
#!/usr/bin/env bash
cat >/dev/null
seg="$("$FI_TEST_BIN" status --format=segment --cwd "$FI_TEST_CWD" | LC_ALL=C sed $'s/\x1b\\[[0-9;]*m//g')"
printf 'model x %s\n' "$seg"
SH
  cat > tmp/.claude/settings.json <<EOF
{"statusLine": {"command": "bash $(pwd)/tmp/plain.sh"}}
EOF
  HOME="$(pwd)/tmp" fi_run doctor-statusline-runtime
  echo "$output" | grep -q "Segment rendered" || { echo "$output"; false; }
  ! echo "$output" | grep -q "did NOT render" || false
}

@test "doctor: a package-runner statusline command gets no path-not-a-file warning" {
  : > .found-issues.md
  cat > tmp/.claude/settings.json <<'EOF'
{"statusLine": {"command": "npx -y ccstatusline@latest"}}
EOF
  HOME="$(pwd)/tmp" fi_run doctor
  ! echo "$output" | grep -q "is not a file" || false
  HOME="$(pwd)/tmp" fi_run doctor-statusline-runtime
  ! echo "$output" | grep -q "is not a file" || false
}

# --- entry 2: statusline path parsing ---

_segment_statusline() {
  # $1 = path of the script to create
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'SH'
#!/usr/bin/env bash
input="$(cat)"
dir="$(echo "$input" | jq -r '.workspace.current_dir // ""')"
echo "SLMARK | $dir"
SH
  fi_run install-statusline --target "$1" --apply
  [ "$status" -eq 0 ]
}

@test "probe: quoted HOME statusline path is the probe target" {
  printf -- '- [open] 2026-05-13 a.ts:1 - entry\n' > .found-issues.md
  _segment_statusline tmp/x/sl.sh
  printf '%s\n' '{"statusLine": {"command": "bash \"$HOME/x/sl.sh\""}}' > tmp/.claude/settings.json
  HOME="$(pwd)/tmp" fi_run doctor-statusline-runtime
  echo "$output" | grep -q "Segment rendered: SLMARK"
}

@test "probe: braced HOME and tilde statusline paths are expanded" {
  printf -- '- [open] 2026-05-13 a.ts:1 - entry\n' > .found-issues.md
  _segment_statusline tmp/x/sl.sh
  printf '%s\n' '{"statusLine": {"command": "bash ${HOME}/x/sl.sh"}}' > tmp/.claude/settings.json
  HOME="$(pwd)/tmp" fi_run doctor-statusline-runtime
  echo "$output" | grep -q "Segment rendered: SLMARK"
  printf '%s\n' '{"statusLine": {"command": "bash ~/x/sl.sh"}}' > tmp/.claude/settings.json
  HOME="$(pwd)/tmp" fi_run doctor-statusline-runtime
  echo "$output" | grep -q "Segment rendered: SLMARK"
}

@test "probe: quoted path containing a space is the probe target" {
  printf -- '- [open] 2026-05-13 a.ts:1 - entry\n' > .found-issues.md
  _segment_statusline "tmp/my dir/sl.sh"
  printf '%s\n' '{"statusLine": {"command": "bash \"$HOME/my dir/sl.sh\""}}' > tmp/.claude/settings.json
  HOME="$(pwd)/tmp" fi_run doctor-statusline-runtime
  echo "$output" | grep -q "Segment rendered: SLMARK"
}

@test "probe: configured path that is not a file warns naming it" {
  printf -- '- [open] 2026-05-13 a.ts:1 - entry\n' > .found-issues.md
  printf '%s\n' '{"statusLine": {"command": "bash \"$HOME/missing/sl.sh\""}}' > tmp/.claude/settings.json
  HOME="$(pwd)/tmp" fi_run doctor-statusline-runtime
  echo "$output" | grep -q "$(pwd)/tmp/missing/sl.sh"
  echo "$output" | grep -qi "not a file"
}

@test "doctor: quoted HOME statusline path resolves as the target" {
  printf -- '- [open] 2026-05-13 a.ts:1 - entry\n' > .found-issues.md
  _segment_statusline tmp/x/sl.sh
  printf '%s\n' '{"statusLine": {"command": "bash \"$HOME/x/sl.sh\""}}' > tmp/.claude/settings.json
  HOME="$(pwd)/tmp" fi_run doctor
  echo "$output" | grep -q "Resolved target: $(pwd)/tmp/x/sl.sh"
}

@test "doctor: configured statusline path that is not a file warns naming it" {
  printf '%s\n' '{"statusLine": {"command": "bash \"$HOME/missing/sl.sh\""}}' > tmp/.claude/settings.json
  HOME="$(pwd)/tmp" fi_run doctor
  echo "$output" | grep -q "$(pwd)/tmp/missing/sl.sh"
  echo "$output" | grep -qi "not a file"
}

# --- entry 3: append lands before a trailing exit / exec ---

_stub_found_issues() {
  mkdir -p tmp/stubbin
  cat > tmp/stubbin/found-issues <<'SH'
#!/usr/bin/env bash
echo "STUBSEG"
SH
  chmod +x tmp/stubbin/found-issues
}

@test "install-statusline append: block lands before a trailing exit 0 and renders" {
  _stub_found_issues
  cat > "$HOME/.claude/statusline.sh" <<'SH'
#!/usr/bin/env bash
input="$(cat)"
echo "base line"
# trailing comment

exit 0
SH
  fi_run install-statusline
  [ "$status" -eq 0 ]
  [[ "$output" == *"appended standalone segment"* ]]
  # exit stays the last command, block sits above it
  [ "$(grep -v '^[[:space:]]*$' "$HOME/.claude/statusline.sh" | tail -1)" = "exit 0" ]
  block_line="$(grep -n 'found-issues plugin segment' "$HOME/.claude/statusline.sh" | head -1 | cut -d: -f1)"
  exit_line="$(grep -n '^exit 0$' "$HOME/.claude/statusline.sh" | tail -1 | cut -d: -f1)"
  [ "$block_line" -lt "$exit_line" ]
  run env PATH="$(pwd)/tmp/stubbin:$PATH" bash "$HOME/.claude/statusline.sh" <<<'{"workspace":{"current_dir":"/tmp"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"base line"* ]]
  [[ "$output" == *"STUBSEG"* ]]
}

@test "install-statusline append: block lands before a trailing exec" {
  _stub_found_issues
  cat > "$HOME/.claude/statusline.sh" <<'SH'
#!/usr/bin/env bash
input="$(cat)"
echo "base line"
exec true
SH
  fi_run install-statusline
  [ "$status" -eq 0 ]
  [ "$(grep -v '^[[:space:]]*$' "$HOME/.claude/statusline.sh" | tail -1)" = "exec true" ]
  run env PATH="$(pwd)/tmp/stubbin:$PATH" bash "$HOME/.claude/statusline.sh" <<<'{"workspace":{"current_dir":"/tmp"}}'
  [[ "$output" == *"STUBSEG"* ]]
}

@test "install-statusline append: script without a trailing exit still appends at EOF" {
  _stub_found_issues
  cat > "$HOME/.claude/statusline.sh" <<'SH'
#!/usr/bin/env bash
input="$(cat)"
echo "base line"
if true; then
  exit 0
fi
SH
  cp "$HOME/.claude/statusline.sh" tmp/sl.orig
  fi_run install-statusline
  [ "$status" -eq 0 ]
  # original content preserved byte-for-byte as the file's prefix
  head -c "$(wc -c < tmp/sl.orig | tr -d ' ')" "$HOME/.claude/statusline.sh" | cmp - tmp/sl.orig
  tail -1 "$HOME/.claude/statusline.sh" | grep -q 'end found-issues plugin segment'
}
