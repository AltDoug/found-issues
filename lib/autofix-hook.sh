#!/usr/bin/env bash
# autofix-hook.sh — hook-side launchers for v3 auto-fix (spec 2026-10-03
# §4.1-§4.4): which launcher an AUTOFIX-QUEUED marker gets, the detached
# launcher A spawn, the launcher B nudge, and the Stop-hook fallback.
#
# Sourced by hooks/post-bash-dispatch.sh and hooks/stop-reminder.sh, after
# lib/autofix-queue.sh (fi_af_item_read / fi_af_item_set). Defines functions
# only. Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   fi_afh_state
#   fi_afh_launcher <harness> <permission_mode> <agent_id>
#   fi_afh_ids <text>
#   fi_afh_item <id> [<cwd>]
#   fi_afh_now
#   fi_afh_mark <item> <A|B> <epoch>
#   fi_afh_root_resolve <root> <ref-cwd> [<item>]
#   fi_afh_launch_a <item> <engine> <fi-bin> [<cwd>]
#   fi_afh_context_b <id> [<item>]
#   fi_afh_lock_fresh <lock-dir>
#   fi_afh_stop <payload> <engine> <fi-bin>

# shellcheck disable=SC2154  # AFI_* are set by fi_af_item_read (autofix-queue.sh)

FI_AFH_LAUNCHER="" FI_AFH_ITEM="" FI_AFH_NOW="" FI_AFH_DAY="" FI_AFH_ROOT=""
FI_AFH_IDS=()

fi_afh_state() { printf '%s' "${FOUND_ISSUES_STATE_DIR:-$HOME/.claude/found-issues}/autofix"; }

# Spec §4.2 table plus the §4.4 recursion guard. Launcher B only where a
# background subagent inherits a mode that never prompts (Claude Code docs,
# re-checked 2026-10-03: auto and bypassPermissions; acceptEdits still
# prompts for Bash). A missing mode is treated as one that prompts.
fi_afh_launcher() {
  local harness="$1" mode="$2" agent="$3"
  FI_AFH_LAUNCHER=none
  [[ "${FOUND_ISSUES_AUTOFIX_CHILD:-}" == "1" || -n "$agent" ]] && return 0
  FI_AFH_LAUNCHER=A
  [[ "$harness" == "codex" || "${FOUND_ISSUES_AUTOFIX_LAUNCHER:-}" == "headless" ]] && return 0
  case "$mode" in auto|bypassPermissions) FI_AFH_LAUNCHER=B ;; esac
  return 0
}

fi_afh_ids() {
  local rest="$1" id seen=" " re='AUTOFIX-(QUEUED|SWEEP-DUE)[[:space:]]+([0-9]{8}-[0-9]{6}-[0-9]{5})'
  FI_AFH_IDS=()
  while [[ "$rest" =~ $re ]]; do
    id="${BASH_REMATCH[2]}"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
    [[ "$seen" == *" $id "* ]] && continue
    seen+="$id "
    FI_AFH_IDS+=("$id")
  done
}

# The queued item for <id>, or fail. A marker re-printed for an id that was
# launched within the Stop grace is not relaunched (a duplicate B nudge, a
# reset launched=), and an item of another repo than <cwd> (default: the
# hook's own cwd) is not this session's to launch.
fi_afh_item() {
  local f ref="${2:-$PWD}"
  FI_AFH_ITEM=""
  [[ -n "$FI_AFH_NOW" ]] || fi_afh_now
  for f in "$(fi_afh_state)"/*/queue/"$1"; do
    [[ -f "$f" ]] || continue
    fi_af_item_read "$f" || continue
    if [[ "$AFI_launched" =~ ^[0-9]+$ ]] \
       && (( FI_AFH_NOW - AFI_launched < ${FOUND_ISSUES_AUTOFIX_STOP_GRACE:-60} )); then
      continue
    fi
    if [[ "$ref" != "$AFI_root" ]]; then
      fi_afh_root_resolve "$AFI_root" "$ref" "$f" || continue
      [[ "$ref" == "$FI_AFH_ROOT" ]] || [[ "$(fi_afh_common_dir "$FI_AFH_ROOT")" == "$(fi_afh_common_dir "$ref")" ]] || continue
    fi
    FI_AFH_ITEM="$f"; return 0
  done
  return 1
}

# bash 3.2 has no $EPOCHSECONDS: one date call for both values.
fi_afh_now() {
  local s
  s="$(date '+%s %Y-%m-%d')"
  FI_AFH_NOW="${s%% *}" FI_AFH_DAY="${s#* }"
}

fi_afh_mark() {
  fi_af_item_set "$1" launcher "$2" && fi_af_item_set "$1" launched "$3"
}

# The directory a run for an item rooted at <root> starts in. <root> itself
# when it exists. An item queued from a .claude/worktrees/<name> checkout that
# was removed since (reaper, session end) falls back to the main checkout, the
# prefix before the FIRST /.claude/worktrees/, when that is a git checkout of
# the same repo as <ref-cwd>. Anything else is refused. With <item>, a
# fallback is written back to it: the run reads root= for its worktree, ledger
# and git calls, and the dead path would fail every one of them; a wt= under
# the dead root went with it.
fi_afh_root_resolve() {
  local root="$1" ref="$2" item="${3:-}" main ref_git main_git
  FI_AFH_ROOT=""
  if [[ -d "$root" ]]; then FI_AFH_ROOT="$root"; return 0; fi
  [[ "$root" == */.claude/worktrees/* ]] || return 1
  main="${root%%/.claude/worktrees/*}"
  [[ -n "$main" && -d "$main" && -e "$main/.git" ]] || return 1
  ref_git="$(fi_afh_common_dir "$ref")" || return 1
  main_git="$(fi_afh_common_dir "$main")" || return 1
  [[ "$ref_git" == "$main_git" ]] || return 1
  FI_AFH_ROOT="$main"
  [[ -n "$item" ]] || return 0
  fi_af_item_set "$item" root "$main" || return 1
  [[ -z "$AFI_wt" ]] || fi_af_item_set "$item" wt "" || return 1
  AFI_root="$main" AFI_wt=""
}

# Detached and fd-clean: the session never waits on it and bats never hangs
# on an inherited fd 3.
fi_afh_launch_a() {
  local item="$1" engine="$2" bin="$3" log
  fi_af_item_read "$item" || return 1
  fi_afh_root_resolve "$AFI_root" "${4:-$PWD}" "$item" || return 1
  log="${item%/queue/*}/spawn.log"
  ( cd "$FI_AFH_ROOT" && nohup "$bin" autofix run "$AFI_id" --engine "$engine" \
      </dev/null >>"$log" 2>&1 3>&- & ) >/dev/null 2>&1
}

# <item> (optional) picks the agent: a kind=sweep item gets the sweeper.
fi_afh_context_b() {
  local line kind=""
  if [[ -n "${2:-}" && -f "$2" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" == kind=* ]] && { kind="${line#kind=}"; break; }
    done <"$2"
  fi
  if [[ "$kind" == "sweep" ]]; then
    cat <<EOF
## found-issues auto-fix: sweep $1 is queued

The user turned on found-issues auto-fix. Start the plugin agent
found-issues:found-issues-sweeper now, in the background, with model sonnet
(its own setting) and exactly this prompt:

  Run found-issues auto-fix sweep $1.

Do not fix anything yourself and do not wait for the agent; carry on with
your current task.
EOF
    return 0
  fi
  cat <<EOF
## found-issues auto-fix: item $1 is queued

The user turned on found-issues auto-fix. Start the plugin agent
found-issues:found-issues-fixer now, in the background, with model sonnet
(its own setting) and exactly this prompt:

  Fix found-issues auto-fix item $1.

Do not fix the issue yourself and do not wait for the agent; carry on with
your current task.
EOF
}

# A lock older than FOUND_ISSUES_AUTOFIX_LOCK_STALE belonged to a dead run
# (killed A run, B fixer out of turns); the run we start breaks it in
# fi_af_lock. Forks only while a lock exists.
fi_afh_lock_fresh() {
  local m
  m="$(stat -c %Y -- "$1" 2>/dev/null)" || m=""
  [[ "$m" =~ ^[0-9]+$ ]] || m="$(stat -f %m -- "$1" 2>/dev/null)" || m=""
  [[ "$m" =~ ^[0-9]+$ ]] || return 0
  (( FI_AFH_NOW - m < ${FOUND_ISSUES_AUTOFIX_LOCK_STALE:-3600} ))
}

# The physical path of <dir>'s git common dir: every worktree of one repo
# shares it. Fails outside a git checkout.
fi_afh_common_dir() {
  local d
  d="$(cd "$1" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null)" || return 1
  [[ -n "$d" ]] || return 1
  (cd "$1" && cd "$d" 2>/dev/null && pwd -P)
}

# Spec §4.3: an item still queued when the session stops gets launcher A, so
# a skipped launcher B nudge (or an item queued inside a fixer) never
# strands. Zero forks while the queue is empty: one glob, then return.
# Skipped: a fresh repo lock is held (a run is draining), today's cap was hit,
# or the item was launched less than FOUND_ISSUES_AUTOFIX_STOP_GRACE seconds
# ago (default 60; a B fixer may not have claimed yet).
fi_afh_stop() {
  local input="$1" engine="$2" bin="$3" st_root f st cwd cwd_git="" root_seen="" root_git="" eff v cap n line
  local re_agent='"agent_id"[[:space:]]*:[[:space:]]*"[^"]' re_cwd='"cwd"[[:space:]]*:[[:space:]]*"([^"\\]*)"'
  local -a items=()
  [[ "${FOUND_ISSUES_AUTOFIX_CHILD:-}" == "1" ]] && return 0
  case "${FOUND_ISSUES_AUTOFIX:-}" in off|0|false|no) return 0 ;; esac
  # fi_afh_state inlined: its $( ) would fork on every Stop.
  st_root="${FOUND_ISSUES_STATE_DIR:-$HOME/.claude/found-issues}/autofix"
  [[ -e "$st_root/disabled" ]] && return 0
  for f in "$st_root"/*/queue/*; do [[ -f "$f" ]] && items+=("$f"); done
  (( ${#items[@]} > 0 )) || return 0
  [[ "$input" =~ $re_agent ]] && return 0
  cwd="$PWD"
  [[ "$input" =~ $re_cwd ]] && cwd="${BASH_REMATCH[1]}"
  fi_afh_now
  for f in "${items[@]}"; do
    st="${f%/queue/*}"
    [[ -e "$st/day/$FI_AFH_DAY.capped" ]] && continue
    [[ -d "$st/lock" ]] && fi_afh_lock_fresh "$st/lock" && continue
    fi_af_item_read "$f" || continue
    [[ "$AFI_wait_next" =~ ^[0-9]+$ ]] && (( AFI_wait_next > FI_AFH_NOW )) && continue
    [[ -n "$AFI_root" ]] || continue
    # Same repo, any checkout (3.4.2): a sibling worktree or the main
    # checkout drains an item queued from a nested worktree, and a separate
    # repo nested under the root does not. A nested worktree that was removed
    # resolves to its main checkout (fi_afh_root_resolve). git forks only when
    # the cwd is not the root itself, once for the cwd and once per distinct
    # root.
    fi_afh_root_resolve "$AFI_root" "$cwd" || continue
    eff="$FI_AFH_ROOT"
    if [[ "$cwd" != "$eff" ]]; then
      [[ -n "$cwd_git" ]] || cwd_git="$(fi_afh_common_dir "$cwd")" || cwd_git="-"
      [[ "$cwd_git" != "-" ]] || continue
      if [[ "$eff" != "$root_seen" ]]; then
        root_seen="$eff"; root_git="$(fi_afh_common_dir "$eff")" || root_git="-"
      fi
      [[ "$root_git" == "$cwd_git" ]] || continue
    fi
    if [[ "$AFI_launched" =~ ^[0-9]+$ ]] \
       && (( FI_AFH_NOW - AFI_launched < ${FOUND_ISSUES_AUTOFIX_STOP_GRACE:-60} )); then
      continue
    fi
    # Per-repo switch: found-issues.autofix=false there means every run exits
    # 1 at once, so do not spawn one at every Stop.
    v="$(git -C "$eff" config --type=bool --get found-issues.autofix 2>/dev/null || true)"
    [[ "$v" == "true" ]] || continue
    # Today's spot cap, read the way fi_af_cap_ok does: a B claim that hits it
    # (claim rc 3) writes no capped marker, so count the claims here.
    if [[ "$AFI_kind" != "sweep" ]]; then
      cap="$(git -C "$eff" config --get found-issues.autofix.dailyFixes 2>/dev/null || true)"
      [[ "$cap" =~ ^[0-9]+$ ]] && (( 10#$cap >= 1 )) || cap=5
      n=0
      if [[ -f "$st/day/$FI_AFH_DAY.spot" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do n=$((n + 1)); done <"$st/day/$FI_AFH_DAY.spot"
      fi
      (( n < 10#$cap )) || continue
    fi
    fi_afh_mark "$f" A "$FI_AFH_NOW"
    fi_afh_launch_a "$f" "$engine" "$bin" "$cwd"
    return 0
  done
  return 0
}
