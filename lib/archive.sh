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
      --days)     fi_need_value archive --days $# "${2:-}" || return 2
                  threshold_days="$2"; shift 2 ;;
      --count=*)  threshold_count="${1#--count=}"; shift ;;
      --count)    fi_need_value archive --count $# "${2:-}" || return 2
                  threshold_count="$2"; shift 2 ;;
      -h|--help)
        printf 'Usage: found-issues archive [--dry-run] [--days N] [--count N]\n'
        printf 'Move [fixed] entries older than N days (default 30), or beyond the newest N\n'
        printf '(default 50), to found-issues-archive.md.\n'
        return 0 ;;
      # Archive moves entries out of the ledger: never guess at an option
      # (`--dry-runn` used to archive for real — ledger entry lib/archive.sh:36).
      *)          fi_unknown_arg archive "$1"; return 2 ;;
    esac
  done
  if [[ ! "$threshold_days" =~ ^[0-9]+$ || ! "$threshold_count" =~ ^[0-9]+$ ]]; then
    fi_err "archive: --days and --count take a whole number"
    return 2
  fi

  local file
  file="$(fi_find_issues_file)" || {
    fi_err "archive: no found-issues.md found"
    return 1
  }

  # Inside conflict markers the same entry can appear twice (once per side);
  # moving either copy decides the merge for the operator (audit ledger-17).
  if fi_has_conflict_markers "$file"; then
    fi_err "archive: $file has merge-conflict markers — resolve them first; nothing archived"
    return 0
  fi

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
  # entry's own header date. Output one "DATE\tNR\tLINE" per fixed entry,
  # oldest first, ties in file order. NR (the line number) is what pass 3
  # deletes by — see there. LC_ALL=C: the ledger is bytes, and a stray
  # invalid-UTF-8 byte must not change what any tool here matches.
  local fixed_pairs
  fixed_pairs="$(LC_ALL=C awk '
    /^- \[fixed\]/ {
      line = $0
      date = ""
      # Try (fixed: YYYY-MM-DD) first
      if (match(line, /\(fixed: [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)/)) {
        date = substr(line, RSTART+8, 10)
      } else if (match(line, / [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] /)) {
        # Fall back to entry header date
        date = substr(line, RSTART+1, 10)
      }
      if (date != "") {
        print date "\t" NR "\t" line
      }
    }
  ' "$file" | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2n)"

  local fixed_total=0
  if [[ -n "$fixed_pairs" ]]; then
    fixed_total=$(printf '%s\n' "$fixed_pairs" | wc -l | tr -d ' ')
  fi

  # Decide what to archive
  # An entry is archived if EITHER:
  #   (a) its date < cutoff  (older than threshold_days)
  #   (b) it's among the oldest (fixed_total - threshold_count) entries
  local to_archive_lines="" to_archive_nrs=""
  local archived_count=0
  local remaining=$fixed_total

  if [[ -n "$fixed_pairs" ]]; then
    # Split by hand, not with IFS=$'\t' read: tab is IFS whitespace, so read
    # strips a line's trailing tabs, and the stripped text no longer matched
    # the ledger line it came from (audit ledger-15).
    local rec date nr line
    while IFS= read -r rec; do
      date="${rec%%$'\t'*}"
      rec="${rec#*$'\t'}"
      nr="${rec%%$'\t'*}"
      line="${rec#*$'\t'}"
      local archive_this=0
      if [[ "$date" < "$cutoff" ]]; then
        archive_this=1
      elif (( remaining > threshold_count )); then
        archive_this=1
      fi
      if (( archive_this == 1 )); then
        to_archive_lines+="$line"$'\n'
        to_archive_nrs+="$nr"$'\n'
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

  # Pass 3: build the active file without the archived LINE NUMBERS. This used
  # to be `grep -F -x -v -f <archived lines>`, which (a) deleted every
  # byte-identical copy when the count rule picked one, and (b) in a UTF-8
  # locale treated a ledger with one invalid byte as binary — the `|| true`
  # swallowed the error and the mv installed a ledger missing every [open]
  # entry (audit ledger-3). awk by NR has no binary mode and no pattern
  # semantics. Built and checked BEFORE the archive is appended, so a failure
  # here leaves both files untouched.
  local snapshot tmp nrs_file
  snapshot="$(fi_ledger_snapshot "$file")"
  tmp="$(fi_ledger_tmp "$file")"
  nrs_file="$(fi_ledger_tmp "$file")"
  printf '%s' "$to_archive_nrs" >"$nrs_file"
  if ! LC_ALL=C awk 'NR == FNR { drop[$1]; next } !(FNR in drop)' "$nrs_file" "$file" >"$tmp"; then
    rm -f "$tmp" "$nrs_file"
    fi_err "archive: could not rewrite $file — nothing archived"
    return 1
  fi
  rm -f "$nrs_file"
  local before_n after_n
  before_n="$(LC_ALL=C awk 'END { print NR }' "$file")"
  after_n="$(LC_ALL=C awk 'END { print NR }' "$tmp")"
  if (( after_n != before_n - archived_count )); then
    rm -f "$tmp"
    fi_err "archive: line count check failed ($before_n - $archived_count != $after_n) — nothing archived"
    return 1
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

  local replace_rc=0
  fi_ledger_replace "$file" "$tmp" "$snapshot" || replace_rc=$?
  if (( replace_rc != 0 )); then
    fi_err "archive: $file changed while archiving — the moved entries were appended to $archive_file but are still in the active file; re-run archive after checking for duplicates"
    return 1
  fi

  printf 'archive: moved %d entries from %s to %s\n' \
    "$archived_count" "$file" "$archive_file"
}

