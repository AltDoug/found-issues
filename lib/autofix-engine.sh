#!/usr/bin/env bash
# autofix-engine.sh — launcher A's engine children: a headless `claude -p`
# or `codex exec` fixer and a read-only verifier, under a bash watchdog
# (spec 2026-10-03 §4.5, §5 steps 3-5, §9).
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Children only edit files in the item's worktree. They never run git or gh
# and never write the ledger or the state dir (the Codex workspace-write
# sandbox could not); they end with an FI-RESULT line that bash acts on.
#
# Allowlist syntax pinned live 2026-10-03 (Claude Code 2.1.289): Bash(x:*)
# and Bash(x *) are prefix matches, Bash(x) is exact, compound commands are
# denied, and denials never prompt under dontAsk + --permission-prompts none.
#
# Functions:
#   fi_af_child <out> <err> <cwd> cmd...
#   fi_af_allowlist <test-command>
#   fi_af_fixer_prompt <test-command> <feedback> [<engine>]
#   fi_af_verifier_prompt <diff>
#   fi_af_fixer_cmd <engine> <prompt> <last-file>
#   fi_af_verifier_cmd <engine> <prompt> <last-file> <schema-file>
#   fi_af_collect <engine> <out> <last-file>
#   fi_af_parse_result <text>
#   fi_af_parse_verdict <text>
#   fi_af_budget_left

# shellcheck disable=SC2154  # AFI_* are set by fi_af_item_read (autofix-queue.sh)

FI_AF_TOOLS=() FI_AF_CMD=() FI_AF_TEXT="" FI_AF_COST="0" FI_AF_TOKENS=0
FI_AF_RESULT="" FI_AF_RESULT_TEXT="" FI_AF_APPROVE="false" FI_AF_REASON=""

# macOS ships no `timeout`. Poll once a second; on the limit, TERM then KILL.
fi_af_child() {
  local out="$1" err="$2" cwd="$3" secs cpid waited=0 rc=0
  shift 3
  secs="${FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS:-$(( $(fi_af_int runTimeoutMin 20) * 60 ))}"
  ( cd "$cwd" && FOUND_ISSUES_AUTOFIX_CHILD=1 exec "$@" ) </dev/null >"$out" 2>"$err" &
  cpid=$!
  while kill -0 "$cpid" 2>/dev/null; do
    if (( waited >= secs )); then
      kill -TERM "$cpid" 2>/dev/null || true
      sleep 2
      kill -KILL "$cpid" 2>/dev/null || true
      wait "$cpid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$cpid" || rc=$?
  return $rc
}

# Read/Edit tools plus the repo's test command, exactly and with appended
# arguments. Pure test runners may also run a single test file.
fi_af_allowlist() {
  local t="$1" first="${1%% *}"
  FI_AF_TOOLS=(Read Edit Write Glob Grep "Bash($t)" "Bash($t *)")
  case "$first" in
    bats|pytest) FI_AF_TOOLS+=("Bash($first *)") ;;
  esac
}

fi_af_fixer_prompt() {
  local testcmd="$1" feedback="$2" engine="${3:-claude}" tools
  # Measured live 2026-10-03: sonnet wrapped the test command as
  # `sh test.sh; echo "exit=$?"`, the allowlist refused the compound, and the
  # fixer gave up; codex, told to run nothing but the tests, could not even
  # read a file. So each engine is told exactly what its sandbox allows.
  if [[ "$engine" == "codex" ]]; then
    tools="You may read files and run read-only shell commands; your edits stay
inside this worktree. Never run git or gh: the orchestrator commits, pushes
and opens the PR."
  else
    tools="Read and edit files with the Read, Edit, Write, Grep and Glob tools. The
only shell command you may run is the test command, as its own Bash call,
exactly as: ${testcmd} (a test file may be appended). Run it alone,
with no cd, ;, &&, |, redirection or echo \$? around it (the Bash tool
already reports the exit code), and no git or gh: anything else is refused.
The orchestrator commits, pushes and opens the PR."
  fi
  cat <<EOF
You are the found-issues auto-fixer. This run is sanctioned and unattended:
you are in a dedicated git worktree on branch ${AFI_branch} (never main), and
nobody will answer questions or permission prompts.

The issue, from the repo's found-issues ledger:
${AFI_entry}

Do exactly this:
1. Check whether the symptom is still present in this checkout.
2. Add or extend a test that fails because of this symptom. The repo's test
   command is: ${testcmd}
3. Make the smallest change that fixes the symptom. Change nothing unrelated.
   Do not edit docs/found-issues.md or any found-issues ledger.
4. Run the test command until it passes.
${tools}

End your reply with exactly one line, one of:
FI-RESULT: fixed
FI-RESULT: already-fixed <evidence>
FI-RESULT: decide <the question a human must answer first>
FI-RESULT: manual <why this cannot be fixed or proven by a test>
EOF
  if [[ -n "$feedback" ]]; then
    printf '\nThe previous attempt was rejected and the worktree was reset. Why:\n%s\n' "$feedback"
  fi
}

fi_af_verifier_prompt() {
  local diff="$1"
  [[ ${#diff} -gt 60000 ]] && diff="${diff:0:60000}"$'\n[diff truncated]'
  cat <<EOF
You are a strict reviewer of an unattended bug fix. You may read files in this
checkout; do not edit anything.

The issue:
${AFI_entry}

The change (git diff against the default branch):
${diff}

Approve only if all three hold: the change fixes the cited symptom; it
changes nothing unrelated; and it adds or extends a test that reproduces the
symptom (fails without the fix).

Reply with only a JSON object: {"approve": true or false, "reason": "<one sentence>"}
EOF
}

fi_af_fixer_cmd() {
  local engine="$1" prompt="$2" last="$3"
  if [[ "$engine" == "codex" ]]; then
    FI_AF_CMD=(codex exec --sandbox workspace-write -C "$AFI_wt" --ephemeral --json -o "$last" "$prompt")
  else
    FI_AF_CMD=(claude -p --model sonnet --max-budget-usd "$(fi_af_budget_left || printf '0.10')"
      --max-turns 40 --no-session-persistence
      --permission-mode dontAsk --permission-prompts none
      --allowedTools "${FI_AF_TOOLS[@]}"
      --output-format json "$prompt")
  fi
}

fi_af_verifier_cmd() {
  local engine="$1" prompt="$2" last="$3" schema="$4"
  if [[ "$engine" == "codex" ]]; then
    printf '%s\n' '{"type":"object","properties":{"approve":{"type":"boolean"},"reason":{"type":"string"}},"required":["approve","reason"],"additionalProperties":false}' >"$schema"
    FI_AF_CMD=(codex exec --sandbox read-only -C "$AFI_wt" --ephemeral --json
      -c model_reasoning_effort=high --output-schema "$schema" -o "$last" "$prompt")
  else
    FI_AF_CMD=(claude -p --model opus --effort high --max-budget-usd "$(fi_af_budget_left || printf '0.10')"
      --max-turns 15 --no-session-persistence
      --permission-mode dontAsk --permission-prompts none
      --allowedTools Read Grep Glob
      --output-format json "$prompt")
  fi
}

fi_af_collect() {
  local engine="$1" out="$2" last="$3" c t
  FI_AF_TEXT=""
  if [[ "$engine" == "codex" ]]; then
    [[ -n "$last" && -f "$last" ]] && FI_AF_TEXT="$(cat "$last")"
    t="$(jq -s '[.[] | select(.type=="turn.completed") | (.usage.input_tokens // 0) + (.usage.output_tokens // 0)] | add // 0' "$out" 2>/dev/null || true)"
    [[ "$t" =~ ^[0-9]+$ ]] && FI_AF_TOKENS=$((FI_AF_TOKENS + t))
  else
    FI_AF_TEXT="$(jq -r '.result // empty' "$out" 2>/dev/null || true)"
    c="$(jq -r '.total_cost_usd // 0' "$out" 2>/dev/null || true)"
    [[ "$c" =~ ^[0-9.eE+-]+$ ]] || c=0
    FI_AF_COST="$(awk -v a="$FI_AF_COST" -v b="$c" 'BEGIN { printf "%.4f", a + b }')"
  fi
}

fi_af_parse_result() {
  FI_AF_RESULT="none" FI_AF_RESULT_TEXT=""
  local line re='^[[:space:]*`]*FI-RESULT:[[:space:]]*(fixed|already-fixed|decide|manual)([[:space:]]+(.*))?$'
  while IFS= read -r line; do
    line="${line%$'\r'}"
    while [[ "$line" == *'*' || "$line" == *'`' || "$line" == *' ' ]]; do line="${line%?}"; done
    if [[ "$line" =~ $re ]]; then
      FI_AF_RESULT="${BASH_REMATCH[1]}"
      FI_AF_RESULT_TEXT="${BASH_REMATCH[3]}"
    fi
  done <<<"$1"
}

fi_af_parse_verdict() {
  FI_AF_APPROVE="false" FI_AF_REASON="no parseable verdict"
  local t="$1" v
  [[ "$t" == *"{"*"}"* ]] || return 0
  t="{${t#*\{}"
  t="${t%\}*}}"
  v="$(printf '%s' "$t" | jq -r 'if (.approve | type) == "boolean" then "\(.approve)\t\(.reason // "")" else empty end' 2>/dev/null || true)"
  [[ -n "$v" ]] || return 0
  FI_AF_APPROVE="${v%%$'\t'*}"
  FI_AF_REASON="${v#*$'\t'}"
  FI_AF_REASON="${FI_AF_REASON//$'\n'/ }"
}

# Spec §7: runBudget caps the whole run (every fixer and verifier child).
fi_af_budget_left() {
  awk -v b="$(fi_af_budget)" -v s="$FI_AF_COST" 'BEGIN { l = b - s; if (l < 0.10) exit 1; printf "%.2f", l }'
}
