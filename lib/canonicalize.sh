#!/usr/bin/env bash
# canonicalize.sh — path/symptom normalization and dedup keys
#
# Sourced by other scripts. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   fi_canonicalize_path <path> [<repo_root>]
#       Resolve to repo-relative form. Strips ./, normalizes separators,
#       converts absolute paths under repo_root to relative.
#
#   fi_canonicalize_symptom <symptom> [<n=50>]
#       Lowercase, collapse whitespace, truncate to N chars.
#
#   fi_dedup_key <path> <line> <symptom>
#       Generate a stable dedup key from canonicalized inputs.

# Resolve a path to repo-relative form.
fi_canonicalize_path() {
  local input="$1"
  local repo_root="${2:-}"

  # Strip leading/trailing whitespace
  input="${input#"${input%%[![:space:]]*}"}"
  input="${input%"${input##*[![:space:]]}"}"

  # Normalize separators (Windows backslashes -> forward slash)
  input="${input//\\//}"

  # Strip leading ./
  while [[ "$input" == ./* ]]; do
    input="${input#./}"
  done

  # If no repo_root given, try to detect from git
  if [[ -z "$repo_root" ]]; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  fi

  # If input is absolute and under repo_root, make it relative
  if [[ -n "$repo_root" && "$input" == "$repo_root"/* ]]; then
    input="${input#"$repo_root"/}"
  fi

  printf '%s' "$input"
}

# Normalize a symptom string for dedup comparison.
# Lowercase, collapse internal whitespace to single space, trim, truncate.
fi_canonicalize_symptom() {
  local input="$1"
  local n="${2:-50}"

  local normalized
  normalized="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ')"

  # Trim leading/trailing whitespace
  normalized="${normalized#"${normalized%%[![:space:]]*}"}"
  normalized="${normalized%"${normalized##*[![:space:]]}"}"

  # Truncate to N chars
  printf '%.*s' "$n" "$normalized"
}

# Strip parenthetical annotations from a symptom string.
# "null check missing (suggested: add guard) (PR: org/repo#5)" -> "null check missing"
# Used by dedup so the same bug logged with vs. without a suggestion still dedups.
fi_strip_parentheticals() {
  local input="$1"
  local bare="${input%%(*}"
  bare="${bare%"${bare##*[![:space:]]}"}"
  printf '%s' "$bare"
}

# Generate dedup key: canonical_path + line + first 50 chars of bare symptom.
# Strips parentheticals before canonicalizing so dedup is annotation-agnostic.
fi_dedup_key() {
  local path="$1"
  local line="$2"
  local symptom="$3"

  local bare cpath cks
  bare="$(fi_strip_parentheticals "$symptom")"
  cpath="$(fi_canonicalize_path "$path")"
  cks="$(fi_canonicalize_symptom "$bare" 50)"

  printf '%s:%s:%s' "$cpath" "$line" "$cks"
}

# Dedup key for abstract entries (no path:line). Uses 80 chars of bare symptom.
fi_dedup_key_abstract() {
  local symptom="$1"
  local bare
  bare="$(fi_strip_parentheticals "$symptom")"
  printf 'abstract::%s' "$(fi_canonicalize_symptom "$bare" 80)"
}
