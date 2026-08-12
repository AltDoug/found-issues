#!/usr/bin/env bash
# log.sh — log — append an entry (dedup, validation, auto-annotate)
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Extracted verbatim from bin/found-issues in v2.2.7 (the tracked §12 split);
# see the [open] loc-validator entry in docs/found-issues.md.
#
# Functions:
#   cmd_log [...]

# === Subcommand: log ===
#
# Usage: found-issues log [--critical] <location> — <symptom>
#
# location can be:
#   - path/file.ext:42  (concrete file:line)
#   - path/file.ext     (concrete file, no line)
#   - any-topic         (abstract; no path:line)
#
# Symptom may include "(suggested: ...)" inline.

cmd_log() {
  local critical="no"
  if [[ "${1:-}" == "--critical" ]]; then
    critical="yes"
    shift
  fi

  if [[ $# -eq 0 ]]; then
    fi_err "found-issues log: missing arguments"
    fi_err "Usage: found-issues log [--critical] <location> — <symptom>"
    return 2
  fi

  # Reassemble full input from remaining args
  local input="$*"

  # Split on the first ' — ' (em-dash with spaces)
  local location symptom
  if [[ "$input" != *" — "* ]]; then
    fi_err "found-issues log: missing ' — ' separator"
    fi_err "Usage: found-issues log [--critical] <location> — <symptom>"
    return 2
  fi
  location="${input%% — *}"
  symptom="${input#* — }"

  # Strip leading/trailing whitespace
  location="${location#"${location%%[![:space:]]*}"}"
  location="${location%"${location##*[![:space:]]}"}"
  symptom="${symptom#"${symptom%%[![:space:]]*}"}"
  symptom="${symptom%"${symptom##*[![:space:]]}"}"

  if [[ -z "$symptom" ]]; then
    fi_err "found-issues log: empty symptom"
    return 2
  fi

  # Parse location: path:line, path:start-end, path, or abstract
  local path="" line_num="" line_end=""
  if [[ "$location" =~ ^([^:[:space:]]+):([0-9]+)(-([0-9]+))?$ ]]; then
    # Charset parity with fi_parse_entry's re_path_line (lib/parse-entries.sh):
    # the writer must accept exactly the line specs the parser round-trips, or
    # an agent that spots a multi-line symptom has to hand-edit the ledger —
    # and hand-edited entries are the pre-guard shape v2.2.3 had to rescue.
    path="${BASH_REMATCH[1]}"
    line_num="${BASH_REMATCH[2]}"
    line_end="${BASH_REMATCH[4]}"
    # A range must be strictly increasing. `49-23` is a typo, and `10-10` is a
    # single line wearing range syntax — both would round-trip through the
    # parser as a valid-looking location, so reject at the writer instead.
    if [[ -n "$line_end" ]] && (( 10#$line_end <= 10#$line_num )); then
      fi_err "found-issues log: invalid line spec '${line_num}-${line_end}' in location — a range must end after it starts (path:23-49)"
      return 2
    fi
  elif [[ "$location" =~ ^([^:[:space:]]+):([0-9][^[:space:]]*)$ ]]; then
    # A colon suffix starting with a digit was clearly intended as a line
    # spec (e.g. 10,85 / 42abc / 10-20-30) but is neither a bare integer nor a
    # single range. fi_parse_entry can only round-trip ^[0-9]+(-[0-9]+)?$ line
    # specs — anything else silently drops the path, breaking dedup,
    # annotate-commit/annotate-pr matching, and tombstone sync. Same
    # charset-alignment class as the v1.5.7 path fix (bin/found-issues:426).
    # Abstract topics with a non-numeric colon suffix (e.g. "workflow:shutdown")
    # don't match this branch and keep their existing behavior below.
    fi_err "found-issues log: invalid line spec '${BASH_REMATCH[2]}' in location — use a single numeric line (path:42), a range (path:23-49), or an abstract topic without a colon"
    return 2
  elif [[ "$location" == */* || "$location" == *.* ]]; then
    # Looks like a file path
    path="$location"
  else
    # Abstract topic — keep as-is in path field
    path="$location"
  fi

  # Canonicalize path
  if [[ "$path" == */* || "$path" == *.* ]]; then
    path="$(fi_canonicalize_path "$path")"
  fi

  # Resolve issues file
  local file
  file="$(fi_resolve_issues_file)"

  # Dedup check
  local new_key
  if [[ -n "$line_num" ]]; then
    new_key="$(fi_dedup_key "$path" "$line_num" "$symptom")"
  elif [[ "$path" == */* || "$path" == *.* ]]; then
    new_key="$(fi_dedup_key "$path" "" "$symptom")"
  else
    new_key="$(fi_dedup_key_abstract "$symptom")"
  fi

  # Dedup against [open] AND [deferred] entries.
  # - [open] match: existing behavior — print "Skipped — already logged" and return.
  # - [deferred] match: new behavior — append touch annotation, possibly nudge or
  #   auto-promote (handled by fi_handle_deferred_touch).
  local matched_status=""  # "open" or "deferred", or empty if no match
  local matched_entry=""
  local entry e_data e_path e_line e_symptom existing_key

  # Scan [open] first (preserve existing precedence)
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    e_data="$(fi_parse_entry "$entry")" || continue
    e_path="$(printf '%s' "$e_data" | grep '^path=' | head -1 | cut -d= -f2-)"
    e_line="$(printf '%s' "$e_data" | grep '^line=' | head -1 | cut -d= -f2-)"
    e_symptom="$(printf '%s' "$e_data" | grep '^symptom=' | head -1 | cut -d= -f2-)"
    if [[ -n "$e_line" ]]; then
      existing_key="$(fi_dedup_key "$e_path" "$e_line" "$e_symptom")"
    elif [[ "$e_path" == */* || "$e_path" == *.* ]]; then
      existing_key="$(fi_dedup_key "$e_path" "" "$e_symptom")"
    else
      existing_key="$(fi_dedup_key_abstract "$e_symptom")"
    fi
    if [[ "$existing_key" == "$new_key" ]]; then
      matched_status="open"
      matched_entry="$entry"
      break
    fi
  done < <(fi_entries "$file" open 2>/dev/null || true)

  # If no [open] match, scan [deferred]
  if [[ -z "$matched_status" ]]; then
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      e_data="$(fi_parse_entry "$entry")" || continue
      e_path="$(printf '%s' "$e_data" | grep '^path=' | head -1 | cut -d= -f2-)"
      e_line="$(printf '%s' "$e_data" | grep '^line=' | head -1 | cut -d= -f2-)"
      e_symptom="$(printf '%s' "$e_data" | grep '^symptom=' | head -1 | cut -d= -f2-)"
      if [[ -n "$e_line" ]]; then
        existing_key="$(fi_dedup_key "$e_path" "$e_line" "$e_symptom")"
      elif [[ "$e_path" == */* || "$e_path" == *.* ]]; then
        existing_key="$(fi_dedup_key "$e_path" "" "$e_symptom")"
      else
        existing_key="$(fi_dedup_key_abstract "$e_symptom")"
      fi
      if [[ "$existing_key" == "$new_key" ]]; then
        matched_status="deferred"
        matched_entry="$entry"
        break
      fi
    done < <(fi_entries "$file" deferred 2>/dev/null || true)
  fi

  # Branch on match
  if [[ "$matched_status" == "open" ]]; then
    printf 'Skipped — already logged: %s\n' "$matched_entry"
    cmd_status plain
    return 0
  fi

  if [[ "$matched_status" == "deferred" ]]; then
    fi_handle_deferred_touch "$file" "$matched_entry"
    return $?
  fi

  # No match — fall through to existing "build new entry" code.

  # Build new entry
  local crit_flag=""
  [[ "$critical" == "yes" ]] && crit_flag=" [!]"

  # Rejoin the range halves here and ONLY here, mirroring fi_entry_loc — the
  # dedup key above deliberately keeps the numeric start, because the scan
  # builds an existing entry's key from fi_parse_entry's `line` (also the
  # numeric start). Rendering the range into the key instead would make a
  # re-logged range entry miss its own twin and duplicate it every time.
  local location_str=""
  if [[ -n "$line_num" && -n "$line_end" ]]; then
    location_str=" $path:$line_num-$line_end"
  elif [[ -n "$line_num" ]]; then
    location_str=" $path:$line_num"
  elif [[ -n "$path" ]]; then
    location_str=" $path"
  fi

  local entry="- [open]${crit_flag} $(fi_today)${location_str} — $symptom"

  # Append (with leading newline if file doesn't end in one).
  # Note: command substitution strips trailing newlines, so an empty result
  # from `tail -c 1` means the file already ends in \n.
  if [[ -s "$file" ]]; then
    local last_char
    last_char="$(tail -c 1 "$file")"
    if [[ -n "$last_char" ]]; then
      printf '\n' >>"$file"
    fi
  fi
  printf '%s\n' "$entry" >>"$file"

  printf 'Logged: %s\n' "$entry"
  cmd_status plain
}

