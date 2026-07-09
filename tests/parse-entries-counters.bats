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

@test "fi_count_stale: fresh entry with old ISO date in symptom is not stale" {
  local today
  today="$(date +%Y-%m-%d)"
  cat > issues.md <<EOF
# found-issues
- [open] $today src/a.py:1 — regressed on 2020-01-01 after deploy
EOF
  result="$(fi_count_stale issues.md 30)"
  [ "$result" -eq 0 ]
}

@test "fi_count_stale: stale entry with fresh ISO date in symptom still counts" {
  local old_date today
  old_date="$(date -v-40d +%Y-%m-%d 2>/dev/null || date -d '40 days ago' +%Y-%m-%d)"
  today="$(date +%Y-%m-%d)"
  cat > issues.md <<EOF
# found-issues
- [open] $old_date src/a.py:1 — will recur on $today per schedule
EOF
  result="$(fi_count_stale issues.md 30)"
  [ "$result" -eq 1 ]
}

@test "fi_count_stale: critical flag between status and date does not break the anchor" {
  local old_date
  old_date="$(date -v-40d +%Y-%m-%d 2>/dev/null || date -d '40 days ago' +%Y-%m-%d)"
  cat > issues.md <<EOF
# found-issues
- [open] [!] $old_date src/a.py:1 — old critical bug
EOF
  result="$(fi_count_stale issues.md 30)"
  [ "$result" -eq 1 ]
}

@test "fi_count_in_pr: ignores both sides of a merge conflict" {
  cat > issues.md <<'EOF'
# found-issues
<<<<<<< HEAD
- [open] 2026-05-11 src/a.py:1 — bug (PR: foo/bar#1)
=======
- [open] 2026-05-11 src/a.py:2 — bug variant (PR: foo/bar#2)
>>>>>>> feature
- [open] 2026-05-11 src/c.py:1 — clean entry (PR: foo/bar#3)
EOF
  result="$(fi_count_in_pr issues.md)"
  [ "$result" -eq 1 ]
}

@test "fi_count_critical: ignores both sides of a merge conflict" {
  cat > issues.md <<'EOF'
# found-issues
<<<<<<< HEAD
- [open] [!] 2026-05-11 src/a.py:1 — bug
=======
- [open] [!] 2026-05-11 src/a.py:2 — bug variant
>>>>>>> feature
- [open] 2026-05-11 src/c.py:1 — clean entry
EOF
  result="$(fi_count_critical issues.md)"
  [ "$result" -eq 0 ]
}

@test "fi_count_stale: demoted-term ignores both sides of a merge conflict" {
  cat > issues.md <<'EOF'
# found-issues
<<<<<<< HEAD
- [open] 2026-05-11 src/a.py:1 — bug (PR-closed: foo/bar#1)
=======
- [open] 2026-05-11 src/a.py:2 — bug variant (commit-stale: deadbee)
>>>>>>> feature
EOF
  result="$(fi_count_stale issues.md 30)"
  [ "$result" -eq 0 ]
}

@test "fi_count_residual: excludes critical and in-PR without double-subtracting overlap" {
  cat > issues.md <<'EOF'
# found-issues
- [open] [!] 2026-05-11 src/a.py:1 — critical AND in PR (PR: foo/bar#1)
- [open] 2026-05-11 src/b.py:1 — plain open entry
EOF
  result="$(fi_count_residual issues.md)"
  [ "$result" -eq 1 ]
}

@test "fi_count_residual: zero when every open entry is critical or in PR" {
  cat > issues.md <<'EOF'
# found-issues
- [open] [!] 2026-05-11 src/a.py:1 — critical
- [open] 2026-05-11 src/b.py:1 — in PR (PR: foo/bar#2)
EOF
  result="$(fi_count_residual issues.md)"
  [ "$result" -eq 0 ]
}
