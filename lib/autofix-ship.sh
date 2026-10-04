#!/usr/bin/env bash
# autofix-ship.sh — turn a verified worktree into a self-merging PR
# (spec 2026-10-03 §5 step 6; audit prompt-9: the (PR:) annotation is
# committed onto the PR branch so it reaches the default branch).
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   fi_af_ledger_paths <wt>
#   fi_af_reset_ledger <wt> <base>
#   fi_af_diff <wt> <base>
#   fi_af_run_tests <wt> <cmd> <log>
#   fi_af_annotate_ledger <ledger|""> <annotation>
#   fi_af_spawn <cwd> <found-issues args...>
#   fi_af_ship
#   fi_af_merge_when_green <N>

# shellcheck disable=SC2154  # AFI_*/FE_* come from autofix-queue.sh / parse-entries.sh

FI_AF_PR="" FI_AF_MERGE="" FI_AF_TESTCMD="" FI_AF_VERDICT_REASON=""
FI_SELF="${FI_BIN_DIR:-}/found-issues"

# The worktree's own ledger files, relative. Only paths INSIDE the worktree:
# fi_find_issues_file would walk up into the source checkout when the
# worktree has none (Review Focus 2).
fi_af_ledger_paths() {
  local p
  for p in docs/found-issues.md docs/found-issues-archive.md .found-issues.md; do
    [[ -f "$1/$p" ]] && printf '%s\n' "$p"
  done
  return 0
}

# The fixer must not change the ledger, and a headless child's SessionStart
# sync may have (Review Focus 3). Put every ledger file back to origin.
fi_af_reset_ledger() {
  local wt="$1" base="$2" p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if git -C "$wt" cat-file -e "origin/$base:$p" 2>/dev/null; then
      git -C "$wt" checkout -q "origin/$base" -- "$p" 2>/dev/null || true
    else
      rm -f "$wt/$p"
    fi
  done <<<"$(fi_af_ledger_paths "$wt")"
}

fi_af_diff() {
  fi_af_reset_ledger "$1" "$2"
  git -C "$1" add -A >/dev/null 2>&1 || true
  git -C "$1" diff --cached "origin/$2"
}

fi_af_run_tests() {
  fi_af_child "$3" "$3.err" "$1" bash -c "$2" || return $?
}

# Append a closing annotation to THIS item's entry (matched by dedup key) in
# <ledger> ("" = the source checkout's). `annotate-pr --pick <loc>` matches
# by location, so with two entries on one line it tags the wrong one or both.
fi_af_annotate_ledger() {
  fi_af_find_entry "$1" || return 1
  local new="$FI_AF_ENTRY $2" snapshot tmp line done_one=0
  snapshot="$(fi_ledger_snapshot "$FI_AF_LEDGER")"
  tmp="$(fi_ledger_tmp "$FI_AF_LEDGER")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( ! done_one )) && [[ "$line" == "$FI_AF_ENTRY" ]]; then
      printf '%s\n' "$new" >>"$tmp"; done_one=1
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$FI_AF_LEDGER"
  fi_ledger_replace "$FI_AF_LEDGER" "$tmp" "$snapshot"
}

fi_af_spawn() {
  local cwd="$1"
  shift
  ( cd "$cwd" && nohup "$FI_SELF" "$@" </dev/null >>"$FI_AF_RUNS/spawn.log" 2>&1 & )
}

_fi_af_pr_body() {
  local tlog="$1"
  printf 'Unattended fix by found-issues auto-fix (launcher A, engine %s).\n\n' "${AFI_engine:-?}"
  printf 'Issue:\n\n    %s\n\n' "$AFI_entry"
  printf 'Tests: `%s` passed. Last lines:\n\n' "$FI_AF_TESTCMD"
  tail -n 15 "$tlog" 2>/dev/null | sed 's/^/    /'
  printf '\nVerifier: approved — %s\n' "${FI_AF_VERDICT_REASON:-n/a}"
  printf 'Run cost: $%s (claude), %s tokens (codex)\n\n' "${FI_AF_COST:-0}" "${FI_AF_TOKENS:-0}"
  printf 'This PR merges itself when its checks pass (found-issues auto-fix policy).\n'
}

fi_af_ship() {
  local wt="$AFI_wt" base="$AFI_base" br="$AFI_branch" runlog="$FI_AF_RUNS/$AFI_id.log"
  local tlog="$FI_AF_RUNS/$AFI_id.ship-tests.log" bodyf="$FI_AF_RUNS/$AFI_id.pr-body.md" frag url p
  FI_AF_PR="" FI_AF_MERGE="none" FI_AF_WHY=""
  [[ -n "$FI_AF_TESTCMD" ]] || FI_AF_TESTCMD="$(fi_af_test_command "$wt")" || { FI_AF_WHY="no test command"; return 1; }
  fi_af_reset_ledger "$wt" "$base"
  fi_af_run_tests "$wt" "$FI_AF_TESTCMD" "$tlog" || { FI_AF_WHY="tests fail at ship"; return 1; }
  git -C "$wt" add -A
  if git -C "$wt" diff --cached --quiet "origin/$base"; then FI_AF_WHY="nothing to ship"; return 1; fi
  fi_parse_entry_vars "$AFI_entry" || true
  frag="${FE_symptom:-$AFI_loc}"
  frag="${frag:0:60}"
  git -C "$wt" commit -q -m "fix: $frag (found-issues $AFI_loc)" >>"$runlog" 2>&1 \
    || { FI_AF_WHY="git commit refused (a commit hook?)"; return 1; }
  git -C "$wt" push -q -u origin "$br" >>"$runlog" 2>&1 || { FI_AF_WHY="git push failed"; return 1; }
  _fi_af_pr_body "$tlog" >"$bodyf"
  url="$(cd "$wt" && gh pr create --base "$base" --head "$br" --title "fix: $frag" --body-file "$bodyf" 2>>"$runlog")" \
    || { FI_AF_WHY="gh pr create failed"; return 1; }
  FI_AF_PR="${url##*/}"
  [[ "$FI_AF_PR" =~ ^[0-9]+$ ]] || { FI_AF_WHY="no PR number in: $url"; return 1; }
  fi_af_log "$AFI_id" "opened PR #$FI_AF_PR"

  local ann="(PR: $AFI_slug#$FI_AF_PR)" wl=""
  # The PR branch's ledger, when origin already has the entry (prompt-9).
  for p in docs/found-issues.md .found-issues.md; do
    [[ -f "$wt/$p" ]] && { wl="$p"; break; }
  done
  if [[ -n "$wl" ]] && fi_af_annotate_ledger "$wt/$wl" "$ann"; then
    git -C "$wt" add -- "$wl"
    if git -C "$wt" commit -q -m "docs(found-issues): annotate $AFI_loc with PR $FI_AF_PR" >>"$runlog" 2>&1; then
      git -C "$wt" push -q origin "$br" >>"$runlog" 2>&1 || fi_af_log "$AFI_id" "ledger annotation push failed"
    fi
  fi
  # The source checkout's ledger, where sync will close the entry on merge.
  fi_af_annotate_ledger "" "$ann" || fi_af_log "$AFI_id" "source ledger annotation failed"

  if ( cd "$wt" && gh pr merge "$FI_AF_PR" --auto --squash ) >>"$runlog" 2>&1; then
    FI_AF_MERGE="auto"
  else
    fi_af_spawn "$AFI_root" autofix merge-when-green "$FI_AF_PR"
    FI_AF_MERGE="merge-when-green"
  fi
  fi_af_log "$AFI_id" "merge: $FI_AF_MERGE"
}

fi_af_merge_when_green() {
  local n="$1" i v polls="${FOUND_ISSUES_AUTOFIX_MERGE_POLLS:-60}" pause="${FOUND_ISSUES_AUTOFIX_MERGE_SLEEP:-60}"
  local jqf='[.state, ([.statusCheckRollup[]? | (.conclusion // .state // "")] | if length == 0 then "none" elif any(. == "FAILURE" or . == "ERROR" or . == "CANCELLED" or . == "TIMED_OUT" or . == "ACTION_REQUIRED" or . == "STARTUP_FAILURE") then "fail" elif all(. == "SUCCESS" or . == "SKIPPED" or . == "NEUTRAL") then "green" else "pending" end)] | join(" ")'
  for (( i = 0; i < polls; i++ )); do
    v="$(gh pr view "$n" --json state,statusCheckRollup --jq "$jqf" 2>/dev/null || true)"
    case "$v" in
      MERGED*|CLOSED*) printf 'PR #%s is already %s\n' "$n" "${v%% *}"; return 0 ;;
      "OPEN none"|"OPEN green")
        gh pr merge "$n" --squash && { printf 'merged PR #%s\n' "$n"; return 0; }
        fi_err "autofix: merging PR #$n failed"; return 1 ;;
      "OPEN fail") fi_err "autofix: PR #$n checks failed — not merging"; return 1 ;;
    esac
    sleep "$pause"
  done
  fi_err "autofix: PR #$n still pending after $polls checks — not merging"
  return 1
}
