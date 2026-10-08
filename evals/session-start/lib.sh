#!/usr/bin/env bash
# lib.sh -- shared helpers for the session-start A/B eval (sourced; bash 3.2 safe).
#
# Verified flags (3.4.0 Task 1 probe): `claude -p --plugin-dir <arm>
# --setting-sources project,local` loads exactly ONE copy of found-issues, the
# <arm> one. The installed plugin is enabled through USER settings, and
# `--setting-sources project,local` keeps those out.

EVAL_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_REPO="$(cd "$EVAL_HERE/../.." && pwd)"

: "${EVAL_SCRATCH:=/private/tmp/claude-501/-Users-diogosilvasena-Documents-projects-found-issues--claude-worktrees-v3-4-0/6d550577-a87c-4d61-9f40-c9c15ac730da/scratchpad/eval}"
: "${EVAL_OLD_DIR:=$EVAL_SCRATCH/old}"     # git archive v3.3.1 | tar -x -C ...
: "${EVAL_NEW_DIR:=$EVAL_REPO}"            # this branch
: "${EVAL_COST_FILE:=$EVAL_SCRATCH/cost.txt}"
: "${EVAL_COST_CAP:=18}"
: "${EVAL_RUN_BUDGET:=0.60}"

fi_eval_arm_dir() {
  case "$1" in
    old) printf '%s' "$EVAL_OLD_DIR" ;;
    new) printf '%s' "$EVAL_NEW_DIR" ;;
    *) return 1 ;;
  esac
}

# PATH without any installed found-issues plugin bin (*/found-issues/*/bin).
# v3.3.1's session-start hook injects no entries when a bare `found-issues` is
# on PATH, and this machine's PATH carries the installed 3.3.1 plugin bin.
# Each arm then falls back to its own co-located bin.
fi_eval_clean_path() {
  local out="" d IFS=:
  for d in $PATH; do
    case "$d" in
      */found-issues/*/bin) continue ;;
    esac
    out="${out:+$out:}$d"
  done
  printf '%s' "$out"
}

# Sum of the cost file (lines: "<label> <usd>").
fi_eval_cost_total() {
  [[ -f "$EVAL_COST_FILE" ]] || { printf '0'; return 0; }
  awk '{ s += $2 } END { printf "%.4f", s + 0 }' "$EVAL_COST_FILE"
}

fi_eval_cost_add() {  # <label> <usd>
  local usd
  usd="$(awk -v v="$2" 'BEGIN { printf "%.6f", v + 0 }')"
  [[ "$usd" =~ ^[0-9]+\.[0-9]+$ ]] || { echo "lib.sh: bad cost '$2' for $1" >&2; return 1; }
  mkdir -p "$(dirname "$EVAL_COST_FILE")"
  printf '%s %s\n' "$1" "$usd" >> "$EVAL_COST_FILE"
}

# True (0) when one more run at the full per-run budget still fits the cap.
fi_eval_cost_room() {
  awk -v t="$(fi_eval_cost_total)" -v b="$EVAL_RUN_BUDGET" -v c="$EVAL_COST_CAP" \
    'BEGIN { exit (t + b > c) ? 1 : 0 }'
}

# fi_eval_claude <arm> <cwd> <model> <budget> <max-turns> [extra claude args...] -- <prompt>
# Runs one headless claude with only that arm's plugin; JSON on stdout.
# Hard wall-clock cap of EVAL_RUN_TIMEOUT seconds (default 900).
fi_eval_claude() {
  local arm="$1" cwd="$2" model="$3" budget="$4" turns="$5"; shift 5
  local extra=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do extra+=("$1"); shift; done
  shift
  local prompt="$1" armdir cp
  armdir="$(fi_eval_arm_dir "$arm")" || return 2
  cp="$(fi_eval_clean_path)"
  (
    cd "$cwd" || exit 2
    PATH="$cp" FOUND_ISSUES_AUTOFIX=off \
      claude -p --plugin-dir "$armdir" --setting-sources project,local \
        --model "$model" --max-budget-usd "$budget" --max-turns "$turns" \
        --no-session-persistence --output-format json \
        ${extra[@]+"${extra[@]}"} "$prompt" &
    pid=$!
    ( sleep "${EVAL_RUN_TIMEOUT:-900}"; kill "$pid" 2>/dev/null ) &
    wd=$!
    wait "$pid"; rc=$?
    kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
    exit "$rc"
  )
}
