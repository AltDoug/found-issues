#!/usr/bin/env bats
# `sync` holds closures of [!] CRITICAL entries and of entries carrying a
# per-entry (hold: <reason>) marker (#161 part 1, #169). Idea and first tests
# from jbelmana's PR #171, re-seated on the keyed annotation form: a plain
# "(needs human verify)" text made the parser drop the entry's (PR:) group.
#
# Severity and hold are read from the entry, never inferred: a closure that
# comes from an INFERRED signal (tombstone, landed annotation) must not be
# taken unattended for an entry a human flagged as needing a human decision.

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

# Commit a file, then remove it: the tombstone precondition (absent from HEAD,
# present in history) that fi_git_confirms_removed requires (#151).
seed_removed_file() {
  mkdir -p src
  printf 'export const gone = 1;\n' > src/gone.ts
  git add src/gone.ts
  git commit -q -m "add gone.ts"
  git rm -q src/gone.ts
  git commit -q -m "delete gone.ts"
}

@test "hold: sync holds a critical tombstone closure and closes the plain twin" {
  seed_removed_file
  fi_run log --critical "src/gone.ts:1 — critical defect in a file that later gets deleted"
  [ "$status" -eq 0 ]
  fi_run log "src/gone.ts:1 — plain defect in a file that later gets deleted"
  [ "$status" -eq 0 ]

  fi_run sync
  [ "$status" -eq 0 ]

  grep -q '^- \[open\] \[!\].*critical defect' docs/found-issues.md
  grep -q 'critical defect.*(hold: needs human verify)' docs/found-issues.md
  run grep -c '^- \[fixed\] \[!\]' docs/found-issues.md
  [ "$output" = "0" ]

  # The plain control entry still closes: the tombstone mechanism is intact.
  grep -q '^- \[fixed\].*plain defect' docs/found-issues.md
  grep -q 'plain defect.*closure: tombstone' docs/found-issues.md
}

@test "hold: summary counts the held entry as not closed and reports it" {
  seed_removed_file
  fi_run log --critical "src/gone.ts:1 — critical defect reported"
  fi_run log "src/gone.ts:1 — plain defect reported"

  fi_run sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"Closed: 1 (0 PR + 0 commit + 1 tombstone)"* ]]
  [[ "$output" == *"Held: 1 entry for human verification"* ]]
  [[ "$output" == *"critical defect reported"* ]]
  [[ "$output" == *"--verified review"* ]]
}

@test "hold: the next sync still reports the held entry" {
  seed_removed_file
  fi_run log --critical "src/gone.ts:1 — critical defect held twice"
  fi_run sync
  fi_run sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"Held: 1 entry for human verification"* ]]
}

@test "hold: says nothing about holds when no entry was held" {
  seed_removed_file
  fi_run log "src/gone.ts:1 — plain defect only"
  fi_run sync
  [ "$status" -eq 0 ]
  [[ "$output" != *"Held:"* ]]
  grep -q '^- \[fixed\].*plain defect only' docs/found-issues.md
}

@test "hold: the marker is appended exactly once across repeated runs" {
  seed_removed_file
  fi_run log --critical "src/gone.ts:1 — critical defect marked once"
  fi_run sync
  fi_run sync
  fi_run sync
  [ "$status" -eq 0 ]
  run grep -c '(hold: ' docs/found-issues.md
  [ "$output" -eq 1 ]
  grep -q '^- \[open\] \[!\]' docs/found-issues.md
}

@test "hold: sync --dry-run reports the hold without writing the ledger" {
  seed_removed_file
  fi_run log --critical "src/gone.ts:1 — critical defect under dry run"
  local before
  before="$(cat docs/found-issues.md)"
  fi_run sync --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Held: 1 entry for human verification"* ]]
  [ "$before" = "$(cat docs/found-issues.md)" ]
}

@test "hold: a critical with a landed commit annotation is held, not closed" {
  mkdir -p src
  echo "x" > src/foo.py
  git add src/foo.py
  git commit -q -m "add foo"
  local short_sha
  short_sha="$(git rev-parse --short=7 HEAD)"
  mkdir -p docs
  printf -- '- [open] [!] 2026-05-01 src/foo.py:1 — critical bug (commit: %s)\n' "$short_sha" > docs/found-issues.md

  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\] \[!\].*critical bug' docs/found-issues.md
  grep -q "(commit: $short_sha) (hold: needs human verify)" docs/found-issues.md
  [[ "$output" == *"Held: 1 entry for human verification"* ]]
}

@test "hold: a critical with a merged PR is held and keeps its PR annotation" {
  fi_use_gh_shim
  fi_init_github_repo foo/bar main
  export GH_MOCK_PR_VIEW=$'42\t{"state":"MERGED","baseRefName":"main","mergedAt":"2026-05-01T12:00:00Z","isDraft":false}'
  mkdir -p src
  printf 'x\n' > src/foo.py
  mkdir -p docs
  printf -- '- [open] [!] 2026-05-01 src/foo.py:1 — critical bug (PR: foo/bar#42)\n' > docs/found-issues.md

  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\] \[!\].*(PR: foo/bar#42) (hold: needs human verify)$' docs/found-issues.md
  [[ "$output" == *"Held: 1 entry for human verification"* ]]
}

@test "hold: a per-entry hold keeps a non-critical entry open after its PR merged" {
  fi_use_gh_shim
  fi_init_github_repo foo/bar main
  export GH_MOCK_PR_VIEW=$'42\t{"state":"MERGED","baseRefName":"main","mergedAt":"2026-05-01T12:00:00Z","isDraft":false}'
  mkdir -p src docs
  printf 'x\n' > src/foo.py
  printf -- '- [open] 2026-05-01 src/foo.py:1 — plain bug (PR: foo/bar#42) (hold: waiting on QA)\n' > docs/found-issues.md

  fi_run sync
  [ "$status" -eq 0 ]
  # Held with the human's own reason; sync adds nothing.
  [ "$(cat docs/found-issues.md)" = "- [open] 2026-05-01 src/foo.py:1 — plain bug (PR: foo/bar#42) (hold: waiting on QA)" ]
  [[ "$output" == *"Held: 1 entry for human verification"* ]]
  [[ "$output" == *"waiting on QA"* ]]
}

@test "hold: parser keeps the PR annotation next to a hold marker (list --json)" {
  mkdir -p docs
  printf -- '- [open] 2026-05-01 src/a.sh:10 — odd thing (PR: acme/r#5) (hold: needs human verify)\n' > docs/found-issues.md
  fi_run list --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"prs":"acme/r#5"'* ]]
  [[ "$output" == *'"hold":"needs human verify"'* ]]
  [[ "$output" == *'"symptom":"odd thing"'* ]]
}

@test "hold: tag --hold sets the marker and replaces an earlier reason" {
  mkdir -p src
  printf 'a\n' > src/foo.py
  fi_run log "src/foo.py:1 — marker target"
  fi_run tag "marker target" --hold "wait for QA"
  [ "$status" -eq 0 ]
  grep -q '^- \[open\].*marker target (hold: wait for QA)$' docs/found-issues.md
  fi_run tag "marker target" --hold "wait for legal"
  [ "$status" -eq 0 ]
  run grep -c '(hold: ' docs/found-issues.md
  [ "$output" -eq 1 ]
  grep -q '(hold: wait for legal)$' docs/found-issues.md
}

@test "hold: tag --unhold removes the marker" {
  mkdir -p src
  printf 'a\n' > src/foo.py
  fi_run log "src/foo.py:1 — marker target"
  fi_run tag "marker target" --hold "wait for QA"
  fi_run tag "marker target" --unhold
  [ "$status" -eq 0 ]
  run grep -c '(hold: ' docs/found-issues.md
  [ "$output" = "0" ]
}

@test "hold: tag --unhold on an entry without a hold fails" {
  mkdir -p src
  printf 'a\n' > src/foo.py
  fi_run log "src/foo.py:1 — marker target"
  fi_run tag "marker target" --unhold
  [ "$status" -eq 1 ]
}

@test "hold: resolve closes a held entry even with a PR annotation and drops the hold" {
  mkdir -p docs
  printf -- '- [open] [!] 2026-05-01 src/a.sh:10 — held critical (PR: acme/r#5) (hold: needs human verify)\n' > docs/found-issues.md
  fi_run resolve "held critical" --verified review
  [ "$status" -eq 0 ]
  grep -q '^- \[fixed\] \[!\].*(PR: acme/r#5) (verified: review) (fixed: ' docs/found-issues.md
  run grep -c '(hold: ' docs/found-issues.md
  [ "$output" = "0" ]
}

@test "hold: resolve still refuses an active PR entry that carries no hold" {
  mkdir -p docs
  printf -- '- [open] 2026-05-01 src/a.sh:10 — in flight (PR: acme/r#5)\n' > docs/found-issues.md
  fi_run resolve "in flight" --verified review
  [ "$status" -eq 4 ]
}

# A hold reserves the closure for a human: the default verifier (ai) and an
# explicit ai are refused, and the ledger is left byte-identical.
@test "hold: resolve with the default verifier refuses a held entry and leaves the ledger alone" {
  mkdir -p docs
  printf -- '- [open] [!] 2026-05-01 src/a.sh:10 — held critical (PR: acme/r#5) (hold: needs human verify)\n' > docs/found-issues.md
  cp docs/found-issues.md before.md
  fi_run resolve "held critical"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--verified review"* ]]
  cmp docs/found-issues.md before.md
}

@test "hold: resolve --verified ai refuses a held entry and leaves the ledger alone" {
  mkdir -p docs
  printf -- '- [open] 2026-05-01 src/a.sh:10 — held plain (hold: waiting on QA)\n' > docs/found-issues.md
  cp docs/found-issues.md before.md
  fi_run resolve "held plain" --verified ai
  [ "$status" -eq 2 ]
  [[ "$output" == *"--verified review"* ]]
  cmp docs/found-issues.md before.md
}

@test "hold: resolve --verified human closes a held entry as review and drops the hold" {
  mkdir -p docs
  printf -- '- [open] 2026-05-01 src/a.sh:10 — held plain (hold: waiting on QA)\n' > docs/found-issues.md
  fi_run resolve "held plain" --verified human
  [ "$status" -eq 0 ]
  grep -q '^- \[fixed\] .*held plain.*(verified: review) (fixed: ' docs/found-issues.md
  run grep -c '(hold: ' docs/found-issues.md
  [ "$output" = "0" ]
}

@test "hold: resolve with the default verifier still closes a non-held entry" {
  mkdir -p docs
  printf -- '- [open] 2026-05-01 src/a.sh:10 — plain thing\n' > docs/found-issues.md
  fi_run resolve "plain thing"
  [ "$status" -eq 0 ]
  grep -q '^- \[fixed\] .*plain thing.*(verified: ai) (fixed: ' docs/found-issues.md
}
