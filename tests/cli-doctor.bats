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

@test "doctor: runtime probe emits no arithmetic noise when grep counts are zero" {
  mkdir -p tmp/.claude
  cat > tmp/.found-issues.md <<'EOF'
- [open] 2026-05-13 a.ts:1 — entry
EOF
  # Statusline with NO output statements and NO seg markers: both grep -c
  # probes find nothing (print 0 AND exit 1), and the script renders nothing
  # so the probe takes the FAIL path into sub-probe (b).
  cat > tmp/custom.sh <<'EOF'
#!/usr/bin/env bash
input="$(cat)"
: "$input"
EOF
  chmod +x tmp/custom.sh
  cat > tmp/.claude/settings.json <<EOF
{"statusLine": {"command": "bash $(pwd)/tmp/custom.sh"}}
EOF
  HOME="$(pwd)/tmp" fi_run doctor
  doctor_output="$output"
  echo "$doctor_output" | grep -q "did NOT render"
  run grep -q "syntax error" <<<"$doctor_output"
  [ "$status" -ne 0 ]
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

# === stale-CLI detection (#135) ===
#
# Claude Code injects a VERSION-PINNED plugin bin dir into the environment at
# session start, so a session started before a release keeps resolving the old
# version indefinitely (installed_plugins.json installPath=2.2.2 while $PATH
# still had .../found-issues/2.2.0/bin). Two concurrent sessions ran 2.2.0 for
# hours after v2.2.1 shipped a data-loss fix, including 2.2.0's SessionStart
# auto-sync. Doctor printed a bare "CLI: <path>" and reported healthy — it is
# the one command whose entire job is catching this class.
#
# The version dirs accumulate rather than prune, which is why a stale path
# resolves quietly instead of failing loudly.

# Write a fake plugin manifest under tmp/.claude. $1 = installPath, $2 = version.
_fi_fake_plugin_manifest() {
  mkdir -p tmp/.claude/plugins "$1/.claude-plugin"
  cat > tmp/.claude/plugins/installed_plugins.json <<EOF
{"plugins":{"found-issues@altdoug-plugins":[{"scope":"user","installPath":"$1","version":"$2"}]}}
EOF
  cat > "$1/.claude-plugin/plugin.json" <<EOF
{"name":"found-issues","version":"$2"}
EOF
}

# The running CLI's own version, so fixtures never hardcode a release number.
_fi_running_version() {
  "$FI_BIN" --version | sed -E 's/.*version //'
}

@test "doctor: reports plugin version match when running CLI equals installed plugin" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  local ver
  ver="$(_fi_running_version)"
  _fi_fake_plugin_manifest "$(pwd)/tmp/.claude/plugins/cache/altdoug-plugins/found-issues/$ver" "$ver"

  HOME="$(pwd)/tmp" fi_run doctor
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "matches the installed plugin"
  ! echo "$output" | grep -q "does not match"
}

@test "doctor: warns to restart the session when a stale plugin bin dir is resolved" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  # Run a COPY of this checkout's bin+lib from inside the fake plugin cache,
  # so the resolved CLI really does live at a version-pinned cache path. bin
  # and lib come from the same checkout: an old bin against a fixed lib is a
  # false negative (hazard 2 of the v2.2.1 session).
  local stale_dir="$(pwd)/tmp/.claude/plugins/cache/altdoug-plugins/found-issues/0.0.1"
  mkdir -p "$stale_dir/bin" "$stale_dir/lib"
  cp "$FI_BIN" "$stale_dir/bin/found-issues"
  cp "$FI_LIB_DIR"/*.sh "$stale_dir/lib/"
  chmod +x "$stale_dir/bin/found-issues"
  _fi_fake_plugin_manifest "$(pwd)/tmp/.claude/plugins/cache/altdoug-plugins/found-issues/9.9.9" "9.9.9"

  HOME="$(pwd)/tmp" FOUND_ISSUES_LIB_DIR="$stale_dir/lib" run "$stale_dir/bin/found-issues" doctor
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "does not match the installed plugin"
  echo "$output" | grep -q "9.9.9"
  echo "$output" | grep -q "restart your session"
}

@test "doctor: does not tell a dev checkout to restart its session" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  _fi_fake_plugin_manifest "$(pwd)/tmp/.claude/plugins/cache/altdoug-plugins/found-issues/9.9.9" "9.9.9"

  HOME="$(pwd)/tmp" fi_run doctor
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "does not match the installed plugin"
  ! echo "$output" | grep -q "restart your session"
  echo "$output" | grep -q "outside the plugin cache"
}

@test "doctor: stays quiet about plugin version when no plugin manifest exists" {
  # CI and any non-plugin install have no ~/.claude/plugins. The check must
  # skip silently rather than reporting a bogus mismatch on all three OSes.
  mkdir -p tmp/.claude

  HOME="$(pwd)/tmp" fi_run doctor
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "does not match the installed plugin"
  ! echo "$output" | grep -q "matches the installed plugin"
}
