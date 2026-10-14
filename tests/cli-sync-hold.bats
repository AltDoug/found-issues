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

# 3.10.1: the hold decision runs BEFORE any closure probe. A held entry used to
# cost the gh PR call and the git history probes on every SessionStart sync and
# then have the result walked back; a probe that records a side effect would
# have leaked a closure for it.

# A git on PATH that logs every call, then runs the real one.
git_trace_shim() {
  local real_git
  real_git="$(command -v git)"
  mkdir -p "$TMP/git-shim"
  cat > "$TMP/git-shim/git" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/git-trace"
exec "$real_git" "\$@"
SHIM
  chmod +x "$TMP/git-shim/git"
  : > "$TMP/git-trace"
  export PATH="$TMP/git-shim:$PATH"
}

@test "hold: sync checks a plain and an unmarked critical PR, and a marked entry never closes on one" {
  fi_use_gh_shim
  fi_init_github_repo foo/bar main
  export GH_MOCK_TRACE="$TMP/gh-trace"
  : > "$GH_MOCK_TRACE"
  export GH_MOCK_PR_VIEW=$'42\t{"state":"MERGED","baseRefName":"main","mergedAt":"2026-05-01T12:00:00Z","isDraft":false}\n43\t{"state":"MERGED","baseRefName":"main","mergedAt":"2026-05-01T12:00:00Z","isDraft":false}\n44\t{"state":"MERGED","baseRefName":"main","mergedAt":"2026-05-01T12:00:00Z","isDraft":false}'
  mkdir -p src docs
  printf 'x\n' > src/foo.py
  cat > docs/found-issues.md <<'LEDGER'
- [open] [!] 2026-05-01 src/foo.py:1 — critical with a merged PR (PR: foo/bar#42)
- [open] 2026-05-01 src/foo.py:2 — held by a human (PR: foo/bar#43) (hold: waiting on QA)
- [open] 2026-05-01 src/foo.py:3 — plain control (PR: foo/bar#44)
LEDGER

  PATH="$TEST_REPO_ROOT/bin:$PATH" fi_run sync
  [ "$status" -eq 0 ]
  # An unmarked critical probes like any entry (3.10.0), then is held.
  grep -q 'pr view 42' "$GH_MOCK_TRACE"
  grep -q 'pr view 44' "$GH_MOCK_TRACE"
  # The plain entry closes; the critical is marked, the human hold is untouched.
  grep -q '^- \[fixed\].*plain control.*(PR: foo/bar#44)' docs/found-issues.md
  grep -q '^- \[open\] \[!\].*critical with a merged PR (PR: foo/bar#42) (hold: needs human verify)$' docs/found-issues.md
  grep -q '^- \[open\] .*held by a human (PR: foo/bar#43) (hold: waiting on QA)$' docs/found-issues.md
  [[ "$output" == *"Closed: 1 (1 PR + 0 commit + 0 tombstone)"* ]]
  [[ "$output" == *"Held: 2 entries for human verification"* ]]
}

@test "hold: sync summary still counts and lists held entries when probes are skipped" {
  fi_use_gh_shim
  fi_init_github_repo foo/bar main
  export GH_MOCK_PR_VIEW=$'42\t{"state":"MERGED","baseRefName":"main","mergedAt":"2026-05-01T12:00:00Z","isDraft":false}\n44\t{"state":"MERGED","baseRefName":"main","mergedAt":"2026-05-01T12:00:00Z","isDraft":false}'
  mkdir -p src docs
  printf 'x\n' > src/foo.py
  cat > docs/found-issues.md <<'LEDGER'
- [open] [!] 2026-05-01 src/foo.py:1 — critical with a merged PR (PR: foo/bar#42)
- [open] 2026-05-01 src/foo.py:3 — plain control (PR: foo/bar#44)
LEDGER

  PATH="$TEST_REPO_ROOT/bin:$PATH" fi_run sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"Closed: 1 (1 PR + 0 commit + 0 tombstone)"* ]]
  [[ "$output" == *"Held: 1 entry for human verification (NOT closed):"* ]]
  [[ "$output" == *"critical with a merged PR"* ]]
  [[ "$output" == *"[hold: needs human verify]"* ]]
}

@test "hold: sync runs no removal probe for a marked entry and still probes a plain or unmarked critical one" {
  seed_removed_file
  mkdir -p src
  printf 'export const gone = 1;\n' > src/gone2.ts
  printf 'export const gone = 1;\n' > src/gone3.ts
  git add src/gone2.ts src/gone3.ts
  git commit -q -m "add gone2 gone3"
  git rm -q src/gone2.ts src/gone3.ts
  git commit -q -m "delete gone2 gone3"
  mkdir -p docs
  cat > docs/found-issues.md <<'LEDGER'
- [open] [!] 2026-05-01 src/gone.ts:1 — critical in a removed file
- [open] 2026-05-01 src/gone2.ts:1 — held in a removed file (hold: waiting on QA)
- [open] 2026-05-01 src/gone3.ts:1 — plain control in a removed file
LEDGER
  git_trace_shim

  PATH="$TEST_REPO_ROOT/bin:$PATH" fi_run sync
  [ "$status" -eq 0 ]
  local sync_out="$output"
  # The removal oracle (cat-file -e HEAD:<path>) runs for the plain control and
  # the unmarked critical, never for the marked entry.
  grep -q 'cat-file -e HEAD:src/gone3.ts' "$TMP/git-trace"
  grep -q 'cat-file -e HEAD:src/gone.ts' "$TMP/git-trace"
  run grep -c 'cat-file -e HEAD:src/gone2.ts' "$TMP/git-trace"
  [ "$output" = "0" ]
  [[ "$sync_out" == *"Held: 2 entries for human verification (NOT closed):"* ]]
  grep -q '^- \[fixed\].*plain control in a removed file.*closure: tombstone' docs/found-issues.md
  grep -q '^- \[open\] \[!\].*critical in a removed file (hold: needs human verify)$' docs/found-issues.md
  grep -q '^- \[open\] .*held in a removed file (hold: waiting on QA)$' docs/found-issues.md
}

# 3.10.1 review fixes: a critical entry is marked only when a closure signal
# would have fired (as in 3.10.0); a marked entry skips the closure probes but
# still gets its path corrected after a rename and its closed PRs demoted.

@test "hold: a critical entry with no closure signal is left untouched and not listed" {
  mkdir -p src docs
  printf 'x\n' > src/foo.py
  printf -- '- [open] [!] 2026-05-01 src/foo.py:1 — critical with no closure signal\n' > docs/found-issues.md
  cp docs/found-issues.md before.md

  PATH="$TEST_REPO_ROOT/bin:$PATH" fi_run sync
  [ "$status" -eq 0 ]
  cmp docs/found-issues.md before.md
  [[ "$output" != *"Held:"* ]]
  # Still resolvable: no marker was added, so plain resolve is not refused.
  fi_run resolve "critical with no closure signal"
  [ "$status" -eq 0 ]
}

@test "hold: a critical entry with a closed-unmerged PR is not marked held" {
  fi_use_gh_shim
  fi_init_github_repo foo/bar main
  export GH_MOCK_PR_VIEW=$'5\t{"state":"CLOSED","baseRefName":"main","mergedAt":null,"isDraft":false}'
  mkdir -p src docs
  printf 'x\n' > src/foo.py
  printf -- '- [open] [!] 2026-05-01 src/foo.py:1 — critical with a dead PR (PR: foo/bar#5)\n' > docs/found-issues.md

  PATH="$TEST_REPO_ROOT/bin:$PATH" fi_run sync
  [ "$status" -eq 0 ]
  [[ "$output" != *"Held:"* ]]
  run grep -c '(hold: ' docs/found-issues.md
  [ "$output" = "0" ]
  grep -q '(PR-closed: foo/bar#5)' docs/found-issues.md
}

@test "hold: a held entry still gets its path corrected after git mv" {
  mkdir -p src docs
  echo "content" > src/old.py
  git add src/old.py
  git commit -q -m "add old.py"
  printf -- '- [open] 2026-05-01 src/old.py:1 — held bug (hold: waiting on QA)\n' > docs/found-issues.md
  git mv src/old.py src/new.py
  git commit -q -m "rename old to new"

  PATH="$TEST_REPO_ROOT/bin:$PATH" fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\].*src/new.py:1.*held bug.*(hold: waiting on QA).*(renamed-from: src/old.py)' docs/found-issues.md
  [[ "$output" == *"Held: 1 entry for human verification"* ]]
}

@test "hold: a held entry whose file was deleted stays open" {
  seed_removed_file
  mkdir -p docs
  printf -- '- [open] 2026-05-01 src/gone.ts:1 — held in a removed file (hold: waiting on QA)\n' > docs/found-issues.md
  cp docs/found-issues.md before.md

  PATH="$TEST_REPO_ROOT/bin:$PATH" fi_run sync
  [ "$status" -eq 0 ]
  cmp docs/found-issues.md before.md
  [[ "$output" != *"Closed:"* ]]
}

@test "hold: a held entry with a closed-unmerged PR gets the PR demoted" {
  fi_use_gh_shim
  fi_init_github_repo foo/bar main
  export GH_MOCK_PR_VIEW=$'5\t{"state":"CLOSED","baseRefName":"main","mergedAt":null,"isDraft":false}'
  mkdir -p src docs
  printf 'x\n' > src/foo.py
  printf -- '- [open] 2026-05-01 src/foo.py:1 — held with a dead PR (PR: foo/bar#5) (hold: waiting on QA)\n' > docs/found-issues.md

  PATH="$TEST_REPO_ROOT/bin:$PATH" fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\].*(PR-closed: foo/bar#5).*(hold: waiting on QA)' docs/found-issues.md
  run grep -c '(PR: foo/bar#5)' docs/found-issues.md
  [ "$output" = "0" ]
}

@test "hold: a held entry with a merged PR stays open and bumps no closure counter" {
  fi_use_gh_shim
  fi_init_github_repo foo/bar main
  export GH_MOCK_PR_VIEW=$'42\t{"state":"MERGED","baseRefName":"main","mergedAt":"2026-05-01T12:00:00Z","isDraft":false}'
  mkdir -p src docs
  printf 'x\n' > src/foo.py
  printf -- '- [open] 2026-05-01 src/foo.py:1 — held bug (PR: foo/bar#42) (hold: waiting on QA)\n' > docs/found-issues.md
  cp docs/found-issues.md before.md

  PATH="$TEST_REPO_ROOT/bin:$PATH" fi_run sync
  [ "$status" -eq 0 ]
  cmp docs/found-issues.md before.md
  [[ "$output" != *"Closed:"* ]]
}

@test "hold: a held entry with no PR annotation makes no gh call" {
  fi_use_gh_shim
  fi_init_github_repo foo/bar main
  export GH_MOCK_TRACE="$TMP/gh-trace"
  : > "$GH_MOCK_TRACE"
  mkdir -p src docs
  printf 'x\n' > src/foo.py
  printf -- '- [open] 2026-05-01 src/foo.py:1 — held bug (hold: waiting on QA)\n' > docs/found-issues.md

  PATH="$TEST_REPO_ROOT/bin:$PATH" fi_run sync
  [ "$status" -eq 0 ]
  run grep -c 'pr view' "$GH_MOCK_TRACE"
  [ "$output" = "0" ]
}
