#!/usr/bin/env bats
# Codex wiring (2026-10-03): found-issues was installed in Codex but no hook
# ever fired there — install-codex-hooks had never run, nothing noticed, the
# Stop nudge did not exist on Codex, and ledger edits arrive as apply_patch,
# which the format enforcer did not read. Stop payload/output shapes are the
# stop.command.input / stop.command.output JSON Schemas shipped in the Codex
# 0.159 binary (last_assistant_message, stop_hook_active, turn_id; output
# {"decision":"block","reason":...}).

load 'helpers'

STOP="$TEST_REPO_ROOT/hooks/stop-reminder.sh"
FE="$TEST_REPO_ROOT/hooks/format-enforcer.sh"

setup() {
  fi_setup_tmp
  export HOME="$TMP/home"
  mkdir -p "$HOME"
}
teardown() { fi_teardown_tmp; }

# A Codex rollout whose current turn ($1 = yes/no) made a tool call.
rollout() {
  local used_tool="$1" f="$TMP/rollout.jsonl"
  {
    printf '%s\n' '{"type":"session_meta","payload":{"id":"s1"}}'
    printf '%s\n' '{"type":"event_msg","payload":{"type":"task_started","turn_id":"t0"}}'
    printf '%s\n' '{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"x"}}'
    printf '%s\n' '{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t0"}}'
    printf '%s\n' '{"type":"event_msg","payload":{"type":"task_started","turn_id":"t1"}}'
    if [[ "$used_tool" == yes ]]; then
      printf '%s\n' '{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"apply_patch"}}'
    fi
    printf '%s\n' '{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}'
  } > "$f"
  printf '%s' "$f"
}

# Codex Stop payload: $1 last_assistant_message, $2 transcript path ("" = null),
# $3 stop_hook_active, $4 session id.
stop_payload() {
  jq -cn --arg m "$1" --arg t "$2" --argjson a "${3:-false}" --arg s "${4:-sess1}" \
    '{cwd:"/x",hook_event_name:"Stop",last_assistant_message:$m,model:"gpt",permission_mode:"default",
      session_id:$s,stop_hook_active:$a,transcript_path:(if $t == "" then null else $t end),turn_id:"t1"}'
}

codex_stop() {
  printf '%s' "$1" > "$TMP/stop.json"
  run env FOUND_ISSUES_HARNESS=codex bash -c "'$STOP' < '$TMP/stop.json'"
}

@test "codex stop: a tool-using turn without the marker is blocked once, via JSON" {
  codex_stop "$(stop_payload "Done, I changed the parser." "$(rollout yes)")"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.decision == "block"'
  printf '%s' "$output" | jq -e '.reason | contains("<!-- found-issues-checked: none-noticed")'
  # second Stop in the same session passes
  codex_stop "$(stop_payload "Done again." "$(rollout yes)")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "codex stop: the marker in last_assistant_message passes" {
  codex_stop "$(stop_payload "Done. <!-- found-issues-checked: none-noticed -->" "$(rollout yes)")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "codex stop: a turn with no tool call passes" {
  codex_stop "$(stop_payload "The answer is 4." "$(rollout no)")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "codex stop: stop_hook_active passes" {
  codex_stop "$(stop_payload "Done." "$(rollout yes)" true)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "codex stop: an unreadable rollout counts as a tool-using turn" {
  codex_stop "$(stop_payload "Done." "")"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.decision == "block"'
}

@test "codex stop: FOUND_ISSUES_STOP_REMINDER=off passes" {
  printf '%s' "$(stop_payload "Done." "$(rollout yes)")" > "$TMP/stop.json"
  run env FOUND_ISSUES_HARNESS=codex FOUND_ISSUES_STOP_REMINDER=off bash -c "'$STOP' < '$TMP/stop.json'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- install-codex-hooks registers Stop and apply_patch ---

@test "install-codex-hooks: registers the Stop nudge and matches apply_patch edits" {
  CODEX_HOME="$TMP/codex-home"
  fi_run install-codex-hooks --codex-home "$CODEX_HOME"
  [ "$status" -eq 0 ]
  jq -e '.hooks.Stop | length == 1' "$CODEX_HOME/hooks.json"
  jq -e '.hooks.Stop[0].hooks[0].command | test("env FOUND_ISSUES_HARNESS=codex .*/hooks/stop-reminder\\.sh")' "$CODEX_HOME/hooks.json"
  jq -e '.hooks.PreToolUse[0].matcher | split("|") | index("apply_patch") != null' "$CODEX_HOME/hooks.json"
}

@test "install-codex-hooks: appends after foreign entries so their trust indices do not move" {
  CODEX_HOME="$TMP/codex-home"
  mkdir -p "$CODEX_HOME"
  printf '%s' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"orca"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"guard"}]}]}}' \
    > "$CODEX_HOME/hooks.json"
  fi_run install-codex-hooks --codex-home "$CODEX_HOME"
  [ "$status" -eq 0 ]
  jq -e '.hooks.Stop[0].hooks[0].command == "orca"' "$CODEX_HOME/hooks.json"
  jq -e '.hooks.PreToolUse[0].hooks[0].command == "guard"' "$CODEX_HOME/hooks.json"
}

# --- format-enforcer reads apply_patch envelopes ---

fe_patch() {
  jq -cn --arg c "$1" '{tool_name:"apply_patch",tool_input:{command:$c}}' > "$TMP/p.json"
  run env FOUND_ISSUES_HARNESS=codex FOUND_ISSUES_MODE=github-direct bash -c "cd '$TMP' && '$FE' < '$TMP/p.json'"
}

@test "fe apply_patch: a token-less [open] to [fixed] flip in the ledger is blocked" {
  fe_patch $'*** Begin Patch\n*** Update File: docs/found-issues.md\n@@\n-- [open] 2026-09-01 lib/x.sh:4 — real bug\n+- [fixed] 2026-09-01 lib/x.sh:4 — real bug\n*** End Patch'
  [ "$status" -eq 2 ]
  [[ "$output" == *"verification token"* ]]
}

@test "fe apply_patch: the same lines in another file pass" {
  fe_patch $'*** Begin Patch\n*** Update File: notes/other.md\n@@\n+- [fixed] 2026-09-01 lib/x.sh:4 — real bug\n*** End Patch'
  [ "$status" -eq 0 ]
}

@test "fe apply_patch: a well-formed added ledger entry passes" {
  fe_patch $'*** Begin Patch\n*** Update File: docs/found-issues.md\n@@\n+- [open] 2026-09-01 lib/x.sh:4 — real bug\n*** End Patch'
  [ "$status" -eq 0 ]
}

# --- doctor and SessionStart notice the missing wiring ---

seed_codex_plugin() {
  CODEX_HOME="$TMP/codex-home"
  mkdir -p "$CODEX_HOME/plugins/cache/altdoug-plugins/found-issues/2.8.0"
  printf '[plugins."found-issues@altdoug-plugins"]\nenabled = true\n' > "$CODEX_HOME/config.toml"
  printf '%s' '{"hooks":{}}' > "$CODEX_HOME/hooks.json"
  export FOUND_ISSUES_CODEX_HOME="$CODEX_HOME"
}

@test "doctor: flags a Codex install whose hooks were never wired" {
  seed_codex_plugin
  fi_run doctor
  [[ "$output" == *"Codex"* ]]
  [[ "$output" == *"install-codex-hooks"* ]]
}

@test "doctor: flags wired Codex hooks that Codex has not trusted yet" {
  seed_codex_plugin
  fi_run install-codex-hooks --codex-home "$CODEX_HOME"
  fi_run doctor
  [[ "$output" == *"/hooks"* ]]
  [[ "$output" != *"never wired"* ]]
}

@test "doctor: wired and trusted Codex hooks pass" {
  seed_codex_plugin
  fi_run install-codex-hooks --codex-home "$CODEX_HOME"
  jq -r --arg f "$CODEX_HOME/hooks.json" '
    .hooks | to_entries[] | .key as $ev | .value | to_entries[] | .key as $g
    | .value.hooks | to_entries[]
    | select(.value.command | startswith("env FOUND_ISSUES_HARNESS=codex "))
    | "[hooks.state.\"\($f):\($ev | gsub("(?<a>[a-z])(?<b>[A-Z])"; "\(.a)_\(.b)") | ascii_downcase):\($g):\(.key)\"]\ntrusted_hash = \"sha256:x\"\n"' \
    "$CODEX_HOME/hooks.json" >> "$CODEX_HOME/config.toml"
  fi_run doctor
  [[ "$output" == *"Codex hooks: wired and trusted"* ]]
}

@test "session-start (claude): once a day, says the Codex install has no hooks" {
  seed_codex_plugin
  mkdir -p repo && cd repo && fi_init_git
  run env CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_ROOT="$TEST_REPO_ROOT" bash "$TEST_REPO_ROOT/hooks/session-start.sh" </dev/null
  [[ "$output" == *"install-codex-hooks"* ]]
  run env CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_ROOT="$TEST_REPO_ROOT" bash "$TEST_REPO_ROOT/hooks/session-start.sh" </dev/null
  [[ "$output" != *"install-codex-hooks"* ]]
}

# A 3.3.x install: every hook wired through the stable shims except first-touch.
seed_pre_first_touch() {
  seed_codex_plugin
  fi_run install-codex-hooks --codex-home "$CODEX_HOME"
  jq 'del(.hooks.PostToolUse[] | select(.matcher == "apply_patch"))' "$CODEX_HOME/hooks.json" > "$CODEX_HOME/h.tmp"
  mv "$CODEX_HOME/h.tmp" "$CODEX_HOME/hooks.json"
}

@test "doctor: reports Codex hooks without the first-touch entry as incomplete, with the fix" {
  seed_pre_first_touch
  fi_run doctor
  [[ "$output" == *"partly wired"* ]]
  [[ "$output" == *"install-codex-hooks"* ]]
  [[ "$output" == *"/hooks"* ]]
  [[ "$output" != *"never wired"* ]]
}

@test "doctor: re-running install-codex-hooks clears the incomplete report" {
  seed_pre_first_touch
  fi_run install-codex-hooks --codex-home "$CODEX_HOME"
  fi_run doctor
  [[ "$output" != *"partly wired"* ]]
}

@test "wiring state: incomplete when first-touch is missing, untrusted once it is back" {
  seed_pre_first_touch
  run bash -c ". '$TEST_REPO_ROOT/lib/codex-hooks.sh'; fi_codex_wiring_state '$CODEX_HOME'"
  [ "$output" = "incomplete" ]
  fi_run install-codex-hooks --codex-home "$CODEX_HOME"
  run bash -c ". '$TEST_REPO_ROOT/lib/codex-hooks.sh'; fi_codex_wiring_state '$CODEX_HOME'"
  [ "$output" = "untrusted" ]
}

@test "session-start (claude): once a day, says the Codex hooks are incomplete" {
  seed_pre_first_touch
  mkdir -p repo && cd repo && fi_init_git
  run env CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_ROOT="$TEST_REPO_ROOT" bash "$TEST_REPO_ROOT/hooks/session-start.sh" </dev/null
  [[ "$output" == *"incomplete in Codex"* ]]
  [[ "$output" == *"install-codex-hooks"* ]]
  [[ "$output" != *"inactive in Codex"* ]]
  run env CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_ROOT="$TEST_REPO_ROOT" bash "$TEST_REPO_ROOT/hooks/session-start.sh" </dev/null
  [[ "$output" != *"incomplete in Codex"* ]]
}

@test "session-start (claude): fully wired Codex hooks print no Codex notice" {
  seed_codex_plugin
  fi_run install-codex-hooks --codex-home "$CODEX_HOME"
  mkdir -p repo && cd repo && fi_init_git
  run env CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_ROOT="$TEST_REPO_ROOT" bash "$TEST_REPO_ROOT/hooks/session-start.sh" </dev/null
  [[ "$output" != *"in Codex"* ]]
}

@test "codex stop: an empty session_id does not swallow the transcript path" {
  codex_stop "$(stop_payload "The answer is 4." "$(rollout no)" false "")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
