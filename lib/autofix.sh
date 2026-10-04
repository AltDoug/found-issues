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
    ""|-h|--help|help) _fi_af_usage ;;
    *) fi_unknown_arg autofix "$sub"; return 2 ;;
  esac
}
