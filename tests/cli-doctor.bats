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
  # Header should mention the version string. Match "vX.Y.Z" generically
  # instead of hardcoding a major version — this hardcoded "v1." and broke
  # on the v2.0.0 bump; a regex keeps future bumps from re-breaking it.
  [[ "$output" == *"found-issues doctor"* ]]
  [[ "$output" =~ v[0-9]+\.[0-9]+\.[0-9]+ ]]
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

@test "doctor: reports FAIL when issues file has merge conflict markers" {
  cat > .found-issues.md <<'EOF'
- [open] 2026-05-01 a.ts:1 — entry one
<<<<<<< HEAD
- [open] 2026-05-02 b.ts:1 — branch HEAD
=======
- [open] 2026-05-02 b.ts:1 — branch OTHER
>>>>>>> other
EOF
  fi_run doctor
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Source file health"
  echo "$output" | grep -qE "(FAIL|✗).*conflict marker"
}

@test "doctor: reports OK when issues file is clean" {
  cat > .found-issues.md <<'EOF'
- [open] 2026-05-01 a.ts:1 — entry one
- [open] 2026-05-02 b.ts:1 — entry two
EOF
  fi_run doctor
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Source file health"
  echo "$output" | grep -qE "(OK|✓).*Source file"
}

@test "doctor: detects custom statusline path from ~/.claude/settings.json" {
  mkdir -p tmp/.claude
  cat > tmp/.claude/settings.json <<'EOF'
{"statusLine": {"command": "node ${HOME}/custom-statusline.js"}}
EOF
  HOME="$(pwd)/tmp" fi_run doctor
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "statusLine.command"
  echo "$output" | grep -q "custom-statusline.js"
}

@test "doctor: detects v1.4.x broken-posix marker in custom Node target" {
  mkdir -p tmp/.claude
  cat > tmp/custom.js <<'EOF'
#!/usr/bin/env node
// === found-issues plugin segment ===
let __fiSeg = '';
try {
  const path = process.env.HOME + '/.claude';
  const { execSync } = require('child_process');
  execSync('command -v found-issues');
} catch (e) {}
// === end found-issues plugin segment ===
console.log(`repo${__fiSeg}`);  // found-issues:seg
EOF
  cat > tmp/.claude/settings.json <<EOF
{"statusLine": {"command": "node $(pwd)/tmp/custom.js"}}
EOF
  HOME="$(pwd)/tmp" fi_run doctor
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE "(broken-posix|v1.4.x)"
  echo "$output" | grep -qi "migrat"
}

@test "doctor: runtime probe emits OK when integration is healthy" {
  mkdir -p tmp/.claude
  cat > tmp/.found-issues.md <<'EOF'
- [open] 2026-05-13 a.ts:1 — entry
EOF
  cat > tmp/custom.sh <<'EOF'
#!/usr/bin/env bash
input="$(cat)"
dir="$(echo "$input" | jq -r '.workspace.current_dir // ""')"
echo "repo | $dir"
EOF
  chmod +x tmp/custom.sh
  fi_run install-statusline --target tmp/custom.sh --apply
  [ "$status" -eq 0 ]

  cat > tmp/.claude/settings.json <<EOF
{"statusLine": {"command": "bash $(pwd)/tmp/custom.sh"}}
EOF
  HOME="$(pwd)/tmp" fi_run doctor
  echo "$output" | grep -q "Runtime probe"
  echo "$output" | grep -qE "(OK|✓).*[Ss]egment"
}

@test "doctor: runtime probe reports FAIL with splice-gap diagnostic when output branch unpatched" {
  mkdir -p tmp/.claude
  cat > tmp/.found-issues.md <<'EOF'
- [open] 2026-05-13 a.ts:1 — entry
EOF
  cat > tmp/custom.js <<'EOF'
#!/usr/bin/env node
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(0, 'utf8'));
const dir = data.workspace.current_dir;
if (dir) {
  console.log(`A | ${dir}`);
} else {
  console.log(`B | none`);
}
EOF
  fi_run install-statusline --target tmp/custom.js --apply
  [ "$status" -eq 0 ]
  # Remove ONE splice trailer to simulate a gap. Use portable awk (BSD/GNU safe).
  LC_ALL=C awk 'BEGIN{done=0} /\/\/ found-issues:seg/ && !done {sub(/[[:space:]]*\/\/.*found-issues:seg.*/,""); done=1} {print}' \
    tmp/custom.js > tmp/custom.js.tmp && mv tmp/custom.js.tmp tmp/custom.js

  cat > tmp/.claude/settings.json <<EOF
{"statusLine": {"command": "node $(pwd)/tmp/custom.js"}}
EOF
  HOME="$(pwd)/tmp" fi_run doctor
  echo "$output" | grep -qE "splice gap|output statements"
}

@test "doctor-statusline-runtime: standalone subcommand emits only the runtime probe section" {
  mkdir -p tmp/.claude
  cat > tmp/.found-issues.md <<'EOF'
- [open] 2026-05-13 a.ts:1 — entry
EOF
  cat > tmp/custom.sh <<'EOF'
#!/usr/bin/env bash
input="$(cat)"
dir="$(echo "$input" | jq -r '.workspace.current_dir // ""')"
echo "repo | $dir"
EOF
  chmod +x tmp/custom.sh
  fi_run install-statusline --target tmp/custom.sh --apply
  [ "$status" -eq 0 ]
  cat > tmp/.claude/settings.json <<EOF
{"statusLine": {"command": "bash $(pwd)/tmp/custom.sh"}}
EOF

  HOME="$(pwd)/tmp" fi_run doctor-statusline-runtime
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Runtime probe"
  ! echo "$output" | grep -q "Plugin runtime"
  ! echo "$output" | grep -q "Mode detection"
}
