#!/usr/bin/env bash
# segment-cache.sh — builtin-only cache for `status --format=segment`.
#
# Sourced by bin/found-issues TWICE on purpose: once by the fast path at the
# very top (before the other libs and before any $(...)), and once with the
# rest of the libs so cmd_status can write the cache. Defines functions only.
#
# Why (2026-10-03, dougstation): the statusline renders the segment every few
# seconds per session, and every render cost ~57 process creations (cd/pwd
# subshells, dirname, the fi_count_* grep/awk pipelines, date, stat, mkdir).
# Under Git Bash each one is a Windows process, and Windows 11 leaks a kernel
# token per process creation while the foreground lock is armed.
#
# Contract — a cache hit prints exactly what cmd_status would print:
#   - The cached segment is served only when the key matches (CLI version,
#     FOUND_ISSUES_STALE_DAYS, today's date — the stale cutoff — the locale
#     the count pipelines ran under, the ledger path) AND the ledger's bytes
#     equal the bytes stored with it. Content, not mtime: no clock-granularity
#     or same-second-write race can serve a stale count.
#   - The ledger is read BEFORE the counts are computed, so a write that lands
#     mid-render leaves a cache that no longer matches the file.
#   - Anything the builtins cannot answer returns 1 and the full CLI runs:
#     bash < 4.2 (no builtin clock), CDPATH set, a cd that fails, a `//` path,
#     a ledger holding a NUL byte, an autosync that is due or whose stamp has
#     no epoch in it (written by a CLI older than 2.9.0), a non-numeric
#     interval. FOUND_ISSUES_SEGMENT_CACHE=off disables the cache entirely.
#
# Functions:
#   fi_segment_fast_path <status args...>   0 = printed the segment
#   fi_segment_cache_key <ledger>           sets FI_SEG_KEY, FI_SEG_CACHE
#   fi_segment_read_ledger <ledger>         sets FI_SEG_LEDGER
#   fi_segment_cache_get                    sets FI_SEG_OUT on a hit
#   fi_segment_cache_put <segment>          best effort, never fails
#   fi_segment_af_suffix <ledger>           sets FI_SEG_AF (🔧N or empty), FI_SEG_AF_N (N or 0)
#   fi_segment_join <segment>               prints segment + FI_SEG_AF

# fi_autosync_stamp_path <cache dir> <ledger> — the per-ledger autosync
# stamp (shared by this fast path and cmd_status). A name too long for one
# path component falls back to the pre-2.10.2 global stamp.
fi_autosync_stamp_path() {
  local name="${2//[^A-Za-z0-9._-]/_}"
  if (( ${#name} <= 200 )); then
    printf '%s' "$1/segment-autosync/$name"
  else
    printf '%s' "$1/segment-autosync-ts"
  fi
}

fi_segment_clock_ok() {
  (( BASH_VERSINFO[0] > 4 || ( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2 ) ))
}

fi_segment_cache_key() {
  local file="$1" today name
  [[ "${FOUND_ISSUES_SEGMENT_CACHE:-on}" == "off" ]] && return 1
  fi_segment_clock_ok || return 1
  [[ -n "${FOUND_ISSUES_CACHE_DIR:-}" || -n "${HOME:-}" ]] || return 1
  printf -v today '%(%Y-%m-%d)T' -1
  name="${file//[^A-Za-z0-9._-]/_}"
  (( ${#name} <= 200 )) || return 1
  FI_SEG_CACHE="${FOUND_ISSUES_CACHE_DIR:-$HOME/.cache/found-issues}/segment/$name"
  FI_SEG_KEY="seg2|${FI_VERSION:-}|${FOUND_ISSUES_STALE_DAYS:-30}|$today|${LC_ALL:-}|${LC_CTYPE:-}|${LANG:-}|$file"
}

# read -d '' succeeds only when it stops at a NUL byte — content a bash string
# cannot hold, so such a ledger is never cached.
fi_segment_read_ledger() {
  FI_SEG_LEDGER=""
  [[ -r "$1" ]] || return 1
  if IFS= read -r -d '' FI_SEG_LEDGER <"$1"; then return 1; fi
  return 0
}

# Cache file layout: key line, segment line, then the ledger bytes verbatim.
fi_segment_cache_get() {
  local cached="" rest
  [[ -f "$FI_SEG_CACHE" ]] || return 1
  if IFS= read -r -d '' cached <"$FI_SEG_CACHE"; then return 1; fi
  [[ "$cached" == *$'\n'*$'\n'* ]] || return 1
  [[ "${cached%%$'\n'*}" == "$FI_SEG_KEY" ]] || return 1
  rest="${cached#*$'\n'}"
  [[ "${rest#*$'\n'}" == "$FI_SEG_LEDGER" ]] || return 1
  FI_SEG_OUT="${rest%%$'\n'*}"
}

fi_segment_cache_put() {
  local tmp="$FI_SEG_CACHE.$$"
  [[ "$1" == *$'\n'* ]] && return 0
  mkdir -p "${FI_SEG_CACHE%/*}" 2>/dev/null || return 0
  if printf '%s\n%s\n%s' "$FI_SEG_KEY" "$1" "$FI_SEG_LEDGER" >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$FI_SEG_CACHE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
  return 0
}

# 🔧N: auto-fix runs in progress in the ledger's repo (phase 5 ruling 1),
# from the state file lib/autofix-status.sh writes per physical repo root.
# 🔧stuck (3.8.0, ledger lib/autofix-queue.sh:345): the repo's last
# FI_AF_STUCK_AFTER items all retired "stale: tests fail at base"; the streak
# lives in autofix/stuck/<root>, written at retire time (fi_af_stuck_update).
# Read AFTER the cache, never cached. Builtins only: cd -P resolves the
# root git reports, so a symlinked checkout still finds its file.
#
# The stuck-file helpers below are shared with lib/autofix-status.sh (which
# writes the file and prints the SessionStart line), so the threshold, the
# root-to-filename key and the reader exist once. The file: line 1 the streak
# count, line 2 the first failing test names, line 3 the epoch of the last
# base failure; a streak whose last failure is older than FI_AF_STUCK_MAX_AGE
# (7 days) no longer counts, so a repo nobody touches does not stay red.
FI_AF_STUCK_AFTER="${FI_AF_STUCK_AFTER:-3}"
FI_AF_STUCK_MAX_AGE="${FI_AF_STUCK_MAX_AGE:-604800}"

# Sets FI_AF_KEY, the state-file name (seg/, stuck/) of a repo root.
fi_af_root_key() { FI_AF_KEY="${1//[^A-Za-z0-9._-]/_}"; }

# Sets FI_AF_NOW (epoch seconds): a builtin where bash has one, date otherwise
# (only a bash older than 4.2 gets here, and never on the statusline fast path).
fi_af_now() {
  if fi_segment_clock_ok; then printf -v FI_AF_NOW '%(%s)T' -1
  else FI_AF_NOW="$(date +%s)"; fi
}

# Reads a stuck file: sets FI_AF_STUCK_N / _NAMES / _TS (empty when unset).
# rc 1 when there is no such file.
# shellcheck disable=SC2034  # _NAMES is read by lib/autofix-status.sh
fi_af_stuck_read() {
  FI_AF_STUCK_N="" FI_AF_STUCK_NAMES="" FI_AF_STUCK_TS=""
  [[ -f "$1" ]] || return 1
  { IFS= read -r FI_AF_STUCK_N || true; IFS= read -r FI_AF_STUCK_NAMES || true; IFS= read -r FI_AF_STUCK_TS || true; } <"$1"
  return 0
}

# rc 0 when the file holds a live streak: the count reached
# FI_AF_STUCK_AFTER and its last base failure is within FI_AF_STUCK_MAX_AGE
# (a file without a timestamp counts as fresh). Leaves the fields set.
fi_af_stuck_active() {
  fi_af_stuck_read "$1" || return 1
  [[ "$FI_AF_STUCK_N" =~ ^[0-9]+$ ]] && (( 10#$FI_AF_STUCK_N >= FI_AF_STUCK_AFTER )) || return 1
  if [[ "$FI_AF_STUCK_TS" =~ ^[0-9]+$ ]]; then
    fi_af_now
    (( FI_AF_NOW - 10#$FI_AF_STUCK_TS <= FI_AF_STUCK_MAX_AGE )) || return 1
  fi
  return 0
}

fi_segment_af_suffix() {
  local file="$1" root saved n="" base name local_form=""
  FI_SEG_AF="" FI_SEG_AF_N=0
  case "$file" in
    */docs/found-issues.md) root="${file%/docs/found-issues.md}" ;;
    */.found-issues.md)     root="${file%/.found-issues.md}"; local_form=1 ;;
    *) return 0 ;;
  esac
  [[ -n "${FOUND_ISSUES_STATE_DIR:-}" || -n "${HOME:-}" ]] || return 0
  base="${FOUND_ISSUES_STATE_DIR:-$HOME/.claude/found-issues}/autofix"
  [[ -d "$base" ]] || return 0
  saved="$PWD"
  cd -P "$root" 2>/dev/null || return 0
  root="$PWD"
  cd "$saved" 2>/dev/null || return 0
  # The state file is keyed by the git toplevel; a nested (monorepo package)
  # ledger sits below it, so walk up to the directory holding .git. Git mode
  # only (3.8.0): a local-mode ledger (FOUND_ISSUES_MODE=local, or the
  # .found-issues.md form that only local mode creates below a repo root)
  # nested under some repo, e.g. a dotfiles repo tracking $HOME, does not
  # inherit that repo's counts.
  if [[ ! -e "$root/.git" ]]; then
    [[ "${FOUND_ISSUES_MODE:-}" == local || -n "$local_form" ]] && return 0
    n="$root"
    while [[ -n "$n" && "$n" != "/" && ! -e "$n/.git" ]]; do n="${n%/*}"; done
    [[ -n "$n" && "$n" != "/" ]] && root="$n"
  fi
  n=""
  fi_af_root_key "$root"; name="$FI_AF_KEY"
  if [[ -f "$base/seg/$name" ]]; then
    IFS= read -r n <"$base/seg/$name" || true
    if [[ "$n" =~ ^[1-9][0-9]*$ ]]; then
      FI_SEG_AF_N="$n"
      FI_SEG_AF=$'\033[35m'"🔧$n"$'\033[0m'
    fi
  fi
  if fi_af_stuck_active "$base/stuck/$name"; then
    FI_SEG_AF+="${FI_SEG_AF:+ }"$'\033[31m'"🔧stuck"$'\033[0m'
  fi
  return 0
}

fi_segment_join() {
  if [[ -z "$FI_SEG_AF" ]]; then printf '%s' "$1"
  elif [[ -z "$1" ]]; then printf ' | %s' "$FI_SEG_AF"
  else printf '%s · %s' "$1" "$FI_SEG_AF"; fi
}

# Mirrors main()'s `status` argument loop and cmd_status's file resolution
# (fi_find_issues_file: cd + logical pwd, then walk up checking
# docs/found-issues.md before .found-issues.md, never checking "/").
fi_segment_fast_path() {
  local format="segment" cwd="" search_root saved dir file="" ts last now interval name
  fi_segment_clock_ok || return 1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --format=*) format="${1#--format=}"; shift ;;
      --format)   [[ $# -ge 2 ]] || return 1; format="${2:-segment}"; shift 2 ;;
      --cwd=*)    cwd="${1#--cwd=}"; shift ;;
      --cwd)      [[ $# -ge 2 ]] || return 1; cwd="${2:-}"; shift 2 ;;
      -h|--help)  return 1 ;;
      *)          shift ;;
    esac
  done
  [[ "$format" == "segment" ]] || return 1
  [[ -z "${CDPATH:-}" ]] || return 1

  search_root="${cwd:-${CLAUDE_PROJECT_DIR:-$PWD}}"
  [[ "$search_root" == -* ]] && return 1
  saved="$PWD"
  cd "$search_root" 2>/dev/null || return 1
  dir="$PWD"
  cd "$saved" 2>/dev/null || return 1
  [[ "$dir" == //* ]] && return 1
  while [[ -n "$dir" && "$dir" != "/" ]]; do
    if [[ -f "$dir/docs/found-issues.md" ]]; then file="$dir/docs/found-issues.md"; break; fi
    if [[ -f "$dir/.found-issues.md" ]]; then file="$dir/.found-issues.md"; break; fi
    [[ -e "$dir/.git" ]] && break
    dir="${dir%/*}"
    [[ -z "$dir" ]] && dir="/"
  done
  # No ledger: cmd_status prints nothing and skips autosync.
  [[ -z "$file" ]] && return 0

  if [[ "${FOUND_ISSUES_SEGMENT_AUTOSYNC:-on}" != "off" ]]; then
    interval="${FOUND_ISSUES_SEGMENT_AUTOSYNC_INTERVAL:-600}"
    [[ "$interval" =~ ^[0-9]+$ ]] || return 1
    [[ -n "${FOUND_ISSUES_CACHE_DIR:-}" || -n "${HOME:-}" ]] || return 1
    ts="${FOUND_ISSUES_CACHE_DIR:-$HOME/.cache/found-issues}"
    name="${file//[^A-Za-z0-9._-]/_}"
    if (( ${#name} <= 200 )); then ts+="/segment-autosync/$name"; else ts+="/segment-autosync-ts"; fi
    [[ -f "$ts" ]] || return 1
    last=""
    IFS= read -r last <"$ts" || true
    [[ "$last" =~ ^[0-9]+$ ]] || return 1
    printf -v now '%(%s)T' -1
    [[ "$now" =~ ^[0-9]+$ ]] || return 1
    (( now - last < interval )) || return 1
  fi

  fi_segment_cache_key "$file" || return 1
  fi_segment_read_ledger "$file" || return 1
  fi_segment_cache_get || return 1
  fi_segment_af_suffix "$file"
  fi_segment_join "$FI_SEG_OUT"
  return 0
}
