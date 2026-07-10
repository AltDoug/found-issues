#!/usr/bin/env bats
# Tests for lib/parse-entries.sh

load 'helpers'

setup() {
  fi_source_lib parse-entries
  fi_setup_tmp
}

teardown() {
  fi_teardown_tmp
}

# === fi_find_issues_file ===

@test "find_issues_file: finds docs/found-issues.md in cwd" {
  mkdir -p docs
  echo "# found-issues" > docs/found-issues.md
  result="$(fi_find_issues_file)"
  [[ "$result" == */docs/found-issues.md ]]
}

@test "find_issues_file: finds .found-issues.md in cwd" {
  echo "# found-issues" > .found-issues.md
  result="$(fi_find_issues_file)"
  [[ "$result" == */.found-issues.md ]]
}

@test "find_issues_file: walks up directory tree" {
  mkdir -p docs sub/dir
  echo "# found-issues" > docs/found-issues.md
  cd sub/dir
  result="$(fi_find_issues_file)"
  [[ "$result" == */docs/found-issues.md ]]
}

@test "find_issues_file: prefers docs/ over .found-issues.md when both present" {
  mkdir -p docs
  echo "# A" > docs/found-issues.md
  echo "# B" > .found-issues.md
  result="$(fi_find_issues_file)"
  [[ "$result" == */docs/found-issues.md ]]
}

@test "find_issues_file: returns nonzero when not found" {
  run fi_find_issues_file
  [ "$status" -ne 0 ]
}

# === fi_parse_entry ===

@test "parse_entry: extracts status open" {
  out="$(fi_parse_entry '- [open] 2026-05-08 src/foo.py:42 — bug')"
  [[ "$out" == *"status=open"* ]]
}

@test "parse_entry: extracts status fixed" {
  out="$(fi_parse_entry '- [fixed] 2026-05-08 src/foo.py:42 — bug')"
  [[ "$out" == *"status=fixed"* ]]
}

@test "parse_entry: extracts critical flag" {
  out="$(fi_parse_entry '- [open] [!] 2026-05-08 src/foo.py:42 — bug')"
  [[ "$out" == *"critical=yes"* ]]
}

@test "parse_entry: critical=no when no [!]" {
  out="$(fi_parse_entry '- [open] 2026-05-08 src/foo.py:42 — bug')"
  [[ "$out" == *"critical=no"* ]]
}

@test "parse_entry: extracts date" {
  out="$(fi_parse_entry '- [open] 2026-05-08 src/foo.py:42 — bug')"
  [[ "$out" == *"date=2026-05-08"* ]]
}

@test "parse_entry: extracts path and line" {
  out="$(fi_parse_entry '- [open] 2026-05-08 src/foo.py:42 — bug')"
  [[ "$out" == *"path=src/foo.py"* ]]
  [[ "$out" == *"line=42"* ]]
}

@test "parse_entry: extracts path-only when no line" {
  out="$(fi_parse_entry '- [open] 2026-05-08 src/foo.py — bug')"
  [[ "$out" == *"path=src/foo.py"* ]]
  [[ "$out" == *"line="*$'\n'* ]] || [[ "$(printf '%s' "$out" | grep '^line=')" == "line=" ]]
}

@test "parse_entry: extracts path correctly when symptom contains additional ISO dates (regression)" {
  # Pre-fix, the location strip used a greedy `sed -E 's/^.*[0-9]{4}-[0-9]{2}-[0-9]{2} //'`
  # so when the symptom contained extra ISO dates, the strip consumed past the
  # leading entry-date and ate into the symptom — path extraction returned empty
  # and annotate-pr / annotate-commit silently failed to match the entry's file
  # against PR-touched files. Repros bug observed 2026-05-12 while annotating
  # the stop-reminder entry against PR #83.
  out="$(fi_parse_entry '- [open] 2026-05-12 hooks/stop-reminder.sh — Stop hook silent since 2026-05-08; auto-logging dried up ~2026-05-04 across all repos.')"
  [[ "$out" == *"path=hooks/stop-reminder.sh"* ]]
  [[ "$out" == *"date=2026-05-12"* ]]
}

@test "parse_entry: extracts path:line correctly when symptom contains multiple ISO dates" {
  # Same root cause as above but with path:line shape; ensures the path/line
  # regex still matches after the leading-date strip.
  out="$(fi_parse_entry '- [open] 2026-05-12 lib/foo.sh:42 — regressed in 2026-04-30 release, surfaced 2026-05-10')"
  [[ "$out" == *"path=lib/foo.sh"* ]]
  [[ "$out" == *"line=42"* ]]
  [[ "$out" == *"date=2026-05-12"* ]]
}

@test "parse_entry: extracts path from 'path symbol ~range' location form (regression)" {
  # Pre-fix, fi_parse_entry's location regex required the path token to stand
  # alone before ' — '. Entries that included a function/symbol name and a
  # tilde-prefixed approximate line range (a common form for AI-logged
  # findings inside large files) got an empty path= result, silently breaking
  # annotate-pr / annotate-commit matching. Repros the bug observed
  # 2026-05-15 while annotating PR #92 against five 2026-05-13 entries; all
  # five required manual sed annotation.
  out="$(fi_parse_entry '- [open] 2026-05-13 bin/found-issues fi_strip_target_markers ~1982-1989 — dead-code sub() regexes (suggested: delete the dead patterns)')"
  [[ "$out" == *"path=bin/found-issues"* ]]
  [[ "$out" == *"date=2026-05-13"* ]]
}

@test "parse_entry: extracts path from 'path symbol ~range' with .sh extension" {
  out="$(fi_parse_entry '- [open] 2026-05-13 hooks/session-start.sh ~145-177 — awk programs duplicated verbatim')"
  [[ "$out" == *"path=hooks/session-start.sh"* ]]
}

@test "parse_entry: extracts path from 'path:line symbol' form" {
  # First token has path:line shape with trailing symbol — line number must
  # still be extracted from the first whitespace-delimited token.
  out="$(fi_parse_entry '- [open] 2026-05-13 lib/foo.sh:42 my_func — leak detected')"
  [[ "$out" == *"path=lib/foo.sh"* ]]
  [[ "$out" == *"line=42"* ]]
}

@test "parse_entry: extracts symptom (without parentheticals)" {
  out="$(fi_parse_entry '- [open] 2026-05-08 src/foo.py:42 — null check (suggested: add guard)')"
  [[ "$out" == *"symptom=null check"* ]]
}

@test "parse_entry: extracts suggested fix" {
  out="$(fi_parse_entry '- [open] 2026-05-08 src/foo.py:42 — bug (suggested: do X)')"
  [[ "$out" == *"fix=do X"* ]]
}

@test "parse_entry: extracts single PR annotation" {
  out="$(fi_parse_entry '- [open] 2026-05-08 src/foo.py:42 — bug (PR: org/repo#42)')"
  [[ "$out" == *"prs=org/repo#42"* ]]
}

@test "parse_entry: extracts multiple PR annotations" {
  out="$(fi_parse_entry '- [open] 2026-05-08 src/foo.py:42 — bug (PR: org/repo#5) (PR: org/repo#7)')"
  [[ "$out" == *"prs=org/repo#5,org/repo#7"* ]]
}

@test "parse_entry: extracts commit annotation" {
  out="$(fi_parse_entry '- [open] 2026-05-08 src/foo.py:42 — bug (commit: a1b2c3d)')"
  [[ "$out" == *"commits=a1b2c3d"* ]]
}

@test "parse_entry: extracts fixed date" {
  out="$(fi_parse_entry '- [fixed] 2026-05-08 src/foo.py:42 — bug (PR: org/repo#5) (fixed: 2026-05-09)')"
  [[ "$out" == *"fixed_date=2026-05-09"* ]]
}

@test "parse_entry: extracts verified source" {
  out="$(fi_parse_entry '- [fixed] 2026-05-08 src/foo.py:42 — bug (verified: ai)')"
  [[ "$out" == *"verified=ai"* ]]
}

@test "parse_entry: returns nonzero on non-entry line" {
  run fi_parse_entry "this is not an entry"
  [ "$status" -ne 0 ]
}

# === fi_entries / fi_count ===

@test "entries: filters by status open" {
  fi_seed_sample docs/found-issues.md
  result="$(fi_entries docs/found-issues.md open | wc -l | tr -d ' ')"
  [ "$result" = "4" ]
}

@test "entries: filters by status fixed" {
  fi_seed_sample docs/found-issues.md
  result="$(fi_entries docs/found-issues.md fixed | wc -l | tr -d ' ')"
  [ "$result" = "1" ]
}

@test "entries: filters by status deferred" {
  fi_seed_sample docs/found-issues.md
  result="$(fi_entries docs/found-issues.md deferred | wc -l | tr -d ' ')"
  [ "$result" = "1" ]
}

@test "entries: 'all' returns every entry" {
  fi_seed_sample docs/found-issues.md
  result="$(fi_entries docs/found-issues.md all | wc -l | tr -d ' ')"
  [ "$result" = "6" ]
}

@test "count: open returns 4" {
  fi_seed_sample docs/found-issues.md
  result="$(fi_count docs/found-issues.md open)"
  [ "$result" = "4" ]
}

@test "count: returns 0 when file missing" {
  result="$(fi_count nonexistent.md open)"
  [ "$result" = "0" ]
}

@test "count_in_pr: only counts open entries with PR annotation" {
  fi_seed_sample docs/found-issues.md
  result="$(fi_count_in_pr docs/found-issues.md)"
  [ "$result" = "1" ]
}

@test "count_critical: counts open [!] entries" {
  fi_seed_sample docs/found-issues.md
  result="$(fi_count_critical docs/found-issues.md)"
  [ "$result" = "1" ]
}

# === fi_extract_touched_segment ===

@test "fi_extract_touched_segment: returns empty when annotation absent" {
  result="$(fi_extract_touched_segment "- [deferred] 2026-05-10 src/foo.py:42 — bug")"
  [ -z "$result" ]
}

@test "fi_extract_touched_segment: extracts single date" {
  result="$(fi_extract_touched_segment "- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21)")"
  [ "$result" = "2026-05-21" ]
}

@test "fi_extract_touched_segment: extracts multiple dates with cycle separator" {
  result="$(fi_extract_touched_segment "- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, 2026-05-28; 2026-07-15)")"
  [ "$result" = "2026-05-21, 2026-05-28; 2026-07-15" ]
}

# === fi_current_cycle_touch_count ===

@test "fi_current_cycle_touch_count: returns 0 when annotation absent" {
  result="$(fi_current_cycle_touch_count "- [deferred] 2026-05-10 src/foo.py:42 — bug")"
  [ "$result" -eq 0 ]
}

@test "fi_current_cycle_touch_count: counts dates in cycle 1 (no separator)" {
  result="$(fi_current_cycle_touch_count "- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, 2026-05-28, 2026-06-04)")"
  [ "$result" -eq 3 ]
}

@test "fi_current_cycle_touch_count: counts only current cycle (after last ';')" {
  result="$(fi_current_cycle_touch_count "- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, 2026-05-28, 2026-06-04; 2026-07-15, 2026-07-22)")"
  [ "$result" -eq 2 ]
}

@test "fi_current_cycle_touch_count: returns 0 when current segment is empty (just appended ';')" {
  result="$(fi_current_cycle_touch_count "- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, 2026-05-28; )")"
  [ "$result" -eq 0 ]
}

@test "fi_current_cycle_touch_count: ignores malformed (non-date) tokens" {
  result="$(fi_current_cycle_touch_count "- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, garbage, 2026-05-28)")"
  [ "$result" -eq 2 ]
}

# === fi_extract_defer_cycle ===

@test "fi_extract_defer_cycle: returns 1 when annotation absent" {
  result="$(fi_extract_defer_cycle "- [deferred] 2026-05-10 src/foo.py:42 — bug")"
  [ "$result" -eq 1 ]
}

@test "fi_extract_defer_cycle: extracts numeric cycle" {
  result="$(fi_extract_defer_cycle "- [deferred] 2026-05-10 src/foo.py:42 — bug (defer-cycle: 3)")"
  [ "$result" -eq 3 ]
}

@test "fi_extract_defer_cycle: defaults to 1 on non-numeric value (defensive)" {
  result="$(fi_extract_defer_cycle "- [deferred] 2026-05-10 src/foo.py:42 — bug (defer-cycle: garbage)")"
  [ "$result" -eq 1 ]
}

# === fi_extract_reason ===

@test "fi_extract_reason: returns empty when annotation absent" {
  result="$(fi_extract_reason "- [deferred] 2026-05-10 src/foo.py:42 — bug")"
  [ -z "$result" ]
}

@test "fi_extract_reason: extracts reason text" {
  result="$(fi_extract_reason "- [deferred] 2026-05-10 src/foo.py:42 — bug (reason: tracked in JIRA-1234)")"
  [ "$result" = "tracked in JIRA-1234" ]
}

# === fi_compute_threshold ===

@test "fi_compute_threshold: cycle 1 default (3)" {
  unset FOUND_ISSUES_DEFER_TOUCH_THRESHOLD FOUND_ISSUES_DEFER_ESCALATION_FACTOR
  result="$(fi_compute_threshold 1)"
  [ "$result" -eq 3 ]
}

@test "fi_compute_threshold: cycle 2 default (6)" {
  unset FOUND_ISSUES_DEFER_TOUCH_THRESHOLD FOUND_ISSUES_DEFER_ESCALATION_FACTOR
  result="$(fi_compute_threshold 2)"
  [ "$result" -eq 6 ]
}

@test "fi_compute_threshold: cycle 4 default (24)" {
  unset FOUND_ISSUES_DEFER_TOUCH_THRESHOLD FOUND_ISSUES_DEFER_ESCALATION_FACTOR
  result="$(fi_compute_threshold 4)"
  [ "$result" -eq 24 ]
}

@test "fi_compute_threshold: respects custom base" {
  FOUND_ISSUES_DEFER_TOUCH_THRESHOLD=5 \
  FOUND_ISSUES_DEFER_ESCALATION_FACTOR=2 \
    result="$(fi_compute_threshold 2)"
  [ "$result" -eq 10 ]
}

@test "fi_compute_threshold: respects custom factor" {
  FOUND_ISSUES_DEFER_TOUCH_THRESHOLD=3 \
  FOUND_ISSUES_DEFER_ESCALATION_FACTOR=3 \
    result="$(fi_compute_threshold 3)"
  [ "$result" -eq 27 ]
}

@test "fi_compute_threshold: invalid base falls back to default with warning" {
  FOUND_ISSUES_DEFER_TOUCH_THRESHOLD=garbage \
    result="$(fi_compute_threshold 1 2>&1)"
  [[ "$result" == *"3"* ]]
  [[ "$result" == *"warning"* ]] || [[ "$result" == *"FOUND_ISSUES_DEFER_TOUCH_THRESHOLD"* ]]
}

# === fi_append_touch ===

@test "fi_append_touch: creates annotation when absent" {
  cat > test.md <<'EOF'
- [deferred] 2026-05-10 src/foo.py:42 — bug
EOF
  fi_append_touch test.md "- [deferred] 2026-05-10 src/foo.py:42 — bug" "2026-05-21"
  grep -F "(touched: 2026-05-21)" test.md
}

@test "fi_append_touch: appends to existing single-cycle annotation" {
  cat > test.md <<'EOF'
- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21)
EOF
  fi_append_touch test.md "- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21)" "2026-05-28"
  grep -F "(touched: 2026-05-21, 2026-05-28)" test.md
}

@test "fi_append_touch: appends after last ';' (cycle 2)" {
  cat > test.md <<'EOF'
- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, 2026-05-28; ) (defer-cycle: 2)
EOF
  fi_append_touch test.md "- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, 2026-05-28; ) (defer-cycle: 2)" "2026-07-15"
  grep -F "(touched: 2026-05-21, 2026-05-28; 2026-07-15)" test.md
}

@test "fi_append_touch: leaves other entries untouched" {
  cat > test.md <<'EOF'
- [deferred] 2026-05-10 src/foo.py:42 — bug
- [open] 2026-05-11 src/bar.py:99 — other bug
- [deferred] 2026-05-12 src/baz.py:1 — third bug
EOF
  fi_append_touch test.md "- [deferred] 2026-05-10 src/foo.py:42 — bug" "2026-05-21"
  grep -F "(touched: 2026-05-21)" test.md
  ! grep "src/bar.py" test.md | grep -q "touched:"
  ! grep "src/baz.py" test.md | grep -q "touched:"
}

@test "fi_increment_defer_cycle: adds (defer-cycle: 2) and ';' to touched on first re-defer" {
  cat > test.md <<'EOF'
- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, 2026-05-28)
EOF
  fi_increment_defer_cycle test.md "- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, 2026-05-28)"
  grep -F "(defer-cycle: 2)" test.md
  grep -F "(touched: 2026-05-21, 2026-05-28; )" test.md
}

@test "fi_increment_defer_cycle: bumps existing cycle (2 -> 3)" {
  cat > test.md <<'EOF'
- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, 2026-05-28; 2026-07-15) (defer-cycle: 2)
EOF
  fi_increment_defer_cycle test.md "- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, 2026-05-28; 2026-07-15) (defer-cycle: 2)"
  grep -F "(defer-cycle: 3)" test.md
  grep -F "(touched: 2026-05-21, 2026-05-28; 2026-07-15; )" test.md
  ! grep -F "(defer-cycle: 2)" test.md
}

@test "fi_increment_defer_cycle: no ';' appended when no touched annotation" {
  cat > test.md <<'EOF'
- [deferred] 2026-05-10 src/foo.py:42 — bug
EOF
  fi_increment_defer_cycle test.md "- [deferred] 2026-05-10 src/foo.py:42 — bug"
  grep -F "(defer-cycle: 2)" test.md
  ! grep "touched:" test.md
}

@test "fi_increment_defer_cycle: no ';' appended when current segment is empty" {
  cat > test.md <<'EOF'
- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21; ) (defer-cycle: 2)
EOF
  fi_increment_defer_cycle test.md "- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21; ) (defer-cycle: 2)"
  grep -F "(defer-cycle: 3)" test.md
  # No double ';;' — annotation stays "; "
  grep -F "(touched: 2026-05-21; )" test.md
  ! grep -F ";;" test.md
}

@test "fi_parse_entry: path with plus sign parses (charset parity with cmd_log)" {
  result="$(fi_parse_entry '- [open] 2026-07-09 src/UIView+Ext.swift:42 — category method leaks')"
  echo "$result" | grep -q '^path=src/UIView+Ext.swift$'
  echo "$result" | grep -q '^line=42$'
}

@test "fi_json_escape escapes backslash quote and tab, strips CR" {
  run fi_json_escape "$(printf 'a\\b "c"\td\r')"
  [ "$status" -eq 0 ]
  [ "$output" = 'a\\b \"c\"\td' ]
}

@test "fi_json_str emits null for empty and quoted string otherwise" {
  run fi_json_str ""
  [ "$output" = "null" ]
  run fi_json_str 'say "hi"'
  [ "$output" = '"say \"hi\""' ]
}

@test "fi_entry_to_json emits full object for a rich entry" {
  TODAY="$(date +%Y-%m-%d)"
  line="- [open] [!] $TODAY src/app.sh:42 — bad thing happens (suggested: do the fix) (PR: org/repo#7)"
  run fi_entry_to_json 5 "$line"
  [ "$status" -eq 0 ]
  [[ "$output" == '{"line_no":5,"status":"open","critical":true,'* ]]
  [[ "$output" == *'"path":"src/app.sh"'* ]]
  [[ "$output" == *'"line":42'* ]]
  [[ "$output" == *'"symptom":"bad thing happens"'* ]]
  [[ "$output" == *'"suggested":"do the fix"'* ]]
  [[ "$output" == *'"prs":"org/repo#7"'* ]]
  [[ "$output" == *'"raw":"- [open] [!]'* ]]
}

@test "fi_entry_to_json emits nulls for absent fields and mute_until when present" {
  TODAY="$(date +%Y-%m-%d)"
  line="- [deferred] $TODAY topic:with:colons — parked thing (mute-until: 2099-01-01)"
  run fi_entry_to_json 9 "$line"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"critical":false'* ]]
  [[ "$output" == *'"path":null'* ]]
  [[ "$output" == *'"line":null'* ]]
  [[ "$output" == *'"suggested":null'* ]]
  [[ "$output" == *'"mute_until":"2099-01-01"'* ]]
}

@test "fi_entry_to_json returns 1 on a non-entry line" {
  run fi_entry_to_json 1 "# found-issues"
  [ "$status" -eq 1 ]
}

@test "fi_entries numbered mode prefixes file line numbers and stays conflict-aware" {
  TODAY="$(date +%Y-%m-%d)"
  cat > issues.md <<EOF
# header

- [open] $TODAY a.sh:1 — first
<<<<<<< HEAD
- [open] $TODAY b.sh:2 — conflicted ours
=======
- [open] $TODAY c.sh:3 — conflicted theirs
>>>>>>> branch
- [open] $TODAY d.sh:4 — last
EOF
  run fi_entries issues.md open numbered
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "3:- [open] $TODAY a.sh:1 — first" ]]
  [[ "${lines[1]}" == "9:- [open] $TODAY d.sh:4 — last" ]]
}

@test "fi_entries two-arg form is unchanged by numbered mode addition" {
  TODAY="$(date +%Y-%m-%d)"
  printf -- '- [open] %s a.sh:1 — thing\n' "$TODAY" > issues.md
  run fi_entries issues.md open
  [ "$output" = "- [open] $TODAY a.sh:1 — thing" ]
}

@test "fi_entries rejects an unknown third argument" {
  TODAY="$(date +%Y-%m-%d)"
  printf -- '- [open] %s a.sh:1 — thing\n' "$TODAY" > issues.md
  run fi_entries issues.md open true
  [ "$status" -eq 2 ]
}
