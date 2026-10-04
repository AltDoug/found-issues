#!/usr/bin/env bash
# autofix.sh — the `autofix` subcommand family (spec 2026-10-03 §4-§8).
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   cmd_autofix <sub> [...]

_fi_af_usage() {
  cat <<'EOF'
Usage: found-issues autofix <command>
  on | off                    Clear or set the kill switch (all repos)
  status                      Queue, running, today's count, recent results
  run <id> [--engine claude|codex]
                              Fix a queued item headlessly, then the rest of the queue
  claim <id>                  Take a queued item: lock, cap, worktree (prints its path)
  diff <id>                   The claimed item's change against origin/<default>
  ship <id>                   Test, commit, push, open the PR, annotate, arm auto-merge
  release <id> --already-fixed|--decide|--manual|--failed "<text>"
                              Give a claimed item back with an outcome
  merge-when-green <N>        Wait for PR <N>'s checks, then squash-merge it
Settings: git config found-issues.autofix true|false (local overrides --global),
found-issues.autofix.{engine,testCommand,dailyFixes,runBudget,runTimeoutMin}.
EOF
}

cmd_autofix() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    on)
      fi_af_root
      rm -f "$FI_AF_ROOT/disabled"
      printf 'Auto-fix kill switch cleared. Auto-fix runs in repos where found-issues.autofix=true.\n' ;;
    off)
      fi_af_root
      mkdir -p "$FI_AF_ROOT"
      : >"$FI_AF_ROOT/disabled"
      printf 'Auto-fix switched off in every repo (undo: found-issues autofix on).\n' ;;
    claim)
      [[ $# -eq 1 ]] || { fi_err "Usage: found-issues autofix claim <id>"; return 2; }
      fi_af_context || return 1
      fi_af_reap
      local rc=0
      fi_af_claim "$1" || rc=$?
      case $rc in
        0) printf '%s\n' "$AFI_wt" ;;
        1) fi_err "autofix: no queued item $1" ;;
        3) fi_err "autofix: today's spot-fix cap is reached; $1 waits for tomorrow" ;;
        4) fi_err "autofix: another auto-fix run holds this repo; $1 stays queued" ;;
        5) fi_err "autofix: $1 retired — $FI_AF_WHY" ;;
        6) fi_err "autofix: $1 failed — $FI_AF_WHY" ;;
      esac
      return $rc ;;
    release)
      local rid="${1:-}" outcome="" text=""
      [[ $# -gt 0 ]] && shift
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --already-fixed|--decide|--manual|--failed)
            [[ -z "$outcome" ]] || { fi_err "autofix release: one outcome only"; return 2; }
            fi_need_value "autofix release" "$1" $# "${2:-}" || return 2
            outcome="${1#--}"; text="$2"; shift 2 ;;
          *) fi_unknown_arg "autofix release" "$1"; return 2 ;;
        esac
      done
      if [[ -z "$rid" || -z "$outcome" ]]; then
        fi_err "Usage: found-issues autofix release <id> --already-fixed|--decide|--manual|--failed \"<text>\""
        return 2
      fi
      fi_af_context || return 1
      [[ -f "$FI_AF_ST/running/$rid" || -f "$FI_AF_ST/queue/$rid" ]] || { fi_err "autofix: no queued or running item $rid"; return 1; }
      fi_af_finish "$rid" "$outcome" "$text" ;;
    ""|-h|--help|help) _fi_af_usage ;;
    *) fi_unknown_arg autofix "$sub"; return 2 ;;
  esac
}
