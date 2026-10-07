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
  ! grep -qx -- '--max-budget-usd' "$TMP/argv" || false
  grep -qx -- '--max-turns' "$TMP/argv"
  grep -qx 'Bash(sh test.sh)' "$TMP/argv"
  grep -qx 'Bash(sh test.sh \*)' "$TMP/argv"
  ! grep -q 'Bash(git' "$TMP/argv" || false
  ! grep -qx 'bypassPermissions' "$TMP/argv" || false
}

@test "autofix engine: claude fixer is sandboxed - restricted, no MCP, named tools, sandbox settings" {
  fi_af_allowlist 'sh test.sh'
  fi_af_fixer_cmd claude "P" "$TMP/last"
  printf '%s\n' "${FI_AF_CMD[@]}" > "$TMP/argv"
  grep -qx -- '--restricted' "$TMP/argv"
  grep -qx -- '--strict-mcp-config' "$TMP/argv"
  ! grep -qx -- '--mcp-config' "$TMP/argv" || false
  grep -qx -- '--tools' "$TMP/argv"
  # --tools is followed by exactly the fixer's six tools, then the next flag.
  [ "$(awk '/^--tools$/{f=1;next} /^--/{f=0} f' "$TMP/argv" | tr '\n' ' ')" = "Read Edit Write Glob Grep Bash " ]
  # the --allowedTools Bash(...) allowlist is still the gate
  grep -qx 'Bash(sh test.sh)' "$TMP/argv"
  grep -qx -- '--settings' "$TMP/argv"
  settings="$(awk '/^--settings$/{getline; print}' "$TMP/argv")"
  [ "$(printf '%s' "$settings" | jq -r '.sandbox.enabled')" = true ]
  [ "$(printf '%s' "$settings" | jq -r '.sandbox.failIfUnavailable')" = true ]
  [ "$(printf '%s' "$settings" | jq -r '.sandbox.allowUnsandboxedCommands')" = false ]
  [ "$(printf '%s' "$settings" | jq -r '.sandbox.network.allowedDomains[0]')" = '*' ]
}

@test "autofix engine: claude verifier is restricted with no MCP and only its search tools" {
  AFI_id=t1
  fi_af_verifier_cmd claude "V" "$TMP/last" "$TMP/schema"
  printf '%s\n' "${FI_AF_CMD[@]}" > "$TMP/argv"
  grep -qx -- '--restricted' "$TMP/argv"
  grep -qx -- '--strict-mcp-config' "$TMP/argv"
  [ "$(awk '/^--tools$/{f=1;next} /^--/{f=0} f' "$TMP/argv" | tr '\n' ' ')" = "Read Glob Grep Bash " ]
  grep -qx 'Bash(found-issues autofix search t1 \*)' "$TMP/argv"
  # no Edit/Write in the verifier, and no sandbox block (it runs no test command)
  ! grep -qx 'Edit' "$TMP/argv" || false
  ! grep -qx 'Write' "$TMP/argv" || false
  ! grep -qx -- '--settings' "$TMP/argv" || false
}

@test "autofix engine: codex argv carries none of the claude sandbox flags" {
  fi_af_allowlist 'sh test.sh'
  fi_af_fixer_cmd codex "P" "$TMP/last"
  printf '%s\n' "${FI_AF_CMD[@]}" > "$TMP/argv"
  grep -qx 'workspace-write' "$TMP/argv"
  ! grep -qx -- '--restricted' "$TMP/argv" || false
  ! grep -qx -- '--strict-mcp-config' "$TMP/argv" || false
  ! grep -qx -- '--tools' "$TMP/argv" || false
  ! grep -qx -- '--settings' "$TMP/argv" || false
  fi_af_verifier_cmd codex "P" "$TMP/last" "$TMP/schema"
  printf '%s\n' "${FI_AF_CMD[@]}" > "$TMP/argv"
  grep -qx 'read-only' "$TMP/argv"
  ! grep -qx -- '--restricted' "$TMP/argv" || false
  ! grep -qx -- '--strict-mcp-config' "$TMP/argv" || false
}

@test "autofix engine: a set runBudget puts --max-budget-usd on every claude child" {
  git config found-issues.autofix.runBudget 2
  fi_af_allowlist 'sh test.sh'
  fi_af_fixer_cmd claude "P" "$TMP/last"
  printf '%s\n' "${FI_AF_CMD[@]}" > "$TMP/argv"
  grep -qx -- '--max-budget-usd' "$TMP/argv"
  grep -qx '2.00' "$TMP/argv"
  fi_af_verifier_cmd claude "P" "$TMP/last" "$TMP/schema"
  printf '%s\n' "${FI_AF_CMD[@]}" > "$TMP/argv"
  grep -qx -- '--max-budget-usd' "$TMP/argv"
}

@test "autofix engine: no budget set means no dollar cap" {
  FI_AF_COST=500
  [ -z "$(fi_af_budget)" ]
  fi_af_budget_left
  [ -z "$(fi_af_budget_left)" ]
  fi_af_run_budget_left claude
  fi_af_verifier_cmd claude "P" "$TMP/last" "$TMP/schema"
  printf '%s\n' "${FI_AF_CMD[@]}" > "$TMP/argv"
  ! grep -qx -- '--max-budget-usd' "$TMP/argv" || false
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
  [ "$(grep -c '^Bash(' "$TMP/argv")" -eq 1 ]
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

@test "autofix engine: the verifier prompt says how to search" {
  AFI_entry=e
  p="$(fi_af_verifier_prompt 'diff')"
  [[ "$p" == *"found-issues autofix search t1 '<regex>'"* ]]
  [[ "$p" == *"found-issues autofix search t1 --files"* ]]
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

@test "autofix engine: codex roles get pinned models and efforts by default" {
  fi_af_fixer_cmd codex "P" "$TMP/last"
  printf '%s\n' "${FI_AF_CMD[@]}" > "$TMP/fix"
  grep -qx 'gpt-6.1-sol' "$TMP/fix"
  grep -qx 'model_reasoning_effort=medium' "$TMP/fix"
  [ "${FI_AF_CMD[${#FI_AF_CMD[@]}-1]}" = "P" ]
  fi_af_verifier_cmd codex "V" "$TMP/last" "$TMP/schema"
  printf '%s\n' "${FI_AF_CMD[@]}" > "$TMP/ver"
  grep -qx 'gpt-6-astra' "$TMP/ver"
  grep -qx 'model_reasoning_effort=high' "$TMP/ver"
  fi_af_codex_margs classifier
  [ "${FI_AF_MARGS[*]}" = "-m gpt-6.1-sol -c model_reasoning_effort=low" ]
  [ "$FI_AF_MDESC" = "gpt-6.1-sol (low)" ]
}

@test "autofix engine: inherit is per role and drops both -m and effort" {
  git config found-issues.autofix.codexVerifierModel inherit
  fi_af_verifier_cmd codex "V" "$TMP/last" "$TMP/schema"
  printf '%s\n' "${FI_AF_CMD[@]}" > "$TMP/ver"
  ! grep -qx -- '-m' "$TMP/ver" || false
  ! grep -q 'model_reasoning_effort' "$TMP/ver" || false
  grep -qx 'read-only' "$TMP/ver"
  fi_af_fixer_cmd codex "P" "$TMP/last"
  printf '%s\n' "${FI_AF_CMD[@]}" | grep -qx 'gpt-6.1-sol'
  fi_af_codex_margs verifier
  [ "${#FI_AF_MARGS[@]}" -eq 0 ]
  [ "$FI_AF_MDESC" = "inherit" ]
}

@test "autofix engine: inherit drops -m and effort for the fixer and classifier too, under set -u" {
  git config found-issues.autofix.codexModel inherit
  set -u
  fi_af_fixer_cmd codex "P" "$TMP/last"
  printf '%s\n' "${FI_AF_CMD[@]}" > "$TMP/fix"
  ! grep -qx -- '-m' "$TMP/fix" || false
  ! grep -q 'model_reasoning_effort' "$TMP/fix" || false
  [ "${FI_AF_CMD[${#FI_AF_CMD[@]}-1]}" = "P" ]
  fi_af_codex_margs classifier
  [ "${#FI_AF_MARGS[@]}" -eq 0 ]
  [ "$FI_AF_MDESC" = "inherit" ]
  printf -- '- [open] 2026-10-01 src/calc.sh:1 — untagged thing\n' >> docs/found-issues.md
  export FI_STANDIN_TRACE="$TMP/trace"
  FI_AF_RUNS="$TMP"; AFI_engine=codex
  fi_af_classify docs/found-issues.md t1 || true
  set +u
  grep -q '^codex' "$TMP/trace"
  ! grep -q 'model_reasoning_effort' "$TMP/trace" || false
}

@test "autofix engine: inherit is matched in any case" {
  git config found-issues.autofix.codexVerifierModel INHERIT
  fi_af_verifier_cmd codex "V" "$TMP/last" "$TMP/schema"
  printf '%s\n' "${FI_AF_CMD[@]}" > "$TMP/ver"
  ! grep -qx -- '-m' "$TMP/ver" || false
  fi_af_codex_margs verifier
  [ "$FI_AF_MDESC" = "inherit" ]
  git config found-issues.autofix.codexModel ' Inherit '
  fi_af_codex_margs fixer
  [ "${#FI_AF_MARGS[@]}" -eq 0 ]
}

@test "autofix engine: a model value starting with a dash is ignored with a warning and the default is used" {
  git config found-issues.autofix.codexModel '--unset'
  fi_af_codex_margs fixer
  [ "${FI_AF_MARGS[*]}" = "-m gpt-6.1-sol -c model_reasoning_effort=medium" ]
  [ "$FI_AF_MWARN" = "invalid codex model '--unset' for fixer; using default gpt-6.1-sol" ]
  git config found-issues.autofix.codexVerifierModel '   '
  fi_af_codex_margs verifier
  [ "${FI_AF_MARGS[*]}" = "-m gpt-6-astra -c model_reasoning_effort=high" ]
  [[ "$FI_AF_MWARN" == "invalid codex model '   ' for verifier; using default gpt-6-astra" ]]
  git config found-issues.autofix.codexModel gpt-ok
  fi_af_codex_margs fixer
  [ -z "$FI_AF_MWARN" ]
  fi_af_log t1 "x"
  FI_AF_RUNS="$TMP"; git config found-issues.autofix.codexModel '-x'
  FI_AF_CHILD_TOKENS=1 FI_AF_TOKENS=1 fi_af_codex_note t1 fixer
  grep -q 'warning: invalid codex model .-x. for fixer; using default gpt-6.1-sol' "$TMP/t1.log"
  grep -q 'codex fixer: model gpt-6.1-sol (medium)' "$TMP/t1.log"
}

@test "autofix engine: a custom codex model passes through as one argv element" {
  git config found-issues.autofix.codexModel 'org/model:tag-1.2'
  fi_af_fixer_cmd codex "P" "$TMP/last"
  printf '%s\n' "${FI_AF_CMD[@]}" | grep -qx 'org/model:tag-1.2'
}

@test "autofix engine: the codex classifier argv carries the classifier model" {
  printf -- '- [open] 2026-10-01 src/calc.sh:1 — untagged thing\n' >> docs/found-issues.md
  export FI_STANDIN_TRACE="$TMP/trace"
  FI_AF_RUNS="$TMP"; AFI_engine=codex
  fi_af_classify docs/found-issues.md t1 || true
  grep -q 'model_reasoning_effort=low' "$TMP/trace"
  grep -q 'gpt-6.1-sol' "$TMP/trace"
}

@test "autofix engine: a codex turn.failed becomes the engine error text" {
  FI_AF_TOKENS=0
  FI_STANDIN_CODEX_FAIL=all codex exec -o "$TMP/last" "x" > "$TMP/f.jsonl" 2>/dev/null || true
  fi_af_collect codex "$TMP/f.jsonl" "$TMP/last"
  [ "$FI_AF_ENGINE_ERR" = "The 'bad-model' model is not supported when using Codex with a ChatGPT account." ]
  [ "$FI_AF_TOKENS" = 0 ]
  codex exec -o "$TMP/last" "x" > "$TMP/ok.jsonl"
  fi_af_collect codex "$TMP/ok.jsonl" "$TMP/last"
  [ -z "$FI_AF_ENGINE_ERR" ]
  [ "$FI_AF_CHILD_TOKENS" = 1500 ]
}

@test "autofix engine: a turn.failed whose message is not a JSON object still gives the engine error text" {
  FI_AF_TOKENS=0
  printf '%s\n' '{"type":"turn.failed","error":{"message":"500"}}' > "$TMP/f1.jsonl"
  fi_af_collect codex "$TMP/f1.jsonl" "$TMP/last"
  [ "$FI_AF_ENGINE_ERR" = "500" ]
  printf '%s\n' '{"type":"turn.failed","error":{"message":"\"boom\""}}' > "$TMP/f2.jsonl"
  fi_af_collect codex "$TMP/f2.jsonl" "$TMP/last"
  [ -n "$FI_AF_ENGINE_ERR" ]
  [[ "$FI_AF_ENGINE_ERR" == *boom* ]]
  printf '%s\n' '{"type":"turn.failed","error":"flat"}' > "$TMP/f3.jsonl"
  fi_af_collect codex "$TMP/f3.jsonl" "$TMP/last"
  [ "$FI_AF_ENGINE_ERR" = "turn failed" ]
  printf '%s\n' '{"type":"turn.failed","error":{"message":""}}' > "$TMP/f4.jsonl"
  fi_af_collect codex "$TMP/f4.jsonl" "$TMP/last"
  [ "$FI_AF_ENGINE_ERR" = "turn failed" ]
}

@test "autofix engine: only a model-rejection text leaves the doctor marker" {
  FI_AF_TOKENS=0
  fi_af_root
  rm -f "$FI_AF_ROOT/codex-model-error"
  printf '%s\n' '{"type":"turn.failed","error":{"message":"{\"error\":{\"message\":\"You have hit your usage limit for model gpt-6-astra\"}}"}}' > "$TMP/u.jsonl"
  fi_af_collect codex "$TMP/u.jsonl" "$TMP/last"
  [ -n "$FI_AF_ENGINE_ERR" ]
  [ ! -e "$FI_AF_ROOT/codex-model-error" ]
  printf '%s\n' '{"type":"turn.failed","error":{"message":"{\"error\":{\"message\":\"Model gpt-6-astra is overloaded, not available right now\"}}"}}' > "$TMP/o.jsonl"
  fi_af_collect codex "$TMP/o.jsonl" "$TMP/last"
  [ ! -e "$FI_AF_ROOT/codex-model-error" ]
  printf '%s\n' '{"type":"turn.failed","error":{"message":"{\"error\":{\"message\":\"The model `x` does not exist\"}}"}}' > "$TMP/m.jsonl"
  fi_af_collect codex "$TMP/m.jsonl" "$TMP/last"
  [ -s "$FI_AF_ROOT/codex-model-error" ]
  rm -f "$FI_AF_ROOT/codex-model-error"
  printf '%s\n' '{"type":"turn.failed","error":{"message":"Unknown model: zzz"}}' > "$TMP/m2.jsonl"
  fi_af_collect codex "$TMP/m2.jsonl" "$TMP/last"
  [ -s "$FI_AF_ROOT/codex-model-error" ]
}

@test "autofix engine: tokens left shrink with use and run out at the cap" {
  git config found-issues.autofix.codexRunTokens 1000
  FI_AF_TOKENS=400
  [ "$(fi_af_tokens_left)" = 600 ]
  fi_af_run_budget_left codex
  FI_AF_TOKENS=1000
  run fi_af_tokens_left
  [ "$status" -eq 1 ]
  ! fi_af_run_budget_left codex || false
  [ "$(fi_af_spent_text codex)" = "run budget spent (1000 tokens)" ]
  FI_AF_COST=0.50
  [ "$(fi_af_spent_text claude)" = 'run budget spent ($0.50)' ]
  fi_af_run_budget_left claude
  AFI_kind=sweep
  git config found-issues.autofix.codexSweepTokens 5000
  [ "$(fi_af_token_cap)" = 5000 ]
}

@test "autofix engine: no token cap set means the codex gate never stops" {
  FI_AF_TOKENS=999999999
  [ -z "$(fi_af_token_cap)" ]
  fi_af_tokens_left
  [ -z "$(fi_af_tokens_left)" ]
  fi_af_run_budget_left codex
}
