#!/usr/bin/env bash
# run.sh -- live A/B eval for the 3.4.0 session-start cut (spec section 9).
#
# Arms: old = v3.3.1 (git archive v3.3.1 | tar -x -C $EVAL_OLD_DIR),
#       new = this checkout. Each run loads ONLY that arm's plugin:
#
#   claude -p --plugin-dir <arm> --setting-sources project,local ...
#
# Verified (3.4.0 Task 1): that pair of flags loads exactly one copy of
# found-issues. The installed plugin is enabled via USER settings, which
# --setting-sources project,local leaves out. It also leaves out the
# operator's ~/.claude/CLAUDE.md (probed: a haiku run reports no
# "Universal Agent Instructions" and no "dougstation" in its context).
# For BOTH arms every `*/found-issues/*/bin` dir is stripped from PATH first
# (see lib.sh), so each arm resolves its own co-located bin.
#
# Usage:
#   run.sh [--only calc|parser|queue] [--runs N] [--arms "old new"]
#          [--out DIR] [--perm "<claude permission args>"]
#
# Order is interleaved (run index, then fixture, then arm) so API or cache
# drift over the hours the run takes lands on both arms alike. Sequential,
# never parallel. Re-running resumes: a run whose JSON already holds a
# total_cost_usd is skipped. Stops before a run that could take the
# cumulative cost (probes included, in $EVAL_COST_FILE) past $EVAL_COST_CAP.
#
# Per run, under $OUT:
#   <arm>-<fx>-<i>.json    claude's JSON result (usage, cost, result text)
#   <arm>-<fx>-<i>.ledger0.md / .ledger.md   ledger before / after
#   <arm>-<fx>-<i>.task    exit code of `sh test.sh` afterwards
#   <arm>-<fx>-<i>.diff    git diff of the working tree
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

only="" runs=5 arms="old new" out="$EVAL_SCRATCH/out"
# Bash and Skill must be allowed: logging is the /found-issues:log skill (it runs the CLI) and the task
# says to run `sh test.sh`; under acceptEdits alone -p denies every Bash and Skill call
# (measured in the dry runs). Same flags for both arms.
perm="--permission-mode acceptEdits --allowedTools=Bash,Skill"
fixtures="calc parser queue"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) only="$2"; shift 2 ;;
    --runs) runs="$2"; shift 2 ;;
    --arms) arms="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --perm) perm="$2"; shift 2 ;;
    *) echo "run.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[[ -n "$only" ]] && fixtures="$only"
mkdir -p "$out" "$EVAL_SCRATCH/work"

for arm in $arms; do
  d="$(fi_eval_arm_dir "$arm")" || { echo "run.sh: bad arm '$arm'" >&2; exit 2; }
  [[ -f "$d/hooks/session-start.sh" ]] || { echo "run.sh: $d is not a plugin checkout" >&2; exit 2; }
done

done_ok() { [[ -s "$1" ]] && jq -e '.total_cost_usd != null' "$1" >/dev/null 2>&1; }

i=1
while (( i <= runs )); do
  for fx in $fixtures; do
    for arm in $arms; do
      tag="$arm-$fx-$i"
      if done_ok "$out/$tag.json"; then
        echo "skip $tag (done)"
        continue
      fi
      if ! fi_eval_cost_room; then
        echo "STOP before $tag: cumulative cost $(fi_eval_cost_total) + $EVAL_RUN_BUDGET would pass cap $EVAL_COST_CAP"
        exit 3
      fi
      work="$EVAL_SCRATCH/work/$tag"
      rm -rf "${work:?}"
      bash "$HERE/fixtures/$fx/setup.sh" "$work" >/dev/null 2>&1 || { echo "setup failed for $tag" >&2; exit 4; }
      cp "$work/docs/found-issues.md" "$out/$tag.ledger0.md"
      echo "run  $tag  (cost so far $(fi_eval_cost_total))"
      # shellcheck disable=SC2086
      fi_eval_claude "$arm" "$work" sonnet "$EVAL_RUN_BUDGET" 30 $perm \
        -- "$(cat "$HERE/fixtures/$fx/task.md")" > "$out/$tag.json" 2> "$out/$tag.err"
      echo "     rc=$?"
      cost="$(jq -r '.total_cost_usd // 0' "$out/$tag.json" 2>/dev/null || echo 0)"
      [[ -n "$cost" ]] || cost=0
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
