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
#   fi_af_sweep_brief
#   fi_af_brief
#   fi_af_b_test <id>
#   fi_af_b_verify <id>
#   fi_af_search <worktree> <regex> [<path>...] | --files [<path>...]

# shellcheck disable=SC2154  # AFI_* are set by fi_af_item_read (autofix-queue.sh)

# A B fixer has no long-lived pid; a fresh lock is what marks it alive.
fi_af_touch_lock() {
  local owner=""
  [[ -f "$FI_AF_ST/lock/owner" ]] && IFS= read -r owner <"$FI_AF_ST/lock/owner"
  [[ "$owner" == "$1" ]] && touch "$FI_AF_ST/lock" 2>/dev/null
  return 0
}

# A sweep also loads its current entry (AFI_entry empty when none is left).
fi_af_b_running() {
  fi_af_item_read "$FI_AF_ST/running/$1" || { fi_err "autofix: $1 is not claimed (run: found-issues autofix claim $1)"; return 1; }
  fi_af_touch_lock "$1"
  if [[ "$AFI_kind" == "sweep" ]]; then
    # A full batch hands out no more entries: next and verify say ship.
    if [[ "$AFI_more" == 1 ]]; then AFI_entry=""; else fi_af_sweep_load "$1" || AFI_entry=""; fi
  fi
  return 0
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
  [[ "$AFI_kind" == "sweep" ]] && { fi_af_sweep_brief; return; }
  t="$(fi_af_test_command "$AFI_wt" 2>/dev/null || printf '(none found)')"
  cat <<EOF
found-issues auto-fix brief for item ${AFI_id}. This run is sanctioned: the user
enabled found-issues auto-fix. Nobody will answer questions.

Issue (from the repo's found-issues ledger):
${AFI_entry}

Worktree: ${AFI_wt}
Branch:   ${AFI_branch} (from origin/${AFI_base}; never main)
Test command (bash runs it for you): ${t}

Edit ONLY files under the worktree path above, with Read, Edit and Write,
always by absolute path; search with autofix search below. Never edit docs/found-issues.md or any
found-issues ledger. Your only Bash calls are these, each alone, exactly as
written (no cd, &&, |, git or gh), with a 600000 ms timeout:
  found-issues autofix search ${AFI_id} '<regex>' [<path>...]   search the worktree
  found-issues autofix search ${AFI_id} --files [<path>...]     list its files
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
  fi_af_test_report "$log" 30
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
# A sweep (phase 4 ruling 3) verifies its current entry against the last
# good commit: approval commits it at once (no window to change the tree);
# a second reject fails only that entry (5); a budget stop or an outage
# leaves it untouched and tells the sweeper to ship (6, 7).
fi_af_b_verify() {
  local id="$1" r="$FI_AF_ST/running/$1" engine n log p sweep=0
  if [[ "$AFI_kind" == "sweep" ]]; then
    sweep=1
    if [[ -z "$AFI_entry" ]]; then
      printf 'no entry in progress: run found-issues autofix ship %s\n' "$id"; return 2
    fi
  fi
  if [[ -z "$(fi_af_diff "$AFI_wt" "${AFI_base_sha:-origin/$AFI_base}")" ]]; then
    printf 'nothing to verify: the worktree has no change\n'; return 2
  fi
  # Before the tests and the paid verifier: see _fi_af_fix_loop.
  if (( sweep )) && p="$(_fi_af_sweep_skip_hit "$AFI_wt" "${AFI_head:-${AFI_base_sha:-origin/$AFI_base}}")"; then
    FI_AF_WHY="touches $p (file in an earlier batch's PR)"
    fi_af_sweep_settle "$id" skipped-chain "$FI_AF_WHY"
    printf 'not verified (%s): entry skipped.\nNext: found-issues autofix next %s\n' "$FI_AF_WHY" "$id"; return 5
  fi
  FI_AF_TESTCMD="$(fi_af_test_command "$AFI_wt")" || { fi_err "autofix: no test command"; return 2; }
  log="$FI_AF_RUNS/$id.bverify-tests.log"
  if ! fi_af_tests_pass "$AFI_wt" "$FI_AF_TESTCMD" "$log"; then
    fi_af_test_report "$log" 20
    printf 'tests fail: fix them (found-issues autofix test %s) before verify\n' "$id"; return 3
  fi
  engine="$(fi_af_engine "${AFI_engine:-claude}")" || engine=claude
  _fi_af_chain_seed
  if ! fi_af_run_budget_left "$engine"; then
    if (( sweep )); then
      printf '%s: run found-issues autofix ship %s\n' "$(fi_af_spent_text "$engine")" "$id"; return 6
    fi
    fi_af_finish "$id" failed "$(fi_af_spent_text "$engine")"
    printf 'failed: run budget spent; stop\n'; return 6
  fi
  n=$(( ${AFI_attempts:-0} + 1 ))
  _fi_af_verify "$engine" "$n"
  _fi_af_chain_save "$r"
  if [[ -n "$FI_AF_ENGINE_ERR" ]]; then
    if (( sweep )); then
      printf 'verifier unavailable (%s): run found-issues autofix ship %s\n' "$FI_AF_ENGINE_ERR" "$id"; return 7
    fi
    fi_af_requeue "$id" "verifier unavailable: $FI_AF_ENGINE_ERR"
    printf 'verifier unavailable (%s): the item is requeued; stop\n' "$FI_AF_ENGINE_ERR"; return 7
  fi
  fi_af_item_set "$r" attempts "$n"
  fi_af_item_set "$r" verdict_reason "$FI_AF_REASON"
  fi_af_touch_lock "$id"
  if [[ "$FI_AF_APPROVE" == "true" ]] && (( sweep )); then
    FI_AF_VERDICT_REASON="$FI_AF_REASON"
    local crc=0
    fi_af_sweep_commit "$id" || crc=$?
    if (( crc == 2 )); then
      printf 'not committed (%s): entry skipped.\nNext: found-issues autofix next %s\n' "$FI_AF_WHY" "$id"; return 5
    elif (( crc != 0 )); then
      fi_af_sweep_settle "$id" failed "commit: $FI_AF_WHY"
      printf 'not committed (%s): entry marked failed.\nNext: found-issues autofix next %s\n' "$FI_AF_WHY" "$id"; return 5
    fi
    if _fi_af_sweep_close_if_full "$id" "$engine"; then
      printf 'approved and committed: %s\nsweep: batch %s closes at %s fixes.\nNext: found-issues autofix ship %s\n' \
        "$FI_AF_REASON" "$(_fi_af_sweep_batch_no)" "$AFI_fixed" "$id"; return 0
    fi
    printf 'approved and committed: %s\nNext: found-issues autofix next %s\n' "$FI_AF_REASON" "$id"; return 0
  fi
  if [[ "$FI_AF_APPROVE" == "true" ]]; then
    fi_af_item_set "$r" verdict_tree "$FI_AF_TREE"
    fi_af_item_set "$r" verdict approve
    printf 'approved: %s\nNext: found-issues autofix ship %s\n' "$FI_AF_REASON" "$id"; return 0
  fi
  fi_af_item_set "$r" verdict reject
  if (( n >= 2 )) && (( sweep )); then
    fi_af_sweep_settle "$id" failed "verifier rejected: $FI_AF_REASON after 2 attempts"
    printf 'rejected twice (%s): entry marked failed.\nNext: found-issues autofix next %s\n' "$FI_AF_REASON" "$id"; return 5
  fi
  if (( n >= 2 )); then
    fi_af_finish "$id" failed "verifier rejected: $FI_AF_REASON after 2 attempts"
    printf 'rejected twice (%s): the item is marked failed; stop\n' "$FI_AF_REASON"; return 5
  fi
  printf 'rejected: %s\nOne attempt left: revise, run found-issues autofix test %s, then verify again.\n' "$FI_AF_REASON" "$id"
  return 1
}

fi_af_sweep_brief() {
  local t n=0 line
  t="$(fi_af_test_command "$AFI_wt" 2>/dev/null || printf '(none found)')"
  while IFS= read -r line || [[ -n "$line" ]]; do n=$((n + 1)); done <"$FI_AF_ST/sweeps/$AFI_id.entries"
  cat <<BRIEF
found-issues auto-fix sweep ${AFI_id}. This run is sanctioned: the user enabled
found-issues auto-fix. Nobody will answer questions.

Worktree: ${AFI_wt}
Branch:   ${AFI_branch} (from origin/${AFI_base}; never main)
Entries:  ${n}, fixed one at a time in the order given
Test command (bash runs it for you): ${t}

Edit ONLY files under the worktree path above, with Read, Edit and Write,
always by absolute path; search with autofix search below. Never edit docs/found-issues.md or any
found-issues ledger. Your only Bash calls are these, each alone, exactly as
written (no cd, &&, |, git or gh), with a 600000 ms timeout:
  found-issues autofix next ${AFI_id}      the entry to fix now
  found-issues autofix search ${AFI_id} '<regex>' [<path>...]   search the worktree
  found-issues autofix search ${AFI_id} --files [<path>...]     list its files
  found-issues autofix test ${AFI_id}      run the test command in the worktree
  found-issues autofix verify ${AFI_id}    tests + reviewer; on approval bash commits this entry
  found-issues autofix release ${AFI_id} --already-fixed|--decide|--manual|--failed "<text>"
                                           give up on THIS entry and move on
  found-issues autofix ship ${AFI_id}      when next says no entries are left

Loop:
1. Run autofix next. If it says no entries are left, run autofix ship and stop.
2. Check the symptom is still present in the worktree. Already fixed: release
   --already-fixed "<evidence>". Needs a human decision: release --decide
   "<question>". No test can prove a fix: release --manual "<why>". Then go to 1.
3. Add or extend a test that fails because of this symptom; run autofix test.
4. Make the smallest change that fixes it. Change nothing unrelated.
5. Run autofix test until it passes.
6. Run autofix verify. Exit 0 or 5: go to 1. Exit 1: revise, autofix test,
   verify again. Exit 3: the tests fail; fix them, autofix test, verify
   again. Any other exit: run autofix ship and stop.
If you cannot fix an entry, release it with --failed "<why>" and go to 1.
End your reply with one line: the sweep id and its outcome.
BRIEF
}

# Read-only search for the unattended models (tracked and new untracked
# files, .gitignore honoured): some Claude Code builds give
# them no Grep/Glob tools, and rg/fd/git grep can each launch a program
# through their own flags (--pre, --exec, -O), so only this fixed form is
# allowed. The regex follows -e and paths follow --, so neither can become
# a flag. Exit: 0 matches, 1 none, 2 bad usage or a git error.
FI_AF_SEARCH_MAX=200
fi_af_search() {
  local wt="$1" out rc=0 n
  shift
  local g=(git -C "$wt" -c core.fsmonitor=false --no-pager)
  if [[ "${1:-}" == "--files" ]]; then
    shift
    out="$("${g[@]}" ls-files --cached --others --exclude-standard -- "$@" 2>&1)" || rc=2
  else
    [[ -n "${1:-}" ]] || { fi_err "Usage: found-issues autofix search <id> <regex> [<path>...] | --files [<path>...]"; return 2; }
    local re="$1"
    shift
    out="$("${g[@]}" grep --untracked -n -I -E -e "$re" -- "$@" 2>&1)" || rc=$?
    (( rc > 1 )) && rc=2
  fi
  if (( rc == 2 )); then fi_err "autofix search: ${out:-git failed}"; return 2; fi
  if [[ -z "$out" ]]; then printf 'no matches\n'; return 1; fi
  n="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  printf '%s\n' "$out" | head -n "$FI_AF_SEARCH_MAX"
  if (( n > FI_AF_SEARCH_MAX )); then
    printf '[%s more lines; narrow the regex or pass a path]\n' "$((n - FI_AF_SEARCH_MAX))"
  fi
  return 0
}
