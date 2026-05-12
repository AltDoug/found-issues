#!/usr/bin/env bats
load 'helpers'

setup() {
  fi_setup_tmp
  fi_source_lib parse-entries
}

teardown() { fi_teardown_tmp; }

@test "fi_count_in_pr: excludes (PR-closed: ...) entries" {
  cat > issues.md <<'EOF'
# found-issues
- [open] 2026-05-11 src/a.py:1 — bug (PR: foo/bar#1)
- [open] 2026-05-11 src/b.py:1 — bug (PR-closed: foo/bar#2)
- [open] 2026-05-11 src/c.py:1 — bug
EOF
  result="$(fi_count_in_pr issues.md)"
  [ "$result" -eq 1 ]
}

@test "fi_count_stale: includes (PR-closed: ...) and (commit-stale: ...)" {
  cat > issues.md <<'EOF'
# found-issues
- [open] 2026-05-11 src/a.py:1 — bug (PR-closed: foo/bar#2)
- [open] 2026-05-11 src/b.py:1 — bug (commit-stale: deadbeef)
- [open] 2026-05-11 src/c.py:1 — bug
EOF
  result="$(fi_count_stale issues.md 30)"
  [ "$result" -ge 2 ]
}

@test "fi_count_stale: entry older than stale_days counts as stale regardless of annotation" {
  local old_date
  old_date="$(date -v-40d +%Y-%m-%d 2>/dev/null || date -d '40 days ago' +%Y-%m-%d)"
  cat > issues.md <<EOF
# found-issues
- [open] $old_date src/a.py:1 — bug (PR: foo/bar#1)
EOF
  result="$(fi_count_stale issues.md 30)"
  [ "$result" -eq 1 ]
}

@test "fi_count_stale: avoids double-counting date-stale + demoted entry" {
  local old_date
  old_date="$(date -v-40d +%Y-%m-%d 2>/dev/null || date -d '40 days ago' +%Y-%m-%d)"
  cat > issues.md <<EOF
# found-issues
- [open] $old_date src/a.py:1 — bug (PR-closed: foo/bar#1)
- [open] 2026-05-11 src/b.py:1 — bug (commit-stale: deadbeef)
EOF
  # First entry: stale by date AND demoted → count once
  # Second entry: only demoted → count once
  # Total: 2 (not 3, despite "stale by date" + "demoted" overlap on first)
  result="$(fi_count_stale issues.md 30)"
  [ "$result" -eq 2 ]
}
