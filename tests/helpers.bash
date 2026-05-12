#!/usr/bin/env bash
# tests/helpers.bash — shared bats helpers
#
# Source from each .bats file: `load 'helpers'`

# Resolve the repo root (one level up from tests/)
TEST_REPO_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"

export FI_BIN="$TEST_REPO_ROOT/bin/found-issues"
export FI_LIB_DIR="$TEST_REPO_ROOT/lib"
export FOUND_ISSUES_LIB_DIR="$FI_LIB_DIR"

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

# Activate the gh shim for this test by prepending bin-shims to PATH.
# Caller must set GH_MOCK_PR_VIEW / GH_MOCK_REPO_VIEW / GH_MOCK_AUTH as needed.
fi_use_gh_shim() {
  export PATH="$TEST_REPO_ROOT/tests/bin-shims:$PATH"
}
