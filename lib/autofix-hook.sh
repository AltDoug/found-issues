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
#   fi_afh_item <id>
#   fi_afh_now
#   fi_afh_mark <item> <A|B> <epoch>
#   fi_afh_launch_a <item> <engine> <fi-bin>
#   fi_afh_context_b <id>

# shellcheck disable=SC2154  # AFI_* are set by fi_af_item_read (autofix-queue.sh)

FI_AFH_LAUNCHER="" FI_AFH_ITEM="" FI_AFH_NOW="" FI_AFH_DAY=""
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
  local rest="$1" id seen=" " re='AUTOFIX-QUEUED[[:space:]]+([0-9]{8}-[0-9]{6}-[0-9]{5})'
  FI_AFH_IDS=()
  while [[ "$rest" =~ $re ]]; do
    id="${BASH_REMATCH[1]}"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
    [[ "$seen" == *" $id "* ]] && continue
    seen+="$id "
    FI_AFH_IDS+=("$id")
  done
}

fi_afh_item() {
  local f
  FI_AFH_ITEM=""
  for f in "$(fi_afh_state)"/*/queue/"$1"; do
    [[ -f "$f" ]] && { FI_AFH_ITEM="$f"; return 0; }
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
  fi_af_item_set "$1" launcher "$2"
  fi_af_item_set "$1" launched "$3"
}

# Detached and fd-clean: the session never waits on it and bats never hangs
# on an inherited fd 3.
fi_afh_launch_a() {
  local item="$1" engine="$2" bin="$3" log
  fi_af_item_read "$item" || return 1
  [[ -d "$AFI_root" ]] || return 1
  log="${item%/queue/*}/spawn.log"
  ( cd "$AFI_root" && nohup "$bin" autofix run "$AFI_id" --engine "$engine" \
      </dev/null >>"$log" 2>&1 3>&- & ) >/dev/null 2>&1
}

fi_afh_context_b() {
  cat <<EOF
## found-issues auto-fix: item $1 is queued

The user turned on found-issues auto-fix. Start the plugin agent
found-issues:found-issues-fixer now, in the background, with exactly this
prompt:

  Fix found-issues auto-fix item $1.

Do not fix the issue yourself and do not wait for the agent; carry on with
your current task.
EOF
}
