#!/usr/bin/env bats
# Tests for scripts/check-version.sh
#
# The script enforces:
#   1. FI_VERSION in bin/found-issues matches the top CHANGELOG version.
#   2. "version" field in .claude-plugin/plugin.json matches FI_VERSION.
#   2b. "version" field in .codex-plugin/plugin.json matches FI_VERSION too.
#   3. A PATCH-only bump must NOT contain '### Added' in its section.

load 'helpers'

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/check-version.sh"

# Default codex plugin.json fixture, parameterised by version. Tests that
# care about the codex-manifest invariant call this AFTER fi_write_plugin_json
# to override with a mismatched version.
fi_write_codex_plugin_json() {
  local version="$1"
  mkdir -p "$TMP/.codex-plugin"
  cat > "$TMP/.codex-plugin/plugin.json" <<EOF
{
  "name": "found-issues",
  "version": "$version",
  "skills": "./codex-skills",
  "hooks": "./hooks/hooks.json"
}
EOF
}

# Default plugin.json fixture, parameterised by version. Tests that care about
# the plugin.json invariant override $PJ_VERSION before writing; tests that
# don't care just inherit the matching default. Also writes a matching codex
# plugin.json (check-version.sh requires both manifests to exist) — tests
# exercising the codex-specific invariant call fi_write_codex_plugin_json
# again afterward with a different version.
fi_write_plugin_json() {
  local version="$1"
  mkdir -p "$TMP/.claude-plugin"
  cat > "$TMP/.claude-plugin/plugin.json" <<EOF
{
  "name": "found-issues",
  "version": "$version"
}
EOF
  fi_write_codex_plugin_json "$version"
}

setup() {
  fi_setup_tmp
  # Build a fresh minimal fixture (CLI file + CHANGELOG + plugin.json +
  # codex plugin.json) per test, override the script's lookups via env vars.
  # Keeps each test isolated and avoids depending on the real repo state.
  CLI="$TMP/bin/found-issues"
  CL="$TMP/CHANGELOG.md"
  PJ="$TMP/.claude-plugin/plugin.json"
  PJC="$TMP/.codex-plugin/plugin.json"
  mkdir -p "$TMP/bin"
  export CHECK_VERSION_CLI_FILE="$CLI"
  export CHECK_VERSION_CHANGELOG="$CL"
  export CHECK_VERSION_PLUGIN_JSON="$PJ"
  export CHECK_VERSION_CODEX_JSON="$PJC"
}

teardown() {
  fi_teardown_tmp
  unset CHECK_VERSION_CLI_FILE CHECK_VERSION_CHANGELOG CHECK_VERSION_PLUGIN_JSON CHECK_VERSION_CODEX_JSON
}

# --- Positive paths ---

@test "check-version: PATCH bump with no ### Added passes" {
  printf 'readonly FI_VERSION="1.0.6"\n' > "$CLI"
  fi_write_plugin_json "1.0.6"
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
  fi_write_plugin_json "1.1.0"
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
  fi_write_plugin_json "2.0.0"
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
  fi_write_plugin_json "1.0.0"
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
  fi_write_plugin_json "1.0.5"
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
  fi_write_plugin_json "1.0.7"
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
  fi_write_plugin_json "1.0.0"
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
  fi_write_plugin_json "1.0.0"
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
  fi_write_plugin_json "1.0.6"
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
  # Sanity check that the actual repo bin/found-issues + CHANGELOG.md +
  # plugin.json + codex plugin.json pass the check (i.e. release branches
  # that get to this point are valid).
  unset CHECK_VERSION_CLI_FILE CHECK_VERSION_CHANGELOG CHECK_VERSION_PLUGIN_JSON CHECK_VERSION_CODEX_JSON
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "codex and claude plugin manifests carry the same version" {
  cv="$(jq -r .version "$TEST_REPO_ROOT/.codex-plugin/plugin.json")"
  av="$(jq -r .version "$TEST_REPO_ROOT/.claude-plugin/plugin.json")"
  [ "$cv" = "$av" ]
}

@test "codex manifest points skills at codex-skills and hooks at hooks.json" {
  [ "$(jq -r .skills "$TEST_REPO_ROOT/.codex-plugin/plugin.json")" = "./codex-skills" ]
  [ "$(jq -r .hooks  "$TEST_REPO_ROOT/.codex-plugin/plugin.json")" = "./hooks/hooks.json" ]
}

# --- plugin.json invariant ---
# These guard the manifest-drift class of bug: plugin.json silently lags
# behind FI_VERSION across releases (the 1.0.5 → 1.1.0 drift was caught by
# a friend pre-launch — not by CI).

@test "check-version: plugin.json version mismatch with FI_VERSION fails (exit 1)" {
  printf 'readonly FI_VERSION="1.1.0"\n' > "$CLI"
  fi_write_plugin_json "1.0.5"
  cat > "$CL" <<'EOF'
# Changelog

## [1.1.0] — 2026-05-11

### Added

- New thing
EOF
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"plugin.json version mismatch"* ]]
  [[ "$output" == *"1.0.5"* ]]
  [[ "$output" == *"1.1.0"* ]]
}

@test "check-version: codex plugin.json version mismatch with FI_VERSION fails (exit 1)" {
  printf 'readonly FI_VERSION="1.1.0"\n' > "$CLI"
  fi_write_plugin_json "1.1.0"
  fi_write_codex_plugin_json "1.0.5"
  cat > "$CL" <<'EOF'
# Changelog

## [1.1.0] — 2026-05-11

### Added

- New thing
EOF
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"codex plugin.json version mismatch"* ]]
  [[ "$output" == *"1.0.5"* ]]
  [[ "$output" == *"1.1.0"* ]]
}

@test "check-version: missing codex plugin.json fails (exit 2)" {
  printf 'readonly FI_VERSION="1.0.0"\n' > "$CLI"
  fi_write_plugin_json "1.0.0"
  rm -f "$PJC"
  cat > "$CL" <<'EOF'
## [1.0.0] — 2026-05-09
EOF
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"codex plugin.json not found"* ]]
}

@test "check-version: missing plugin.json fails (exit 2)" {
  printf 'readonly FI_VERSION="1.0.0"\n' > "$CLI"
  rm -f "$PJ"
  cat > "$CL" <<'EOF'
## [1.0.0] — 2026-05-09
EOF
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"plugin.json not found"* ]]
}

@test "check-version: malformed plugin.json (no version field) fails (exit 2)" {
  printf 'readonly FI_VERSION="1.0.0"\n' > "$CLI"
  mkdir -p "$TMP/.claude-plugin"
  printf '{ "name": "found-issues" }\n' > "$PJ"
  cat > "$CL" <<'EOF'
## [1.0.0] — 2026-05-09
EOF
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not parse \"version\""* ]]
}
