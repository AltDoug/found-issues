#!/usr/bin/env bats
# ============================================================================
# Contract tests for `found-issues status --format=segment`
# ============================================================================
# These tests lock the public output shape that user statuslines depend on.
# `/found-issues:setup` splices this call into user statusline scripts on
# their own machines, and those splices render whatever bytes the segment
# command emits. Shape changes silently break every installed integration.
#
# If a test here fails after a code change:
#   - The fix lives in the code change, not in this file.
#   - Adjust the implementation so the locked output is preserved.
#   - Updating an assertion here to match new output would ship the
#     breaking change.
#
# Evolution path (when v1 genuinely needs to change) is documented in
# docs/statusline-integration-contract.md — additive only: introduce
# `--format=segment-v2` alongside the frozen v1.
# ============================================================================

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

# Shared failure message for snapshot mismatches. Printed inline by the
# assertions below — keeps the warning visible at the moment of failure.
CONTRACT_NOTE='PUBLIC CONTRACT TEST FAILED.

This test locks the output of `found-issues status --format=segment`.
User statuslines call this command on their own machines and render its
output directly. Changing the output shape silently breaks every
integrated statusline.

Correct fix: adjust the in-progress code change that caused the output
to shift, so the locked output is preserved. Updating this assertion to
match the new output would let the breaking change ship.

If the contract genuinely needs to evolve, the migration path is in
docs/statusline-integration-contract.md — additive only (introduce
--format=segment-v2 alongside frozen v1).'

# ============================================================================
# Empty-output cases — the most load-bearing part of the contract.
# User statuslines render the segment unconditionally; if a "no issues"
# state ever started emitting characters, every user's statusline would
# get a phantom badge.
# ============================================================================

@test "contract(segment): empty stdout when no found-issues.md file exists" {
  fi_run status --format=segment
  [ "$status" -eq 0 ] || { echo "$CONTRACT_NOTE"; echo "Got exit code: $status"; false; }
  [ -z "$output" ] || { echo "$CONTRACT_NOTE"; echo "Expected empty, got: [$output]"; false; }
}

@test "contract(segment): empty stdout when file exists but contains no entries" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
EOF
  fi_run status --format=segment
  [ "$status" -eq 0 ] || { echo "$CONTRACT_NOTE"; echo "Got exit code: $status"; false; }
  [ -z "$output" ] || { echo "$CONTRACT_NOTE"; echo "Expected empty, got: [$output]"; false; }
}

@test "contract(segment): empty stdout when only [fixed] entries exist" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [fixed] 2026-04-15 src/foo.py:42 — old bug (PR: org/repo#1) (fixed: 2026-04-16)
EOF
  fi_run status --format=segment
  [ "$status" -eq 0 ] || { echo "$CONTRACT_NOTE"; echo "Got exit code: $status"; false; }
  [ -z "$output" ] || { echo "$CONTRACT_NOTE"; echo "Expected empty, got: [$output]"; false; }
}

@test "contract(segment): empty stdout when only [deferred] entries exist" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/bar.py:99 — kicked down road
EOF
  fi_run status --format=segment
  [ "$status" -eq 0 ] || { echo "$CONTRACT_NOTE"; echo "Got exit code: $status"; false; }
  [ -z "$output" ] || { echo "$CONTRACT_NOTE"; echo "Expected empty, got: [$output]"; false; }
}

# ============================================================================
# Byte-snapshot cases — exact-output assertions for canonical inputs.
# These catch any silent shift in prefix, separator, color codes, or label
# wording that would re-render every user's statusline differently.
# ============================================================================

@test "contract(segment): single [open] entry -> ' | <red>1 issue<reset>'" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] 2026-05-10 src/foo.py:42 — null check
EOF
  fi_run status --format=segment
  [ "$status" -eq 0 ] || { echo "$CONTRACT_NOTE"; echo "Got exit code: $status"; false; }
  local expected=$' | \033[31m1 issue\033[0m'
  [ "$output" = "$expected" ] || {
    echo "$CONTRACT_NOTE"
    printf 'Expected (bytes): '; printf '%s' "$expected" | od -c | head -2
    printf 'Got (bytes):      '; printf '%s' "$output"   | od -c | head -2
    false
  }
}

@test "contract(segment): three [open] entries -> ' | <red>3 issues<reset>' (plural)" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] 2026-05-10 src/a.py:1 — x
- [open] 2026-05-10 src/b.py:1 — y
- [open] 2026-05-10 src/c.py:1 — z
EOF
  fi_run status --format=segment
  [ "$status" -eq 0 ] || { echo "$CONTRACT_NOTE"; echo "Got exit code: $status"; false; }
  local expected=$' | \033[31m3 issues\033[0m'
  [ "$output" = "$expected" ] || {
    echo "$CONTRACT_NOTE"
    printf 'Expected (bytes): '; printf '%s' "$expected" | od -c | head -2
    printf 'Got (bytes):      '; printf '%s' "$output"   | od -c | head -2
    false
  }
}

@test "contract(segment): single critical -> ' | <bold-red>1 critical<reset>'" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] [!] 2026-05-10 src/auth.ts:88 — leaks token
EOF
  fi_run status --format=segment
  [ "$status" -eq 0 ] || { echo "$CONTRACT_NOTE"; echo "Got exit code: $status"; false; }
  local expected=$' | \033[1;31m1 critical\033[0m'
  [ "$output" = "$expected" ] || {
    echo "$CONTRACT_NOTE"
    printf 'Expected (bytes): '; printf '%s' "$expected" | od -c | head -2
    printf 'Got (bytes):      '; printf '%s' "$output"   | od -c | head -2
    false
  }
}

@test "contract(segment): mixed critical + open -> relabels residual to other, joined by space-middot-space" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] [!] 2026-05-10 src/auth.ts:88 — leaks token
- [open] 2026-05-10 src/foo.py:42 — null check
EOF
  fi_run status --format=segment
  [ "$status" -eq 0 ] || { echo "$CONTRACT_NOTE"; echo "Got exit code: $status"; false; }
  local expected=$' | \033[1;31m1 critical\033[0m \xc2\xb7 \033[31m1 other\033[0m'
  [ "$output" = "$expected" ] || {
    echo "$CONTRACT_NOTE"
    printf 'Expected (bytes): '; printf '%s' "$expected" | od -c | head -3
    printf 'Got (bytes):      '; printf '%s' "$output"   | od -c | head -3
    false
  }
}

@test "contract(segment): in-PR entry uses yellow (\\\\033[33m)" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] 2026-05-10 src/foo.py:42 — null check (PR: org/repo#5)
EOF
  fi_run status --format=segment
  [ "$status" -eq 0 ] || { echo "$CONTRACT_NOTE"; echo "Got exit code: $status"; false; }
  # When in-PR is the only counter, residual is 0, so the output is just
  # the in-PR bucket — locks the yellow color code in place.
  local expected=$' | \033[33m1 in PR\033[0m'
  [ "$output" = "$expected" ] || {
    echo "$CONTRACT_NOTE"
    printf 'Expected (bytes): '; printf '%s' "$expected" | od -c | head -2
    printf 'Got (bytes):      '; printf '%s' "$output"   | od -c | head -2
    false
  }
}

# ============================================================================
# Structural invariants — properties that must hold for every non-empty
# output, regardless of bucket combination.
# ============================================================================

@test "contract(segment): non-empty output never has a trailing newline" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] 2026-05-10 src/foo.py:42 — null check
EOF
  # bats's $output strips one trailing newline, so we check via wc + od
  # against a direct invocation that preserves bytes.
  local raw
  raw="$("$FI_BIN" status --format=segment)"
  [ "$status" -eq 0 ] || true
  # Compare lengths: if there's a trailing newline, raw via $() would have
  # had it stripped too — but printf without %s\n means there is none to
  # strip. We verify by re-emitting and checking byte count matches.
  local byte_count
  byte_count="$(printf '%s' "$raw" | wc -c | tr -d ' ')"
  local with_newline_count=$(( byte_count + 1 ))
  local actual_emit_count
  actual_emit_count="$("$FI_BIN" status --format=segment | wc -c | tr -d ' ')"
  [ "$actual_emit_count" = "$byte_count" ] || {
    echo "$CONTRACT_NOTE"
    echo "Trailing newline detected — segment must not emit a trailing \\\\n."
    echo "Bytes without newline: $byte_count; bytes as emitted: $actual_emit_count (expected: $byte_count, not $with_newline_count)"
    false
  }
}

@test "contract(segment): non-empty output always begins with ' | ' (space-pipe-space)" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] 2026-05-10 src/foo.py:42 — null check
EOF
  fi_run status --format=segment
  [ "$status" -eq 0 ] || { echo "$CONTRACT_NOTE"; echo "Got exit code: $status"; false; }
  [[ "$output" == " | "* ]] || {
    echo "$CONTRACT_NOTE"
    echo "Expected output to begin with ' | ' (space-pipe-space); got: [$output]"
    false
  }
}

# ============================================================================
# Failure-mode contract — must silent-fail to empty stdout, never error.
# A user statusline that started rendering "Error: ..." bytes mid-line
# would be highly visible breakage.
# ============================================================================

@test "contract(segment): silent-fail (empty stdout, exit 0) when docs dir is unreadable" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] 2026-05-10 src/foo.py:42 — null check
EOF
  # Strip read permissions on the docs dir to simulate a permission error.
  # macOS and Linux both honor this for non-root callers.
  if [ "$(id -u)" = "0" ]; then
    skip "root bypasses permission bits — can't simulate this case"
  fi
  # Windows file systems (NTFS via Git Bash MSYS/MINGW) don't honor POSIX
  # permission bits, so `chmod 000` is a no-op there and the segment finds
  # the seeded entry instead of failing to read. The silent-fail contract
  # property still holds on Windows — it just isn't testable via chmod.
  case "${OSTYPE:-}" in
    msys*|cygwin*|mingw*) skip "chmod 000 not honored on Windows file systems" ;;
  esac
  chmod 000 docs
  fi_run status --format=segment
  local exit_code="$status"
  chmod 755 docs  # restore so teardown can clean up
  [ "$exit_code" -eq 0 ] || { echo "$CONTRACT_NOTE"; echo "Expected exit 0 (silent-fail), got: $exit_code"; false; }
  [ -z "$output" ] || { echo "$CONTRACT_NOTE"; echo "Expected empty stdout on read error, got: [$output]"; false; }
}
