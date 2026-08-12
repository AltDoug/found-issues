#!/usr/bin/env bash
# archive.sh — archive — move closed entries to the archive file
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Extracted verbatim from bin/found-issues in v2.2.6 (the tracked §12 split);
# see the [open] loc-validator entry in docs/found-issues.md.
#
# Functions:
#   cmd_archive [...]

# === Subcommand: archive ===
#
# Move old [fixed] entries from docs/found-issues.md to docs/found-issues-archive.md
# to keep the active file lean. Triggers when EITHER threshold is met:
#   - days: any [fixed] entry whose closure date is older than N days (default 30)
#   - count: total [fixed] entries exceed N (default 50) — oldest get archived
#     until the active count is back at threshold
#
# The archive file is append-only; the plugin never modifies it after writing.
# Open and deferred entries are never touched.

cmd_archive() {
  local dry_run=0
  local threshold_days=30
  local threshold_count=50

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)  dry_run=1; shift ;;
      --days=*)   threshold_days="${1#--days=}"; shift ;;
      --days)     threshold_days="$2"; shift 2 ;;
      --count=*)  threshold_count="${1#--count=}"; shift ;;
      --count)    threshold_count="$2"; shift 2 ;;
      *)          shift ;;
    esac
  done

  local file
  file="$(fi_find_issues_file)" || {
    fi_err "archive: no found-issues.md found"
    return 1
  }

  local archive_file
  archive_file="$(dirname "$file")/found-issues-archive.md"

  # Cross-platform cutoff date (BSD vs GNU date)
  local cutoff
  cutoff="$(date -v-"${threshold_days}"d +%Y-%m-%d 2>/dev/null \
    || date -d "${threshold_days} days ago" +%Y-%m-%d 2>/dev/null \
    || true)"
  if [[ -z "$cutoff" ]]; then
    fi_err "archive: could not compute cutoff date"
    return 1
  fi

  # Pass 1: extract all [fixed] entries with their effective date
  # Effective date = (fixed: YYYY-MM-DD) annotation if present, else the
  # entry's own header date. Output one "DATE\tLINE" per fixed entry,
  # sorted oldest-first.
  local fixed_pairs
  fixed_pairs="$(awk '
    /^- \[fixed\]/ {
      line = $0
      date = ""
      # Try (fixed: YYYY-MM-DD) first
      if (match(line, /\(fixed: [0-9]{4}-[0-9]{2}-[0-9]{2}\)/)) {
        date = substr(line, RSTART+8, 10)
      } else if (match(line, / [0-9]{4}-[0-9]{2}-[0-9]{2} /)) {
        # Fall back to entry header date
        date = substr(line, RSTART+1, 10)
      }
      if (date != "") {
        print date "\t" line
      }
    }
  ' "$file" | sort)"

  local fixed_total=0
  if [[ -n "$fixed_pairs" ]]; then
    fixed_total=$(printf '%s\n' "$fixed_pairs" | wc -l | tr -d ' ')
  fi

  # Decide what to archive
  # An entry is archived if EITHER:
  #   (a) its date < cutoff  (older than threshold_days)
  #   (b) it's among the oldest (fixed_total - threshold_count) entries
  local to_archive_lines=""
  local archived_count=0
  local remaining=$fixed_total

  if [[ -n "$fixed_pairs" ]]; then
    while IFS=$'\t' read -r date line; do
      local archive_this=0
      if [[ "$date" < "$cutoff" ]]; then
        archive_this=1
      elif (( remaining > threshold_count )); then
        archive_this=1
      fi
      if (( archive_this == 1 )); then
        to_archive_lines+="$line"$'\n'
        archived_count=$((archived_count + 1))
        remaining=$((remaining - 1))
      fi
    done <<<"$fixed_pairs"
  fi

  if (( archived_count == 0 )); then
    printf 'archive: nothing to archive\n'
    printf '  fixed entries: %d (threshold: %d)\n' "$fixed_total" "$threshold_count"
    printf '  none older than %s\n' "$cutoff"
    return 0
  fi

  if (( dry_run == 1 )); then
    printf 'archive (dry-run): would move %d entries to %s\n\n' \
      "$archived_count" "$archive_file"
    printf '%s' "$to_archive_lines"
    return 0
  fi

  # Create archive file with header on first write
  if [[ ! -f "$archive_file" ]]; then
    cat >"$archive_file" <<HEADER
# found-issues archive

Closed entries moved out of \`$(basename "$file")\` to keep the active file
lean. Append-only — the plugin never modifies this file after writing.

HEADER
  fi

  printf '%s' "$to_archive_lines" >>"$archive_file"

  # Rewrite active file with archived lines removed
  local tmp
  tmp="$(mktemp -t found-issues-archive.XXXXXX)"
  # Use grep -F -x -v -f with the archived lines as patterns. -x (whole-line
  # match) is load-bearing: without it an archived line that is a strict
  # prefix of a newer entry (sync builds these — it appends "(fixed: date)"
  # to the original line) substring-matched that entry too, deleting it from
  # the active file without ever writing it to the archive.
  local patterns_file
  patterns_file="$(mktemp -t found-issues-archive-patterns.XXXXXX)"
  printf '%s' "$to_archive_lines" >"$patterns_file"
  grep -F -x -v -f "$patterns_file" "$file" >"$tmp" || true
  rm -f "$patterns_file"
  mv "$tmp" "$file"

  printf 'archive: moved %d entries from %s to %s\n' \
    "$archived_count" "$file" "$archive_file"
}

