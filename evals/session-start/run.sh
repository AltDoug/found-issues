#!/usr/bin/env bash
# run.sh -- live A/B eval for the 3.4.0 session-start cut (spec section 9).
#
# Arms are a list: name + plugin dir + optional env. Default (see lib.sh):
#   old       <out>/arms/old   v3.3.1, made by prepare.sh
#   standard  this checkout
#   lean      this checkout, FOUND_ISSUES_SESSION_CONTEXT=lean
# Override with --arm NAME=DIR and --arm-env NAME:KEY=VAL (repeatable).
# Each run loads ONLY that arm's plugin:
#
#   claude -p --plugin-dir <arm> --setting-sources project,local ...
#
# Verified (3.4.0 Task 1): that pair of flags loads exactly one copy of
# found-issues (the installed plugin is enabled via USER settings, which
# --setting-sources project,local leaves out; the operator's ~/.claude/CLAUDE.md
# is left out too). For every arm each `*/found-issues/*/bin` dir is stripped
# from PATH (lib.sh), so each arm resolves its own co-located bin.
#
# Usage:
#   run.sh --out DIR [--only calc|parser|queue] [--runs N]
#          [--arm NAME=DIR]... [--arm-env NAME:KEY=VAL]...
#
# --out (or EVAL_OUT) is required. DIR/manifest.txt records the build behind
# the outputs; resuming into a DIR whose manifest differs from the current
# build is refused (exit 5) -- use a fresh --out for a new build.
#
# Order: run index, then fixture, then arm; the arm order rotates with the run
# index (arm k starts run i at offset (i-1) mod N), so API or cache drift over
# the hours lands on every arm alike. Sequential, never parallel. Re-running
# resumes: a run whose JSON already holds a total_cost_usd is skipped. A run
# that timed out or left no usable JSON is charged the full per-run budget
# against the cap. Stops before a run that could take the cumulative cost
# (probes included, in <out>/cost.txt) past $EVAL_COST_CAP.
#
# Per run, under <out>/runs:
#   <arm>-<fx>-<i>.json    claude's JSON result (usage, cost, result text)
#   <arm>-<fx>-<i>.ledger0.md / .ledger.md   ledger before / after
#   <arm>-<fx>-<i>.task    exit code of `sh test.sh` afterwards
#   <arm>-<fx>-<i>.diff    git diff of the working tree
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

only="" runs=5
fixtures="calc parser queue"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) only="$2"; shift 2 ;;
    --runs) runs="$2"; shift 2 ;;
    --out) EVAL_OUT="$2"; shift 2 ;;
    --arm|--arm-env) fi_eval_arm_opt "$1" "${2:-}"; shift 2 ;;
    *) fi_eval_die "unknown argument '$1'" ;;
  esac
done
[[ -n "$only" ]] && fixtures="$only"
fi_eval_require_out
fi_eval_arms_finalize
arms="$(fi_eval_arm_names)"
narms=$(echo $arms | wc -w | tr -d ' ')
fi_eval_manifest_check || exit 5

out="$EVAL_OUT/runs"
mkdir -p "$out" "$EVAL_OUT/work"

done_ok() { [[ -s "$1" ]] && jq -e '.total_cost_usd != null' "$1" >/dev/null 2>&1; }

i=1
while (( i <= runs )); do
  # rotate the arm order by the run index
  rot=""
  arm_list=($arms)
  k=0
  while (( k < narms )); do
    rot="$rot ${arm_list[$(( (k + i - 1) % narms ))]}"
    k=$((k + 1))
  done
  for fx in $fixtures; do
    for arm in $rot; do
      tag="$arm-$fx-$i"
      if done_ok "$out/$tag.json"; then
        echo "skip $tag (done)"
        continue
      fi
      if ! fi_eval_cost_room; then
        echo "STOP before $tag: cumulative cost $(fi_eval_cost_total) + $EVAL_RUN_BUDGET would pass cap $EVAL_COST_CAP"
        exit 3
      fi
      work="$EVAL_OUT/work/$tag"
      rm -rf "${work:?}"
      bash "$HERE/fixtures/$fx/setup.sh" "$work" >/dev/null 2>&1 || { echo "setup failed for $tag" >&2; exit 4; }
      cp "$work/docs/found-issues.md" "$out/$tag.ledger0.md"
      echo "run  $tag  (cost so far $(fi_eval_cost_total))"
      # shellcheck disable=SC2086
      fi_eval_claude "$arm" "$work" "$EVAL_MODEL" "$EVAL_RUN_BUDGET" "$EVAL_TURNS" $EVAL_PERM \
        -- "$(cat "$HERE/fixtures/$fx/task.md")" > "$out/$tag.json" 2> "$out/$tag.err"
      rc=$?
      echo "     rc=$rc"
      cost="$(jq -r '.total_cost_usd // empty' "$out/$tag.json" 2>/dev/null || true)"
      if [[ -z "$cost" ]]; then
        # timed out, crashed, or no JSON: charge the full budget, never 0
        cost="$EVAL_RUN_BUDGET"
        echo "     NO USABLE RESULT (rc=$rc): charging $cost; the run will be retried on resume"
      fi
      fi_eval_cost_add "$tag" "$cost"
      cp "$work/docs/found-issues.md" "$out/$tag.ledger.md"
      (cd "$work" && sh test.sh >/dev/null 2>&1; echo $? > "$out/$tag.task")
      git -C "$work" diff > "$out/$tag.diff" 2>/dev/null
      echo "     cost=$cost task=$(cat "$out/$tag.task") total=$(fi_eval_cost_total)"
    done
  done
  i=$((i + 1))
done
echo "run.sh finished; total cost $(fi_eval_cost_total)"
