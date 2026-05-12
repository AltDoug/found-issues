#!/usr/bin/env bats
# Tests for the three new annotation forms recognized by fi_parse_entry:
#   (PR-closed: org/repo#N)   — sync-demoted form after PR closure
#   (commit-stale: <sha>)     — sync-demoted form when commit absent from history
#   (renamed-from: <path>)    — auto-correct trail for path renames

load 'helpers'

setup() { fi_source_lib parse-entries; }

@test "fi_parse_entry: recognizes (PR-closed: ...) annotation" {
  output="$(fi_parse_entry '- [open] 2026-05-11 src/foo.py:1 — bug (PR-closed: foo/bar#42)')"
  [[ "$output" == *"prs_closed=foo/bar#42"* ]]
}

@test "fi_parse_entry: recognizes (commit-stale: ...) annotation" {
  output="$(fi_parse_entry '- [open] 2026-05-11 src/foo.py:1 — bug (commit-stale: a1b2c3d)')"
  [[ "$output" == *"commits_stale=a1b2c3d"* ]]
}

@test "fi_parse_entry: recognizes (renamed-from: ...) annotation" {
  output="$(fi_parse_entry '- [open] 2026-05-11 new/path.py:1 — bug (renamed-from: old/path.py)')"
  [[ "$output" == *"renamed_from=old/path.py"* ]]
}

@test "fi_parse_entry: distinguishes (PR: ...) from (PR-closed: ...)" {
  output="$(fi_parse_entry '- [open] 2026-05-11 src/foo.py:1 — bug (PR: foo/bar#42) (PR-closed: foo/bar#41)')"
  [[ "$output" == *"prs=foo/bar#42"* ]]
  [[ "$output" == *"prs_closed=foo/bar#41"* ]]
  # Critical: prs field must NOT contain the closed ref
  [[ "$output" != *"prs=foo/bar#41"* ]]
}
