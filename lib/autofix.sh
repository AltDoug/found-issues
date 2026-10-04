#!/usr/bin/env bash
# autofix.sh — the `autofix` subcommand family (spec 2026-10-03 §4-§8).
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   _fi_af_run <id> <engine> / _fi_af_run_one <id> <engine>
#   _fi_af_status
#   cmd_autofix <sub> [...]

_fi_af_usage() {
  cat <<'EOF'
Usage: found-issues autofix <command>
  on | off                    Clear or set the kill switch (all repos)
  status                      Queue, running, today's count, recent results
  run <id> [--engine claude|codex]
                              Fix a queued item headlessly, then the rest of the queue
                              (exit 1 unknown id, 3 capped, 4 locked, 7 engine outage)
  claim <id>                  Take a queued item: lock, cap, worktree (prints its path)
  brief <id>                  The in-session fixer's instructions for a claimed item
  test <id>                   Run the repo's test command in the claimed item's worktree
  diff <id>                   The claimed item's change against origin/<default>
  ship <id>                   Test, commit, push, open the PR, annotate, arm auto-merge
  release <id> --already-fixed|--decide|--manual|--failed "<text>"
                              Give a claimed item back with an outcome
  merge-when-green <N> [--repo owner/name]
                              Wait for PR <N>'s checks, then squash-merge it
Settings: git config found-issues.autofix true|false (local overrides --global),
found-issues.autofix.{engine,testCommand,dailyFixes,runBudget,runTimeoutMin}.
EOF
}

# One fixer child plus its bookkeeping. Sets FI_AF_RESULT/_TEXT.
_fi_af_fix_attempt() {
  local engine="$1" n="$2" feedback="$3" base="$FI_AF_RUNS/$AFI_id.fix$n" rc=0
  fi_af_allowlist "$FI_AF_TESTCMD"
  fi_af_fixer_cmd "$engine" "$(fi_af_fixer_prompt "$FI_AF_TESTCMD" "$feedback" "$engine")" "$base.last"
  fi_af_child "$base.out" "$base.err" "$AFI_wt" "${FI_AF_CMD[@]}" || rc=$?
  fi_af_collect "$engine" "$base.out" "$base.last"
  fi_af_parse_result "$FI_AF_TEXT"
  FI_AF_FIX_RC=$rc
  if [[ -z "$FI_AF_ENGINE_ERR" ]] && (( rc != 0 && rc != 124 )) && [[ "$FI_AF_RESULT" == "none" ]]; then
    FI_AF_ENGINE_ERR="$engine exited $rc: $(tail -n 1 "$base.err" 2>/dev/null)"
  fi
  (( rc == 124 )) && fi_af_log "$AFI_id" "attempt $n: fixer timed out"
  fi_af_log "$AFI_id" "attempt $n: fixer rc=$rc result=$FI_AF_RESULT"
}

_fi_af_verify() {
  local engine="$1" n="$2" base="$FI_AF_RUNS/$AFI_id.verify$n" rc=0
  fi_af_verifier_cmd "$engine" "$(fi_af_verifier_prompt "$(fi_af_diff "$AFI_wt" "${AFI_base_sha:-origin/$AFI_base}")")" \
    "$base.last" "$FI_AF_RUNS/verdict.schema.json"
  fi_af_child "$base.out" "$base.err" "$AFI_wt" "${FI_AF_CMD[@]}" || rc=$?
  fi_af_collect "$engine" "$base.out" "$base.last"
  fi_af_parse_verdict "$FI_AF_TEXT"
  fi_af_log "$AFI_id" "attempt $n: verifier rc=$rc approve=$FI_AF_APPROVE reason=$FI_AF_REASON"
}

_fi_af_reset_wt() {
  git -C "$AFI_wt" reset -q --hard "${AFI_base_sha:-origin/$AFI_base}" >/dev/null 2>&1 || true
  git -C "$AFI_wt" clean -qfd >/dev/null 2>&1 || true
}

# Every outcome records what the run spent (spec §8: status shows cost).
_fi_af_end() {
  local r="$FI_AF_ST/running/$1"
  if [[ -f "$r" ]]; then
    fi_af_item_set "$r" cost "$FI_AF_COST"
    fi_af_item_set "$r" tokens "$FI_AF_TOKENS"
  fi
  fi_af_finish "$@"
}

# Spec §5 for one claimed item: up to 2 attempts of fix -> bash tests ->
# verifier, then ship. Every path ends in _fi_af_end.
_fi_af_run_one() {
  local id="$1" engine_opt="$2" rc=0 engine n feedback="" why="" tlog
  fi_af_claim "$id" || return $?
  fi_af_item_read "$FI_AF_ST/running/$id"
  FI_AF_COST=0 FI_AF_TOKENS=0
  if ! FI_AF_TESTCMD="$(fi_af_test_command "$AFI_wt")"; then
    _fi_af_end "$id" manual "no test command"; return 0
  fi
  if ! engine="$(fi_af_engine "${engine_opt:-$AFI_engine}")" || ! command -v "$engine" >/dev/null 2>&1; then
    _fi_af_end "$id" failed "no ${engine:-claude or codex} on PATH"; return 0
  fi
  AFI_engine="$engine"
  for n in 1 2; do
    touch "$FI_AF_ST/lock" 2>/dev/null || true
    if [[ "$engine" == "claude" ]] && ! fi_af_budget_left >/dev/null; then
      why="run budget spent (\$$FI_AF_COST)"; break
    fi
    (( n == 1 )) || _fi_af_reset_wt
    _fi_af_fix_attempt "$engine" "$n" "$feedback"
    # An outage (usage limit, logged out, network) is not an attempt: the
    # item goes back to the queue untagged and the drain stops (rc 7).
    if [[ -n "$FI_AF_ENGINE_ERR" ]] \
       && [[ -z "$(fi_af_diff "$AFI_wt" "${AFI_base_sha:-origin/$AFI_base}")" ]]; then
      FI_AF_WHY="$FI_AF_ENGINE_ERR"
      fi_af_requeue "$id" "engine error: $FI_AF_ENGINE_ERR"
      return 7
    fi
    case "$FI_AF_RESULT" in
      already-fixed|decide)
        _fi_af_end "$id" "$FI_AF_RESULT" "${FI_AF_RESULT_TEXT:-no reason given}"
        return 0 ;;
      manual)
        # A fixer that changed code but could not prove it says manual; bash
        # runs the tests and the verifier anyway, so its change still counts.
        if [[ -z "$(fi_af_diff "$AFI_wt" "${AFI_base_sha:-origin/$AFI_base}")" ]]; then
          _fi_af_end "$id" manual "${FI_AF_RESULT_TEXT:-no reason given}"
          return 0
        fi
        fi_af_log "$id" "attempt $n: fixer said manual but left a change; testing and verifying it" ;;
    esac
    if [[ -z "$(fi_af_diff "$AFI_wt" "${AFI_base_sha:-origin/$AFI_base}")" ]]; then
      why="no change"; feedback="The attempt changed no files."; continue
    fi
    tlog="$FI_AF_RUNS/$id.tests$n.log"
    if ! fi_af_run_tests "$AFI_wt" "$FI_AF_TESTCMD" "$tlog"; then
      why="tests fail"; feedback="The test command failed. Last lines:"$'\n'"$(tail -n 20 "$tlog" 2>/dev/null)"
      continue
    fi
    if [[ "$engine" == "claude" ]] && ! fi_af_budget_left >/dev/null; then
      why="run budget spent (\$$FI_AF_COST)"; break
    fi
    _fi_af_verify "$engine" "$n"
    if [[ "$FI_AF_APPROVE" != "true" ]]; then
      why="verifier rejected: $FI_AF_REASON"; feedback="The reviewer rejected it: $FI_AF_REASON"; continue
    fi
    FI_AF_VERDICT_REASON="$FI_AF_REASON"
    if fi_af_ship; then
      fi_af_item_set "$FI_AF_ST/running/$id" pr "$FI_AF_PR"
      _fi_af_end "$id" shipped "PR #$FI_AF_PR, merge $FI_AF_MERGE, \$$FI_AF_COST"
      return 0
    fi
    _fi_af_end "$id" failed "ship: $FI_AF_WHY"
    return 0
  done
  case "$why" in
    "run budget spent"*) ;;
    *) why="$why after 2 attempts" ;;
  esac
  _fi_af_end "$id" failed "$why"
}

_fi_af_next_queued() {
  local f
  for f in "$FI_AF_ST"/queue/*; do
    [[ -f "$f" ]] && { printf '%s' "${f##*/}"; return 0; }
  done
  return 1
}

# A killed run takes its engine child (and the child's process group) with
# it; the item stays in running/ for the next claim to reap and requeue.
_fi_af_on_signal() {
  [[ -n "$FI_AF_CHILD_PGID" ]] && fi_af_kill_child "$FI_AF_CHILD_PGID"
  exit 143
}

# Launcher A: run <id>, then drain the queue while claims succeed.
_fi_af_run() {
  local id="$1" engine_opt="$2" rc next
  export FI_AF_PID=$$
  trap _fi_af_on_signal INT TERM HUP
  # A mistyped id must not silently drain everything else (operator
  # decision 2026-10-04, ledger lib/autofix.sh:150).
  if [[ ! -f "$FI_AF_ST/queue/$id" && ! -f "$FI_AF_ST/running/$id" ]]; then
    fi_err "autofix: no queued item $id"; return 1
  fi
  while [[ -n "$id" ]]; do
    # `autofix off` mid-drain stops before the next item, not after the queue.
    if ! fi_af_enabled; then
      printf 'Auto-fix: switched off (%s); %s stays queued.\n' "$FI_AF_WHY" "$id"; return 0
    fi
    rc=0
    _fi_af_run_one "$id" "$engine_opt" || rc=$?
    case $rc in
      # The capped marker tells the Stop-hook fallback not to relaunch today.
      3) : >"$FI_AF_ST/day/$(fi_today).capped" 2>/dev/null || true
         printf 'Auto-fix: daily cap reached; %s waits for tomorrow.\n' "$id"; return 3 ;;
      4) printf 'Auto-fix: another run holds this repo; %s stays queued.\n' "$id"; return 4 ;;
      7) printf 'Auto-fix: engine error (%s); %s stays queued.\n' "$FI_AF_WHY" "$id"; return 7 ;;
    esac
    [[ -f "$FI_AF_ST/done/$id" ]] && { fi_af_item_read "$FI_AF_ST/done/$id"; printf '%s: %s\n' "$id" "$AFI_result"; }
    next="$(_fi_af_next_queued || true)"
    # An item the claim could not move (rc 1 with its file still queued)
    # would come straight back: stop rather than spin.
    [[ "$next" == "$id" ]] && break
    id="$next"
  done
}

_fi_af_status() {
  local f n=0 line
  if fi_af_enabled; then printf 'Auto-fix: on (%s)\n' "$FI_AF_SLUG"
  else printf 'Auto-fix: off — %s\n' "$FI_AF_WHY"; fi
  if [[ -f "$FI_AF_ST/day/$(fi_today).spot" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do n=$((n + 1)); done <"$FI_AF_ST/day/$(fi_today).spot"
  fi
  printf 'Today: %s/%s spot fixes\n' "$n" "$(fi_af_int dailyFixes 5)"
  local dir label count
  for dir in queue running; do
    count=0
    for f in "$FI_AF_ST/$dir"/*; do [[ -f "$f" ]] && count=$((count + 1)); done
    label="Queued"; [[ "$dir" == running ]] && label="Running"
    printf '%s (%s)\n' "$label" "$count"
    for f in "$FI_AF_ST/$dir"/*; do
      [[ -f "$f" ]] || continue
      fi_af_item_read "$f"
      printf '  %s  %s\n' "$AFI_id" "$AFI_loc"
    done
  done
  printf 'Recent:\n'
  local -a recent=()
  for f in "$FI_AF_ST"/done/*; do [[ -f "$f" ]] && recent+=("$f"); done
  local i shown=0
  for (( i = ${#recent[@]} - 1; i >= 0 && shown < 5; i-- )); do
    fi_af_item_read "${recent[$i]}"
    printf '  %s  %s — %s\n' "$AFI_id" "$AFI_loc" "$AFI_result"
    shown=$((shown + 1))
  done
  return 0
}

cmd_autofix() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    on)
      fi_af_root
      rm -f "$FI_AF_ROOT/disabled"
      printf 'Auto-fix kill switch cleared. Auto-fix runs in repos where found-issues.autofix=true.\n' ;;
    off)
      fi_af_root
      mkdir -p "$FI_AF_ROOT"
      : >"$FI_AF_ROOT/disabled"
      printf 'Auto-fix switched off in every repo (undo: found-issues autofix on).\n' ;;
    claim)
      [[ $# -eq 1 ]] || { fi_err "Usage: found-issues autofix claim <id>"; return 2; }
      fi_af_context || return 1
      fi_af_no_prompts
      local rc=0
      fi_af_claim "$1" || rc=$?
      case $rc in
        0) printf '%s\n' "$AFI_wt" ;;
        1) fi_err "autofix: no queued item $1" ;;
        3) fi_err "autofix: today's spot-fix cap is reached; $1 waits for tomorrow" ;;
        4) fi_err "autofix: another auto-fix run holds this repo; $1 stays queued" ;;
        5) fi_err "autofix: $1 retired — $FI_AF_WHY" ;;
        6) fi_err "autofix: $1 failed — $FI_AF_WHY" ;;
      esac
      return $rc ;;
    release)
      local rid="${1:-}" outcome="" text=""
      [[ $# -gt 0 ]] && shift
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --already-fixed|--decide|--manual|--failed)
            [[ -z "$outcome" ]] || { fi_err "autofix release: one outcome only"; return 2; }
            fi_need_value "autofix release" "$1" $# "${2:-}" || return 2
            outcome="${1#--}"; text="$2"; shift 2 ;;
          *) fi_unknown_arg "autofix release" "$1"; return 2 ;;
        esac
      done
      if [[ -z "$rid" || -z "$outcome" ]]; then
        fi_err "Usage: found-issues autofix release <id> --already-fixed|--decide|--manual|--failed \"<text>\""
        return 2
      fi
      fi_af_context || return 1
      [[ -f "$FI_AF_ST/running/$rid" || -f "$FI_AF_ST/queue/$rid" ]] || { fi_err "autofix: no queued or running item $rid"; return 1; }
      fi_af_finish "$rid" "$outcome" "$text" ;;
    diff|ship)
      [[ $# -eq 1 ]] || { fi_err "Usage: found-issues autofix $sub <id>"; return 2; }
      fi_af_context || return 1
      fi_af_item_read "$FI_AF_ST/running/$1" || { fi_err "autofix: $1 is not claimed"; return 1; }
      fi_af_touch_lock "$1"
      if [[ "$sub" == "diff" ]]; then fi_af_diff "$AFI_wt" "${AFI_base_sha:-origin/$AFI_base}"; return; fi
      fi_af_no_prompts
      if fi_af_ship; then
        printf 'Shipped %s as PR #%s (merge: %s)\n' "$1" "$FI_AF_PR" "$FI_AF_MERGE"
        fi_af_finish "$1" shipped "PR #$FI_AF_PR, merge $FI_AF_MERGE"
      else
        fi_err "autofix: ship refused — $FI_AF_WHY"
        return 1
      fi ;;
    merge-when-green)
      local mpr="${1:-}" mrepo=""
      [[ $# -gt 0 ]] && shift
      if [[ "${1:-}" == "--repo" && -n "${2:-}" ]]; then mrepo="$2"; shift 2; fi
      [[ $# -eq 0 && "$mpr" =~ ^[0-9]+$ ]] || { fi_err "Usage: found-issues autofix merge-when-green <PR-number> [--repo owner/name]"; return 2; }
      fi_af_no_prompts
      fi_af_merge_when_green "$mpr" "$mrepo" ;;
    brief|test)
      [[ $# -eq 1 ]] || { fi_err "Usage: found-issues autofix $sub <id>"; return 2; }
      fi_af_context || return 1
      fi_af_b_running "$1" || return 1
      if [[ "$sub" == brief ]]; then fi_af_brief; else fi_af_b_test "$1"; fi ;;
    run)
      local rid="${1:-}" eng=""
      [[ $# -gt 0 ]] && shift
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --engine) fi_need_value "autofix run" --engine $# "${2:-}" || return 2; eng="$2"; shift 2 ;;
          --engine=*) eng="${1#--engine=}"; shift ;;
          *) fi_unknown_arg "autofix run" "$1"; return 2 ;;
        esac
      done
      [[ -n "$rid" ]] || { fi_err "Usage: found-issues autofix run <id> [--engine claude|codex]"; return 2; }
      case "$eng" in ""|claude|codex) ;; *) fi_err "autofix run: --engine takes claude or codex"; return 2 ;; esac
      fi_af_context || return 1
      fi_af_enabled || { fi_err "autofix: not running — $FI_AF_WHY"; return 1; }
      fi_af_no_prompts
      _fi_af_run "$rid" "$eng" ;;
    status)
      fi_af_context || return 1
      _fi_af_status ;;
    ""|-h|--help|help) _fi_af_usage ;;
    *) fi_unknown_arg autofix "$sub"; return 2 ;;
  esac
}
