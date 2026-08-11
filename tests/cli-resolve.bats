#!/usr/bin/env bats
# Tests for `found-issues resolve` — the serialized [open] -> [fixed] flip.
#
# Added for #124. commands/sync.md Phase 2 step 4 instructed the agent to
# "edit the file: change [open] -> [fixed] and append (verified: ai)
# (fixed: YYYY-MM-DD)" and shipped `Edit` in its allowed-tools, which is the
# exact unserialized direct write the CLI exists to prevent (lost writes under
# concurrent sessions, format drift, guard bypass). `resolve` is the supported
# command that replaces it.
#
# Exit codes mirror `defer`:
#   0 success, 1 no matching [open] entry, 2 usage/ambiguous,
#   3 entry already [fixed], 4 entry has an active (PR: ...) annotation.

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

@test "resolve: flips [open] to [fixed] with (verified: ai) and today's date" {
  mkdir -p src
  printf 'a\nb\nc\n' > src/foo.py
  fi_run log "src/foo.py:2 — null deref"
  today="$(date +%Y-%m-%d)"

  fi_run resolve "null deref"
  [ "$status" -eq 0 ]
  grep -q "^- \[fixed\] .*src/foo.py:2 .*(verified: ai) (fixed: $today)" docs/found-issues.md
  run grep -q '^- \[open\]' docs/found-issues.md
  [ "$status" -ne 0 ]
}

@test "resolve: accepts the --match flag form like promote-deferred" {
  mkdir -p src
  printf 'a\nb\nc\n' > src/foo.py
  fi_run log "src/foo.py:2 — null deref"

  fi_run resolve --match "null deref"
  [ "$status" -eq 0 ]
  grep -q '^- \[fixed\].*(verified: ai)' docs/found-issues.md
}

@test "resolve: --verified human records a human verdict" {
  mkdir -p src
  printf 'a\nb\nc\n' > src/foo.py
  fi_run log "src/foo.py:2 — null deref"

  fi_run resolve "null deref" --verified human
  [ "$status" -eq 0 ]
  grep -q '(verified: human)' docs/found-issues.md
}

@test "resolve: rejects an unknown --verified value" {
  mkdir -p src
  printf 'a\n' > src/foo.py
  fi_run log "src/foo.py:1 — null deref"

  fi_run resolve "null deref" --verified robot
  [ "$status" -eq 2 ]
  [[ "$output" == *"--verified"* ]]
  grep -q '^- \[open\]' docs/found-issues.md
}

@test "resolve: exits 1 with a clear message when nothing matches" {
  mkdir -p src
  printf 'a\n' > src/foo.py
  fi_run log "src/foo.py:1 — null deref"

  fi_run resolve "no such symptom"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no [open] entries match"* ]]
}

@test "resolve: exits 2 and lists candidates on an ambiguous match" {
  mkdir -p src
  printf 'a\n' > src/foo.py
  printf 'a\n' > src/bar.py
  fi_run log "src/foo.py:1 — shared symptom text"
  fi_run log "src/bar.py:1 — shared symptom text"

  fi_run resolve "shared symptom"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ambiguous"* ]]
  [[ "$output" == *"src/foo.py:1"* ]]
  [[ "$output" == *"src/bar.py:1"* ]]
  run grep -q '^- \[fixed\]' docs/found-issues.md
  [ "$status" -ne 0 ]
}

@test "resolve: exits 2 with usage when the match argument is missing" {
  fi_run resolve
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage: found-issues resolve"* ]]
}

@test "resolve: exits 3 when the matched entry is already [fixed]" {
  mkdir -p src
  printf 'a\n' > src/foo.py
  fi_run log "src/foo.py:1 — null deref"
  fi_run resolve "null deref"

  fi_run resolve "null deref"
  [ "$status" -eq 3 ]
  [[ "$output" == *"already [fixed]"* ]]
}

# An entry carrying an active (PR: ...) annotation is in-flight work. sync.md
# already excludes those from AI verification, and closing one by hand would
# race the PR-merge flip that `sync` performs. Refuse, like defer does.
@test "resolve: refuses an entry with an active PR annotation" {
  # Fixture written directly: `annotate-pr` verifies the PR exists via `gh`,
  # which needs a real GitHub remote and a real PR. The state under test is the
  # annotated entry, not how it got annotated (same approach as cli-archive.bats).
  mkdir -p docs src
  printf 'a\n' > src/foo.py
  printf '# found-issues\n\n' > docs/found-issues.md
  printf -- '- [open] 2026-08-11 src/foo.py:1 — null deref (PR: org/repo#7)\n' >> docs/found-issues.md

  fi_run resolve "null deref"
  [ "$status" -eq 4 ]
  [[ "$output" == *"PR: org/repo#7"* ]]
  grep -q '^- \[open\]' docs/found-issues.md
  run grep -q '^- \[fixed\]' docs/found-issues.md
  [ "$status" -ne 0 ]
}

@test "resolve: the flipped entry round-trips through the parser" {
  mkdir -p src
  printf 'a\nb\n' > src/foo.py
  fi_run log "src/foo.py:2 — null deref"
  fi_run resolve "null deref"

  line="$(grep '^- \[fixed\]' docs/found-issues.md)"
  run bash -c "source '$FI_LIB_DIR/parse-entries.sh'; fi_parse_entry '$line' | grep '^status='"
  [ "$status" -eq 0 ]
  [[ "$output" == "status=fixed" ]]
}

@test "resolve: leaves other entries untouched" {
  mkdir -p src
  printf 'a\n' > src/foo.py
  printf 'a\n' > src/bar.py
  fi_run log "src/foo.py:1 — first symptom"
  fi_run log "src/bar.py:1 — second symptom"

  fi_run resolve "first symptom"
  [ "$status" -eq 0 ]
  grep -q '^- \[fixed\].*first symptom' docs/found-issues.md
  grep -q '^- \[open\].*second symptom' docs/found-issues.md
}
