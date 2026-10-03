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
  FI_SEG_KEY="seg1|${FI_VERSION:-}|${FOUND_ISSUES_STALE_DAYS:-30}|$today|${LC_ALL:-}|${LC_CTYPE:-}|${LANG:-}|$file"
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
  printf '%s' "$FI_SEG_OUT"
  return 0
}
