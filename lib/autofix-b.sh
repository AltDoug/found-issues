#!/usr/bin/env bash
# autofix-b.sh — launcher B's fixer-side CLI: the in-session found-issues-fixer
# agent drives one claimed item through single `found-issues autofix …` calls
# (spec 2026-10-03 §4.2-§4.3, §5; phase 3 plan rulings 1-2). The agent only
# edits files; bash runs the tests, the verifier, git, gh and the ledger.
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   fi_af_touch_lock <id>
#   fi_af_b_running <id>
#   fi_af_b_enabled <id>
#   fi_af_brief
#   fi_af_b_test <id>
#   fi_af_b_verify <id>

# shellcheck disable=SC2154  # AFI_* are set by fi_af_item_read (autofix-queue.sh)

# A B fixer has no long-lived pid; a fresh lock is what marks it alive.
fi_af_touch_lock() {
  local owner=""
  [[ -f "$FI_AF_ST/lock/owner" ]] && IFS= read -r owner <"$FI_AF_ST/lock/owner"
  [[ "$owner" == "$1" ]] && touch "$FI_AF_ST/lock" 2>/dev/null
  return 0
}

fi_af_b_running() {
  fi_af_item_read "$FI_AF_ST/running/$1" || { fi_err "autofix: $1 is not claimed (run: found-issues autofix claim $1)"; return 1; }
  fi_af_touch_lock "$1"
}

# `autofix off` (or the repo setting) mid-fix: verify and ship give the
# claimed item back untouched, so `autofix on` later retries it. Exit 8.
fi_af_b_enabled() {
  fi_af_enabled && return 0
  fi_af_requeue "$1" "switched off: $FI_AF_WHY"
  printf 'auto-fix is off (%s): the item is requeued; stop\n' "$FI_AF_WHY"
  return 8
}

fi_af_brief() {
  local t
  t="$(fi_af_test_command "$AFI_wt" 2>/dev/null || printf '(none found)')"
  cat <<EOF
found-issues auto-fix brief for item ${AFI_id}. This run is sanctioned: the user
enabled found-issues auto-fix. Nobody will answer questions.

Issue (from the repo's found-issues ledger):
${AFI_entry}

Worktree: ${AFI_wt}
Branch:   ${AFI_branch} (from origin/${AFI_base}; never main)
Test command (bash runs it for you): ${t}

Edit ONLY files under the worktree path above, with Read, Edit, Write, Grep
and Glob, always by absolute path. Never edit docs/found-issues.md or any
found-issues ledger. Your only Bash calls are these, each alone, exactly as
written (no cd, &&, |, git or gh), with a 600000 ms timeout:
  found-issues autofix test ${AFI_id}      run the test command in the worktree
  found-issues autofix verify ${AFI_id}    tests + independent reviewer on your change
  found-issues autofix ship ${AFI_id}      commit, push and open the fix PR
  found-issues autofix release ${AFI_id} --already-fixed|--decide|--manual|--failed "<text>"

Do exactly this:
1. Check the symptom is still present in the worktree. If it is already fixed,
   release with --already-fixed "<evidence>". If fixing it needs a human
   decision, release with --decide "<question>". If no test can prove a fix,
   release with --manual "<why>".
2. Add or extend a test that fails because of this symptom; run autofix test
   and see it fail.
3. Make the smallest change that fixes the symptom. Change nothing unrelated.
4. Run autofix test until it passes.
5. Run autofix verify. Exit 0 = approved: run autofix ship. Exit 1 = rejected
   with a reason and one attempt left: revise, autofix test, autofix verify
   again. Any other exit: the item is finished or requeued; stop.
6. If you cannot finish, release with --failed "<why>". If any command says
   the item is requeued or finished, stop.
End your reply with one line: the item id and its outcome.
EOF
}

fi_af_b_test() {
  local id="$1" t log rc=0 n=1
  t="$(fi_af_test_command "$AFI_wt")" || { fi_err "autofix: no test command for $id"; return 2; }
  while [[ -e "$FI_AF_RUNS/$id.btest$n.log" ]]; do n=$((n + 1)); done
  log="$FI_AF_RUNS/$id.btest$n.log"
  fi_af_run_tests "$AFI_wt" "$t" "$log" || rc=$?
  tail -n 30 "$log" 2>/dev/null
  tail -n 5 "$log.err" 2>/dev/null
  fi_af_touch_lock "$id"
  if (( rc == 0 )); then printf 'tests: pass\n'; else printf 'tests: fail (exit %s)\n' "$rc"; fi
  fi_af_log "$id" "b test $n: rc=$rc"
  return $rc
}

# Spec §5 steps 4-5 for launcher B: bash re-runs the tests, then the same
# headless read-only verifier launcher A uses. The verdict and the exact
# staged tree are recorded; ship refuses anything else (phase 3 ruling 2).
# Exit: 0 approved, 1 rejected (an attempt left), 2 nothing to verify,
# 3 tests fail (no attempt counted), 5 rejected twice (finished failed),
# 6 run budget spent (finished failed), 7 verifier unavailable (requeued),
# 8 auto-fix switched off (requeued, from cmd_autofix).
fi_af_b_verify() {
  local id="$1" r="$FI_AF_ST/running/$1" engine n log
  if [[ -z "$(fi_af_diff "$AFI_wt" "${AFI_base_sha:-origin/$AFI_base}")" ]]; then
    printf 'nothing to verify: the worktree has no change\n'; return 2
  fi
  FI_AF_TESTCMD="$(fi_af_test_command "$AFI_wt")" || { fi_err "autofix: no test command"; return 2; }
  log="$FI_AF_RUNS/$id.bverify-tests.log"
  if ! fi_af_run_tests "$AFI_wt" "$FI_AF_TESTCMD" "$log"; then
    tail -n 20 "$log" 2>/dev/null
    printf 'tests fail: fix them (found-issues autofix test %s) before verify\n' "$id"; return 3
  fi
  engine="$(fi_af_engine "${AFI_engine:-claude}")" || engine=claude
  FI_AF_COST="${AFI_cost:-0}" FI_AF_TOKENS="${AFI_tokens:-0}"
  if [[ "$engine" == claude ]] && ! fi_af_budget_left >/dev/null; then
    fi_af_finish "$id" failed "run budget spent (\$$FI_AF_COST)"
    printf 'failed: run budget spent; stop\n'; return 6
  fi
  n=$(( ${AFI_attempts:-0} + 1 ))
  _fi_af_verify "$engine" "$n"
  fi_af_item_set "$r" cost "$FI_AF_COST"
  fi_af_item_set "$r" tokens "$FI_AF_TOKENS"
  if [[ -n "$FI_AF_ENGINE_ERR" ]]; then
    fi_af_requeue "$id" "verifier unavailable: $FI_AF_ENGINE_ERR"
    printf 'verifier unavailable (%s): the item is requeued; stop\n' "$FI_AF_ENGINE_ERR"; return 7
  fi
  fi_af_item_set "$r" attempts "$n"
  fi_af_item_set "$r" verdict_reason "$FI_AF_REASON"
  fi_af_touch_lock "$id"
  if [[ "$FI_AF_APPROVE" == "true" ]]; then
    fi_af_item_set "$r" verdict_tree "$FI_AF_TREE"
    fi_af_item_set "$r" verdict approve
    printf 'approved: %s\nNext: found-issues autofix ship %s\n' "$FI_AF_REASON" "$id"; return 0
  fi
  fi_af_item_set "$r" verdict reject
  if (( n >= 2 )); then
    fi_af_finish "$id" failed "verifier rejected: $FI_AF_REASON after 2 attempts"
    printf 'rejected twice (%s): the item is marked failed; stop\n' "$FI_AF_REASON"; return 5
  fi
  printf 'rejected: %s\nOne attempt left: revise, run found-issues autofix test %s, then verify again.\n' "$FI_AF_REASON" "$id"
  return 1
}
