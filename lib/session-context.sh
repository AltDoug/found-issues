#!/usr/bin/env bash
# session-context.sh — entry selectors for the lean SessionStart injection
# and the first-touch hook (3.4.0, spec 2026-10-07-session-start-cut).
#
# Sourced by bin/found-issues and hooks/first-touch.sh. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   fi_sc_entry_path <entry-line>
#   fi_sc_entries_for_path <ledger-file> <relpath>
#   fi_sc_pathless <open-entries-text> <repo-root> <max>

fi_sc_entry_path() {
  fi_parse_entry_vars "$1" 2>/dev/null || return 1
  [[ -n "${FE_path:-}" ]] || return 1
  printf '%s' "$FE_path"
}

fi_sc_entries_for_path() {
  local file="$1" want="$2" line p
  [[ -f "$file" && -n "$want" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    p="$(fi_sc_entry_path "$line")" || continue
    [[ "$p" == "$want" ]] && printf '%s\n' "$line"
  done < <(fi_entries "$file" open 2>/dev/null || true)
  return 0
}

fi_sc_pathless() {
  local text="$1" root="$2" max="$3" line p n=0 out=()
  [[ "$max" =~ ^[0-9]+$ ]] || max=3
  while IFS= read -r line; do
    [[ "$line" == "- [open] "* ]] || continue
    [[ "$line" == "- [open] [!] "* ]] && continue
    p="$(fi_sc_entry_path "$line")" || p=""
    [[ -n "$p" && -f "$root/$p" ]] && continue
    out+=("$line")
  done <<< "$text"
  local i=$(( ${#out[@]} - 1 ))
  while (( i >= 0 && n < max )); do
    printf '%s\n' "${out[$i]}"
    i=$((i - 1)); n=$((n + 1))
  done
  return 0
}
