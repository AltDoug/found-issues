#!/usr/bin/env bash
# resolve.sh — flip [open] to [fixed]
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Extracted verbatim from bin/found-issues in v2.2.7 (the tracked §12 split);
# see the [open] loc-validator entry in docs/found-issues.md.
#
# Functions:
#   cmd_resolve [...]
#   fi_promote_entry_to_open <file> <entry>
#     Defined here, called from promote-deferred.sh and help.sh. It sat in the
#     resolve block in the CLI and a verbatim move leaves it there.

# === Subcommand: resolve ===
#
# Flips [open] → [fixed] for the entry matching <match>, appending
# `(verified: <who>) (fixed: <today>)`.
#
# Exists so agents never hand-edit the ledger. commands/sync.md Phase 2 used
# to instruct "edit the file: change [open] → [fixed] and append
# (verified: ai) (fixed: YYYY-MM-DD)" and shipped `Edit` in its allowed-tools,
# which is the unserialized direct write the CLI exists to prevent — lost
# writes under concurrent sessions, format drift, guard bypass (#124).
#
# Match semantics and exit codes mirror `defer` deliberately, so the two
# closure verbs behave the same way under ambiguity.
#
# Exits:
#   0 success
#   1 no matching [open] entry
#   2 usage error, bad --verified value, or ambiguous match
#   3 entry is already [fixed]
#   4 entry has an active (PR: ...) annotation
cmd_resolve() {
  local match=""
  local verified="ai"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --match)
        match="${2:-}"
        shift 2 || break
        ;;
      --verified)
        verified="${2:-}"
        shift 2 || break
        ;;
      -h|--help)
        printf 'Usage: found-issues resolve <match>   OR   --match <match>\n'
        printf '       [--verified ai|human]   (default: ai)\n'
        return 0
        ;;
      *)
        [[ -z "$match" ]] && match="$1"
        shift
        ;;
    esac
  done

  if [[ -z "$match" ]]; then
    fi_err "resolve: missing <match> argument"
    fi_err "Usage: found-issues resolve <match> [--verified ai|human]   OR   --match <match>"
    return 2
  fi

  # Only two verdict sources are meaningful: an agent that read the code, or a
  # human who confirmed it. Anything else would land in the ledger as an
  # unrecognized annotation and drift the format.
  if [[ "$verified" != "ai" && "$verified" != "human" ]]; then
    fi_err "resolve: --verified must be 'ai' or 'human', got: $verified"
    return 2
  fi

  local file
  file="$(fi_resolve_issues_file)"

  local matches=()
  local entry lower_entry lower_match
  lower_match="$(printf '%s' "$match" | tr '[:upper:]' '[:lower:]')"
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    lower_entry="$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')"
    if [[ "$lower_entry" == *"$lower_match"* ]]; then
      matches+=("$entry")
    fi
  done < <(fi_entries "$file" open 2>/dev/null || true)

  if (( ${#matches[@]} == 0 )); then
    # Distinguish "already closed" from "never existed" — re-running sync over
    # a ledger it just cleaned would otherwise report a confusing hard failure.
    local fixed_matches=()
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      lower_entry="$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')"
      if [[ "$lower_entry" == *"$lower_match"* ]]; then
        fixed_matches+=("$entry")
      fi
    done < <(fi_entries "$file" fixed 2>/dev/null || true)

    if (( ${#fixed_matches[@]} > 0 )); then
      fi_err "resolve: already [fixed]. Nothing to do."
      return 3
    fi

    fi_err "resolve: no [open] entries match \"$match\""
    return 1
  fi

  if (( ${#matches[@]} > 1 )); then
    fi_err "resolve: ambiguous match — ${#matches[@]} [open] entries match \"$match\":"
    local m
    for m in "${matches[@]}"; do
      fi_err "  $m"
    done
    fi_err "Use a more specific match."
    return 2
  fi

  local target="${matches[0]}"

  # An active (PR: ...) annotation means in-flight work. Closing it by hand
  # races the PR-merge flip that `sync` performs, and sync.md already excludes
  # such entries from AI verification. Same refusal `defer` makes.
  local re_pr='\(PR: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+\)'
  if [[ "$target" =~ $re_pr ]]; then
    local pr_match="${BASH_REMATCH[0]}"
    fi_err "resolve: entry has an active PR annotation $pr_match."
    fi_err "It will flip to [fixed] on its own when that PR merges (via /found-issues:sync)."
    fi_err "If the PR was abandoned, remove the annotation first, then re-run resolve."
    return 4
  fi

  local today
  today="$(fi_today)"

  local tmp
  tmp="$(mktemp -t fi-resolve.XXXXXX)"
  local found=0
  local line
  # Final-partial-line guard — see the READ-LOOP GUARD block in bin/found-issues.
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$target" ]] && (( found == 0 )); then
      found=1
      local new_line="${line/- \[open\]/- [fixed]}"
      new_line="${new_line} (verified: ${verified}) (fixed: ${today})"
      printf '%s\n' "$new_line" >> "$tmp"
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"
  mv "$tmp" "$file"

  printf 'Resolved 1 entry. (verified: %s, fixed: %s)\n' "$verified" "$today"
  cmd_status plain
}

# Flip a single matched [deferred] entry to [open] in $file.
# Returns 0 on success. Used by both cmd_promote_deferred (matches by user
# input) and fi_handle_deferred_touch (matches by exact entry).
#
# Strips (mute-until: ...) on flip — the annotation is a defer-state
# concept; an [open] entry has no nudge to suppress. touch history,
# defer-cycle, and reason annotations are preserved as evidence per
# the defer-recurrence-flow design.
fi_promote_entry_to_open() {
  local file="$1"
  local target="$2"
  local tmp
  tmp="$(mktemp -t fi-promote.XXXXXX)"
  local found=0
  local line
  # Final-partial-line guard — see the READ-LOOP GUARD block in bin/found-issues.
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$target" ]] && (( found == 0 )); then
      found=1
      local new_line="${line/- \[deferred\]/- [open]}"
      new_line="$(printf '%s' "$new_line" | sed -E 's/ \(mute-until: [0-9]{4}-[0-9]{2}-[0-9]{2}\)//g')"
      printf '%s\n' "$new_line" >> "$tmp"
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"
  if (( found == 0 )); then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$file"
  return 0
}

