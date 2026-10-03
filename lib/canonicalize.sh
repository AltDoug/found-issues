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

# === Builtin twins (2026-10-03 audit, cli-10 / hook-12) ===
#
# fi_dedup_key / fi_dedup_key_abstract fork ~8 processes per call (three
# subshells, two `tr`, a `git rev-parse` for the repo root), and `log`,
# pre-branch-delete and sync call them once per ledger entry. These twins set
# $FI_KEY instead of printing and use only builtins on bash >= 4 (one `tr`
# on bash 3.2, which has no ${x,,}). Keys are never stored — every comparison
# computes both sides with the same function in the same process — so the
# twins only have to be self-consistent, not byte-identical to the printing
# versions (they differ only in how non-ASCII case folds).

# Repo root, resolved once per process per working directory.
_FI_ROOT_CACHE_DIR="" _FI_ROOT_CACHE=""
fi_repo_root_cached() {
  if [[ "$_FI_ROOT_CACHE_DIR" != "$PWD" ]]; then
    _FI_ROOT_CACHE="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    _FI_ROOT_CACHE_DIR="$PWD"
  fi
  FI_REPO_ROOT="$_FI_ROOT_CACHE"
}

# _fi_canon_symptom_v <text> <n> — lowercase, squeeze whitespace, trim,
# truncate to n characters. Result in $_fi_canon.
_fi_canon_symptom_v() {
  local s="$1" n="$2"
  if (( BASH_VERSINFO[0] >= 4 )); then
    s="${s,,}"
  else
    s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')"
  fi
  local IFS=$' \t\n\r\v\f'
  local -a w=()
  read -r -d '' -a w <<<"$s" || true
  s="${w[*]+"${w[*]}"}"
  _fi_canon="${s:0:n}"
}

# fi_dedup_key_v <path> <line> <symptom> [<repo_root>] — $FI_KEY
fi_dedup_key_v() {
  local path="$1" line="$2" symptom="$3" root="${4-}"
  local bare="${symptom%%(*}"
  bare="${bare%"${bare##*[![:space:]]}"}"
  path="${path#"${path%%[![:space:]]*}"}"
  path="${path%"${path##*[![:space:]]}"}"
  path="${path//\\//}"
  while [[ "$path" == ./* ]]; do path="${path#./}"; done
  if [[ -z "$root" ]]; then
    fi_repo_root_cached
    root="$FI_REPO_ROOT"
  fi
  [[ -n "$root" && "$path" == "$root"/* ]] && path="${path#"$root"/}"
  _fi_canon_symptom_v "$bare" 50
  FI_KEY="$path:$line:$_fi_canon"
}

# fi_dedup_key_abstract_v <symptom> — $FI_KEY
fi_dedup_key_abstract_v() {
  local bare="${1%%(*}"
  bare="${bare%"${bare##*[![:space:]]}"}"
  _fi_canon_symptom_v "$bare" 80
  FI_KEY="abstract::$_fi_canon"
}

# fi_entry_dedup_key_v <entry line> [<repo_root>] — the dedup key `log` uses
# for an existing entry (path:line, path-only, or abstract), in $FI_KEY.
# Returns 1 when the line is not an entry.
fi_entry_dedup_key_v() {
  fi_parse_entry_vars "$1" || return 1
  if [[ -n "$FE_line" ]]; then
    fi_dedup_key_v "$FE_path" "$FE_line" "$FE_symptom" "${2-}"
  elif [[ "$FE_path" == */* || "$FE_path" == *.* ]]; then
    fi_dedup_key_v "$FE_path" "" "$FE_symptom" "${2-}"
  else
    fi_dedup_key_abstract_v "$FE_symptom"
  fi
}
