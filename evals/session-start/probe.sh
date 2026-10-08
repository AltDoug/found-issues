#!/usr/bin/env bash
# probe.sh -- injection probes for the session-start eval (paid: haiku, max $0.30 each).
#
# One haiku run per arm, in a fresh fixture copy, with the same flags as the
# real runs (plugin-dir, setting-sources, permission args, arm env). It asks
# how many times a string appears in the model's context and asserts the answer.
#
# Usage:
#   probe.sh --out DIR [--fixture calc] [--only-arm NAME]...
#            [--arm NAME=DIR]... [--arm-env NAME:KEY=VAL]...
#            [--is-in STRING | --is-not-in STRING]
#
# Default check: the fixture's probe token (fixtures/<fx>/probe.txt, held by
# the path-less [open] ledger entry that every arm injects) appears EXACTLY
# once. --is-in STRING: STRING appears at least once. --is-not-in STRING:
# it appears zero times (e.g. a string only the full rules carry, to prove an
# arm's FOUND_ISSUES_SESSION_CONTEXT env reached the hook). Exit 0 only when
# every checked arm passes; cost goes to <out>/cost.txt and counts toward the cap.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

fx=calc mode=token needle="" only=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) EVAL_OUT="$2"; shift 2 ;;
    --fixture) fx="$2"; shift 2 ;;
    --only-arm) only="$only $2"; shift 2 ;;
    --is-in) mode=in; needle="$2"; shift 2 ;;
    --is-not-in) mode=notin; needle="$2"; shift 2 ;;
    --arm|--arm-env) fi_eval_arm_opt "$1" "${2:-}"; shift 2 ;;
    *) fi_eval_die "unknown argument '$1'" ;;
  esac
done
fi_eval_require_out
fi_eval_arms_finalize
[[ -d "$HERE/fixtures/$fx" ]] || fi_eval_die "no fixture '$fx'"
if [[ "$mode" == token ]]; then
  needle="$(tr -d '[:space:]' < "$HERE/fixtures/$fx/probe.txt")"
  [[ -n "$needle" ]] || fi_eval_die "empty probe token for $fx"
fi
arms="${only:-$(fi_eval_arm_names)}"
PROBE_BUDGET=0.30

failed=0
for arm in $arms; do
  [[ -n "$(fi_eval_arm_field "$arm" 1)" ]] || fi_eval_die "unknown arm '$arm'"
  if ! fi_eval_cost_room "$PROBE_BUDGET"; then
    echo "STOP before probe $arm: cumulative cost $(fi_eval_cost_total) + $PROBE_BUDGET would pass cap $EVAL_COST_CAP"
    exit 3
  fi
  work="$EVAL_OUT/probe/$arm"
  rm -rf "${work:?}"
  bash "$HERE/fixtures/$fx/setup.sh" "$work" >/dev/null 2>&1 || fi_eval_die "setup failed for probe $arm"
  json="$EVAL_OUT/probe/$arm.json"
  prompt="Not counting this question itself, how many times does the exact string ${needle} appear in your context? Reply with the number alone on the first line. Then, on following lines, quote the full text line of each occurrence."
  # shellcheck disable=SC2086
  fi_eval_claude "$arm" "$work" haiku "$PROBE_BUDGET" 2 $EVAL_PERM -- "$prompt" > "$json" 2> "$json.err"
  rc=$?
  cost="$(jq -r '.total_cost_usd // empty' "$json" 2>/dev/null || true)"
  [[ -n "$cost" ]] || cost="$PROBE_BUDGET"
  fi_eval_cost_add "probe-$arm-$mode" "$cost"
  first="$(jq -r '.result // ""' "$json" 2>/dev/null | head -n 1 | tr -d '[:space:]*')"
  if [[ ! "$first" =~ ^[0-9]+$ ]]; then
    echo "FAIL $arm: could not read a count from the answer (rc=$rc, first line '${first}'); see $json"
    failed=1; continue
  fi
  case "$mode" in
    token) want="exactly 1"; (( first == 1 )) && okp=1 || okp=0 ;;
    in)    want=">= 1";      (( first >= 1 )) && okp=1 || okp=0 ;;
    notin) want="0";         (( first == 0 )) && okp=1 || okp=0 ;;
  esac
  if (( okp )); then echo "PASS $arm: '$needle' appears $first time(s) (want $want), cost $cost"
  else echo "FAIL $arm: '$needle' appears $first time(s) (want $want), cost $cost; see $json"; failed=1; fi
done
exit "$failed"
