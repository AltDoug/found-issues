#!/usr/bin/env bats
# Tests for scripts/check-version.sh
#
# The script enforces:
#   1. FI_VERSION in bin/found-issues matches the top CHANGELOG version.
#   2. A PATCH-only bump must NOT contain '### Added' in its section.

load 'helpers'

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/check-version.sh"

setup() {
  fi_setup_tmp
  # Build a fresh minimal fixture (CLI file + CHANGELOG) per test, override
  # the script's lookups via env vars. Keeps each test isolated and avoids
  # depending on the real repo state.
  CLI="$TMP/bin/found-issues"
  CL="$TMP/CHANGELOG.md"
  mkdir -p "$TMP/bin"
  export CHECK_VERSION_CLI_FILE="$CLI"
  export CHECK_VERSION_CHANGELOG="$CL"
}

teardown() {
  fi_teardown_tmp
  unset CHECK_VERSION_CLI_FILE CHECK_VERSION_CHANGELOG
}

# --- Positive paths ---

@test "check-version: PATCH bump with no ### Added passes" {
  printf 'readonly FI_VERSION="1.0.6"\n' > "$CLI"
  cat > "$CL" <<'EOF'
# Changelog

## [Unreleased]

## [1.0.6] — 2026-05-11

### Fixed

- Some bug

## [1.0.5] — 2026-05-10

### Added

- Defer flow
EOF
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
  [[ "$output" == *"is PATCH"* ]]
}

@test "check-version: MINOR bump with ### Added passes" {
  printf 'readonly FI_VERSION="1.1.0"\n' > "$CLI"
  cat > "$CL" <<'EOF'
# Changelog

## [Unreleased]

## [1.1.0] — 2026-05-11

### Added

- New doctor subcommand

## [1.0.6] — 2026-05-11

### Fixed

- Bug
EOF
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is MINOR"* ]]
}

@test "check-version: MAJOR bump with ### Added passes" {
  printf 'readonly FI_VERSION="2.0.0"\n' > "$CLI"
  cat > "$CL" <<'EOF'
# Changelog

## [2.0.0] — 2026-06-01

### Added

- New flag

### Changed

- Breaking rename of /found-issues:log to /found-issues:log-entry

## [1.1.0] — 2026-05-11

### Added

- Doctor
EOF
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is MAJOR"* ]]
}

@test "check-version: first release (no previous version) passes" {
  printf 'readonly FI_VERSION="1.0.0"\n' > "$CLI"
  cat > "$CL" <<'EOF'
# Changelog

## [1.0.0] — 2026-05-09

### Added

- Initial release
EOF
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

# --- Negative paths ---

@test "check-version: FI_VERSION mismatch with CHANGELOG fails (exit 1)" {
  printf 'readonly FI_VERSION="1.0.5"\n' > "$CLI"
  cat > "$CL" <<'EOF'
# Changelog

## [1.0.6] — 2026-05-11

### Fixed

- Bug
EOF
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FI_VERSION mismatch"* ]]
  [[ "$output" == *"1.0.5"* ]]
  [[ "$output" == *"1.0.6"* ]]
}

@test "check-version: PATCH bump with ### Added fails (the v1.0.5 mistake)" {
  printf 'readonly FI_VERSION="1.0.7"\n' > "$CLI"
  cat > "$CL" <<'EOF'
# Changelog

## [1.0.7] — 2026-05-11

### Added

- New doctor subcommand
- New defer flag

## [1.0.6] — 2026-05-11

### Fixed

- Bug
EOF
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SemVer violation"* ]]
  [[ "$output" == *"PATCH bump"* ]]
  [[ "$output" == *"### Added"* ]]
  [[ "$output" == *"MINOR"* ]]
}

@test "check-version: missing FI_VERSION line fails (exit 2)" {
  printf '# no version here\n' > "$CLI"
  cat > "$CL" <<'EOF'
# Changelog

## [1.0.0] — 2026-05-09

### Added

- Initial
EOF
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not parse FI_VERSION"* ]]
}

@test "check-version: missing CLI file fails (exit 2)" {
  rm -f "$CLI"
  cat > "$CL" <<'EOF'
## [1.0.0] — 2026-05-09
EOF
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CLI file not found"* ]]
}

@test "check-version: missing CHANGELOG fails (exit 2)" {
  printf 'readonly FI_VERSION="1.0.0"\n' > "$CLI"
  rm -f "$CL"
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"CHANGELOG not found"* ]]
}

@test "check-version: CHANGELOG with only [Unreleased] section fails (exit 2)" {
  printf 'readonly FI_VERSION="1.0.0"\n' > "$CLI"
  cat > "$CL" <<'EOF'
# Changelog

## [Unreleased]

### Added

- Pending stuff
EOF
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no released version sections"* ]]
}

@test "check-version: PATCH bump with ### Changed (not Added) passes" {
  # Confirms the check only blocks on '### Added' — '### Changed' and
  # '### Fixed' are valid PATCH content.
  printf 'readonly FI_VERSION="1.0.6"\n' > "$CLI"
  cat > "$CL" <<'EOF'
# Changelog

## [1.0.6] — 2026-05-11

### Changed

- Renamed segment label

### Fixed

- Stop-hook regression

## [1.0.5] — 2026-05-10

### Added

- Defer flow
EOF
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is PATCH"* ]]
}

@test "check-version: real repo state passes" {
  # Sanity check that the actual repo bin/found-issues + CHANGELOG.md pass
  # the check (i.e. release branches that get to this point are valid).
  unset CHECK_VERSION_CLI_FILE CHECK_VERSION_CHANGELOG
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}
