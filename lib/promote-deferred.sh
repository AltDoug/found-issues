#!/usr/bin/env bash
# promote-deferred.sh — flip [deferred] back to [open]
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Extracted verbatim from bin/found-issues in v2.2.7 (the tracked §12 split);
# see the [open] loc-validator entry in docs/found-issues.md.
#
# Functions:
#   cmd_promote_deferred [...]
#
# fi_promote_entry_to_open is called from here but DEFINED in resolve.sh: it is
# shared with the deferred-touch nudge in help.sh, and a verbatim move keeps
# each function in the block it was defined in.

# === Subcommand: promote-deferred ===
#
# Flips [deferred] → [open] for the entry matching <match>.
# All annotations preserved byte-identical (touch history + defer-cycle +
# reason serve as evidence of recurrence and historical context).
#
# Exits:
#   0 success
#   1 no matching [deferred] entry
#   2 ambiguous (multiple matches)
#   3 entry is [open], not [deferred] (helpful message)
cmd_promote_deferred() {
  local match=""

  # Argument parsing — accept positional or --match
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --match)
        match="${2:-}"
        shift 2 || break
        ;;
      *)
        if [[ -z "$match" ]]; then
          match="$1"
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$match" ]]; then
    fi_err "promote-deferred: missing <match> argument"
    fi_err "Usage: found-issues promote-deferred <match>   OR   --match <match>"
    return 2
  fi

  local file
  file="$(fi_resolve_issues_file)"

  # Find matching [deferred] entries
  local matches=()
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local lower_entry lower_match
    lower_entry="$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')"
    lower_match="$(printf '%s' "$match" | tr '[:upper:]' '[:lower:]')"
    if [[ "$lower_entry" == *"$lower_match"* ]]; then
      matches+=("$entry")
    fi
  done < <(fi_entries "$file" deferred 2>/dev/null || true)

  if (( ${#matches[@]} == 0 )); then
    # Check whether the match hits an [open] entry — different error.
    local open_matches=()
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      local lower_entry lower_match
      lower_entry="$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')"
      lower_match="$(printf '%s' "$match" | tr '[:upper:]' '[:lower:]')"
      if [[ "$lower_entry" == *"$lower_match"* ]]; then
        open_matches+=("$entry")
      fi
    done < <(fi_entries "$file" open 2>/dev/null || true)

    if (( ${#open_matches[@]} > 0 )); then
      fi_err "promote-deferred: not [deferred] — match \"$match\" hits an [open] entry already."
      return 3
    fi

    fi_err "promote-deferred: no [deferred] entries match \"$match\""
    return 1
  fi

  if (( ${#matches[@]} > 1 )); then
    fi_err "promote-deferred: ambiguous match — ${#matches[@]} [deferred] entries match \"$match\":"
    local m
    for m in "${matches[@]}"; do
      fi_err "  $m"
    done
    fi_err "Use a more specific match."
    return 2
  fi

  local target="${matches[0]}"

  if ! fi_promote_entry_to_open "$file" "$target"; then
    fi_err "promote-deferred: internal error mutating file"
    return 5
  fi

  printf 'Promoted [deferred] → [open]: %s\n' "$target"
  if [[ "$target" == *"(touched:"* ]]; then
    printf 'Touch history preserved as evidence of recurrence.\n'
  fi
}

