#!/usr/bin/env bash
# tests/helpers.bash — shared bats helpers
#
# Source from each .bats file: `load 'helpers'`

# Resolve the repo root (one level up from tests/)
TEST_REPO_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"

export FI_BIN="$TEST_REPO_ROOT/bin/found-issues"
export FI_LIB_DIR="$TEST_REPO_ROOT/lib"
export FOUND_ISSUES_LIB_DIR="$FI_LIB_DIR"

# Default-off the segment auto-sync background spawn for tests that don't
# care about it. Otherwise any test that calls `found-issues status
# --format=segment` triggers a backgrounded `found-issues sync` whose
# subprocess can outlive the test and hold open handles to the tmpdir —
# bats teardown's `rm -rf $TMP` then fails with "Device or resource busy"
# on Windows runners (observed in CI run 25743626711 / PR #86). Tests that
# explicitly exercise the autosync path opt back in via `unset` in their
# setup() (see tests/cli-status-autosync.bats).
export FOUND_ISSUES_SEGMENT_AUTOSYNC=off

# Ensure the CLI is executable (bats clones into a tempdir, may lose +x)
chmod +x "$FI_BIN" 2>/dev/null || true

# Make a temp directory and cd into it (per-test isolation).
# Adds a teardown that removes the dir.
fi_setup_tmp() {
  TMP="$(mktemp -d -t fi-test.XXXXXX)"
  cd "$TMP"
}

fi_teardown_tmp() {
  if [[ -n "${TMP:-}" && -d "$TMP" ]]; then
    cd /tmp
    # Bounded retry: on Windows a just-dispatched background autosync child
    # can still hold $TMP as its cwd, making the first rm fail with
    # "Device or resource busy"; the dir frees as soon as the child exits.
    local attempt
    for attempt in 1 2 3; do
      rm -rf "$TMP" 2>/dev/null && return 0
      sleep 1
    done
    rm -rf "$TMP"
  fi
}

# Initialize a git repo in the current dir, with a default identity.
fi_init_git() {
  git init -q -b main
  git config user.email "test@example.com"
  git config user.name "Test"
}

# Source a lib file by basename (e.g. fi_source_lib canonicalize).
fi_source_lib() {
  local name="$1"
  source "$FI_LIB_DIR/${name}.sh"
}

# Run the CLI; output captured by bats's $output / $status.
fi_run() {
  run "$FI_BIN" "$@"
}

# Strip ANSI escape codes from a string (for testing colored output).
fi_strip_ansi() {
  local input="$1"
  printf '%s' "$input" | sed -E $'s/\033\\[[0-9;]*[a-zA-Z]//g'
}

# Generate a sample valid found-issues.md (for parse/sync tests).
# Args: $1 = file path
fi_seed_sample() {
  local file="$1"
  mkdir -p "$(dirname "$file")"
  cat > "$file" <<'EOF'
# found-issues

Test fixture.

- [open] 2026-04-15 src/foo.py:42 — null check missing (suggested: add guard)
- [open] [!] 2026-04-20 src/auth.ts:88 — leaks token (suggested: redact)
- [open] 2026-04-25 workflow/shutdown — sigterm kills sessions silently
- [open] 2026-05-01 src/bar.py:99 — wrong type cast (PR: org/repo#42)
- [fixed] 2026-04-10 src/old.py:1 — fixed long ago (PR: org/repo#1) (fixed: 2026-04-12)
- [deferred] 2026-05-05 docs/README.md — outdated examples
EOF
}

# Seed a 2-entry ledger whose FINAL line carries NO trailing newline, plus the
# source files both entries cite (so sync's tombstone check stays quiet).
#
# `read` returns non-zero on a final partial line, so an unguarded
# `while IFS= read -r line` never runs its body for it and a rewrite silently
# drops that entry — the v2.2.1 data-loss bug (defer, sync, annotate-commit and
# promote-deferred each turned this 2-entry ledger into 1). Hand-edited ledgers
# and some editors produce exactly this shape.
#
# Args: $1 = status of the FIRST entry (default "open"; pass "deferred" for
# the promote-deferred path). The final entry is always [open].
fi_seed_no_trailing_newline() {
  local first_status="${1:-open}"
  mkdir -p docs src
  printf 'line1\nline2\n' > src/a.py
  printf 'line1\nline2\n' > src/b.py
  printf '# found-issues\n\n' > docs/found-issues.md
  printf -- '- [%s] 2026-08-11 src/a.py:1 — first entry\n' "$first_status" >> docs/found-issues.md
  printf -- '- [open] 2026-08-11 src/b.py:2 — final entry with no trailing newline' >> docs/found-issues.md
}

# Assert both entries seeded by fi_seed_no_trailing_newline survived the
# command under test. Counts entry lines rather than diffing, so a status flip
# on the first entry (open -> deferred/fixed) still passes.
fi_assert_both_entries_survived() {
  [ "$(grep -c '^- \[' docs/found-issues.md)" -eq 2 ]
  grep -q 'final entry with no trailing newline' docs/found-issues.md
}

# Activate the gh shim for this test by prepending bin-shims to PATH.
# Caller must set GH_MOCK_PR_VIEW / GH_MOCK_REPO_VIEW / GH_MOCK_AUTH as needed.
fi_use_gh_shim() {
  export PATH="$TEST_REPO_ROOT/tests/bin-shims:$PATH"
}

# Set up a fake GitHub repo for tests exercising sync's PR-check paths.
# Combines fi_init_git with: an empty initial commit, a github.com origin
# remote, origin/HEAD pointing at main, and FOUND_ISSUES_MODE=github-pr
# to short-circuit detect-mode (avoiding gh-shim/cache dependence).
#
# Caller-controllable: pass org/repo as $1 (default foo/bar) and branch as $2 (default main).
fi_init_github_repo() {
  local repo_slug="${1:-foo/bar}"
  local branch="${2:-main}"
  git checkout -q -b "$branch" 2>/dev/null || true
  git commit --allow-empty -q -m "init" 2>/dev/null || true
  git remote add origin "https://github.com/${repo_slug}.git" 2>/dev/null || true
  git symbolic-ref "refs/remotes/origin/HEAD" "refs/remotes/origin/${branch}" 2>/dev/null || true
  export FOUND_ISSUES_MODE=github-pr
}

# Emit a synthetic Claude Code statusline stdin JSON payload.
# Used by Layer 2 end-to-end tests and Layer 3 doctor runtime probe.
# Args: $1 = workspace.current_dir
fi_synthetic_stdin() {
  local dir="$1"
  printf '{"model":{"display_name":"Test"},"workspace":{"current_dir":"%s"},"session_id":"t","context_window":{"remaining_percentage":50}}' "$dir"
}
