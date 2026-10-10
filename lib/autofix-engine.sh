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
#   fi_af_sandbox_available
#   fi_af_fixer_cmd <engine> <prompt> <last-file>
#   fi_af_verifier_cmd <engine> <prompt> <last-file> <schema-file>
#   fi_af_collect <engine> <out> <last-file>
#   fi_af_parse_result <text>
#   fi_af_parse_verdict <text>
#   fi_af_budget_left
#   fi_af_budget_args
#   fi_af_token_cap
#   fi_af_tokens_left
#   fi_af_run_budget_left <engine>
#   fi_af_spent_text <engine>
#   fi_af_codex_note <id> <role>
#   fi_af_codex_desc <role>

# shellcheck disable=SC2154  # AFI_* are set by fi_af_item_read (autofix-queue.sh)

# The fixer's Bash sandbox (3.3.1). Measured live 2026-10-07 (Claude Code
# 2.1.292): with --restricted, `sh test.sh` could not write under $HOME
# ("Operation not permitted"), could reach https://example.com (200), and
# dangerouslyDisableSandbox was ignored. network.allowedDomains is needed:
# without it every outbound host answers 403. Git still works from the
# fixer's linked worktree: `git add` there wrote the index under the main
# repo's .git while a plain write to the main checkout was refused (measured
# 2026-10-07, same build). Per-user package caches stay writable so a test
# command that fills one (go test, cargo test, uv run, gradle, npm) behaves
# as it does at baseline; found-issues' own cache stays denied (measured the
# same day: ~/.cache writable, ~/.cache/found-issues and ~/Documents refused).
FI_AF_SANDBOX_SETTINGS='{"sandbox":{"enabled":true,"failIfUnavailable":true,"allowUnsandboxedCommands":false,"network":{"allowedDomains":["*"]},"filesystem":{"allowWrite":["~/.cache","~/Library/Caches","~/.npm","~/.cargo/registry","~/.cargo/git","~/go/pkg/mod","~/.gradle/caches","~/.m2/repository"],"denyWrite":["~/.cache/found-issues"]}}}'
FI_AF_SBWARN=""
FI_AF_TOOLS=() FI_AF_CMD=() FI_AF_BARGS=() FI_AF_TEXT="" FI_AF_COST="0" FI_AF_TOKENS=0
FI_AF_RESULT="" FI_AF_RESULT_TEXT="" FI_AF_APPROVE="false" FI_AF_REASON=""
FI_AF_CHILD_PGID="" FI_AF_ENGINE_ERR="" FI_AF_CHILD_TOKENS=0 FI_AF_VERDICT_OK=0 FI_AF_CHILD_TIMEDOUT=""

# macOS ships no `timeout`. Poll once a second; on the limit, TERM then KILL.
# The child gets its own process group (perl setpgrp — bash 3.2 has no
# setsid), so the kill reaches its children too: a hung test runner's node
# or a codex helper used to outlive both the watchdog and a killed run.
# While it runs, the repo lock is refreshed so a long run never looks stale.
# The child never sees FI_AF_PID: inherited, a test that claims and cancels
# an item in its own state recorded the real run's pid and TERMed it (3.0.3).
# FI_AF_CHILD_TIMEDOUT holds the limit in seconds when the watchdog fired,
# so a command that exits 124 on its own is not mistaken for it (3.4.2).
fi_af_child() {
  local out="$1" err="$2" cwd="$3" secs cpid waited=0 rc=0
  shift 3
  FI_AF_CHILD_TIMEDOUT=""
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
      FI_AF_CHILD_PGID="" FI_AF_CHILD_TIMEDOUT="$secs"
      _fi_af_clear_cpgid
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
  _fi_af_clear_cpgid
  return $rc
}

# The item's cpgid names a live group only while the child runs: a later
# cancel would TERM a dead or reused group.
_fi_af_clear_cpgid() {
  if [[ -n "${AFI_id:-}" && -f "$FI_AF_ST/running/$AFI_id" ]]; then
    fi_af_item_set "$FI_AF_ST/running/$AFI_id" cpgid "" 2>/dev/null || true
  fi
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
  # 3.6.0: Claude Code checks each part of an && command on its own.
  local rest="$t" part
  [[ "$rest" == *" && "* ]] || return 0
  # Only the last part takes arguments (a test file): "npm install *" would
  # let the unattended fixer install any package.
  while [[ -n "$rest" ]]; do
    part="${rest%% && *}"
    if [[ "$part" == "$rest" ]]; then
      rest=""; FI_AF_TOOLS+=("Bash($part)" "Bash($part *)")
    else
      rest="${rest#* && }"; FI_AF_TOOLS+=("Bash($part)")
    fi
    case "${part%% *}" in
      bats|pytest) FI_AF_TOOLS+=("Bash(${part%% *} *)") ;;
    esac
  done
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
checkout; do not edit anything. To search it, run
found-issues autofix search ${AFI_id:-<id>} '<regex>' [<path>...] or
found-issues autofix search ${AFI_id:-<id>} --files [<path>...], each as its own Bash call.

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

# 0 when this host has the runtime Claude Code's Bash sandbox needs:
# Seatbelt (sandbox-exec) on macOS, bubblewrap + socat on Linux and WSL2;
# native Windows has none.
fi_af_sandbox_available() {
  case "$(uname -s 2>/dev/null)" in
    Darwin) command -v sandbox-exec >/dev/null 2>&1 ;;
    Linux) command -v bwrap >/dev/null 2>&1 && command -v socat >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

fi_af_fixer_cmd() {
  local engine="$1" prompt="$2" last="$3" sb=()
  FI_AF_SBWARN=""
  if [[ "$engine" == "codex" ]]; then
    fi_af_codex_margs fixer
    FI_AF_CMD=(codex exec --sandbox workspace-write -C "$AFI_wt" --ephemeral --json
      ${FI_AF_MARGS[@]+"${FI_AF_MARGS[@]}"} -o "$last" "$prompt")
  else
    fi_af_budget_args
    # 3.3.1: --restricted confines Edit/Write to the worktree and ignores the
    # user/project/local settings; --strict-mcp-config (no --mcp-config) loads
    # no MCP server. --tools names the only tools the role gets; the
    # --allowedTools Bash(...) patterns stay the gate on which commands run;
    # --settings turns on the OS sandbox for that Bash command (writes outside
    # the worktree denied, network open, no dangerouslyDisableSandbox escape,
    # and no start at all when a present runtime fails). A host with no
    # sandbox runtime fails open instead: no --settings, a run-log warning,
    # and --restricted plus no MCP still apply (ruling 2026-10-07).
    if fi_af_sandbox_available; then
      sb=(--settings "$FI_AF_SANDBOX_SETTINGS")
    else
      FI_AF_SBWARN="no Claude sandbox runtime on this host (macOS sandbox-exec, or bubblewrap + socat on Linux): the fixer's test command runs unsandboxed; its file tools stay confined to the worktree"
    fi
    FI_AF_CMD=(claude -p --restricted --strict-mcp-config
      ${sb[@]+"${sb[@]}"}
      --tools Read Edit Write Glob Grep Bash
      --model sonnet ${FI_AF_BARGS[@]+"${FI_AF_BARGS[@]}"}
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
    fi_af_codex_margs verifier
    FI_AF_CMD=(codex exec --sandbox read-only -C "$AFI_wt" --ephemeral --json
      ${FI_AF_MARGS[@]+"${FI_AF_MARGS[@]}"} --output-schema "$schema" -o "$last" "$prompt")
  else
    fi_af_budget_args
    FI_AF_CMD=(claude -p --restricted --strict-mcp-config
      --tools Read Glob Grep Bash
      --model opus --effort high ${FI_AF_BARGS[@]+"${FI_AF_BARGS[@]}"}
      --max-turns 15 --no-session-persistence
      --permission-mode dontAsk --permission-prompts none
      --allowedTools Read Grep Glob "Bash(found-issues autofix search ${AFI_id:-} *)"
      --output-format json "$prompt")
  fi
}

# 3.3.0: does a failed Codex turn's text say the model itself was refused?
# model ... (not found|does not exist|...) or (unknown|invalid|unsupported)
# model, case-insensitive; never when it speaks of a usage limit, a rate
# limit or an overload.
_fi_af_model_rejected() {
  local t re_limit re_a re_b
  t="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  re_limit='usage limit|rate limit|rate-limit|overloaded'
  re_a='model.*(not found|does not exist|not supported|unsupported|not available|invalid|unknown|no access|do not have access)'
  re_b='(unknown|invalid|unsupported) model'
  [[ "$t" =~ $re_limit ]] && return 1
  [[ "$t" =~ $re_a || "$t" =~ $re_b ]]
}

fi_af_collect() {
  local engine="$1" out="$2" last="$3" c t
  FI_AF_TEXT="" FI_AF_ENGINE_ERR="" FI_AF_CHILD_TOKENS=0
  if [[ "$engine" == "codex" ]]; then
    [[ -n "$last" && -f "$last" ]] && FI_AF_TEXT="$(cat "$last")"
    t="$(jq -s '[.[] | select(.type=="turn.completed") | (.usage.input_tokens // 0) + (.usage.output_tokens // 0)] | add // 0' "$out" 2>/dev/null || true)"
    [[ "$t" =~ ^[0-9]+$ ]] || t=0
    FI_AF_CHILD_TOKENS="$t"
    FI_AF_TOKENS=$((FI_AF_TOKENS + t))
    # 3.3.0 spec section 4: a rejected model (or any failed turn) is an outage.
    # Measured: the message is a JSON error envelope inside a string; a
    # message that is not an envelope object (a bare number, a quoted string)
    # is the text itself. Never empty for a turn.failed event.
    FI_AF_ENGINE_ERR="$(jq -Rrn '
      def msg: (try (.error | objects | .message) catch null) // "turn failed";
      [inputs | (try fromjson catch empty) | select(type == "object" and .type == "turn.failed") | msg]
      | last // empty
      | if type == "string" then
          ((try fromjson catch null) as $j
           | if ($j | type) == "object" then (($j.error | objects | .message | strings) // ($j.message | strings) // .) else . end)
        else tostring end
      | if gsub("[[:space:]]"; "") == "" then "turn failed" else . end' "$out" 2>/dev/null || true)"
    FI_AF_ENGINE_ERR="${FI_AF_ENGINE_ERR//$'\n'/ }"
    if [[ -z "$FI_AF_ENGINE_ERR" ]] && grep -Fq '"turn.failed"' "$out" 2>/dev/null; then
      FI_AF_ENGINE_ERR="turn failed"
    fi
    # A model the account cannot use leaves a marker for doctor; a clean child
    # that spent tokens clears it. Only a model-rejection shape counts: a
    # usage limit or an overload can name a model without it being unusable.
    fi_af_root
    if [[ -n "$FI_AF_ENGINE_ERR" ]]; then
      if _fi_af_model_rejected "$FI_AF_ENGINE_ERR"; then
        printf '%s\n' "$FI_AF_ENGINE_ERR" >"$FI_AF_ROOT/codex-model-error" 2>/dev/null || true
      fi
    elif (( t > 0 )); then
      rm -f "$FI_AF_ROOT/codex-model-error" 2>/dev/null || true
    fi
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
  FI_AF_APPROVE="false" FI_AF_REASON="no parseable verdict" FI_AF_VERDICT_OK=0
  local t="$1" v rest="$1" n=0
  [[ "$t" == *"{"*"}"* ]] || return 0
  # One verdict only: "true then false" must not read as approve.
  while [[ "$rest" == *'"approve"'* ]]; do n=$((n + 1)); rest="${rest#*\"approve\"}"; done
  if (( n != 1 )); then FI_AF_REASON="ambiguous verdict ($n approve fields)"; return 0; fi
  t="{${t#*\{}"
  t="${t%\}*}}"
  v="$(printf '%s' "$t" | jq -r 'if (.approve | type) == "boolean" then "\(.approve)\t\(.reason // "")" else empty end' 2>/dev/null || true)"
  [[ -n "$v" ]] || return 0
  FI_AF_VERDICT_OK=1
  FI_AF_APPROVE="${v%%$'\t'*}"
  FI_AF_REASON="${v#*$'\t'}"
  FI_AF_REASON="${FI_AF_REASON//$'\n'/ }"
}

# Spec §7/§8: runBudget caps the whole run (every child) when set; unset is
# no cap (3.3.0, Decision 6).
fi_af_budget_left() {
  local b
  b="$(fi_af_budget)"
  [[ -n "$b" ]] || return 0
  awk -v b="$b" -v s="$FI_AF_COST" 'BEGIN { l = b - s; if (l < 0.10) exit 1; printf "%.2f", l }'
}

# The claude child's --max-budget-usd, only when a budget is set.
fi_af_budget_args() {
  local b
  FI_AF_BARGS=()
  [[ -n "$(fi_af_budget)" ]] || return 0
  b="$(fi_af_budget_left || printf '0.10')"
  FI_AF_BARGS=(--max-budget-usd "$b")
}

# 3.3.0 spec §2: Codex reports tokens, not dollars, so its runs stop on a
# token cap instead (a sweep has its own). Opt-in: unset = no cap (Decision
# 5). Checked before each child; one child may overshoot (Decision 3).
fi_af_token_cap() {
  if [[ "${AFI_kind:-}" == "sweep" ]]; then fi_af_cap_int codexSweepTokens
  else fi_af_cap_int codexRunTokens; fi
}

fi_af_tokens_left() {
  local cap
  cap="$(fi_af_token_cap)"
  [[ -n "$cap" ]] || return 0
  (( FI_AF_TOKENS < cap )) || return 1
  printf '%s' $(( cap - FI_AF_TOKENS ))
}

# Engine-neutral gate: dollars for claude, tokens for codex.
fi_af_run_budget_left() {
  if [[ "$1" == codex ]]; then fi_af_tokens_left >/dev/null
  else fi_af_budget_left >/dev/null; fi
}

fi_af_spent_text() {
  if [[ "$1" == codex ]]; then printf 'run budget spent (%s tokens)' "$FI_AF_TOKENS"
  else printf 'run budget spent ($%s)' "$FI_AF_COST"; fi
}

# 3.3.0 spec section 3: one run-log line per Codex child.
fi_af_codex_note() {
  fi_af_codex_margs "$2"
  local cap
  cap="$(fi_af_token_cap)"
  [[ -z "$FI_AF_MWARN" ]] || fi_af_log "$1" "warning: $FI_AF_MWARN"
  fi_af_log "$1" "codex $2: model $FI_AF_MDESC, $FI_AF_CHILD_TOKENS tokens, run total $FI_AF_TOKENS${cap:+/$cap}"
}

# Doctor's description of one role; inherit names config.toml's model.
fi_af_codex_desc() {
  local m
  fi_af_codex_margs "$1"
  if [[ "$FI_AF_MDESC" != inherit ]]; then printf '%s' "$FI_AF_MDESC"; return 0; fi
  m="$(sed -n 's/^model[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "${CODEX_HOME:-$HOME/.codex}/config.toml" 2>/dev/null | head -n 1)"
  printf 'inherit (~/.codex/config.toml: %s)' "${m:-its default}"
}
