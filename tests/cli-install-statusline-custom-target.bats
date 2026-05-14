#!/usr/bin/env bats
# Tests for `found-issues install-statusline --target <path>`
# (custom-statusline auto-integration; canonical-path tests live in cli-statusline.bats)

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

@test "install-statusline --target: errors when path does not exist" {
  fi_run install-statusline --target /nonexistent/path.sh --dry-run
  [ "$status" -eq 12 ]  # target_not_found
  [[ "$output" == *"not found"* || "$output" == *"does not exist"* ]]
}

@test "install-statusline --target: detects bash from .sh extension" {
  mkdir -p tmp && cat > tmp/sl.sh <<'EOF'
#!/bin/bash
echo "hello"
EOF
  fi_run install-statusline --target tmp/sl.sh --dry-run
  # At this point, language=bash is detected but splice is not yet implemented.
  # We expect exit 11 (splice_point_not_found) OR the eventual exit 0 — but NOT
  # exit 10 (unsupported_language), which would mean detection failed.
  [ "$status" -ne 10 ]
}

@test "install-statusline --target: detects bash from #!/usr/bin/env bash shebang" {
  mkdir -p tmp && cat > tmp/sl <<'EOF'
#!/usr/bin/env bash
echo "hello"
EOF
  chmod +x tmp/sl
  fi_run install-statusline --target tmp/sl --dry-run
  [ "$status" -ne 10 ]
}

@test "install-statusline --target: rejects unknown language" {
  mkdir -p tmp && cat > tmp/sl.exotic <<'EOF'
some weird script
EOF
  fi_run install-statusline --target tmp/sl.exotic --dry-run
  [ "$status" -eq 10 ]  # unsupported_language
}

@test "install-statusline --target bash: finds LINE1= as splice point (priority 1)" {
  mkdir -p tmp && cat > tmp/sl.sh <<'EOF'
#!/bin/bash
REPO=$(basename "$PWD")
BRANCH=$(git branch --show-current 2>/dev/null)
LINE1="$REPO | $BRANCH"
echo "$LINE1"
EOF
  fi_run install-statusline --target tmp/sl.sh --dry-run
  [ "$status" -eq 0 ]
  # Dry-run output should contain a diff that modifies the LINE1= line
  [[ "$output" == *"LINE1="* ]]
  [[ "$output" == *"__FI_SEG"* ]]
}

@test "install-statusline --target bash: falls back to first echo when no LINE1 (priority 2)" {
  mkdir -p tmp && cat > tmp/sl.sh <<'EOF'
#!/bin/bash
echo "static line"
EOF
  fi_run install-statusline --target tmp/sl.sh --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"echo"* ]]
  [[ "$output" == *"__FI_SEG"* ]]
}

@test "install-statusline --target bash: exits 11 when no splice point found" {
  mkdir -p tmp && cat > tmp/sl.sh <<'EOF'
#!/bin/bash
# nothing here that prints
exit 0
EOF
  fi_run install-statusline --target tmp/sl.sh --dry-run
  [ "$status" -eq 11 ]
}

@test "install-statusline --target bash --apply: writes backup at expected path" {
  mkdir -p tmp && cat > tmp/sl.sh <<'EOF'
#!/bin/bash
LINE1="$REPO | $BRANCH"
echo "$LINE1"
EOF
  fi_run install-statusline --target tmp/sl.sh --apply
  [ "$status" -eq 0 ]
  # Backup file should exist at tmp/sl.sh.fi-bak-<ts>
  ls tmp/sl.sh.fi-bak-* >/dev/null 2>&1
}

@test "install-statusline --target bash --apply: target file contains marker + seg reference" {
  mkdir -p tmp && cat > tmp/sl.sh <<'EOF'
#!/bin/bash
LINE1="$REPO | $BRANCH"
echo "$LINE1"
EOF
  fi_run install-statusline --target tmp/sl.sh --apply
  [ "$status" -eq 0 ]
  grep -Fq "# === found-issues plugin segment ===" tmp/sl.sh
  grep -Fq "__FI_SEG" tmp/sl.sh
  grep -Fq "# found-issues:seg" tmp/sl.sh
}

@test "install-statusline --target bash --apply: idempotent re-apply" {
  mkdir -p tmp && cat > tmp/sl.sh <<'EOF'
#!/bin/bash
LINE1="$REPO | $BRANCH"
echo "$LINE1"
EOF
  fi_run install-statusline --target tmp/sl.sh --apply
  [ "$status" -eq 0 ]
  # Second --apply should be a no-op (already_installed)
  fi_run install-statusline --target tmp/sl.sh --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"already integrated"* ]]
  # Should NOT have inserted two marker blocks
  local count
  count="$(grep -cF "# === found-issues plugin segment ===" tmp/sl.sh)"
  [ "$count" -eq 1 ]
}

@test "uninstall-statusline --target bash: removes marker block + seg reference cleanly" {
  mkdir -p tmp && cat > tmp/sl.sh <<'EOF'
#!/bin/bash
LINE1="$REPO | $BRANCH"
echo "$LINE1"
EOF
  local original_content
  original_content="$(cat tmp/sl.sh)"
  fi_run install-statusline --target tmp/sl.sh --apply
  [ "$status" -eq 0 ]
  fi_run uninstall-statusline --target tmp/sl.sh
  [ "$status" -eq 0 ]
  # File should be byte-equal to the original
  local restored_content
  restored_content="$(cat tmp/sl.sh)"
  [ "$original_content" = "$restored_content" ]
}

@test "uninstall-statusline --target bash: exits 17 when invocation present but markers stripped" {
  mkdir -p tmp && cat > tmp/sl.sh <<'EOF'
#!/bin/bash
__FI_SEG=$(found-issues status --format=segment 2>/dev/null || true)
LINE1="$REPO | $BRANCH${__FI_SEG}"
echo "$LINE1"
EOF
  fi_run uninstall-statusline --target tmp/sl.sh
  [ "$status" -eq 17 ]  # markers_missing_but_invocation_present
}

@test "uninstall-statusline --target bash: no-op when never installed" {
  mkdir -p tmp && cat > tmp/sl.sh <<'EOF'
#!/bin/bash
echo "vanilla statusline"
EOF
  fi_run uninstall-statusline --target tmp/sl.sh
  [ "$status" -eq 0 ]
}

@test "install-statusline --target bash --apply: patches every echo in multi-branch statusline" {
  mkdir -p tmp && cat > tmp/sl.sh <<'EOF'
#!/usr/bin/env bash
input="$(cat)"
dir="$(echo "$input" | jq -r '.workspace.current_dir // ""')"
if [[ -n "$dir" ]]; then
  echo "A | $dir"
else
  echo "B | none"
fi
EOF
  fi_run install-statusline --target tmp/sl.sh --apply
  [ "$status" -eq 0 ]
  local seg_count
  seg_count="$(grep -c 'found-issues:seg' tmp/sl.sh)"
  [ "$seg_count" = "2" ]
}

@test "install-statusline --target: detects node from .js extension" {
  mkdir -p tmp && cat > tmp/sl.js <<'EOF'
#!/usr/bin/env node
console.log(`repo | main`);
EOF
  fi_run install-statusline --target tmp/sl.js --dry-run
  [ "$status" -ne 10 ]
}

@test "install-statusline --target: detects node from #!/usr/bin/env node shebang" {
  mkdir -p tmp && cat > tmp/sl <<'EOF'
#!/usr/bin/env node
console.log(`repo | main`);
EOF
  chmod +x tmp/sl
  fi_run install-statusline --target tmp/sl --dry-run
  [ "$status" -ne 10 ]
}

@test "install-statusline --target node: finds console.log template literal (priority 1)" {
  mkdir -p tmp && cat > tmp/sl.js <<'EOF'
#!/usr/bin/env node
const repo = 'r';
const branch = 'b';
console.log(`${repo} | ${branch}`);
EOF
  fi_run install-statusline --target tmp/sl.js --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"console.log"* ]]
  [[ "$output" == *"__fiSeg"* ]]
}

@test "install-statusline --target node: finds console.log plain string (priority 2)" {
  mkdir -p tmp && cat > tmp/sl.js <<'EOF'
#!/usr/bin/env node
console.log("static line");
EOF
  fi_run install-statusline --target tmp/sl.js --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"__fiSeg"* ]]
}

@test "install-statusline --target node: exits 11 when no console.log/process.stdout.write" {
  mkdir -p tmp && cat > tmp/sl.js <<'EOF'
#!/usr/bin/env node
// just a comment, no output
process.exit(0);
EOF
  fi_run install-statusline --target tmp/sl.js --dry-run
  [ "$status" -eq 11 ]
}

@test "install-statusline --target node --apply: writes backup + modifies target" {
  mkdir -p tmp && cat > tmp/sl.js <<'EOF'
#!/usr/bin/env node
console.log(`repo | main`);
EOF
  fi_run install-statusline --target tmp/sl.js --apply
  [ "$status" -eq 0 ]
  ls tmp/sl.js.fi-bak-* >/dev/null 2>&1
  grep -Fq "// === found-issues plugin segment ===" tmp/sl.js
  grep -Fq "__fiSeg" tmp/sl.js
  grep -Fq "// found-issues:seg" tmp/sl.js
}

@test "install-statusline --target node --apply: produces a script that parses without error" {
  mkdir -p tmp && cat > tmp/sl.js <<'EOF'
#!/usr/bin/env node
console.log(`repo | main`);
EOF
  fi_run install-statusline --target tmp/sl.js --apply
  [ "$status" -eq 0 ]
  # Syntax-check the modified script if node is available
  if command -v node >/dev/null 2>&1; then
    node --check tmp/sl.js
  else
    skip "node not available; cannot syntax-check"
  fi
}

@test "uninstall-statusline --target node: byte-equal restore" {
  mkdir -p tmp && cat > tmp/sl.js <<'EOF'
#!/usr/bin/env node
console.log(`repo | main`);
EOF
  local original
  original="$(cat tmp/sl.js)"
  fi_run install-statusline --target tmp/sl.js --apply
  [ "$status" -eq 0 ]
  fi_run uninstall-statusline --target tmp/sl.js
  [ "$status" -eq 0 ]
  [ "$original" = "$(cat tmp/sl.js)" ]
}

@test "install-statusline --target: detects python from .py extension" {
  mkdir -p tmp && cat > tmp/sl.py <<'EOF'
#!/usr/bin/env python3
print(f"repo | main")
EOF
  fi_run install-statusline --target tmp/sl.py --dry-run
  [ "$status" -ne 10 ]
}

@test "install-statusline --target python: finds print f-string (priority 1)" {
  mkdir -p tmp && cat > tmp/sl.py <<'EOF'
#!/usr/bin/env python3
import os
repo = "r"
print(f"{repo} | main")
EOF
  fi_run install-statusline --target tmp/sl.py --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"_fi_seg"* ]]
}

@test "install-statusline --target python: finds print plain string (priority 2)" {
  mkdir -p tmp && cat > tmp/sl.py <<'EOF'
#!/usr/bin/env python3
print("static line")
EOF
  fi_run install-statusline --target tmp/sl.py --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"_fi_seg"* ]]
}

@test "install-statusline --target python: exits 11 when no print/sys.stdout.write" {
  mkdir -p tmp && cat > tmp/sl.py <<'EOF'
#!/usr/bin/env python3
import sys
sys.exit(0)
EOF
  fi_run install-statusline --target tmp/sl.py --dry-run
  [ "$status" -eq 11 ]
}

@test "install-statusline --target python --apply: produces script that parses without error" {
  mkdir -p tmp && cat > tmp/sl.py <<'EOF'
#!/usr/bin/env python3
print(f"repo | main")
EOF
  fi_run install-statusline --target tmp/sl.py --apply
  [ "$status" -eq 0 ]
  if command -v python3 >/dev/null 2>&1; then
    python3 -m py_compile tmp/sl.py
  else
    skip "python3 not available; cannot syntax-check"
  fi
}

@test "uninstall-statusline --target python: byte-equal restore" {
  mkdir -p tmp && cat > tmp/sl.py <<'EOF'
#!/usr/bin/env python3
print(f"repo | main")
EOF
  local original
  original="$(cat tmp/sl.py)"
  fi_run install-statusline --target tmp/sl.py --apply
  [ "$status" -eq 0 ]
  fi_run uninstall-statusline --target tmp/sl.py
  [ "$status" -eq 0 ]
  [ "$original" = "$(cat tmp/sl.py)" ]
}

@test "install-statusline --target node: marker block uses os.homedir not process.env.HOME" {
  mkdir -p tmp && cat > tmp/sl.js <<'EOF'
#!/usr/bin/env node
console.log(`repo | main`);
EOF
  fi_run install-statusline --target tmp/sl.js --apply
  [ "$status" -eq 0 ]
  # New shim: no process.env.HOME; uses os.homedir.
  ! grep -q "process.env.HOME" tmp/sl.js
  grep -q "os.homedir" tmp/sl.js
  # Platform-gated: shim has process.platform check.
  grep -q "process.platform" tmp/sl.js
  # __fiSeg is now a function, not a value.
  grep -q "function __fiSeg" tmp/sl.js
}

@test "install-statusline --target node: shim parses + binary resolution executes without throwing" {
  mkdir -p tmp && cat > tmp/sl.js <<'EOF'
#!/usr/bin/env node
console.log(`repo | main`);
EOF
  fi_run install-statusline --target tmp/sl.js --apply
  [ "$status" -eq 0 ]
  if command -v node >/dev/null 2>&1; then
    node --check tmp/sl.js
  else
    skip "node not available"
  fi
}

@test "install-statusline --target node --apply: patches every console.log in multi-branch statusline" {
  mkdir -p tmp && cat > tmp/sl.js <<'EOF'
#!/usr/bin/env node
const data = { workspace: { current_dir: '/tmp/x' } };
const dir = data.workspace.current_dir;
if (dir) {
  console.log(`A | ${dir}`);
} else {
  console.log(`B | none`);
}
EOF
  fi_run install-statusline --target tmp/sl.js --apply
  [ "$status" -eq 0 ]
  local seg_count
  seg_count="$(grep -c 'found-issues:seg' tmp/sl.js)"
  [ "$seg_count" = "2" ]
}

@test "install-statusline --target python --apply: patches every print in multi-branch statusline" {
  mkdir -p tmp && cat > tmp/sl.py <<'EOF'
#!/usr/bin/env python3
import json, sys
data = json.loads(sys.stdin.read() or '{}')
dir = data.get('workspace', {}).get('current_dir', '/tmp/x')
if dir:
    print(f"A | {dir}")
else:
    print(f"B | none")
EOF
  fi_run install-statusline --target tmp/sl.py --apply
  [ "$status" -eq 0 ]
  local seg_count
  seg_count="$(grep -c 'found-issues:seg' tmp/sl.py)"
  [ "$seg_count" = "2" ]
}

@test "install-statusline --target python: marker block uses pathlib.Path.home not HOME env" {
  mkdir -p tmp && cat > tmp/sl.py <<'EOF'
#!/usr/bin/env python3
print(f"repo | main")
EOF
  fi_run install-statusline --target tmp/sl.py --apply
  [ "$status" -eq 0 ]
  ! grep -q "environ.get('HOME'" tmp/sl.py
  grep -q "pathlib" tmp/sl.py
  grep -q "platform.system" tmp/sl.py
  grep -q "def _fi_seg" tmp/sl.py
}

@test "install-statusline --target python: shim parses without error" {
  mkdir -p tmp && cat > tmp/sl.py <<'EOF'
#!/usr/bin/env python3
print(f"repo | main")
EOF
  fi_run install-statusline --target tmp/sl.py --apply
  [ "$status" -eq 0 ]
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import ast; ast.parse(open('tmp/sl.py').read())"
  else
    skip "python3 not available"
  fi
}

@test "install-statusline --target node: detects v1.4.x POSIX-only marker block as broken" {
  mkdir -p tmp && cat > tmp/sl.js <<'EOF'
#!/usr/bin/env node
// === found-issues plugin segment ===
// PATH-resilience: try `found-issues` on PATH, fall back to plugin cache glob.
let __fiSeg = '';
try {
  const { execSync } = require('child_process');
  let __fiCli = 'found-issues';
  try { execSync('command -v found-issues', { stdio: 'ignore' }); }
  catch (e) {
    const cacheGlob = process.env.HOME + '/.claude/plugins/cache';
    // ... rest of v1.4.x form
  }
} catch (e) {}
// === end found-issues plugin segment ===
console.log(`repo | main${__fiSeg}`);  // found-issues:seg
EOF
  fi_run install-statusline --target tmp/sl.js --apply
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "migrating v1.4.x"
  ! grep -q "process.env.HOME" tmp/sl.js
  grep -q "os.homedir" tmp/sl.js
  ls tmp/sl.js.fi-bak-* >/dev/null 2>&1
}

@test "install-statusline --target python: detects v1.4.x POSIX-only marker block as broken" {
  mkdir -p tmp && cat > tmp/sl.py <<'EOF'
#!/usr/bin/env python3
# === found-issues plugin segment ===
import subprocess as _fi_subprocess
import shutil as _fi_shutil
import os as _fi_os
_fi_seg = ''
try:
    _fi_cli = _fi_shutil.which('found-issues')
    if _fi_cli:
        _fi_cwd = _fi_os.environ.get('CLAUDE_PROJECT_DIR') or _fi_os.environ.get('HOME', '.')
        _fi_seg = _fi_subprocess.run([_fi_cli, 'status', '--format=segment'], cwd=_fi_cwd, capture_output=True, text=True, timeout=5).stdout.strip()
except Exception:
    _fi_seg = ''
# === end found-issues plugin segment ===
print(f"repo | main{_fi_seg}")  # found-issues:seg
EOF
  fi_run install-statusline --target tmp/sl.py --apply
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "migrating v1.4.x"
  ! grep -q "environ.get('HOME'" tmp/sl.py
  grep -q "pathlib" tmp/sl.py
}
