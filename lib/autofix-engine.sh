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
#   fi_af_kill_child <pid>
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
FI_AF_CHILD_PGID="" FI_AF_ENGINE_ERR=""

# macOS ships no `timeout`. Poll once a second; on the limit, TERM then KILL.
# The child gets its own process group (perl setpgrp — bash 3.2 has no
# setsid), so the kill reaches its children too: a hung test runner's node
# or a codex helper used to outlive both the watchdog and a killed run.
# While it runs, the repo lock is refreshed so a long run never looks stale.
# The child never sees FI_AF_PID: inherited, a test that claims and cancels
# an item in its own state recorded the real run's pid and TERMed it (3.0.3).
fi_af_child() {
  local out="$1" err="$2" cwd="$3" secs cpid waited=0 rc=0
  shift 3
  secs="${FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS:-$(( $(fi_af_int runTimeoutMin 20) * 60 ))}"
  # PATH changes only inside the child's subshell, on purpose.
  # shellcheck disable=SC2030,SC2031
  if command -v perl >/dev/null 2>&1; then
    ( cd "$cwd" && unset FI_AF_PID && PATH="${FI_BIN_DIR:+$FI_BIN_DIR:}$PATH" && FOUND_ISSUES_AUTOFIX_CHILD=1 exec perl -e 'setpgrp(0, 0); exec { $ARGV[0] } @ARGV or exit 127' "$@" ) </dev/null >"$out" 2>"$err" &
    cpid=$!
    FI_AF_CHILD_PGID="$cpid"
    # autofix cancel (another process) needs the group to kill.
    if [[ -n "${AFI_id:-}" && -f "$FI_AF_ST/running/$AFI_id" ]]; then
      fi_af_item_set "$FI_AF_ST/running/$AFI_id" cpgid "$cpid" 2>/dev/null || true
    fi
  else
    ( cd "$cwd" && unset FI_AF_PID && PATH="${FI_BIN_DIR:+$FI_BIN_DIR:}$PATH" && FOUND_ISSUES_AUTOFIX_CHILD=1 exec "$@" ) </dev/null >"$out" 2>"$err" &
    cpid=$!
  fi
  while kill -0 "$cpid" 2>/dev/null; do
    if (( waited >= secs )); then
      fi_af_kill_child "$cpid"
      wait "$cpid" 2>/dev/null || true
      FI_AF_CHILD_PGID=""
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
    if (( waited % 30 == 0 )) && [[ -n "${FI_AF_ST:-}" && -d "$FI_AF_ST/lock" ]]; then
      touch "$FI_AF_ST/lock" 2>/dev/null || true
    fi
  done
  wait "$cpid" || rc=$?
  FI_AF_CHILD_PGID=""
  return $rc
}

# TERM then KILL the child's process group (or just the child without perl).
fi_af_kill_child() {
  local target="$1"
  [[ -n "$FI_AF_CHILD_PGID" ]] && target="-$FI_AF_CHILD_PGID"
  kill -TERM -- "$target" 2>/dev/null || true
  sleep 2
  kill -KILL -- "$target" 2>/dev/null || true
}

# Read/Edit tools plus the repo's test command, exactly and with appended
# arguments, and the item's read-only search. Pure test runners may also run
# a single test file.
fi_af_allowlist() {
  local t="$1" first="${1%% *}" id="${2:-}"
  FI_AF_TOOLS=(Read Edit Write Glob Grep "Bash($t)" "Bash($t *)")
  [[ -n "$id" ]] && FI_AF_TOOLS+=("Bash(found-issues autofix search $id *)")
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
    tools="Read and edit files with the Read, Edit and Write tools. Search with
found-issues autofix search ${AFI_id:-<id>} '<regex>' [<path>...] (git grep in this
worktree) or found-issues autofix search ${AFI_id:-<id>} --files [<path>...] (list
files), each as its own Bash call. The only other shell command you may run
is the test command, as its own Bash call,
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
      --allowedTools Read Grep Glob "Bash(found-issues autofix search ${AFI_id:-} *)"
      --output-format json "$prompt")
  fi
}

fi_af_collect() {
  local engine="$1" out="$2" last="$3" c t
  FI_AF_TEXT="" FI_AF_ENGINE_ERR=""
  if [[ "$engine" == "codex" ]]; then
    [[ -n "$last" && -f "$last" ]] && FI_AF_TEXT="$(cat "$last")"
    t="$(jq -s '[.[] | select(.type=="turn.completed") | (.usage.input_tokens // 0) + (.usage.output_tokens // 0)] | add // 0' "$out" 2>/dev/null || true)"
    [[ "$t" =~ ^[0-9]+$ ]] && FI_AF_TOKENS=$((FI_AF_TOKENS + t))
  else
    FI_AF_TEXT="$(jq -r '.result // empty' "$out" 2>/dev/null || true)"
    # An outage (usage limit, logged out, network) is is_error or an error_*
    # subtype; error_max_* is a run limit this run set, not an outage.
    FI_AF_ENGINE_ERR="$(jq -r 'if (.is_error == true or ((.subtype // "success") | startswith("error_"))) and (((.subtype // "") | startswith("error_max_")) | not) then (.result // .subtype // "engine error") else empty end' "$out" 2>/dev/null || true)"
    FI_AF_ENGINE_ERR="${FI_AF_ENGINE_ERR//$'\n'/ }"
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
  local t="$1" v rest="$1" n=0
  [[ "$t" == *"{"*"}"* ]] || return 0
  # One verdict only: "true then false" must not read as approve.
  while [[ "$rest" == *'"approve"'* ]]; do n=$((n + 1)); rest="${rest#*\"approve\"}"; done
  if (( n != 1 )); then FI_AF_REASON="ambiguous verdict ($n approve fields)"; return 0; fi
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
