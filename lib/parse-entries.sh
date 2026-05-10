#!/usr/bin/env bash
# parse-entries.sh — read and parse docs/found-issues.md entries
#
# Sourced by other scripts. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# All regex patterns are assigned to variables before matching — bash's
# parser is fussy about `\)` and similar escapes inline within [[ =~ ]].
#
# Functions:
#   fi_find_issues_file [<start_dir>]
#   fi_parse_entry <line>
#   fi_entries <file> [<status_filter>]
#   fi_count <file> [<status_filter>]
#   fi_count_in_pr <file>
#   fi_count_critical <file>
#   fi_count_stale <file> [<days=30>]

# Walk up from start_dir looking for the issues file.
# Prefers <dir>/docs/found-issues.md, falls back to <dir>/.found-issues.md.
fi_find_issues_file() {
  local start="${1:-$PWD}"
  local dir
  dir="$(cd "$start" 2>/dev/null && pwd)" || return 1

  while [[ -n "$dir" && "$dir" != "/" ]]; do
    if [[ -f "$dir/docs/found-issues.md" ]]; then
      printf '%s' "$dir/docs/found-issues.md"
      return 0
    fi
    if [[ -f "$dir/.found-issues.md" ]]; then
      printf '%s' "$dir/.found-issues.md"
      return 0
    fi
    dir="$(dirname "$dir")"
  done

  return 1
}

# Parse a single entry line into KEY=VALUE pairs (one per line).
# Returns 1 if the line is not a valid entry.
fi_parse_entry() {
  local line="$1"

  # Status (acts as entry-validity check)
  local re_status='^- \[(open|deferred|fixed)\]'
  local status=""
  if [[ "$line" =~ $re_status ]]; then
    status="${BASH_REMATCH[1]}"
  else
    return 1
  fi

  # Critical flag
  local re_critical='^- \[(open|deferred|fixed)\] \[!\]'
  local critical="no"
  if [[ "$line" =~ $re_critical ]]; then
    critical="yes"
  fi

  # Date (first ISO date in the line)
  local re_date='([0-9]{4}-[0-9]{2}-[0-9]{2})'
  local date=""
  if [[ "$line" =~ $re_date ]]; then
    date="${BASH_REMATCH[1]}"
  fi

  # Location: path:line, path-only, or abstract topic
  # Note: em-dash is U+2014 (—); using grep for portability instead of inline regex
  local path="" line_num=""
  local after_date
  after_date="$(printf '%s' "$line" | sed -E 's/^.*[0-9]{4}-[0-9]{2}-[0-9]{2} //')"
  # after_date now starts with location followed by ' — symptom...'
  local location_part="${after_date%% — *}"

  local re_path_line='^([A-Za-z0-9_./-]+):([0-9]+)$'
  local re_path_only='^([A-Za-z0-9_./-]+)$'
  if [[ "$location_part" =~ $re_path_line ]]; then
    path="${BASH_REMATCH[1]}"
    line_num="${BASH_REMATCH[2]}"
  elif [[ "$location_part" =~ $re_path_only ]]; then
    path="${BASH_REMATCH[1]}"
  fi

  # Symptom: text after ' — ' up to first '(' or end of line
  local symptom=""
  if [[ "$after_date" == *" — "* ]]; then
    local rest="${after_date#* — }"
    symptom="${rest%%(*}"
    symptom="${symptom%"${symptom##*[![:space:]]}"}"
  fi

  # Suggested fix
  local re_fix='\(suggested: ([^)]+)\)'
  local fix=""
  if [[ "$line" =~ $re_fix ]]; then
    fix="${BASH_REMATCH[1]}"
  fi

  # PR annotations (multiple allowed) — extract via grep -oE
  local prs
  prs="$(printf '%s' "$line" \
    | grep -oE '\(PR: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+\)' \
    | sed -E 's/^\(PR: //; s/\)$//' \
    | paste -sd , - 2>/dev/null || true)"

  # Commit annotations (multiple allowed)
  local commits
  commits="$(printf '%s' "$line" \
    | grep -oE '\(commit: [a-f0-9]{7,40}\)' \
    | sed -E 's/^\(commit: //; s/\)$//' \
    | paste -sd , - 2>/dev/null || true)"

  # Fixed date
  local re_fixed='\(fixed: ([0-9]{4}-[0-9]{2}-[0-9]{2})\)'
  local fixed_date=""
  if [[ "$line" =~ $re_fixed ]]; then
    fixed_date="${BASH_REMATCH[1]}"
  fi

  # Verified source
  local re_verified='\(verified: (ai|review)\)'
  local verified=""
  if [[ "$line" =~ $re_verified ]]; then
    verified="${BASH_REMATCH[1]}"
  fi

  printf 'status=%s\n' "$status"
  printf 'critical=%s\n' "$critical"
  printf 'date=%s\n' "$date"
  printf 'path=%s\n' "$path"
  printf 'line=%s\n' "$line_num"
  printf 'symptom=%s\n' "$symptom"
  printf 'fix=%s\n' "$fix"
  printf 'prs=%s\n' "$prs"
  printf 'commits=%s\n' "$commits"
  printf 'fixed_date=%s\n' "$fixed_date"
  printf 'verified=%s\n' "$verified"
}

# Output entries matching status_filter (open|deferred|fixed|all).
# Returns 1 if file doesn't exist.
fi_entries() {
  local file="$1"
  local status_filter="${2:-all}"

  if [[ ! -f "$file" ]]; then
    return 1
  fi

  case "$status_filter" in
    all)
      grep -E '^- \[(open|deferred|fixed)\]' "$file" || true
      ;;
    open|deferred|fixed)
      grep -E "^- \[$status_filter\]" "$file" || true
      ;;
    *)
      return 2
      ;;
  esac
}

# Count entries by status. Always prints a number (0 if no file or no matches).
fi_count() {
  local file="$1"
  local status_filter="${2:-open}"

  if [[ ! -f "$file" ]]; then
    printf '0'
    return
  fi

  local count
  count="$(fi_entries "$file" "$status_filter" 2>/dev/null | grep -c . || true)"
  printf '%s' "${count:-0}"
}

# Count [open] entries with at least one (PR: ...) annotation.
fi_count_in_pr() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    printf '0'
    return
  fi

  local count
  count="$(grep -cE '^- \[open\].*\(PR: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+\)' "$file" 2>/dev/null || true)"
  printf '%s' "${count:-0}"
}

# Count [open] [!] entries (critical).
fi_count_critical() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    printf '0'
    return
  fi

  local count
  count="$(grep -cE '^- \[open\] \[!\]' "$file" 2>/dev/null || true)"
  printf '%s' "${count:-0}"
}

# Count [open] entries older than N days (default 30).
# Cross-platform: BSD `date -v` and GNU `date -d` both supported.
fi_count_stale() {
  local file="$1"
  local days="${2:-30}"

  if [[ ! -f "$file" ]]; then
    printf '0'
    return
  fi

  local cutoff
  cutoff="$(date -v-"${days}"d +%Y-%m-%d 2>/dev/null \
    || date -d "${days} days ago" +%Y-%m-%d 2>/dev/null \
    || true)"

  if [[ -z "$cutoff" ]]; then
    printf '0'
    return
  fi

  local re_open_date='^- \[open\].*\ ([0-9]{4}-[0-9]{2}-[0-9]{2})\ '
  local count=0
  while IFS= read -r line; do
    if [[ "$line" =~ $re_open_date ]]; then
      local entry_date="${BASH_REMATCH[1]}"
      if [[ "$entry_date" < "$cutoff" ]]; then
        count=$((count + 1))
      fi
    fi
  done < <(fi_entries "$file" open 2>/dev/null)

  printf '%d' "$count"
}

# Extract the value of the (touched: ...) annotation from an entry line.
# Echoes the raw value (comma-separated dates, possibly with ';' cycle
# separators). Echoes empty string if the annotation is absent.
fi_extract_touched_segment() {
  local line="$1"
  local re_touched='\(touched: ([^)]+)\)'
  if [[ "$line" =~ $re_touched ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Count the number of well-formed YYYY-MM-DD dates in the CURRENT cycle's
# segment of the (touched: ...) annotation. The current segment is the
# substring after the last ';' separator (or the entire annotation if no
# ';' is present). Echoes 0 if the annotation is absent or the current
# segment contains no well-formed dates.
fi_current_cycle_touch_count() {
  local line="$1"
  local segment
  segment="$(fi_extract_touched_segment "$line")"
  if [[ -z "$segment" ]]; then
    printf '0'
    return
  fi

  # Take everything after the last ';' (if no ';', this is the full segment).
  local current="${segment##*;}"

  # Count well-formed dates (defensive: ignore garbage tokens).
  local count
  count="$(printf '%s' "$current" \
    | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' \
    | grep -c . || true)"
  printf '%s' "${count:-0}"
}
