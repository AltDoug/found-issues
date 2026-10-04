#!/usr/bin/env bash
# autofix-config.sh — v3 auto-fix settings, kill switch, state paths, test
# command and engine (spec 2026-10-03 §5 step 3, §7, §8, §9).
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   fi_af_cfg <key> <default>
#   fi_af_int <key> <default>
#   fi_af_budget
#   fi_af_root
#   fi_af_enabled
#   fi_af_dirs <owner/repo>
#   fi_af_context
#   fi_af_test_command <dir>
#   fi_af_engine [<explicit>]

FI_AF_ROOT="" FI_AF_WHY="" FI_AF_ST="" FI_AF_RUNS="" FI_AF_SLUG=""

# git config reads global then local, so a per-repo value overrides.
fi_af_cfg() {
  local v
  v="$(git config --get "found-issues.autofix.$1" 2>/dev/null || true)"
  printf '%s' "${v:-$2}"
}

fi_af_int() {
  local v
  v="$(fi_af_cfg "$1" "$2")"
  if [[ ! "$v" =~ ^[0-9]+$ ]] || (( 10#$v < 1 )); then
    fi_err "found-issues: found-issues.autofix.$1=$v is not a positive integer — using $2"
    v="$2"
  fi
  printf '%s' "$((10#$v))"
}

fi_af_budget() {
  local v
  v="$(fi_af_cfg runBudget 3)"
  if [[ ! "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    fi_err "found-issues: found-issues.autofix.runBudget=$v is not a USD amount — using 3"
    v=3
  fi
  printf '%s' "$v"
}

fi_af_root() {
  FI_AF_ROOT="${FOUND_ISSUES_STATE_DIR:-$HOME/.claude/found-issues}/autofix"
}

# On: the toggle is true here, nothing switched it off, and origin is on
# GitHub (v3.0.0 is GitHub-PR-mode only, spec §2).
fi_af_enabled() {
  FI_AF_WHY=""
  case "${FOUND_ISSUES_AUTOFIX:-}" in
    off|0|false|no) FI_AF_WHY="FOUND_ISSUES_AUTOFIX=off"; return 1 ;;
  esac
  fi_af_root
  if [[ -e "$FI_AF_ROOT/disabled" ]]; then
    FI_AF_WHY="switched off (found-issues autofix on)"; return 1
  fi
  local v
  v="$(git config --type=bool --get found-issues.autofix 2>/dev/null || true)"
  [[ "$v" == "true" ]] || { FI_AF_WHY="found-issues.autofix is not true"; return 1; }
  fi_repo_id >/dev/null 2>&1 || { FI_AF_WHY="origin is not a GitHub repo"; return 1; }
}

fi_af_dirs() {
  local key="${1//\//__}"
  fi_af_root
  FI_AF_ST="$FI_AF_ROOT/$key"
  FI_AF_RUNS="${FOUND_ISSUES_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/found-issues}/autofix/$key/runs"
  mkdir -p "$FI_AF_ST/queue" "$FI_AF_ST/running" "$FI_AF_ST/done" "$FI_AF_ST/day" "$FI_AF_RUNS"
}

fi_af_context() {
  FI_AF_SLUG="$(fi_repo_id 2>/dev/null)" || { fi_err "autofix: not in a GitHub repo"; return 1; }
  fi_af_dirs "$FI_AF_SLUG"
}

# _fi_af_has <file> <literal> — 0 if any line contains the literal.
_fi_af_has() {
  local line
  [[ -f "$1" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *"$2"* ]] && return 0
  done <"$1"
  return 1
}

# npm's generated placeholder ("no test specified") is not a test command.
_fi_af_npm_test() {
  local line re='"test"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
  [[ -f "$1" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $re ]]; then
      [[ "${BASH_REMATCH[1]}" != *"no test specified"* ]]
      return
    fi
  done <"$1"
  return 1
}

_fi_af_make_test() {
  local line
  [[ -f "$1" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == test:* ]] && return 0
  done <"$1"
  return 1
}

# Spec §5 step 3: the setting, else the first marker that matches.
fi_af_test_command() {
  local d="$1" cmd f
  cmd="$(git -C "$d" config --get found-issues.autofix.testCommand 2>/dev/null || true)"
  if [[ -n "$cmd" ]]; then printf '%s' "$cmd"; return 0; fi
  for f in "$d"/tests/*.bats; do
    [[ -f "$f" ]] && { printf 'bats tests/'; return 0; }
  done
  _fi_af_npm_test "$d/package.json" && { printf 'npm test'; return 0; }
  if [[ -f "$d/pytest.ini" || -f "$d/conftest.py" ]] \
     || _fi_af_has "$d/pyproject.toml" '[tool.pytest' \
     || _fi_af_has "$d/setup.cfg" '[tool:pytest]'; then
    printf 'pytest'; return 0
  fi
  [[ -f "$d/go.mod" ]] && { printf 'go test ./...'; return 0; }
  [[ -f "$d/Cargo.toml" ]] && { printf 'cargo test'; return 0; }
  _fi_af_make_test "$d/Makefile" && { printf 'make test'; return 0; }
  return 1
}

# Spec §9: engine=auto follows the calling harness. Phase 3's hook passes
# the harness explicitly; this fallback serves log-time queueing and a
# hand-run `autofix run`.
fi_af_engine() {
  local e="${1:-}"
  [[ -n "$e" ]] || e="$(fi_af_cfg engine auto)"
  case "$e" in
    claude|codex) printf '%s' "$e"; return 0 ;;
    auto) ;;
    *) fi_err "found-issues: found-issues.autofix.engine=$e (want auto, claude or codex) — using auto" ;;
  esac
  if [[ -n "${CLAUDECODE:-}" ]]; then printf 'claude'; return 0; fi
  if [[ -n "$(compgen -v CODEX_ 2>/dev/null || true)" ]]; then printf 'codex'; return 0; fi
  command -v claude >/dev/null 2>&1 && { printf 'claude'; return 0; }
  command -v codex >/dev/null 2>&1 && { printf 'codex'; return 0; }
  return 1
}
