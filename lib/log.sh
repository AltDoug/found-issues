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
# Usage: found-issues log [--critical] [--fix S|M|L | --decide Q | --manual W] <location> — <symptom>
#
# location can be:
#   - path/file.ext:42  (concrete file:line)
#   - path/file.ext     (concrete file, no line)
#   - any-topic         (abstract; no path:line)
#
# Symptom may include "(suggested: ...)" inline.

# Apply log's requested fix tag to the entry it matched instead of appending
# (v3 review I2: the tag used to be dropped on escalation and on a deferred
# match). Reads cmd_log's tag_kind; sets _fi_log_line to the entry as it now
# reads. Returns 1 only when the write failed.
_fi_log_tag_existing() {
  local file="$1" entry="$2" trc=0
  _fi_log_line="$entry"
  [[ -n "$tag_kind" ]] || return 0
  fi_parse_entry_vars "$entry"
  if [[ -n "$FE_fixtag$FE_decide$FE_manual" ]]; then
    fi_err "found-issues log: entry already tagged — left as is; change it with: found-issues tag '<match>' --$tag_kind ..."
    return 0
  fi
  fi_tag_apply "$file" "$entry" "$FI_TAG_KIND" "$FI_TAG_VALUE" || trc=$?
  (( trc == 0 )) || { fi_err "found-issues log: could not tag the existing entry (rc $trc) — re-run"; return 1; }
  _fi_log_line="$FI_RETAGGED"
}

cmd_log() {
  local critical="no" tag_kind="" tag_value=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --critical) critical="yes"; shift ;;
      --fix|--decide|--manual)
        [[ -z "$tag_kind" ]] || { fi_err "found-issues log: one fix tag per entry (got $1 after --$tag_kind)"; return 2; }
        fi_need_value log "$1" $# "${2:-}" || return 2
        tag_kind="${1#--}"; tag_value="$2"; shift 2 ;;
      --fix=*|--decide=*|--manual=*)
        [[ -z "$tag_kind" ]] || { fi_err "found-issues log: one fix tag per entry (got ${1%%=*} after --$tag_kind)"; return 2; }
        tag_kind="${1%%=*}"; tag_kind="${tag_kind#--}"; tag_value="${1#*=}"; shift ;;
      *) break ;;
    esac
  done
  # A tag flag AFTER the entry used to be folded into the symptom and logged
  # untagged with exit 0 (v3 review I1) — refuse rather than guess.
  local _fi_arg
  for _fi_arg in "$@"; do
    case "$_fi_arg" in
      --fix|--fix=*|--decide|--decide=*|--manual|--manual=*)
        fi_err "found-issues log: put ${_fi_arg%%=*} before the entry: found-issues log ${_fi_arg%%=*} <value> '<location> — <symptom>'"
        return 2 ;;
    esac
  done

  if [[ $# -eq 0 ]]; then
    fi_err "found-issues log: missing arguments"
    fi_err "Usage: found-issues log [--critical] [--fix small|medium|large | --decide \"<q>\" | --manual \"<why>\"] <location> — <symptom>"
    return 2
  fi

  # Reassemble full input from remaining args
  local input="$*"

  # One entry is one line. An embedded newline wrote continuation lines into
  # the ledger, and one starting "- [open] " became an unvalidated entry
  # (audit cli-16).
  if [[ "$input" == *$'\n'* || "$input" == *$'\r'* ]]; then
    fi_err "found-issues log: the entry must be a single line (no newlines)"
    return 2
  fi

  # `--critical` is only honored as the first argument. Anywhere else it was
  # folded into the location (`src/a.sh:1 --critical`), logged as a spaced
  # pseudo-path with no [!] and no error (audit prompt-14).
  case " ${input%% — *} " in
    *" --critical "*)
      fi_err "found-issues log: --critical must come first: found-issues log --critical '<location> — <symptom>'"
      return 2 ;;
  esac

  # Split on the first ' — ' (em-dash with spaces)
  local location symptom
  if [[ "$input" != *" — "* ]]; then
    fi_err "found-issues log: missing ' — ' separator"
    fi_err "Usage: found-issues log [--critical] [--fix small|medium|large | --decide \"<q>\" | --manual \"<why>\"] <location> — <symptom>"
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

  # The parser reads a trailing "(key: ...)" run as annotations, and sync
  # closes on (commit:)/(PR:) — so a symptom that merely CITES the regressing
  # commit ("broke in (commit: abc1234)") was closed by the next unattended
  # sync (audit cli-4). Only (suggested: ...) belongs in what log writes;
  # everything else has a command that writes it with its guards.
  local tail_ann tail_rest re_suggested='^\(suggested: [^)]*\)[[:space:]]*'
  tail_ann="$(fi_annotation_tail "$symptom")"
  tail_rest="$tail_ann"
  while [[ "$tail_rest" =~ $re_suggested ]]; do
    tail_rest="${tail_rest#"${BASH_REMATCH[0]}"}"
  done
  if [[ -n "$tail_rest" ]]; then
    fi_err "found-issues log: the symptom ends in an annotation-shaped group: $tail_ann"
    fi_err "  log writes only (suggested: ...). Reword the reference (e.g. 'since commit abc1234'),"
    fi_err "  or attach a fix reference with annotate-pr / annotate-commit after logging."
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

  # v3 fix tag: validated and off-limits-checked up front so a bad value
  # writes nothing (spec §3.3, §3.5). An abstract topic has no file, so it is
  # checked as file-less rather than as an untracked path.
  if [[ -n "$tag_kind" ]]; then
    local tag_path=""
    [[ "$path" == */* || "$path" == *.* ]] && tag_path="$path"
    fi_repo_root_cached
    fi_tag_resolve "$tag_kind" "$tag_value" "$tag_path" "$FI_REPO_ROOT" || return 2
    if [[ "$tag_kind" == "fix" && "$FI_TAG_KIND" == "manual" ]]; then
      fi_err "found-issues log: ${path:-this entry} is off-limits for auto-fix ($FI_TAG_VALUE) — tagged manual instead"
    fi
  fi

  # Resolve issues file
  local file
  file="$(fi_resolve_issues_file)"

  # Dedup check. Builtin keys (fi_*_v in lib/canonicalize.sh) and one repo-root
  # lookup for the whole scan: this loop used to cost ~40 process creations
  # per existing entry (audit cli-10).
  fi_repo_root_cached
  local repo_root="$FI_REPO_ROOT"
  # Key the NEW entry exactly the way the scan keys existing ones: build the
  # line it would write and parse it. Keying from log's own split disagreed
  # with the parser for repo-prefixed locations ("Repo:src/a.go:12"), so every
  # re-log appended a duplicate (audit cli-2).
  local new_key cand_loc="$path"
  if [[ -n "$line_num" && -n "$line_end" ]]; then
    cand_loc="$path:$line_num-$line_end"
  elif [[ -n "$line_num" ]]; then
    cand_loc="$path:$line_num"
  fi
  fi_entry_dedup_key_v "- [open] 2000-01-01 $cand_loc — $symptom" "$repo_root" || {
    fi_err "found-issues log: could not parse the entry it would write"
    return 2
  }
  new_key="$FI_KEY"

  # Dedup against [open] AND [deferred] entries.
  # - [open] match: existing behavior — print "Skipped — already logged" and return.
  # - [deferred] match: new behavior — append touch annotation, possibly nudge or
  #   auto-promote (handled by fi_handle_deferred_touch).
  local matched_status=""  # "open" or "deferred", or empty if no match
  local matched_entry=""
  local entry

  # Scan [open] first (preserve existing precedence)
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    fi_entry_dedup_key_v "$entry" "$repo_root" || continue
    if [[ "$FI_KEY" == "$new_key" ]]; then
      matched_status="open"
      matched_entry="$entry"
      break
    fi
  done < <(fi_entries "$file" open 2>/dev/null || true)

  # If no [open] match, scan [deferred]
  if [[ -z "$matched_status" ]]; then
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      fi_entry_dedup_key_v "$entry" "$repo_root" || continue
      if [[ "$FI_KEY" == "$new_key" ]]; then
        matched_status="deferred"
        matched_entry="$entry"
        break
      fi
    done < <(fi_entries "$file" deferred 2>/dev/null || true)
  fi

  # Branch on match
  if [[ "$matched_status" == "open" ]]; then
    # --critical on an entry that is already open escalates it instead of
    # being dropped with the "Skipped" message (audit cli-15).
    if [[ "$critical" == "yes" && "$matched_entry" != "- [open] [!] "* ]]; then
      local esc_line="- [open] [!] ${matched_entry#- \[open\] }" tmp line snapshot
      snapshot="$(fi_ledger_snapshot "$file")"
      tmp="$(fi_ledger_tmp "$file")"
      local done_one=0
      while IFS= read -r line || [[ -n "$line" ]]; do
        if (( ! done_one )) && [[ "$line" == "$matched_entry" ]]; then
          printf '%s\n' "$esc_line" >>"$tmp"; done_one=1
        else
          printf '%s\n' "$line" >>"$tmp"
        fi
      done <"$file"
      if fi_ledger_replace "$file" "$tmp" "$snapshot"; then
        printf 'Escalated to critical: %s\n' "$esc_line"
      else
        fi_err "found-issues log: the ledger changed while escalating — re-run"
        return 1
      fi
      _fi_log_tag_existing "$file" "$esc_line" || return 1
      cmd_status plain
      return 0
    fi
    if [[ -n "$tag_kind" ]]; then
      _fi_log_tag_existing "$file" "$matched_entry" || return 1
      if [[ "$_fi_log_line" != "$matched_entry" ]]; then
        cmd_status plain
        return 0
      fi
    fi
    printf 'Skipped — already logged: %s\n' "$matched_entry"
    cmd_status plain
    return 0
  fi

  if [[ "$matched_status" == "deferred" ]]; then
    _fi_log_tag_existing "$file" "$matched_entry" || return 1
    fi_handle_deferred_touch "$file" "$_fi_log_line"
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
  if [[ -n "$tag_kind" ]]; then
    fi_entry_retag "$entry" "$FI_TAG_KIND" "$FI_TAG_VALUE"
    entry="$FI_RETAGGED"
  fi

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

