#!/usr/bin/env bash
# defer.sh — defer — [open] -> [deferred] with reason / mute window
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Extracted verbatim from bin/found-issues in v2.2.7 (the tracked §12 split);
# see the [open] loc-validator entry in docs/found-issues.md.
#
# Functions:
#   cmd_defer [...]

# === Subcommand: defer ===
#
# Flips [open] → [deferred] for the entry matching <match>.
# Match is a substring matched case-insensitively against the entry's path
# OR symptom (after canonicalization). Same matching style as annotate-pr.
#
# On re-defer (entry already has touched: history), increments defer-cycle
# annotation and appends ';' to touched to mark the new cycle boundary.
#
# Exits:
#   0 success
#   1 no matching [open] entry
#   2 ambiguous (multiple matches)
#   3 entry already [deferred] (with helpful re-defer-after-promote message)
#   4 entry has active (PR: ...) annotation (would silently drop from in-PR count)
cmd_defer() {
  local match="${1:-}"
  local reason=""
  local mute_until=""

  # Argument parsing
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reason)
        reason="${2:-}"
        shift 2 || break
        ;;
      --mute-until)
        mute_until="${2:-}"
        shift 2 || break
        ;;
      *)
        shift
        ;;
    esac
  done

  if [[ -z "$match" ]]; then
    fi_err "defer: missing <match> argument"
    fi_err "Usage: found-issues defer <match> [--reason \"<text>\"] [--mute-until YYYY-MM-DD]"
    return 2
  fi

  # Validate --mute-until format if provided. Lexical YYYY-MM-DD is required;
  # we don't run semantic validation (Feb 30 etc.) because cross-platform
  # `date` parsing is gnarly. Bad dates degrade to "annotation present, never
  # matches today's date" which fails open (nudge resumes) — safe.
  if [[ -n "$mute_until" ]]; then
    if ! [[ "$mute_until" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      fi_err "defer: --mute-until value must be YYYY-MM-DD, got: $mute_until"
      return 2
    fi
    # Warn (not error) on a date in the past — the user may have a stale
    # value and probably wants to know, but the entry is still validly
    # deferred (just with a no-op mute).
    local today
    today="$(fi_today)"
    if [[ "$mute_until" < "$today" ]] || [[ "$mute_until" == "$today" ]]; then
      fi_err "defer: warning — --mute-until $mute_until is not in the future (today: $today). The mute will be a no-op; nudges resume on the next touch."
    fi
  fi

  local file
  file="$(fi_resolve_issues_file)"

  # Find matching [open] entries
  local matches=()
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    # Case-insensitive substring match on the whole entry line
    local lower_entry lower_match
    lower_entry="$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')"
    lower_match="$(printf '%s' "$match" | tr '[:upper:]' '[:lower:]')"
    if [[ "$lower_entry" == *"$lower_match"* ]]; then
      matches+=("$entry")
    fi
  done < <(fi_entries "$file" open 2>/dev/null || true)

  if (( ${#matches[@]} == 0 )); then
    # Check whether the match hits a [deferred] entry — different error.
    local deferred_matches=()
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      local lower_entry lower_match
      lower_entry="$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')"
      lower_match="$(printf '%s' "$match" | tr '[:upper:]' '[:lower:]')"
      if [[ "$lower_entry" == *"$lower_match"* ]]; then
        deferred_matches+=("$entry")
      fi
    done < <(fi_entries "$file" deferred 2>/dev/null || true)

    if (( ${#deferred_matches[@]} > 0 )); then
      fi_err "defer: already [deferred]. To re-defer (after promote), use \`found-issues defer\` — defer-cycle increments automatically. To promote back to [open], use \`found-issues promote-deferred --match $match\`."
      return 3
    fi

    fi_err "defer: no [open] entries match \"$match\""
    return 1
  fi

  if (( ${#matches[@]} > 1 )); then
    fi_err "defer: ambiguous match — ${#matches[@]} [open] entries match \"$match\":"
    local m
    for m in "${matches[@]}"; do
      fi_err "  $m"
    done
    fi_err "Use a more specific match."
    return 2
  fi

  local target="${matches[0]}"

  # Block defer of in-PR entries (would silently drop from both issues + in-PR counts)
  local re_pr='\(PR: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+\)'
  if [[ "$target" =~ $re_pr ]]; then
    local pr_match="${BASH_REMATCH[0]}"
    fi_err "defer: entry has an active PR annotation $pr_match."
    fi_err "Deferring an in-flight PR creates a confusing state. Either:"
    fi_err "  1. Wait for the PR to merge (entry will auto-flip to [fixed] via /found-issues:sync)."
    fi_err "  2. Manually remove the (PR: ...) annotation if the PR was abandoned, then re-run defer."
    return 4
  fi

  # Detect re-defer: entry has prior touch history OR existing defer-cycle annotation
  local has_prior_touches=0
  if [[ "$target" == *"(touched:"* ]] || [[ "$target" == *"(defer-cycle:"* ]]; then
    has_prior_touches=1
  fi

  # First: flip [open] → [deferred] and replace any existing (reason: ...)
  # and (mute-until: ...) annotations.
  local tmp
  tmp="$(mktemp -t fi-defer.XXXXXX)"
  local found=0
  local flipped_entry=""
  local line
  # Final-partial-line guard — see the READ-LOOP GUARD block in bin/found-issues.
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$target" ]] && (( found == 0 )); then
      found=1
      local new_line="${line/- \[open\]/- [deferred]}"
      # Strip any existing (reason: ...) and (mute-until: ...) annotations.
      new_line="$(printf '%s' "$new_line" | sed -E 's/ \(reason: [^)]+\)//g')"
      new_line="$(printf '%s' "$new_line" | sed -E 's/ \(mute-until: [0-9]{4}-[0-9]{2}-[0-9]{2}\)//g')"
      # Append new (reason: ...) if --reason was provided.
      if [[ -n "$reason" ]]; then
        new_line="${new_line} (reason: ${reason})"
      fi
      # Append new (mute-until: ...) if --mute-until was provided.
      if [[ -n "$mute_until" ]]; then
        new_line="${new_line} (mute-until: ${mute_until})"
      fi
      flipped_entry="$new_line"
      printf '%s\n' "$new_line" >> "$tmp"
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"
  mv "$tmp" "$file"

  # Second: if this is a re-defer, increment cycle + append ';' to touched
  local current_cycle=1
  if (( has_prior_touches == 1 )); then
    fi_increment_defer_cycle "$file" "$flipped_entry"
    current_cycle="$(fi_extract_defer_cycle "$flipped_entry")"
    current_cycle=$((current_cycle + 1))  # because increment hasn't been re-read
  fi

  local next_threshold
  next_threshold="$(fi_compute_threshold "$current_cycle")"
  if (( current_cycle == 1 )); then
    printf 'Deferred 1 entry. (cycle 1, threshold for nudge: %s touches)\n' "$next_threshold"
  else
    printf 'Re-deferred 1 entry. (cycle %s, threshold for next nudge: %s touches)\n' "$current_cycle" "$next_threshold"
  fi
}

