#!/usr/bin/env bats
# Tests for `found-issues sync` — annotation flips + tombstone

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

@test "sync: no-op when nothing to close" {
  # Create the referenced file so tombstone doesn't fire
  mkdir -p src
  printf 'line1\nline2\nline3\n' > src/foo.py
  fi_run log "src/foo.py:1 — bug"
  fi_run sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to close"* ]]
}

@test "sync: tombstone closes entry when a tracked file is deleted" {
  mkdir -p src
  printf 'content\n' > src/missing.py
  git add src/missing.py
  git commit -q -m "add missing.py"
  fi_run log "src/missing.py:1 — bug in a file that later gets deleted"
  git rm -q src/missing.py
  git commit -q -m "delete missing.py"

  fi_run sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"tombstone"* ]] || [[ "$output" == *"1"* ]]
  grep -q '\[fixed\]' docs/found-issues.md
  grep -q 'closure: tombstone' docs/found-issues.md
}

# === present-but-shorter file is LINE DRIFT, never a closure (2026-08-12) ===
#
# A cited line past EOF says nothing about whether the issue was fixed — only
# that the file changed shape. Tombstoning on it false-closes live entries
# every time a tracked file shrinks, silently and with no user action, since
# SessionStart runs sync unattended. Hit for real during the v2.2.5-v2.2.7
# §12 extraction: bin/found-issues went 5209 -> 3443 lines and the
# loc-validator entry cited at :4811 flipped to [fixed] while the file was
# still 3443 lines against a 500 signal. There is no supported way to reopen
# a [fixed] entry, so a merged false close is permanent.
#
# Closure still fires when the file is genuinely GONE or RENAMED - those say
# something real about the entry. Line count alone does not.
@test "sync: leaves entry open when the cited line is past the end of a present file" {
  mkdir -p src
  printf 'line1\n' > src/short.py  # 1 line file
  fi_run log "src/short.py:99 — line 99 does not exist"
  fi_run sync
  grep -q '^- \[open\].*src/short.py:99' docs/found-issues.md
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

@test "sync: does not tombstone an entry whose present file merely shrank below it" {
  mkdir -p src
  # 10-line file; the entry cites a line that exists when it is logged
  printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\n' > src/shrink.py
  fi_run log "src/shrink.py:9 — bug at line 9"
  grep -q '^- \[open\].*src/shrink.py:9' docs/found-issues.md

  # the file is refactored smaller: line 9 is gone, but the file is still here
  printf 'l1\nl2\nl3\n' > src/shrink.py
  fi_run sync
  [ "$status" -eq 0 ]

  grep -q '^- \[open\].*src/shrink.py:9' docs/found-issues.md
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

@test "sync: leaves entries with present file alone" {
  mkdir -p src
  printf 'line1\nline2\n' > src/here.py
  fi_run log "src/here.py:2 — bug at line 2"
  fi_run sync
  # Entry stays [open] because file/line still exists, no annotation
  grep -q '^- \[open\].*src/here.py:2' docs/found-issues.md
}

@test "sync: commits annotation flips entry when commit is on default branch" {
  mkdir -p src
  echo "x" > src/foo.py
  git add src/foo.py
  git commit -q -m "add foo"
  short_sha="$(git rev-parse --short=7 HEAD)"

  # Log against an existing file/line, then manually annotate with the commit
  fi_run log "src/foo.py:1 — bug"
  # Edit the entry to add the commit annotation
  sed -i.bak "s|src/foo.py:1 — bug|src/foo.py:1 — bug (commit: $short_sha)|" docs/found-issues.md
  rm -f docs/found-issues.md.bak

  fi_run sync
  grep -q '\[fixed\]' docs/found-issues.md
  grep -q "(commit: $short_sha)" docs/found-issues.md
}

@test "sync: appends (fixed: <date>) on closure" {
  mkdir -p src
  printf 'x\n' > src/missing.py
  git add src/missing.py
  git commit -q -m "add missing.py"
  fi_run log "src/missing.py:1 — bug"
  git rm -q src/missing.py
  git commit -q -m "delete missing.py"

  fi_run sync
  grep -qE '\(fixed: [0-9]{4}-[0-9]{2}-[0-9]{2}\)' docs/found-issues.md
}

@test "sync: auto-archives old fixed entries by default" {
  local old
  old="$(date -v-45d +%Y-%m-%d 2>/dev/null || date -d '45 days ago' +%Y-%m-%d)"
  mkdir -p docs
  cat > docs/found-issues.md <<EOF
# found-issues

- [fixed] $old src/foo.py:1 — old bug (PR: org/repo#1) (fixed: $old)
- [open] 2026-05-09 src/bar.py:1 — new bug
EOF

  fi_run sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"moved 1 entries"* ]]
  [ -f docs/found-issues-archive.md ]
  grep -Fq "$old" docs/found-issues-archive.md
  ! grep -Fq "$old" docs/found-issues.md
}

@test "sync: respects FOUND_ISSUES_AUTO_ARCHIVE=off" {
  local old
  old="$(date -v-45d +%Y-%m-%d 2>/dev/null || date -d '45 days ago' +%Y-%m-%d)"
  mkdir -p docs
  cat > docs/found-issues.md <<EOF
# found-issues

- [fixed] $old src/foo.py:1 — old bug (PR: org/repo#1) (fixed: $old)
- [open] 2026-05-09 src/bar.py:1 — new bug
EOF

  FOUND_ISSUES_AUTO_ARCHIVE=off fi_run sync
  [ "$status" -eq 0 ]
  [[ "$output" != *"moved"* ]]
  [ ! -f docs/found-issues-archive.md ]
  grep -Fq "$old" docs/found-issues.md
}

@test "sync: silent when no archive needed (no spurious output)" {
  fi_run log "src/missing.py:1 — bug"
  fi_run sync
  [ "$status" -eq 0 ]
  [[ "$output" != *"moved"* ]]
  [[ "$output" != *"Hint"* ]]
}

# === home-relative / env-var locations must never tombstone (2026-07-20) ===
# A ledger can legitimately cite machine state outside the repo
# (~/.claude.json, $HOME/.config/...). Probing those as repo-relative
# literals ($repo_root/~/.claude.json) always misses, so sync tombstoned
# them on every run — reproduced live in agent-config: four false closures
# of the same ~-path entry in one day, each hand-repair lost within
# seconds to the next post-bash dispatcher fire.

@test "sync: never tombstones a ~-prefixed (home-relative) location" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues

- [open] 2026-07-20 ~/.claude.json someFlag (recurrence) — flag reset by an update (suggested: post-update check)
EOF
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\] 2026-07-20 ~/.claude.json' docs/found-issues.md
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

@test "sync: never tombstones a \$VAR-prefixed location" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues

- [open] 2026-07-20 $HOME/.config/tool/config.json — drift outside the repo (suggested: doctor check)
EOF
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\] 2026-07-20 \$HOME/.config' docs/found-issues.md
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

# === annotation tokens inside symptom text must not drive flips ===

@test "sync: commit annotation form inside SYMPTOM text does not flip the entry" {
  mkdir -p src
  echo "x" > src/foo.py
  git add src/foo.py
  git commit -q -m "add foo"
  short_sha="$(git rev-parse --short=7 HEAD)"

  # The canonical form appears mid-symptom (narrating another entry's fix),
  # followed by more symptom text — it is NOT a trailing annotation.
  mkdir -p docs
  cat > docs/found-issues.md <<EOF
# found-issues

- [open] 2026-07-20 src/foo.py:1 — earlier repair shipped as (commit: $short_sha) but this symptom persists (suggested: real fix)
EOF
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\] 2026-07-20 src/foo.py:1' docs/found-issues.md
}

@test "sync: tombstone never probes paths with .. components (path traversal)" {
  # Regression (2026-07-09 audit, critical): entry paths are attacker-
  # controlled (committed found-issues.md in any cloned repo) and were
  # joined to repo_root verbatim — a ../-laden path made sync stat and
  # wc -l files OUTSIDE the repo (existence/line-count oracle), and
  # SessionStart auto-runs sync with no user action.
  # Layout: the git repo is a SUBDIR of $TMP so ../outside.txt escapes it.
  mkdir -p repo && cd repo && git init -q -b main
  printf 'one line\n' > ../outside.txt   # exists, 1 line — outside the repo
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues

- [open] 2020-01-01 ../outside.txt:999999 — traversal probe
- [open] 2020-01-01 ../../../../../../../../etc/hosts:999999 — deep traversal probe
EOF
  fi_run sync
  [ "$status" -eq 0 ]
  # Old behavior: both flipped to [fixed] (closure: tombstone) because the
  # out-of-repo probe found a file shorter than the entry line. New
  # behavior: traversal paths are skipped — entries stay [open], untouched.
  [ "$(grep -c '^- \[open\]' docs/found-issues.md)" -eq 2 ]
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

@test "sync: tombstone never probes absolute entry paths" {
  mkdir -p docs src
  printf 'one line\n' > src/real.py
  cat > docs/found-issues.md <<'EOF'
# found-issues

- [open] 2020-01-01 /etc/hosts:999999 — absolute-path probe
EOF
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\] 2020-01-01 /etc/hosts:999999' docs/found-issues.md
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

@test "sync: entry on last line of file without trailing newline is NOT tombstoned" {
  mkdir -p src
  printf 'line1\nline2\nline3' > src/nonewline.py  # 3 lines, no trailing \n
  fi_run log "src/nonewline.py:3 — bug on the unterminated last line"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\].*src/nonewline.py:3' docs/found-issues.md
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

# Companion to the test above. The pair originally proved the awk END{NR}
# count distinguished "entry on the unterminated last line" (never a closure)
# from "entry past EOF" (a closure). Since 2026-08-12 neither closes: a line
# count says nothing about whether the issue was fixed. Kept as a stays-open
# assertion so the unterminated-file path stays covered on both sides.
@test "sync: line past end of a file without trailing newline stays open" {
  mkdir -p src
  printf 'line1\nline2' > src/nonewline2.py  # 2 lines, no trailing \n
  fi_run log "src/nonewline2.py:3 — cites a line past EOF"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\].*src/nonewline2.py:3' docs/found-issues.md
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

@test "sync: glob-style location tokens are never tombstone-probed" {
  # The widened location charset lets glob/brace tokens parse as paths;
  # probing them as literal filenames false-flipped the entries at every
  # SessionStart sync.
  fi_run log "tests/*.bats — every bats file hardcodes the fixture date"
  fi_run log "config/{dev,prod}.yml — duplicated keys drift"
  fi_run sync
  [ "$status" -eq 0 ]
  ! grep -q 'closure: tombstone' docs/found-issues.md
  [ "$(grep -c '^- \[open\]' docs/found-issues.md)" -eq 2 ]
}

# === directory paths must never tombstone (agent-config 2026-07-27) ===
# An entry can cite a directory (.git/worktrees, src/utils). The probe used
# [[ ! -f ]], so an EXISTING directory read as "file missing" and sync
# tombstoned the entry on every pass — reproduced live in agent-config:
# a fresh .git/worktrees entry false-closed twice within minutes of landing.

@test "sync: never tombstones an entry whose path is an existing directory" {
  mkdir -p .git/worktrees
  fi_run log ".git/worktrees — orphaned worktree registration left by ended session"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\].*\.git/worktrees' docs/found-issues.md
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

@test "sync: existing directory cited with a line number is not line-probed" {
  mkdir -p src/utils
  fi_run log "src/utils:3 — dead module tree"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\].*src/utils:3' docs/found-issues.md
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

# === paths containing spaces must never tombstone (2026-07-31) ===
# fi_parse_entry takes the first whitespace-delimited token as the path, so a
# path containing spaces ("docs/handoff/HO production env setup.md:88") became
# a DIFFERENT, non-existent path ("docs/handoff/HO") and was tombstoned on
# every pass even though the file was present. `log` creates such entries
# itself, so it needed no hand-editing. Reproduced live in a consumer ledger,
# where it false-closed a critical credential-exposure entry whose credential
# was still unrotated. Fourth member of the ~/$VAR, glob and directory family.

@test "sync: never tombstones an entry whose path contains spaces" {
  mkdir -p "docs/handoff"
  printf 'line\n%.0s' $(seq 1 20) > "docs/handoff/HO production env setup.md"
  fi_run log "docs/handoff/HO production env setup.md:12 — token committed in plaintext"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\].*HO production env setup\.md' docs/found-issues.md
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

@test "sync: spaced path that is genuinely missing still tombstones" {
  mkdir -p docs/handoff
  printf 'x\n' > "docs/handoff/absent report file.md"
  git add -A
  git commit -q -m "add spaced report"
  fi_run log "docs/handoff/absent report file.md:3 — cites a file that later goes away"
  git rm -q "docs/handoff/absent report file.md"
  git commit -q -m "delete spaced report"

  fi_run sync
  [ "$status" -eq 0 ]
  grep -q 'closure: tombstone' docs/found-issues.md
}

@test "sync: existing directory whose path contains spaces is not tombstoned" {
  mkdir -p "src/legacy modules"
  fi_run log "src/legacy modules — dead tree pending deletion"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\].*legacy modules' docs/found-issues.md
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

# === repo-prefixed locations must never be probed (#123, 2026-08-11) ===
# Teaching the parser the legacy `Repo:path[:line]` shape gives these entries
# a non-empty path for the first time, which would otherwise route them into
# the tombstone probe and false-close them against THIS repo's root. They are
# not repo-local paths, so the probe chain skips them entirely, exactly like
# the ~/$VAR and glob/brace guards. Fifth potential member of that family.

@test "sync: never tombstones an entry whose location carries a repo prefix" {
  fi_run log "LendMatrix-svc:src/services/foo.ts:42 — foreign repo entry, no such local file"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\].*LendMatrix-svc:src/services/foo\.ts:42' docs/found-issues.md
  run grep -q 'closure: tombstone' docs/found-issues.md
  [ "$status" -ne 0 ]
}

@test "sync: repo-prefixed entry without a line number is not tombstoned" {
  fi_run log "LendMatrix-svc:node_modules/dotenv — outdated dep"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\].*LendMatrix-svc:node_modules/dotenv' docs/found-issues.md
  run grep -q 'closure: tombstone' docs/found-issues.md
  [ "$status" -ne 0 ]
}

# === final-partial-line data loss (v2.2.1) ===
#
# The worst case of the bug class: SessionStart runs sync automatically, so an
# unguarded rewrite loses the last entry with no user action and no output
# saying anything was removed. See fi_seed_no_trailing_newline in helpers.bash.

@test "sync: does not drop a final entry that lacks a trailing newline" {
  fi_seed_no_trailing_newline

  fi_run sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to close"* ]]
  fi_assert_both_entries_survived
}

# === git is the oracle for "the file is really gone" (2026-08-14, issue #151) ===
#
# Filesystem absence alone is not evidence an issue was fixed. A path can be
# absent because it was never a file at all (abstract locations like
# `workflow/release-process`), because it is gitignored, or because someone
# deleted it in a dirty worktree and has not committed. Tombstoning on bare
# absence false-closed live entries in all three cases -- silently, since
# SessionStart runs sync unattended, and permanently, since nothing reopens a
# [fixed] entry.
#
# The rule now: only tombstone when git confirms the path WAS tracked and is
# NOT in the current HEAD tree -- a committed removal. Everything else stays
# [open].

@test "sync: does not tombstone a path git never tracked (abstract location)" {
  printf 'x\n' > seed.txt
  git add seed.txt
  git commit -q -m seed
  fi_run log "workflow/release-process — the release runbook drifts from reality"

  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\].*workflow/release-process' docs/found-issues.md
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

@test "sync: does not tombstone a tracked file deleted only in the working tree" {
  mkdir -p src
  printf 'x\n' > src/dirty.py
  git add -A
  git commit -q -m seed
  fi_run log "src/dirty.py:1 — bug in a file about to be removed uncommitted"
  rm src/dirty.py   # deleted on disk, still tracked in HEAD

  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\].*src/dirty.py:1' docs/found-issues.md
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

@test "sync: does not tombstone a critical entry whose path was never tracked" {
  printf 'x\n' > seed.txt
  git add seed.txt
  git commit -q -m seed
  fi_run log --critical "src/typo-never-existed.py:1 — critical logged against a mistyped path"

  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\] \[!\].*typo-never-existed' docs/found-issues.md
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

@test "sync: does not tombstone a gitignored path that is absent" {
  printf 'build/\n' > .gitignore
  git add .gitignore
  git commit -q -m seed
  fi_run log "build/artifact.js:1 — generated bundle ships a stale banner"

  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\].*build/artifact.js:1' docs/found-issues.md
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

# === mutating subcommands must reject unknown flags (2026-08-14, issue #151) ===
#
# `found-issues sync --help` ran a full mutating sync and closed entries: the
# command parsed no arguments at all, so every flag was silently ignored. A
# user reaching for help instead performed an irreversible closure pass.

fi_seed_deletable_entry() {
  mkdir -p src
  printf 'x\n' > src/gone.py
  git add -A
  git commit -q -m seed
  fi_run log "src/gone.py:1 — bug in a file that is then deleted"
  git rm -q src/gone.py
  git commit -q -m "delete gone.py"
}

@test "sync: --help prints usage and does not mutate the ledger" {
  fi_seed_deletable_entry
  fi_run sync --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"sync"* ]]
  grep -q '^- \[open\].*src/gone.py:1' docs/found-issues.md
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

@test "sync: unknown flag is a hard error and does not mutate the ledger" {
  fi_seed_deletable_entry
  fi_run sync --no-such-flag
  [ "$status" -ne 0 ]
  grep -q '^- \[open\].*src/gone.py:1' docs/found-issues.md
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

@test "sync: --dry-run reports the closure without writing it" {
  fi_seed_deletable_entry
  fi_run sync --dry-run
  [ "$status" -eq 0 ]
  # Assert the SUMMARY, not a bare "1": cmd_status prints "1 issue" at the end
  # of every sync, so a substring check on "1" passes even when the dry run
  # reported nothing at all.
  [[ "$output" == *"Dry run"* ]]
  [[ "$output" == *"tombstone"* ]]
  grep -q '^- \[open\].*src/gone.py:1' docs/found-issues.md
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

@test "sync: --dry-run does not auto-archive" {
  # Auto-archive rewrites the ledger and creates the archive file, so a dry run
  # that skipped only the main write still moved entries once the [fixed]
  # threshold was crossed.
  local old
  old="$(date -v-45d +%Y-%m-%d 2>/dev/null || date -d '45 days ago' +%Y-%m-%d)"
  mkdir -p docs
  {
    printf '# found-issues\n\n'
    for i in $(seq 1 55); do
      printf -- '- [fixed] %s src/f%d.py:1 — old bug (PR: org/repo#%d) (fixed: %s)\n' "$old" "$i" "$i" "$old"
    done
    printf -- '- [open] 2026-08-14 src/live.py:1 — still open\n'
  } > docs/found-issues.md
  local before
  before="$(wc -l < docs/found-issues.md)"

  fi_run sync --dry-run
  [ "$status" -eq 0 ]
  [ ! -f docs/found-issues-archive.md ]
  [ "$(wc -l < docs/found-issues.md)" -eq "$before" ]
}

@test "sync: rejects flags hidden behind a -- separator" {
  fi_seed_deletable_entry
  fi_run sync -- --help
  [ "$status" -ne 0 ]
  grep -q '^- \[open\].*src/gone.py:1' docs/found-issues.md
  ! grep -q 'closure: tombstone' docs/found-issues.md
}

@test "sync: corrects a renamed location that contains spaces without garbling it" {
  # rename_source must be the path actually MATCHED. Using the whitespace-
  # truncated first token replaced only the prefix and left a corrupted
  # location behind, with no supported way to repair it by hand.
  mkdir -p docs/handoff
  printf 'x\ny\n' > "docs/handoff/HO production env setup.md"
  git add -A
  git commit -q -m "add spaced doc"
  fi_run log "docs/handoff/HO production env setup.md:2 — stale instructions"
  git mv "docs/handoff/HO production env setup.md" docs/handoff/renamed-setup.md
  git commit -q -m "rename spaced doc"

  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\].*docs/handoff/renamed-setup\.md:2 — stale instructions' docs/found-issues.md
  ! grep -q 'production env setup\.md:2' docs/found-issues.md
}

@test "sync: still tombstones a 'path symbol ~range' location whose file was removed" {
  # Only the FIRST token is a filename here; the recovered location is the whole
  # descriptor, which git never tracked. Probing only that dropped both
  # tombstone and rename handling for a documented location form.
  mkdir -p lib
  printf 'a\nb\nc\n' > lib/foo.sh
  git add -A
  git commit -q -m "add foo.sh"
  fi_run log "lib/foo.sh fi_helper ~1-3 — helper is broken"
  git rm -q lib/foo.sh
  git commit -q -m "delete foo.sh"

  fi_run sync
  [ "$status" -eq 0 ]
  grep -q 'closure: tombstone' docs/found-issues.md
}

# === Suggestion tokens never close (2026-08-17) ===============================
# The incident this guards: an entry deliberately left [open] was auto-annotated
# because a commit touched its cited line; the next sync would have flipped it
# to [fixed], silently closing work nobody did. Suggestions are recorded and
# REPORTED, never closed on.

@test "sync: (commit-auto:) on a landed commit does NOT flip the entry" {
  mkdir -p src
  echo "x" > src/foo.py
  git add src/foo.py
  git commit -q -m "add foo"
  short_sha="$(git rev-parse --short=7 HEAD)"

  fi_run log "src/foo.py:1 — bug"
  sed -i.bak "s|src/foo.py:1 — bug|src/foo.py:1 — bug (commit-auto: $short_sha)|" docs/found-issues.md
  rm -f docs/found-issues.md.bak

  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\]' docs/found-issues.md
  run grep -q '\[fixed\]' docs/found-issues.md
  [ "$status" -ne 0 ]
}

@test "sync: reports a landed suggestion as awaiting confirmation" {
  mkdir -p src
  echo "x" > src/foo.py
  git add src/foo.py
  git commit -q -m "add foo"
  short_sha="$(git rev-parse --short=7 HEAD)"

  fi_run log "src/foo.py:1 — bug"
  sed -i.bak "s|src/foo.py:1 — bug|src/foo.py:1 — bug (commit-auto: $short_sha)|" docs/found-issues.md
  rm -f docs/found-issues.md.bak

  fi_run sync
  [[ "$output" == *"awaiting confirmation"* ]]
  [[ "$output" == *"NOT closed"* ]]
  [[ "$output" == *"src/foo.py:1"* ]]
}

@test "sync: an UNLANDED suggestion is silent (nothing to confirm yet)" {
  mkdir -p src
  echo "x" > src/foo.py
  git add src/foo.py
  git commit -q -m "add foo"

  fi_run log "src/foo.py:1 — bug"
  sed -i.bak "s|src/foo.py:1 — bug|src/foo.py:1 — bug (commit-auto: deadbee)|" docs/found-issues.md
  rm -f docs/found-issues.md.bak

  fi_run sync
  [[ "$output" != *"awaiting confirmation"* ]]
  grep -q '^- \[open\]' docs/found-issues.md
}
