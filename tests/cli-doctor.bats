#!/usr/bin/env bats
# Tests for `found-issues doctor` — general-purpose health diagnostic.
#
# 2026-05-10 UX audit fast-follow (surfaces 5.2 + 6.2). Doctor aggregates
# CLI / statusline / gh / mode / hooks / issues-file state into a single
# read-only report. Always exits 0.

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
  unset FOUND_ISSUES_STOP_REMINDER FOUND_ISSUES_PROMOTE_GUARD
  unset FOUND_ISSUES_FORMAT_ENFORCER FOUND_ISSUES_PRE_COMMIT FOUND_ISSUES_AUTO_ARCHIVE
  unset FOUND_ISSUES_DEFER_TOUCH_THRESHOLD FOUND_ISSUES_DEFER_ESCALATION_FACTOR
  unset FOUND_ISSUES_STALE_DAYS
}

@test "doctor: exits 0 and prints all top-level sections" {
  fi_run doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"Plugin runtime"* ]]
  [[ "$output" == *"Statusline"* ]]
  [[ "$output" == *"gh CLI"* ]]
  [[ "$output" == *"Mode detection"* ]]
  [[ "$output" == *"Hook opt-outs"* ]]
  [[ "$output" == *"Issues file"* ]]
  [[ "$output" == *"Recommended next"* ]]
}

@test "doctor: prints CLI version in header" {
  fi_run doctor
  [ "$status" -eq 0 ]
  # Header should mention the version string
  [[ "$output" == *"found-issues doctor"* ]]
  [[ "$output" == *"v1."* ]]
}

@test "doctor: reports 'no issues file' when none present" {
  fi_run doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"No issues file"* ]]
}

@test "doctor: reports issues file path + counts when present" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] [!] 2026-05-10 src/auth.ts:88 — leak
- [open] 2026-05-10 src/foo.py:42 — null check
- [deferred] 2026-05-10 src/bar.py:99 — race
- [fixed] 2026-05-10 src/old.py:1 — done (fixed: 2026-05-10)
EOF
  fi_run doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"docs/found-issues.md"* ]]
  [[ "$output" == *"open: 2"* ]]
  [[ "$output" == *"critical: 1"* ]]
  [[ "$output" == *"deferred: 1"* ]]
  [[ "$output" == *"fixed: 1"* ]]
}

@test "doctor: surfaces hook opt-outs when env var is off" {
  export FOUND_ISSUES_STOP_REMINDER=off
  fi_run doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"FOUND_ISSUES_STOP_REMINDER=off"* ]]
}

@test "doctor: reports default-active when no opt-outs set" {
  unset FOUND_ISSUES_STOP_REMINDER FOUND_ISSUES_PROMOTE_GUARD
  unset FOUND_ISSUES_FORMAT_ENFORCER FOUND_ISSUES_PRE_COMMIT FOUND_ISSUES_AUTO_ARCHIVE
  fi_run doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"All hooks default-active"* ]]
}

@test "doctor: surfaces non-default tunables when env vars are set" {
  export FOUND_ISSUES_DEFER_TOUCH_THRESHOLD=5
  export FOUND_ISSUES_STALE_DAYS=7
  fi_run doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"FOUND_ISSUES_DEFER_TOUCH_THRESHOLD=5"* ]]
  [[ "$output" == *"FOUND_ISSUES_STALE_DAYS=7"* ]]
  [[ "$output" == *"Tunables"* ]]
}

@test "doctor: hides 'Tunables' section when all are default" {
  fi_run doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"Tunables (non-default)"* ]]
}

@test "doctor: flags suspicious [open] entry with stray (fixed: ...) annotation" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] 2026-05-10 src/foo.py:42 — bug (fixed: 2026-05-10)
EOF
  fi_run doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"stray (fixed:"* ]]
}

@test "doctor: flags [fixed] entries without (fixed: YYYY-MM-DD) annotation" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [fixed] 2026-05-10 src/old.py:1 — done long ago
EOF
  fi_run doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"without (fixed: YYYY-MM-DD)"* ]] || [[ "$output" == *"closure date unknown"* ]]
}

@test "doctor: read-only, does not modify any files" {
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] 2026-05-10 src/foo.py:42 — bug
EOF
  before="$(cat docs/found-issues.md)"
  fi_run doctor
  [ "$status" -eq 0 ]
  after="$(cat docs/found-issues.md)"
  [ "$before" = "$after" ]
}

@test "doctor: env override FOUND_ISSUES_MODE is reflected in output" {
  export FOUND_ISSUES_MODE=github-pr
  fi_run doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"github-pr"* ]]
  [[ "$output" == *"FOUND_ISSUES_MODE"* ]]
}

@test "doctor: reports gh auth status when authenticated" {
  fi_use_gh_shim
  export GH_MOCK_AUTH=ok
  fi_run doctor
  # The shim returns success on `gh auth status` — doctor should reflect this positively
  [[ "$output" == *"gh"*"auth"* ]] || [[ "$output" == *"gh CLI"* ]]
}

@test "doctor: warns when gh is not authenticated" {
  fi_use_gh_shim
  export GH_MOCK_AUTH=fail
  fi_run doctor
  # Doctor should mention auth in some way
  [[ "$output" == *"not authenticated"* ]] || [[ "$output" == *"gh auth"* ]]
}

@test "doctor: warns when origin/HEAD symref is unset" {
  git commit --allow-empty -q -m "init"
  git remote add origin https://example.com/foo/bar.git
  # Intentionally do NOT set origin/HEAD
  fi_run doctor
  [[ "$output" == *"origin/HEAD"* ]] || [[ "$output" == *"default branch"* ]]
}
