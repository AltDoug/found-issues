#!/usr/bin/env bats
# tests/cli-codex-hooks.bats — install-codex-hooks / uninstall-codex-hooks
#
# Codex CLI 0.144.5 removed plugin_hooks (ledger: .codex-plugin/plugin.json:14),
# so found-issues hooks must be installed into Codex's stable user-level
# $CODEX_HOME/hooks.json instead. These tests exercise the merge/strip
# logic in bin/found-issues directly (no real Codex binary required).

load 'helpers'

setup() { fi_setup_tmp; }
teardown() { fi_teardown_tmp; }

@test "install-codex-hooks: creates hooks.json with our 4 entries across 3 events" {
  CODEX_HOME="$TMP/codex-home"
  fi_run install-codex-hooks --codex-home "$CODEX_HOME"
  [ "$status" -eq 0 ]
  [ -f "$CODEX_HOME/hooks.json" ]

  jq -e '.hooks.SessionStart | length == 1' "$CODEX_HOME/hooks.json"
  jq -e '.hooks.PreToolUse | length == 2' "$CODEX_HOME/hooks.json"
  jq -e '.hooks.PostToolUse | length == 1' "$CODEX_HOME/hooks.json"
  jq -e '.hooks.Stop == null' "$CODEX_HOME/hooks.json"

  jq -e '.hooks.PreToolUse[0].matcher == "Write|Edit|MultiEdit"' "$CODEX_HOME/hooks.json"
  jq -e '.hooks.PreToolUse[1].matcher == "Bash"' "$CODEX_HOME/hooks.json"
  jq -e '.hooks.PostToolUse[0].matcher == "Bash"' "$CODEX_HOME/hooks.json"

  jq -e '.hooks.SessionStart[0].hooks[0].command | contains("env FOUND_ISSUES_HARNESS=codex ")' "$CODEX_HOME/hooks.json"
  jq -e '.hooks.SessionStart[0].hooks[0].command | contains("/hooks/session-start.sh")' "$CODEX_HOME/hooks.json"
  jq -e '.hooks.PreToolUse[0].hooks[0].command | contains("/hooks/format-enforcer.sh")' "$CODEX_HOME/hooks.json"
  jq -e '.hooks.PreToolUse[1].hooks[0].command | contains("/hooks/pre-branch-delete.sh")' "$CODEX_HOME/hooks.json"
  jq -e '.hooks.PostToolUse[0].hooks[0].command | contains("/hooks/post-bash-dispatch.sh")' "$CODEX_HOME/hooks.json"

  # Quote-safety (found-issues.md:4368 fix): the script path is
  # single-quoted, e.g. `env FOUND_ISSUES_HARNESS=codex '<ABS>/hooks/session-start.sh'`
  # — not the bare unquoted form.
  jq -e '.hooks.SessionStart[0].hooks[0].command | test("env FOUND_ISSUES_HARNESS=codex '\''.*/hooks/session-start\\.sh'\''$")' "$CODEX_HOME/hooks.json"
  jq -e '.hooks.PreToolUse[0].hooks[0].command | test("env FOUND_ISSUES_HARNESS=codex '\''.*/hooks/format-enforcer\\.sh'\''$")' "$CODEX_HOME/hooks.json"
  jq -e '.hooks.PreToolUse[1].hooks[0].command | test("env FOUND_ISSUES_HARNESS=codex '\''.*/hooks/pre-branch-delete\\.sh'\''$")' "$CODEX_HOME/hooks.json"
  jq -e '.hooks.PostToolUse[0].hooks[0].command | test("env FOUND_ISSUES_HARNESS=codex '\''.*/hooks/post-bash-dispatch\\.sh'\''$")' "$CODEX_HOME/hooks.json"

  # Absolute path — the quoted script path starts with '/ (open quote, then /).
  run jq -r '.hooks.SessionStart[0].hooks[0].command | capture("codex (?<p>'\''.*'\'')$").p' "$CODEX_HOME/hooks.json"
  [ "$status" -eq 0 ]
  [[ "$output" == "'"/* ]]
}

@test "install-codex-hooks: generated commands are space-safe (checkout copied under a path with a space)" {
  CODEX_HOME="$TMP/codex-home"
  copy_root="$TMP/with space/root"
  mkdir -p "$copy_root"
  cp -R "$TEST_REPO_ROOT/bin" "$TEST_REPO_ROOT/lib" "$TEST_REPO_ROOT/hooks" "$copy_root/"
  chmod +x "$copy_root/bin/found-issues"

  run "$copy_root/bin/found-issues" install-codex-hooks --codex-home "$CODEX_HOME"
  [ "$status" -eq 0 ]

  # Quoted form present, and the space-bearing segment sits inside the
  # quotes (not split into a bare unquoted path).
  jq -e '.hooks.SessionStart[0].hooks[0].command | test("'\''.*/with space/root/hooks/session-start\\.sh'\''$")' "$CODEX_HOME/hooks.json"

  # Full e2e: each generated command string round-trips through `bash -c`
  # as one correctly-split invocation. An unquoted space would word-split
  # the path — bash would try to exec the truncated prefix, exit 127
  # "command not found" instead of 0.
  for key in '.hooks.SessionStart[0].hooks[0].command' \
             '.hooks.PreToolUse[0].hooks[0].command' \
             '.hooks.PreToolUse[1].hooks[0].command' \
             '.hooks.PostToolUse[0].hooks[0].command'; do
    cmd="$(jq -r "$key" "$CODEX_HOME/hooks.json")"
    run bash -c "$cmd" < /dev/null
    [ "$status" -eq 0 ]
  done
}

@test "install-codex-hooks: empty hooks.json is seeded then installed (4 entries, exit 0)" {
  CODEX_HOME="$TMP/codex-home"
  mkdir -p "$CODEX_HOME"
  : > "$CODEX_HOME/hooks.json"
  fi_run install-codex-hooks --codex-home "$CODEX_HOME"
  [ "$status" -eq 0 ]
  jq -e '.hooks.SessionStart | length == 1' "$CODEX_HOME/hooks.json"
  jq -e '.hooks.PreToolUse | length == 2' "$CODEX_HOME/hooks.json"
  jq -e '.hooks.PostToolUse | length == 1' "$CODEX_HOME/hooks.json"
}

@test "install-codex-hooks: whitespace-only hooks.json is seeded then installed (4 entries, exit 0)" {
  CODEX_HOME="$TMP/codex-home"
  mkdir -p "$CODEX_HOME"
  printf '   \n  \t \n' > "$CODEX_HOME/hooks.json"
  fi_run install-codex-hooks --codex-home "$CODEX_HOME"
  [ "$status" -eq 0 ]
  jq -e '.hooks.SessionStart | length == 1' "$CODEX_HOME/hooks.json"
  jq -e '.hooks.PreToolUse | length == 2' "$CODEX_HOME/hooks.json"
  jq -e '.hooks.PostToolUse | length == 1' "$CODEX_HOME/hooks.json"
}

@test "install-codex-hooks: corrupt-JSON hooks.json errors rc 5 and leaves the file byte-unchanged" {
  CODEX_HOME="$TMP/codex-home"
  mkdir -p "$CODEX_HOME"
  printf '{not valid json' > "$CODEX_HOME/hooks.json"
  before="$(cat "$CODEX_HOME/hooks.json")"
  fi_run install-codex-hooks --codex-home "$CODEX_HOME"
  [ "$status" -eq 5 ]
  after="$(cat "$CODEX_HOME/hooks.json")"
  [ "$before" = "$after" ]
}

@test "install-codex-hooks + uninstall-codex-hooks: a user hook whose command contains both 'found-issues' and '/hooks/' survives (tightened sentinel ownership)" {
  CODEX_HOME="$TMP/codex-home"
  mkdir -p "$CODEX_HOME"
  cat > "$CODEX_HOME/hooks.json" <<'EOF'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/opt/my-found-issues-fork/hooks/custom.sh"}]}]}}
EOF
  fi_run install-codex-hooks --codex-home "$CODEX_HOME"
  [ "$status" -eq 0 ]
  jq -e '.hooks.SessionStart | length == 2' "$CODEX_HOME/hooks.json"
  jq -e '[.hooks.SessionStart[].hooks[0].command] | index("/opt/my-found-issues-fork/hooks/custom.sh") != null' "$CODEX_HOME/hooks.json"

  fi_run uninstall-codex-hooks --codex-home "$CODEX_HOME"
  [ "$status" -eq 0 ]
  jq -e '.hooks.SessionStart | length == 1' "$CODEX_HOME/hooks.json"
  jq -e '.hooks.SessionStart[0].hooks[0].command == "/opt/my-found-issues-fork/hooks/custom.sh"' "$CODEX_HOME/hooks.json"
}

@test "install-codex-hooks: preserves a pre-existing user hook entry" {
  CODEX_HOME="$TMP/codex-home"
  mkdir -p "$CODEX_HOME"
  cat > "$CODEX_HOME/hooks.json" <<'EOF'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/opt/myorg/hooks/custom.sh"}]}]}}
EOF
  fi_run install-codex-hooks --codex-home "$CODEX_HOME"
  [ "$status" -eq 0 ]
  jq -e '.hooks.SessionStart | length == 2' "$CODEX_HOME/hooks.json"
  jq -e '[.hooks.SessionStart[].hooks[0].command] | index("/opt/myorg/hooks/custom.sh") != null' "$CODEX_HOME/hooks.json"
}

@test "install-codex-hooks: idempotent on double install" {
  CODEX_HOME="$TMP/codex-home"
  fi_run install-codex-hooks --codex-home "$CODEX_HOME"
  [ "$status" -eq 0 ]
  first="$(cat "$CODEX_HOME/hooks.json")"

  fi_run install-codex-hooks --codex-home "$CODEX_HOME"
  [ "$status" -eq 0 ]
  second="$(cat "$CODEX_HOME/hooks.json")"

  [ "$first" = "$second" ]
  jq -e '.hooks.SessionStart | length == 1' "$CODEX_HOME/hooks.json"
  jq -e '.hooks.PreToolUse | length == 2' "$CODEX_HOME/hooks.json"
  jq -e '.hooks.PostToolUse | length == 1' "$CODEX_HOME/hooks.json"
}

@test "install-codex-hooks: replaces stale plugin-cache-path entries on re-install" {
  CODEX_HOME="$TMP/codex-home"
  mkdir -p "$CODEX_HOME"
  cat > "$CODEX_HOME/hooks.json" <<'EOF'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"env FOUND_ISSUES_HARNESS=codex /old/cache/found-issues/1.9.0/hooks/session-start.sh"}]}]}}
EOF
  fi_run install-codex-hooks --codex-home "$CODEX_HOME"
  [ "$status" -eq 0 ]
  # Stale entry replaced, not duplicated: still exactly one SessionStart group.
  jq -e '.hooks.SessionStart | length == 1' "$CODEX_HOME/hooks.json"
  run jq -r '.hooks.SessionStart[0].hooks[0].command' "$CODEX_HOME/hooks.json"
  [[ "$output" != *"/old/cache/"* ]]
  [[ "$output" == *"/hooks/session-start.sh'" ]]
}

@test "uninstall-codex-hooks: removes only our entries" {
  CODEX_HOME="$TMP/codex-home"
  mkdir -p "$CODEX_HOME"
  cat > "$CODEX_HOME/hooks.json" <<'EOF'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/opt/myorg/hooks/custom.sh"}]}]}}
EOF
  fi_run install-codex-hooks --codex-home "$CODEX_HOME"
  [ "$status" -eq 0 ]
  jq -e '.hooks.SessionStart | length == 2' "$CODEX_HOME/hooks.json"

  fi_run uninstall-codex-hooks --codex-home "$CODEX_HOME"
  [ "$status" -eq 0 ]
  jq -e '.hooks.SessionStart | length == 1' "$CODEX_HOME/hooks.json"
  jq -e '.hooks.SessionStart[0].hooks[0].command == "/opt/myorg/hooks/custom.sh"' "$CODEX_HOME/hooks.json"
  jq -e '.hooks.PreToolUse == null' "$CODEX_HOME/hooks.json"
  jq -e '.hooks.PostToolUse == null' "$CODEX_HOME/hooks.json"
}

@test "uninstall-codex-hooks: no-op exit 0 when hooks.json/dir is missing" {
  CODEX_HOME="$TMP/codex-home-never-created"
  fi_run uninstall-codex-hooks --codex-home "$CODEX_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to remove"* ]]
  [ ! -d "$CODEX_HOME" ]
}

@test "install-codex-hooks: errors clearly when jq is absent" {
  CODEX_HOME="$TMP/codex-home"
  shim="$TMP/no-jq-bin"
  mkdir -p "$shim"
  ln -sf "$(command -v dirname)" "$shim/dirname"
  PATH="$shim" run "$BASH" "$FI_BIN" install-codex-hooks --codex-home "$CODEX_HOME"
  [ "$status" -eq 1 ]
  [[ "$output" == *"jq"* ]]
  [ ! -f "$CODEX_HOME/hooks.json" ]
}
