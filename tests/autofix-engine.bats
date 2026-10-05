#!/usr/bin/env bats
# v3 auto-fix engine layer: argv pinning, watchdog, parsing (spec §4.5, §5, §9).

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_fixture; fi_use_standins
  source "$FI_BIN"; fi_af_context
  AFI_id=t1 AFI_wt="$REPO" AFI_root="$REPO"
}
teardown() { fi_teardown_tmp; }

@test "autofix engine: claude fixer argv - dontAsk, no prompts, allowlist, prompt last" {
  fi_af_allowlist 'sh test.sh'
  fi_af_fixer_cmd claude "THE PROMPT" "$TMP/last"
  printf '%s\n' "${FI_AF_CMD[@]}" > "$TMP/argv"
  [ "${FI_AF_CMD[0]}" = claude ]
  [ "${FI_AF_CMD[${#FI_AF_CMD[@]}-1]}" = "THE PROMPT" ]
  [ "${FI_AF_CMD[${#FI_AF_CMD[@]}-3]}" = "--output-format" ]
  [ "${FI_AF_CMD[${#FI_AF_CMD[@]}-2]}" = "json" ]
  grep -qx -- '-p' "$TMP/argv"
  grep -qx 'dontAsk' "$TMP/argv"
  grep -qx -- '--permission-prompts' "$TMP/argv"
  grep -qx 'none' "$TMP/argv"
  grep -qx 'sonnet' "$TMP/argv"
  grep -qx -- '--max-budget-usd' "$TMP/argv"
  grep -qx -- '--max-turns' "$TMP/argv"
  grep -qx 'Bash(sh test.sh)' "$TMP/argv"
  grep -qx 'Bash(sh test.sh \*)' "$TMP/argv"
  ! grep -q 'Bash(git' "$TMP/argv" || false
  ! grep -qx 'bypassPermissions' "$TMP/argv" || false
}

@test "autofix engine: bats and pytest runners may be called with a single file" {
  fi_af_allowlist 'bats tests/'
  printf '%s\n' "${FI_AF_TOOLS[@]}" | grep -qx 'Bash(bats \*)'
  fi_af_allowlist 'npm test'
  ! printf '%s\n' "${FI_AF_TOOLS[@]}" | grep -qx 'Bash(npm \*)' || false
}

@test "autofix engine: the fixer allowlist adds the item's search, and nothing without an id" {
  fi_af_allowlist 'sh test.sh' t1
  printf '%s\n' "${FI_AF_TOOLS[@]}" | grep -qx 'Bash(found-issues autofix search t1 \*)'
  fi_af_allowlist 'sh test.sh'
  ! printf '%s\n' "${FI_AF_TOOLS[@]}" | grep -q 'autofix search' || false
}

@test "autofix engine: a child finds this CLI's found-issues first on PATH" {
  [ -n "$FI_BIN_DIR" ]
  run fi_af_child "$TMP/o" "$TMP/e" "$TMP" bash -c 'printf %s "$PATH"'
  [ "$status" -eq 0 ]
  [[ "$(cat "$TMP/o")" == "$FI_BIN_DIR:"* ]]
}

@test "autofix engine: claude verifier argv - opus, high effort, read-only tools" {
  fi_af_verifier_cmd claude "V" "$TMP/last" "$TMP/schema"
  printf '%s\n' "${FI_AF_CMD[@]}" > "$TMP/argv"
  grep -qx 'opus' "$TMP/argv"
  grep -qx 'high' "$TMP/argv"
  grep -qx 'Read' "$TMP/argv" && grep -qx 'Grep' "$TMP/argv" && grep -qx 'Glob' "$TMP/argv"
  ! grep -qx 'Edit' "$TMP/argv" || false
  [ "$(grep -c '^Bash' "$TMP/argv")" -eq 1 ]
  grep -qx 'Bash(found-issues autofix search t1 \*)' "$TMP/argv"
  [ "${FI_AF_CMD[${#FI_AF_CMD[@]}-1]}" = "V" ]
}

@test "autofix engine: codex argv - workspace-write fixer, read-only verifier" {
  fi_af_fixer_cmd codex "P" "$TMP/last"
  [ "${FI_AF_CMD[0]}" = codex ] && [ "${FI_AF_CMD[1]}" = exec ]
  printf '%s\n' "${FI_AF_CMD[@]}" | grep -qx 'workspace-write'
  printf '%s\n' "${FI_AF_CMD[@]}" | grep -qx -- '--ephemeral'
  fi_af_verifier_cmd codex "V" "$TMP/last" "$TMP/schema"
  printf '%s\n' "${FI_AF_CMD[@]}" | grep -qx 'read-only'
  printf '%s\n' "${FI_AF_CMD[@]}" | grep -qx 'model_reasoning_effort=high'
  printf '%s\n' "${FI_AF_CMD[@]}" | grep -qx -- '--output-schema'
}

@test "autofix engine: the child runs in cwd with the recursion-guard env" {
  run fi_af_child "$TMP/o" "$TMP/e" "$TMP" sh -c 'pwd; echo "child=$FOUND_ISSUES_AUTOFIX_CHILD"'
  [ "$status" -eq 0 ]
  grep -q "child=1" "$TMP/o"
  [ "$(head -1 "$TMP/o")" = "$(cd "$TMP" && pwd)" ]
}

@test "autofix engine: children do not inherit the launcher A run pid" {
  export FI_AF_PID=4242
  run fi_af_child "$TMP/o" "$TMP/e" "$TMP" sh -c 'echo "pid=[${FI_AF_PID:-}]"'
  [ "$status" -eq 0 ]
  grep -q 'pid=\[\]' "$TMP/o"
}

@test "autofix engine: the watchdog kills a hung child with 124" {
  FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS=1 run fi_af_child "$TMP/o" "$TMP/e" "$TMP" sleep 30
  [ "$status" -eq 124 ]
}

@test "autofix engine: result line - last FI-RESULT wins, markdown tolerated" {
  fi_af_parse_result $'thinking\nFI-RESULT: fixed\nmore\n**FI-RESULT: decide plus or table?**'
  [ "$FI_AF_RESULT" = decide ]
  [ "$FI_AF_RESULT_TEXT" = "plus or table?" ]
  fi_af_parse_result 'no marker here'
  [ "$FI_AF_RESULT" = none ]
  fi_af_parse_result $'`FI-RESULT: already-fixed uses + since abc123`'
  [ "$FI_AF_RESULT" = already-fixed ]
  [ "$FI_AF_RESULT_TEXT" = "uses + since abc123" ]
}

@test "autofix engine: verdict - fenced JSON, prose around it, garbage rejects" {
  fi_af_parse_verdict $'Here:\n```json\n{"approve": true, "reason": "fixes it"}\n```'
  [ "$FI_AF_APPROVE" = true ] && [ "$FI_AF_REASON" = "fixes it" ]
  fi_af_parse_verdict '{"approve":false,"reason":"also edits README"}'
  [ "$FI_AF_APPROVE" = false ] && [ "$FI_AF_REASON" = "also edits README" ]
  fi_af_parse_verdict 'I approve!'
  [ "$FI_AF_APPROVE" = false ]
  fi_af_parse_verdict '{"approve":"yes"}'
  [ "$FI_AF_APPROVE" = false ]
}

@test "autofix engine: cost from claude json, tokens from codex jsonl" {
  FI_AF_COST=0 FI_AF_TOKENS=0
  FI_STANDIN_COST=0.4 claude -p x --output-format json > "$TMP/c.json"
  fi_af_collect claude "$TMP/c.json" ""
  [ "$FI_AF_COST" = "0.4000" ]
  [[ "$FI_AF_TEXT" == *"FI-RESULT: fixed"* ]]
  codex exec -o "$TMP/last" "x" > "$TMP/x.jsonl"
  fi_af_collect codex "$TMP/x.jsonl" "$TMP/last"
  [ "$FI_AF_TOKENS" = 1500 ]
  [[ "$FI_AF_TEXT" == *"FI-RESULT: fixed"* ]]
}

@test "autofix engine: budget left shrinks with spend and runs out" {
  git config found-issues.autofix.runBudget 1
  FI_AF_COST=0.25
  [ "$(fi_af_budget_left)" = "0.75" ]
  FI_AF_COST=0.95
  run fi_af_budget_left
  [ "$status" -eq 1 ]
}

@test "autofix engine: the fixer prompt names the branch rule, the test command and the result contract" {
  AFI_branch=fi/autofix/x-1 AFI_entry='- [open] 2026-10-01 src/calc.sh:1 — add subtracts (fix: small)'
  p="$(fi_af_fixer_prompt 'sh test.sh' 'tests fail: expected 5')"
  [[ "$p" == *"fi/autofix/x-1"* ]]
  [[ "$p" == *"sh test.sh"* ]]
  [[ "$p" == *"add subtracts"* ]]
  [[ "$p" == *"FI-RESULT: fixed"* ]]
  [[ "$p" == *"tests fail: expected 5"* ]]
  [[ "$p" == *"Do not edit docs/found-issues.md"* ]]
}

@test "autofix engine: the claude prompt says to run the test command alone and to search with autofix search" {
  AFI_branch=b AFI_entry=e
  p="$(fi_af_fixer_prompt 'sh test.sh' '' claude)"
  [[ "$p" == *"exactly as: sh test.sh"* ]]
  [[ "$p" == *'no cd, ;, &&, |, redirection or echo $?'* ]]
  [[ "$p" == *"Read, Edit and Write tools"* ]]
  [[ "$p" == *"found-issues autofix search t1 '<regex>'"* ]]
  [[ "$p" == *"found-issues autofix search t1 --files"* ]]
  [[ "$p" != *"Grep"* ]]
}

@test "autofix engine: the codex prompt allows reading but never git or gh" {
  AFI_branch=b AFI_entry=e
  p="$(fi_af_fixer_prompt 'sh test.sh' '' codex)"
  [[ "$p" == *"read-only shell commands"* ]]
  [[ "$p" == *"Never run git or gh"* ]]
  [[ "$p" != *"autofix search"* ]]
}

@test "autofix engine: the watchdog kills the whole process group, not just the child" {
  FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS=1 run fi_af_child "$TMP/o" "$TMP/e" "$TMP" bash -c 'sleep 4711; :'
  [ "$status" -eq 124 ]
  sleep 1
  ! pgrep -f 'sleep 4711' >/dev/null || false
}

@test "autofix engine: two verdict objects are ambiguous and never approve" {
  fi_af_parse_verdict $'{"approve":true,"reason":"a"}\n{"approve":false,"reason":"b"}'
  [ "$FI_AF_APPROVE" = false ]
}

@test "autofix engine: an engine error is reported, not mistaken for a result" {
  FI_AF_COST=0 FI_AF_TOKENS=0
  FI_STANDIN_ERROR="You've hit your usage limit" claude -p x --output-format json > "$TMP/c.json" || true
  fi_af_collect claude "$TMP/c.json" ""
  [ "$FI_AF_ENGINE_ERR" = "You've hit your usage limit" ]
}
