#!/usr/bin/env bats
# LIVE checks against the real claude/codex CLIs (spec §4.5, §10). They cost
# money and need logged-in CLIs, so they run only with FI_LIVE=1:
#   FI_LIVE=1 bats tests/autofix-live.bats
# Results (cost, seconds) are appended to $FI_LIVE_REPORT (default $TMPDIR).

load 'helpers'
load 'autofix-helpers'

setup() {
  # Only the "live:" tests spend money; the one non-live test checks argv.
  if [[ "$BATS_TEST_DESCRIPTION" == live:* ]]; then
    [[ "${FI_LIVE:-}" == 1 ]] || skip "live: set FI_LIVE=1 (costs money)"
  fi
  local real_home="$HOME"
  fi_setup_tmp; fi_af_fixture
  # The real CLIs need the operator's login (~/.claude, ~/.codex); the
  # fixture's throwaway HOME would make claude answer "Not logged in".
  [[ "${FI_LIVE:-}" != 1 ]] || export HOME="$real_home"
  export PATH="$TEST_REPO_ROOT/tests/bin-shims:$PATH"
  export GH_MOCK_TRACE="$TMP/gh.trace"
  export GH_MOCK_PR_VIEW=$'7\t{"number":7,"state":"OPEN","statusCheckRollup":[]}'
  REPORT="${FI_LIVE_REPORT:-${TMPDIR:-/tmp}/fi-live-report.txt}"
}
teardown() { fi_teardown_tmp; return 0; }

# The argv the fixer really ships with (fi_af_fixer_cmd: --restricted,
# --strict-mcp-config, --tools, the 3.3.1 sandbox --settings, dontAsk and the
# allowlist), with only the model and the budget swapped for a cheap probe.
# Sets LIVE_ARGV; $1 is the prompt.
live_fixer_argv() {
  local a skip=0
  source "$FI_BIN"; fi_af_context
  AFI_id=live AFI_wt="$PWD" AFI_root="$PWD"
  fi_af_allowlist 'sh test.sh' "$AFI_id"
  fi_af_fixer_cmd claude "$1" "$TMP/last"
  LIVE_ARGV=()
  for a in "${FI_AF_CMD[@]}"; do
    if (( skip )); then skip=0; continue; fi
    case "$a" in
      --model) LIVE_ARGV+=(--model haiku --max-budget-usd 0.5); skip=1 ;;
      --max-budget-usd) skip=1 ;;
      *) LIVE_ARGV+=("$a") ;;
    esac
  done
}

@test "live harness: the allowlist probe argv is the shipped fixer argv with a cheap model and budget" {
  live_fixer_argv "PROBE"
  printf '%s\n' "${LIVE_ARGV[@]}" > "$TMP/argv"
  [ "${LIVE_ARGV[0]}" = claude ]
  [ "${LIVE_ARGV[${#LIVE_ARGV[@]}-1]}" = "PROBE" ]
  grep -qx -- '--restricted' "$TMP/argv"
  grep -qx -- '--strict-mcp-config' "$TMP/argv"
  grep -qx -- '--tools' "$TMP/argv"
  grep -qx -- 'dontAsk' "$TMP/argv"
  grep -qx 'Bash(sh test.sh)' "$TMP/argv"
  grep -qx 'haiku' "$TMP/argv"
  ! grep -qx 'sonnet' "$TMP/argv" || false
  [ "$(grep -cx -- '--max-budget-usd' "$TMP/argv")" = 1 ]
  [ "$(awk '/^--max-budget-usd$/{getline; print}' "$TMP/argv")" = 0.5 ]
  if fi_af_sandbox_available; then grep -qx -- '--settings' "$TMP/argv"; fi
}

@test "live: the fixer allowlist allows the test command and denies writes" {
  # Measured 2026-10-03 (Claude Code 2.1.289): dontAsk also auto-allows
  # read-only commands (git status, git log), so the contract is "the test
  # command runs, nothing that writes or commits does".
  live_fixer_argv "Permission test; denials are expected. Run each exact command with the Bash tool, one per call, unmodified, continuing after denials: 'sh test.sh' ; 'touch probe.txt' ; 'git commit --allow-empty -m x' ; 'curl -s example.com'. Then stop."
  run "${LIVE_ARGV[@]}"
  printf '%s' "$output" > "$TMP/out.json"
  denied="$(jq -r '[.permission_denials[]?.tool_input.command] | join("|")' "$TMP/out.json")"
  printf 'allowlist: denied=%s cost=%s\n' "$denied" "$(jq -r .total_cost_usd "$TMP/out.json")" >> "$REPORT"
  [[ "$denied" == *"touch probe.txt"* ]]
  [[ "$denied" == *"git commit --allow-empty -m x"* ]]
  [[ "$denied" == *"curl -s example.com"* ]]
  [[ "|$denied|" != *"|sh test.sh|"* ]]
  [ ! -e probe.txt ]
}

@test "live: claude engine fixes the fixture and reports its cost" {
  fi_af_queue_fixture
  start=$SECONDS
  run "$FI_BIN" autofix run "$ID" --engine claude
  dur=$((SECONDS - start))
  cat "$FI_AF_RUNS/$ID.log" >&3 || true
  fi_af_item_read "$FI_AF_ST/done/$ID"
  printf 'claude: result=%s cost=%s seconds=%s\n' "$AFI_result" "$AFI_cost" "$dur" >> "$REPORT"
  [[ "$AFI_result" == shipped:* ]]
}

@test "live: codex engine fixes the fixture and reports its tokens" {
  command -v codex >/dev/null || skip "codex not installed"
  fi_af_queue_fixture
  start=$SECONDS
  run "$FI_BIN" autofix run "$ID" --engine codex
  dur=$((SECONDS - start))
  fi_af_item_read "$FI_AF_ST/done/$ID"
  printf 'codex: result=%s tokens=%s seconds=%s\n' "$AFI_result" "$(sed -n 's/^tokens=//p' "$FI_AF_ST/done/$ID")" "$dur" >> "$REPORT"
  [[ "$AFI_result" == shipped:* ]]
}
