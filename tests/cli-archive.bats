#!/usr/bin/env bats
# Tests for `found-issues archive`

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
  mkdir -p docs
}

teardown() {
  fi_teardown_tmp
}

# Helper: write a found-issues.md with a mix of fixed entries at given dates
fi_seed_fixed_at_dates() {
  local file="$1"
  shift
  cat > "$file" <<'HEADER'
# found-issues

Test fixture.

HEADER
  for date in "$@"; do
    printf -- '- [fixed] %s src/foo.py:1 — bug from %s (PR: org/repo#1) (fixed: %s)\n' \
      "$date" "$date" "$date" >> "$file"
  done
}

@test "archive: errors when no found-issues.md found" {
  fi_run archive
  [ "$status" -ne 0 ]
  [[ "$output" == *"no found-issues.md found"* ]]
}

@test "archive: nothing to archive when all entries recent" {
  local recent
  recent="$(date -v-5d +%Y-%m-%d 2>/dev/null || date -d '5 days ago' +%Y-%m-%d)"
  fi_seed_fixed_at_dates docs/found-issues.md "$recent" "$recent"
  fi_run archive
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to archive"* ]]
  [ ! -f docs/found-issues-archive.md ]
}

@test "archive: moves entries older than 30 days by default" {
  local old recent
  old="$(date -v-45d +%Y-%m-%d 2>/dev/null || date -d '45 days ago' +%Y-%m-%d)"
  recent="$(date -v-5d +%Y-%m-%d 2>/dev/null || date -d '5 days ago' +%Y-%m-%d)"
  fi_seed_fixed_at_dates docs/found-issues.md "$old" "$recent"

  fi_run archive
  [ "$status" -eq 0 ]
  [[ "$output" == *"moved 1 entries"* ]]

  [ -f docs/found-issues-archive.md ]
  grep -Fq "$old" docs/found-issues-archive.md
  ! grep -Fq "$old" docs/found-issues.md
  grep -Fq "$recent" docs/found-issues.md
}

@test "archive: respects --days override" {
  local d10
  d10="$(date -v-10d +%Y-%m-%d 2>/dev/null || date -d '10 days ago' +%Y-%m-%d)"
  fi_seed_fixed_at_dates docs/found-issues.md "$d10"

  fi_run archive --days=5
  [ "$status" -eq 0 ]
  [[ "$output" == *"moved 1 entries"* ]]
}

@test "archive: --dry-run does not modify files" {
  local old
  old="$(date -v-45d +%Y-%m-%d 2>/dev/null || date -d '45 days ago' +%Y-%m-%d)"
  fi_seed_fixed_at_dates docs/found-issues.md "$old"
  local before
  before=$(shasum docs/found-issues.md | awk '{print $1}')

  fi_run archive --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would move 1 entries"* ]]

  local after
  after=$(shasum docs/found-issues.md | awk '{print $1}')
  [ "$before" = "$after" ]
  [ ! -f docs/found-issues-archive.md ]
}

@test "archive: respects --count threshold (oldest archived first)" {
  local d
  # All 10 entries are recent (within last 30 days), so days threshold doesn't fire
  fi_seed_fixed_at_dates docs/found-issues.md \
    2026-05-01 2026-05-02 2026-05-03 2026-05-04 2026-05-05 \
    2026-05-06 2026-05-07 2026-05-08 2026-05-09 2026-05-10

  fi_run archive --count=5 --days=3650
  [ "$status" -eq 0 ]
  [[ "$output" == *"moved 5 entries"* ]]

  # 5 oldest should be in archive
  grep -Fq "2026-05-01" docs/found-issues-archive.md
  grep -Fq "2026-05-05" docs/found-issues-archive.md
  # 5 newest should remain in active
  grep -Fq "2026-05-06" docs/found-issues.md
  grep -Fq "2026-05-10" docs/found-issues.md
  # Check we don't double-count
  ! grep -Fq "2026-05-01" docs/found-issues.md
  ! grep -Fq "2026-05-10" docs/found-issues-archive.md
}

@test "archive: never touches [open] or [deferred] entries" {
  local old
  old="$(date -v-45d +%Y-%m-%d 2>/dev/null || date -d '45 days ago' +%Y-%m-%d)"
  cat > docs/found-issues.md <<EOF
# found-issues

- [open] $old src/a.py:1 — open from $old
- [deferred] $old src/b.py:1 — deferred from $old
- [fixed] $old src/c.py:1 — fixed from $old (fixed: $old)
EOF

  fi_run archive
  [ "$status" -eq 0 ]

  # Open and deferred preserved
  grep -Fq "src/a.py:1" docs/found-issues.md
  grep -Fq "src/b.py:1" docs/found-issues.md
  # Fixed moved
  ! grep -Fq "src/c.py:1" docs/found-issues.md
  grep -Fq "src/c.py:1" docs/found-issues-archive.md
}

@test "archive: appends to existing archive file (preserves prior content)" {
  local old
  old="$(date -v-45d +%Y-%m-%d 2>/dev/null || date -d '45 days ago' +%Y-%m-%d)"

  cat > docs/found-issues-archive.md <<'PRIOR'
# found-issues archive

Some prior content.

- [fixed] 2025-01-01 ancient/file.py:1 — ancient bug (fixed: 2025-01-01)
PRIOR
  fi_seed_fixed_at_dates docs/found-issues.md "$old"

  fi_run archive
  [ "$status" -eq 0 ]

  grep -Fq "ancient/file.py:1" docs/found-issues-archive.md
  grep -Fq "$old" docs/found-issues-archive.md
}

@test "archive: idempotent (second run no-ops)" {
  local old
  old="$(date -v-45d +%Y-%m-%d 2>/dev/null || date -d '45 days ago' +%Y-%m-%d)"
  fi_seed_fixed_at_dates docs/found-issues.md "$old"

  fi_run archive
  [ "$status" -eq 0 ]
  fi_run archive
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to archive"* ]]
}
