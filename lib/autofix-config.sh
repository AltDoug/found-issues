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
#   fi_af_cap_int <key>
#   fi_af_budget
#   fi_af_codex_margs <fixer|verifier|classifier>
#   fi_af_root
#   fi_af_enabled
#   fi_af_dirs <owner/repo>
#   fi_af_context
#   fi_af_test_command <dir>
#   fi_af_engine [<explicit>]
#   fi_af_no_prompts
#   fi_cfg_show_line <key>
#   cmd_config [<key> [<value>|--unset]] [--global]

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

# 3.3.0: an opt-in cap. Unset prints nothing (no cap); a value that is not a
# positive integer warns and also means no cap.
fi_af_cap_int() {
  local v
  v="$(fi_af_cfg "$1" "")"
  [[ -n "$v" ]] || return 0
  if [[ ! "$v" =~ ^[0-9]+$ ]] || (( 10#$v < 1 )); then
    fi_err "found-issues: found-issues.autofix.$1=$v is not a positive integer — no cap"
    return 0
  fi
  printf '%s' "$((10#$v))"
}

# A sweep fixes up to sweepMax entries, so it has its own budget (phase 4
# ruling 4: about $1 per entry was measured in phase 3).
fi_af_budget() {
  local v key=runBudget def=3
  [[ "${AFI_kind:-}" == "sweep" ]] && key=sweepBudget def=10
  v="$(fi_af_cfg "$key" "$def")"
  if [[ ! "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    fi_err "found-issues: found-issues.autofix.$key=$v is not a USD amount — using $def"
    v="$def"
  fi
  printf '%s' "$v"
}

# 3.3.0 spec section 1: the -m/effort pair for one Codex role. Effort is fixed
# per role in code, as the claude engine's is. inherit leaves both out, so the
# user's ~/.codex/config.toml decides. Sets FI_AF_MARGS and FI_AF_MDESC.
FI_AF_MARGS=() FI_AF_MDESC=""
fi_af_codex_margs() {
  local key=codexModel def=gpt-6.1-sol effort=medium m
  case "$1" in
    classifier) effort=low ;;
    verifier) key=codexVerifierModel def=gpt-6-astra effort=high ;;
  esac
  m="$(fi_af_cfg "$key" "$def")"
  FI_AF_MARGS=()
  if [[ "$m" == inherit ]]; then FI_AF_MDESC=inherit; return 0; fi
  FI_AF_MARGS=(-m "$m" -c "model_reasoning_effort=$effort")
  FI_AF_MDESC="$m ($effort)"
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

# Spec §1: nothing auto-fix launches may prompt. Unattended git/gh must
# fail instead of waiting on a credential prompt (git asks on /dev/tty even
# with stdin redirected). A user's own GIT_SSH_COMMAND is kept.
fi_af_no_prompts() {
  export GIT_TERMINAL_PROMPT=0 GH_PROMPT_DISABLED=1
  [[ -n "${GIT_SSH_COMMAND:-}" ]] || export GIT_SSH_COMMAND="ssh -o BatchMode=yes"
}

# Spec §8 settings: key|kind|default ("" = detected or none).
_FI_CFG_KEYS='autofix|bool|false
autofix.engine|engine|auto
autofix.codexModel|model|gpt-6.1-sol
autofix.codexVerifierModel|model|gpt-6-astra
autofix.testCommand|text|
autofix.dailyFixes|int|5
autofix.dailySweeps|int|1
autofix.sweepThreshold|int|5
autofix.sweepMax|int|8
autofix.runBudget|usd|3
autofix.sweepBudget|usd|10
autofix.codexRunTokens|int|
autofix.codexSweepTokens|int|
autofix.runTimeoutMin|int|20'

FI_CFG_KEY="" FI_CFG_KIND="" FI_CFG_DEF="" FI_CFG_VAL="" FI_CFG_SRC=""

# Canonical key for a name given with or without the found-issues. prefix,
# in any case (git config names are case-insensitive). rc 1 = unknown.
_fi_cfg_spec() {
  local want line k
  want="$(printf '%s' "${1#found-issues.}" | tr '[:upper:]' '[:lower:]')"
  while IFS= read -r line; do
    k="${line%%|*}"
    if [[ "$(printf '%s' "$k" | tr '[:upper:]' '[:lower:]')" == "$want" ]]; then
      FI_CFG_KEY="$k"; line="${line#*|}"; FI_CFG_KIND="${line%%|*}"; FI_CFG_DEF="${line#*|}"
      return 0
    fi
  done <<<"$_FI_CFG_KEYS"
  return 1
}

# Normalizes FI_CFG_VAL for the key's kind; rc 1 with a reason on stderr.
_fi_cfg_valid() {
  case "$FI_CFG_KIND" in
    bool)
      case "$FI_CFG_VAL" in
        true|on|yes|1) FI_CFG_VAL=true ;;
        false|off|no|0) FI_CFG_VAL=false ;;
        *) fi_err "config: found-issues.$FI_CFG_KEY takes true or false"; return 1 ;;
      esac ;;
    engine)
      [[ "$FI_CFG_VAL" =~ ^(auto|claude|codex)$ ]] \
        || { fi_err "config: found-issues.$FI_CFG_KEY takes auto, claude or codex"; return 1; } ;;
    int)
      if [[ ! "$FI_CFG_VAL" =~ ^[0-9]+$ ]] || (( 10#$FI_CFG_VAL < 1 )); then
        fi_err "config: found-issues.$FI_CFG_KEY takes a whole number of 1 or more"; return 1
      fi ;;
    usd)
      if [[ ! "$FI_CFG_VAL" =~ ^[0-9]+(\.[0-9]+)?$ || "$FI_CFG_VAL" =~ ^0+(\.0+)?$ ]]; then
        fi_err "config: found-issues.$FI_CFG_KEY takes a USD amount above 0, e.g. 3 or 2.5"; return 1
      fi ;;
    model)
      [[ "$FI_CFG_VAL" =~ ^[A-Za-z0-9._:/-]+$ ]] \
        || { fi_err "config: found-issues.$FI_CFG_KEY takes a Codex model name (e.g. gpt-6.1-sol) or inherit"; return 1; } ;;
    text)
      [[ -n "$FI_CFG_VAL" ]] || { fi_err "config: found-issues.$FI_CFG_KEY needs a value"; return 1; } ;;
  esac
}

# Effective value and where it comes from (local, global, default,
# detected or none) for one key; sets FI_CFG_VAL and FI_CFG_SRC.
fi_cfg_show_line() {
  local out root
  _fi_cfg_spec "$1" || return 1
  out="$(git config --show-scope --get "found-issues.$FI_CFG_KEY" 2>/dev/null || true)"
  if [[ -n "$out" ]]; then
    FI_CFG_SRC="${out%%$'\t'*}" FI_CFG_VAL="${out#*$'\t'}"
    return 0
  fi
  FI_CFG_VAL="$FI_CFG_DEF" FI_CFG_SRC=default
  if [[ "$FI_CFG_KEY" == autofix.testCommand ]]; then
    root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "$root" ]] && FI_CFG_VAL="$(fi_af_test_command "$root")"; then
      FI_CFG_SRC=detected
    else
      FI_CFG_VAL="(none detected)" FI_CFG_SRC=none
    fi
  fi
}

# Phase 5 ruling 7: list, get, set (this repo, or --global), --unset.
cmd_config() {
  local key="" val="" unset_it=0 scope=--local line
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --global) scope=--global; shift ;;
      --unset) unset_it=1; shift ;;
      -h|--help)
        printf 'Usage: found-issues config                          List the auto-fix settings\n'
        printf '       found-issues config <key>                    Print one value\n'
        printf '       found-issues config <key> <value> [--global] Set it (this repo, or every repo)\n'
        printf '       found-issues config <key> --unset [--global] Remove it\n'
        return 0 ;;
      -*) fi_unknown_arg config "$1"; return 2 ;;
      *)
        if [[ -z "$key" ]]; then key="$1"
        elif [[ -z "$val" ]]; then val="$1"
        else fi_unknown_arg config "$1"; return 2; fi
        shift ;;
    esac
  done
  if [[ -z "$key" ]]; then
    while IFS= read -r line; do
      fi_cfg_show_line "${line%%|*}"
      printf 'found-issues.%-24s %s  (%s)\n' "$FI_CFG_KEY" "$FI_CFG_VAL" "$FI_CFG_SRC"
    done <<<"$_FI_CFG_KEYS"
    return 0
  fi
  _fi_cfg_spec "$key" || { fi_err "config: unknown setting $key (run: found-issues config)"; return 2; }
  if [[ "$scope" == --local ]] && { (( unset_it )) || [[ -n "$val" ]]; }; then
    git rev-parse --git-dir >/dev/null 2>&1 \
      || { fi_err "config: not in a git repo — use --global to set it for every repo"; return 1; }
  fi
  if (( unset_it )); then
    git config "$scope" --unset "found-issues.$FI_CFG_KEY" 2>/dev/null || true
    printf 'Unset found-issues.%s (%s)\n' "$FI_CFG_KEY" "${scope#--}"
    return 0
  fi
  if [[ -z "$val" ]]; then
    fi_cfg_show_line "$FI_CFG_KEY"; printf '%s\n' "$FI_CFG_VAL"; return 0
  fi
  FI_CFG_VAL="$val"
  _fi_cfg_valid || return 2
  git config "$scope" "found-issues.$FI_CFG_KEY" "$FI_CFG_VAL" || return 1
  printf 'Set found-issues.%s = %s (%s)\n' "$FI_CFG_KEY" "$FI_CFG_VAL" "${scope#--}"
  if [[ "$FI_CFG_KEY" == autofix && "$FI_CFG_VAL" == true ]]; then
    printf 'Fix PRs merge themselves once their checks pass, and runs bill your Claude or Codex account, including in the background.\n'
    printf 'Stop it any time: found-issues autofix off (every repo) or found-issues config autofix false.\n'
  fi
}
