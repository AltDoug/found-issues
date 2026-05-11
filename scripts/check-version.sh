#!/usr/bin/env bash
# check-version.sh — SemVer enforcement guard
#
# Enforces two invariants on every PR + push to main:
#   1. FI_VERSION in bin/found-issues matches the top-most [X.Y.Z] header
#      in CHANGELOG.md.
#   2. If the latest version's bump from the previous is PATCH-only
#      (X.Y unchanged, Z incremented), the latest CHANGELOG section MUST
#      NOT contain an `### Added` heading. Additive changes require a
#      MINOR bump per SemVer 2.0.0.
#
# Exit codes:
#   0  — both invariants satisfied
#   1  — invariant violation (specific reason printed to stderr)
#   2  — script invocation error (missing files, malformed CHANGELOG)
#
# See docs/versioning.md for the rules + decision tree.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI_FILE="${CHECK_VERSION_CLI_FILE:-$REPO_ROOT/bin/found-issues}"
CHANGELOG="${CHECK_VERSION_CHANGELOG:-$REPO_ROOT/CHANGELOG.md}"

err() { printf 'check-version: %s\n' "$@" >&2; }

if [[ ! -f "$CLI_FILE" ]]; then
  err "CLI file not found at $CLI_FILE"
  exit 2
fi
if [[ ! -f "$CHANGELOG" ]]; then
  err "CHANGELOG not found at $CHANGELOG"
  exit 2
fi

# --- 1. Extract FI_VERSION from the CLI ---
# `|| true` so grep-no-match doesn't exit the script under pipefail+errexit;
# we want to fall through to the "missing FI_VERSION" message.
cli_version="$(grep -E '^readonly FI_VERSION="[0-9]+\.[0-9]+\.[0-9]+"' "$CLI_FILE" 2>/dev/null \
  | head -1 \
  | sed -E 's/^readonly FI_VERSION="([0-9]+\.[0-9]+\.[0-9]+)"/\1/' || true)"

if [[ -z "$cli_version" ]]; then
  err "could not parse FI_VERSION from $CLI_FILE"
  err "expected line: readonly FI_VERSION=\"X.Y.Z\""
  exit 2
fi

# --- 2. Extract released CHANGELOG versions (skip [Unreleased]) ---
# `|| true` same reason as above — grep-no-match should fall through, not abort.
changelog_versions="$(grep -E '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$CHANGELOG" 2>/dev/null \
  | sed -E 's/^## \[([0-9]+\.[0-9]+\.[0-9]+)\].*/\1/' || true)"

if [[ -z "$changelog_versions" ]]; then
  err "no released version sections found in $CHANGELOG"
  err "expected at least one '## [X.Y.Z] — YYYY-MM-DD' header"
  exit 2
fi

latest_version="$(printf '%s\n' "$changelog_versions" | head -1)"
previous_version="$(printf '%s\n' "$changelog_versions" | sed -n '2p')"

# --- 3. Invariant 1: FI_VERSION ⟷ latest CHANGELOG version ---
if [[ "$cli_version" != "$latest_version" ]]; then
  err "FI_VERSION mismatch: bin/found-issues has '$cli_version' but CHANGELOG top is '$latest_version'"
  err "Fix: bump them in lockstep. See docs/versioning.md."
  exit 1
fi

# --- 4. Invariant 2: PATCH bump must not have ### Added ---
if [[ -n "$previous_version" ]]; then
  IFS='.' read -r lat_x lat_y lat_z <<< "$latest_version"
  IFS='.' read -r prev_x prev_y prev_z <<< "$previous_version"

  # Is the bump PATCH-only? Same MAJOR + same MINOR + Z incremented.
  if [[ "$lat_x" == "$prev_x" ]] \
     && [[ "$lat_y" == "$prev_y" ]] \
     && (( lat_z > prev_z )); then
    # Extract the latest version's section content (between its header and
    # the next `## [` heading).
    section="$(awk -v ver="$latest_version" '
      /^## \[/ {
        if (in_block) exit
        if ($0 ~ "^## \\[" ver "\\]") in_block=1
        next
      }
      in_block { print }
    ' "$CHANGELOG")"

    if printf '%s\n' "$section" | grep -qE '^### Added'; then
      err "SemVer violation: $previous_version → $latest_version is a PATCH bump,"
      err "but the [$latest_version] CHANGELOG section contains '### Added'."
      err ""
      err "Additive changes require a MINOR bump. Either:"
      err "  - Bump $latest_version to $lat_x.$((lat_y + 1)).0 (MINOR), or"
      err "  - Move the additive content out of this release."
      err ""
      err "See docs/versioning.md for the rules + decision tree."
      exit 1
    fi
  fi
fi

# All checks pass.
printf 'check-version: OK\n'
printf '  FI_VERSION (%s) matches CHANGELOG top section [%s]\n' "$cli_version" "$latest_version"
if [[ -n "$previous_version" ]]; then
  IFS='.' read -r lat_x lat_y lat_z <<< "$latest_version"
  IFS='.' read -r prev_x prev_y prev_z <<< "$previous_version"
  printf '  Bump from %s -> %s ' "$previous_version" "$latest_version"
  if [[ "$lat_x" != "$prev_x" ]]; then
    printf 'is MAJOR. Breaking changes documented? Check docs/versioning.md.\n'
  elif [[ "$lat_y" != "$prev_y" ]]; then
    printf 'is MINOR. Additive changes OK.\n'
  else
    printf 'is PATCH. No ### Added present (good).\n'
  fi
fi
exit 0
