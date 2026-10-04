#!/usr/bin/env bash
# autofix-status.sh — v3 auto-fix visibility and control: cancel, status,
# the statusline state file, the SessionStart summary and the doctor section
# (spec 2026-10-03 §8; phase 5 plan rulings 1-6, 9).
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   fi_af_cancel <id>

# shellcheck disable=SC2154  # AFI_*/FI_AF_* come from autofix-queue.sh / autofix-config.sh

# A pid we may signal: alive and running `found-issues … autofix run`.
_fi_af_is_run_pid() {
  local cmd
  [[ "$1" =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null || return 1
  cmd="$(ps -o command= -p "$1" 2>/dev/null || true)"
  [[ "$cmd" == *found-issues*"autofix run"* ]]
}

# Phase 5 ruling 6: retire a queued or running item as cancelled, stopping
# an A run and its engine child first. No ledger write.
fi_af_cancel() {
  local id="$1" r="$FI_AF_ST/running/$1" q="$FI_AF_ST/queue/$1" n=0 how
  if [[ -f "$FI_AF_ST/done/$id" ]]; then fi_err "autofix: $id already finished"; return 1; fi
  if [[ -f "$q" ]]; then
    fi_af_item_read "$q" || true
    fi_af_retire "$id" cancelled "by autofix cancel while queued"
    printf 'Cancelled %s (it was queued).\n' "$id"
    return 0
  fi
  [[ -f "$r" ]] || { fi_err "autofix: no queued or running item $id"; return 1; }
  fi_af_item_read "$r" || true
  how="by autofix cancel (in-session fixer)"
  if _fi_af_is_run_pid "$AFI_pid"; then
    how="by autofix cancel (background run $AFI_pid stopped)"
    kill -TERM "$AFI_pid" 2>/dev/null || true
    while kill -0 "$AFI_pid" 2>/dev/null && (( n < 40 )); do sleep 0.25; n=$((n + 1)); done
    kill -KILL "$AFI_pid" 2>/dev/null || true
  fi
  if [[ "$AFI_cpgid" =~ ^[0-9]+$ ]]; then
    kill -TERM -- "-$AFI_cpgid" 2>/dev/null || true
  fi
  # The run may have finished the item while it was stopping.
  if [[ ! -f "$r" ]]; then fi_err "autofix: $id already finished"; return 1; fi
  fi_af_item_read "$r" || true
  fi_af_worktree_remove
  fi_af_retire "$id" cancelled "$how"
  printf 'Cancelled %s.\n' "$id"
}
