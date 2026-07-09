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

@test "install-statusline --target node: migrates v1.5.x block without --cwd (v1.5.6)" {
  # Faithful v1.5.0–v1.5.5 install: modern deferred __fiSeg(dir) block and
  # the REAL template-literal splice the installer emits — but the
  # invocation lacks --cwd, so inherited CLAUDE_PROJECT_DIR overrides the
  # cwd → wrong search root. Must migrate (strip + re-splice), not no-op.
  mkdir -p tmp && cat > tmp/sl.js <<'EOF'
#!/usr/bin/env node
// === found-issues plugin segment ===
let __fiCli = null;
function __fiSeg(dir) {
  if (!__fiCli) return '';
  try {
    const { execFileSync } = require('child_process');
    const cwd = dir || process.env.CLAUDE_PROJECT_DIR || require('os').homedir();
    return execFileSync(__fiCli, ['status', '--format=segment'],
      { cwd, encoding: 'utf8', timeout: 5000 }).trim();
  } catch (e) { return ''; }
}
// === end found-issues plugin segment ===
console.log(`repo | main${__fiSeg(typeof dir!=='undefined'?dir:(typeof cwd!=='undefined'?cwd:undefined))}`);  // found-issues:seg
EOF
  fi_run install-statusline --target tmp/sl.js --apply
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "migrating v1.5.x"
  grep -q -- "--cwd" tmp/sl.js
  # Exactly one splice survives the strip + re-splice round-trip
  [ "$(grep -c 'found-issues:seg' tmp/sl.js)" -eq 1 ]
  # Result must still be valid JS
  if command -v node >/dev/null 2>&1; then
    node --check tmp/sl.js
  fi
  # Second run is a no-op — rewritten block classifies as integrated
  fi_run install-statusline --target tmp/sl.js --apply
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "already integrated"
}

@test "install-statusline --target python: migrates v1.5.x block without --cwd (v1.5.6)" {
  # Faithful v1.5.0–v1.5.5 install with the REAL f-string splice the
  # installer emits. See node twin above for the bug being prevented.
  mkdir -p tmp && cat > tmp/sl.py <<'EOF'
#!/usr/bin/env python3
# === found-issues plugin segment ===
import subprocess as _fi_subprocess
import os as _fi_os
import pathlib as _fi_pathlib
_fi_cli = 'found-issues'
def _fi_seg(_dir=None):
    if not _fi_cli:
        return ''
    try:
        _fi_cwd = _dir or _fi_os.environ.get('CLAUDE_PROJECT_DIR') or str(_fi_pathlib.Path.home())
        return _fi_subprocess.run(
            [_fi_cli, 'status', '--format=segment'],
            cwd=_fi_cwd, capture_output=True, text=True, timeout=5
        ).stdout.strip()
    except Exception:
        return ''
# === end found-issues plugin segment ===
print(f"repo | main{_fi_seg(locals().get("dir") or locals().get("cwd"))}")  # found-issues:seg
EOF
  fi_run install-statusline --target tmp/sl.py --apply
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "migrating v1.5.x"
  grep -q -- "--cwd" tmp/sl.py
  # Exactly one splice survives the strip + re-splice round-trip
  [ "$(grep -c 'found-issues:seg' tmp/sl.py)" -eq 1 ]
  # Result must still be valid Python
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import ast; ast.parse(open('tmp/sl.py').read())"
  fi
  fi_run install-statusline --target tmp/sl.py --apply
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "already integrated"
}

# Faithful v1.5.0–v1.5.5 bash custom-target install: the REAL marker block
# and LINE1 splice the installer emitted — the block cd's into the workspace
# but the status call lacks --cwd, so inherited CLAUDE_PROJECT_DIR overrides
# the cd → wrong search root. Shared by the migration tests below.
fi_write_v15x_bash_target() {
  mkdir -p tmp && cat > tmp/sl.sh <<'EOF'
#!/bin/bash
# === found-issues plugin segment ===
__FI_CLI=""
if command -v found-issues >/dev/null 2>&1; then
  __FI_CLI=found-issues
else
  __FI_CLI=$(ls -d "$HOME"/.claude/plugins/cache/*/found-issues/*/bin/found-issues 2>/dev/null | sort -V | tail -1 || true)
  [[ -x "$__FI_CLI" ]] || __FI_CLI=""
fi
__FI_DIR="${CLAUDE_PROJECT_DIR:-}"
__FI_SEG=""
if [[ -n "$__FI_CLI" ]]; then
  if [[ -n "$__FI_DIR" ]]; then
    __FI_SEG=$( cd "$__FI_DIR" 2>/dev/null && "$__FI_CLI" status --format=segment 2>/dev/null || true )
  else
    __FI_SEG=$("$__FI_CLI" status --format=segment 2>/dev/null || true)
  fi
fi
# === end found-issues plugin segment ===
LINE1="repo | main${__FI_SEG}"  # found-issues:seg
echo "$LINE1"
EOF
}

@test "install-statusline --target bash: migrates v1.5.x block without --cwd (v1.5.7)" {
  # v1.5.6 shipped this migration for node/python only (Known gap: no bash
  # strip support). Must migrate (strip + re-splice), not no-op.
  fi_write_v15x_bash_target
  fi_run install-statusline --target tmp/sl.sh --apply
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "migrating v1.5.x"
  grep -q -- "--cwd" tmp/sl.sh
  # Exactly one splice survives the strip + re-splice round-trip
  [ "$(grep -c 'found-issues:seg' tmp/sl.sh)" -eq 1 ]
  # Result must still be valid bash
  bash -n tmp/sl.sh
  # Second run is a no-op — rewritten block classifies as integrated
  fi_run install-statusline --target tmp/sl.sh --apply
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "already integrated"
}

@test "install-statusline --target bash: v1.5.x migration dry-run leaves target untouched" {
  fi_write_v15x_bash_target
  cp tmp/sl.sh tmp/sl.sh.orig
  fi_run install-statusline --target tmp/sl.sh --dry-run
  [ "$status" -eq 0 ]
  diff -q tmp/sl.sh tmp/sl.sh.orig
  ! ls tmp/sl.sh.fi-bak-* 2>/dev/null
}

@test "install-statusline --target bash: v1.5.x migration backup is the pre-migration original" {
  fi_write_v15x_bash_target
  cp tmp/sl.sh tmp/sl.sh.orig
  fi_run install-statusline --target tmp/sl.sh --apply
  [ "$status" -eq 0 ]
  backup="$(ls tmp/sl.sh.fi-bak-*)"
  diff -q "$backup" tmp/sl.sh.orig
}

@test "install-statusline --target bash: line-1 splice point still gets the marker block (shebang-less file)" {
  # Regression: the splice awk's (NR in splice_set) rule preceded the
  # block-at-top rule, so a shebang-less one-liner got the ${__FI_SEG}
  # splice but never the block defining it — and every re-run appended
  # another splice instead of no-op'ing.
  mkdir -p tmp && printf 'echo "repo | main"\n' > tmp/sl.sh
  fi_run install-statusline --target tmp/sl.sh --apply
  [ "$status" -eq 0 ]
  grep -Fq "# === found-issues plugin segment ===" tmp/sl.sh
  [ "$(grep -c 'found-issues:seg' tmp/sl.sh)" -eq 1 ]
  bash -n tmp/sl.sh
  # Re-run converges to a no-op
  fi_run install-statusline --target tmp/sl.sh --apply
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "already integrated"
  [ "$(grep -c 'found-issues:seg' tmp/sl.sh)" -eq 1 ]
}

@test "install-statusline --target bash: v1.5.x migration of a shebang-less target keeps the marker block" {
  # Migration flavor of the line-1 regression: after the strip, the user's
  # output line IS line 1, so the re-splice must still insert the block.
  mkdir -p tmp && cat > tmp/sl.sh <<'EOF'
# === found-issues plugin segment ===
__FI_CLI=found-issues
__FI_SEG=$("$__FI_CLI" status --format=segment 2>/dev/null || true)
# === end found-issues plugin segment ===
echo "repo | main${__FI_SEG}"  # found-issues:seg
EOF
  fi_run install-statusline --target tmp/sl.sh --apply
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "migrating v1.5.x"
  grep -Fq "# === found-issues plugin segment ===" tmp/sl.sh
  grep -q -- "--cwd" tmp/sl.sh
  [ "$(grep -c 'found-issues:seg' tmp/sl.sh)" -eq 1 ]
  bash -n tmp/sl.sh
  fi_run install-statusline --target tmp/sl.sh --apply
  echo "$output" | grep -q "already integrated"
}

@test "install-statusline --target bash: v1.5.x migration strips unbraced \$__FI_SEG splice (no double segment)" {
  # Regression: the strip only removed the exact literal ${__FI_SEG}, so a
  # hand-edited unbraced reference survived and the re-splice doubled the
  # rendered counter.
  fi_write_v15x_bash_target
  # Hand-edited splice line: unbraced reference, trailer intact.
  sed -e 's/${__FI_SEG}/$__FI_SEG/' tmp/sl.sh > tmp/sl.sh.new && mv tmp/sl.sh.new tmp/sl.sh
  fi_run install-statusline --target tmp/sl.sh --apply
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "migrating v1.5.x"
  # The single splice line references the segment exactly once.
  [ "$(grep 'found-issues:seg' tmp/sl.sh | grep -o '__FI_SEG' | wc -l | tr -d ' ')" -eq 1 ]
  bash -n tmp/sl.sh
}

@test "install-statusline --target python: v1.5.x migration strips hand-edited f-string seg variant (no corruption)" {
  # Python sibling of the bash unbraced case: a hand-edited seg call (e.g.
  # single quotes) escapes the exact-literal strip, and the re-splice then
  # inserts at the first '")' on the line — mid-expression — producing a
  # SyntaxError. The variant gsub must remove it first.
  mkdir -p tmp && cat > tmp/sl.py <<'EOF'
#!/usr/bin/env python3
# === found-issues plugin segment ===
import subprocess as _fi_subprocess
import os as _fi_os
_fi_cli = 'found-issues'
def _fi_seg(_dir=None):
    try:
        return _fi_subprocess.run([_fi_cli, 'status', '--format=segment'], capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return ''
# === end found-issues plugin segment ===
print(f"repo | main{_fi_seg(locals().get('dir') or locals().get('cwd'))}")  # found-issues:seg
EOF
  fi_run install-statusline --target tmp/sl.py --apply
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "migrating v1.5.x"
  [ "$(grep -c 'found-issues:seg' tmp/sl.py)" -eq 1 ]
  [ "$(grep 'found-issues:seg' tmp/sl.py | grep -o '_fi_seg' | wc -l | tr -d ' ')" -eq 1 ]
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import ast; ast.parse(open('tmp/sl.py').read())"
  fi
}

@test "install-statusline --target node: v1.5.x migration strips hand-edited template seg variant (no double splice)" {
  mkdir -p tmp && cat > tmp/sl.js <<'EOF'
#!/usr/bin/env node
// === found-issues plugin segment ===
let __fiCli = null;
function __fiSeg(dir) {
  if (!__fiCli) return '';
  try {
    const { execFileSync } = require('child_process');
    const cwd = dir || process.env.CLAUDE_PROJECT_DIR || require('os').homedir();
    return execFileSync(__fiCli, ['status', '--format=segment'], { cwd, encoding: 'utf8', timeout: 5000 }).trim();
  } catch (e) { return ''; }
}
// === end found-issues plugin segment ===
console.log(`repo | main${__fiSeg(dir)}`);  // found-issues:seg
EOF
  fi_run install-statusline --target tmp/sl.js --apply
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "migrating v1.5.x"
  [ "$(grep -c 'found-issues:seg' tmp/sl.js)" -eq 1 ]
  [ "$(grep 'found-issues:seg' tmp/sl.js | grep -o '__fiSeg' | wc -l | tr -d ' ')" -eq 1 ]
  if command -v node >/dev/null 2>&1; then
    node --check tmp/sl.js
  fi
}

@test "install-statusline --target bash: v1.5.x migration preserves user-authored \${__FI_SEG} lines" {
  # Regression: the strip ran on every non-block line, deleting segment
  # references the user hand-added outside the trailer-tagged splice line.
  fi_write_v15x_bash_target
  printf 'echo "custom prefix ${__FI_SEG}"\n' >> tmp/sl.sh
  fi_run install-statusline --target tmp/sl.sh --apply
  [ "$status" -eq 0 ]
  grep -Fq 'echo "custom prefix ${__FI_SEG}"' tmp/sl.sh
}

@test "install-statusline --target node: v1.5.x migration dry-run leaves target untouched" {
  # Regression: the strip used to run in place BEFORE the mode check, so a
  # dry-run destroyed the existing marker block with no backup.
  mkdir -p tmp && cat > tmp/sl.js <<'EOF'
#!/usr/bin/env node
// === found-issues plugin segment ===
let __fiCli = null;
function __fiSeg(dir) {
  if (!__fiCli) return '';
  try {
    const { execFileSync } = require('child_process');
    const cwd = dir || process.env.CLAUDE_PROJECT_DIR || require('os').homedir();
    return execFileSync(__fiCli, ['status', '--format=segment'],
      { cwd, encoding: 'utf8', timeout: 5000 }).trim();
  } catch (e) { return ''; }
}
// === end found-issues plugin segment ===
console.log(`repo | main${__fiSeg(typeof dir!=='undefined'?dir:(typeof cwd!=='undefined'?cwd:undefined))}`);  // found-issues:seg
EOF
  cp tmp/sl.js tmp/sl.js.orig
  fi_run install-statusline --target tmp/sl.js --dry-run
  [ "$status" -eq 0 ]
  diff -q tmp/sl.js tmp/sl.js.orig
  ! ls tmp/sl.js.fi-bak-* 2>/dev/null
}

@test "install-statusline --target python: v1.5.x migration dry-run leaves target untouched" {
  # Same regression as the node twin above, python handler.
  mkdir -p tmp && cat > tmp/sl.py <<'EOF'
#!/usr/bin/env python3
# === found-issues plugin segment ===
import subprocess as _fi_subprocess
import os as _fi_os
import pathlib as _fi_pathlib
_fi_cli = 'found-issues'
def _fi_seg(_dir=None):
    if not _fi_cli:
        return ''
    try:
        _fi_cwd = _dir or _fi_os.environ.get('CLAUDE_PROJECT_DIR') or str(_fi_pathlib.Path.home())
        return _fi_subprocess.run(
            [_fi_cli, 'status', '--format=segment'],
            cwd=_fi_cwd, capture_output=True, text=True, timeout=5
        ).stdout.strip()
    except Exception:
        return ''
# === end found-issues plugin segment ===
print(f"repo | main{_fi_seg(locals().get("dir") or locals().get("cwd"))}")  # found-issues:seg
EOF
  cp tmp/sl.py tmp/sl.py.orig
  fi_run install-statusline --target tmp/sl.py --dry-run
  [ "$status" -eq 0 ]
  diff -q tmp/sl.py tmp/sl.py.orig
  ! ls tmp/sl.py.fi-bak-* 2>/dev/null
}

@test "install-statusline --target node: v1.4.x migration dry-run leaves target untouched" {
  # The v1.4.x branch is a separate copy of the scratch-copy migration flow;
  # pin it independently of the v1.5.x twin so future edits can't diverge it
  # back to an in-place strip.
  mkdir -p tmp && cat > tmp/sl.js <<'EOF'
#!/usr/bin/env node
// === found-issues plugin segment ===
let __fiSeg = '';
try {
  const { execSync } = require('child_process');
  const cacheGlob = process.env.HOME + '/.claude/plugins/cache';
} catch (e) {}
// === end found-issues plugin segment ===
console.log(`repo | main${__fiSeg}`);  // found-issues:seg
EOF
  cp tmp/sl.js tmp/sl.js.orig
  fi_run install-statusline --target tmp/sl.js --dry-run
  [ "$status" -eq 0 ]
  diff -q tmp/sl.js tmp/sl.js.orig
  ! ls tmp/sl.js.fi-bak-* 2>/dev/null
}

@test "install-statusline --target python: v1.4.x migration dry-run leaves target untouched" {
  mkdir -p tmp && cat > tmp/sl.py <<'EOF'
#!/usr/bin/env python3
# === found-issues plugin segment ===
import subprocess as _fi_subprocess
import os as _fi_os
_fi_seg = ''
try:
    _fi_cwd = _fi_os.environ.get('CLAUDE_PROJECT_DIR') or _fi_os.environ.get('HOME', '.')
except Exception:
    _fi_seg = ''
# === end found-issues plugin segment ===
print(f"repo | main{_fi_seg}")  # found-issues:seg
EOF
  cp tmp/sl.py tmp/sl.py.orig
  fi_run install-statusline --target tmp/sl.py --dry-run
  [ "$status" -eq 0 ]
  diff -q tmp/sl.py tmp/sl.py.orig
  ! ls tmp/sl.py.fi-bak-* 2>/dev/null
}

# =====================================================================
# Group 5 — Runtime end-to-end
# Verifies that the generated shim, after install-statusline --apply,
# actually emits the segment in real conditions: piped Claude Code stdin,
# real binary, real .found-issues.md file.
#
# .found-issues.md lives at $(pwd) (the test tmpdir root) so that:
#   - bash shim (no cwd from stdin at block-run time) finds it via CWD
#   - node/python shims receive $(pwd) as workspace.current_dir and find
#     it directly; the $(pwd)/tmp variant in out_b walks up one level and
#     still finds it — both paths exercise fi_find_issues_file.
# =====================================================================

@test "runtime e2e (node): single-branch statusline emits segment" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi

  # FOUND_ISSUES_BIN: cross-platform override so the shim's binary discovery
  # resolves on ALL platforms without relying on PATH (which node shims don't
  # use on Windows) or the plugin cache (which doesn't exist on bare CI runners).
  export FOUND_ISSUES_BIN="${TEST_REPO_ROOT}/bin/found-issues"
  # Also prepend repo bin/ for POSIX (command -v path, harmless elsewhere).
  PATH="${TEST_REPO_ROOT}/bin:$PATH"

  # Dynamic date: a hardcoded one goes stale after 30 days, relabeling the
  # segment from "1 issue" to "1 other · 1 stale" and breaking the greps.
  cat > .found-issues.md <<EOF
- [open] $(date +%Y-%m-%d) a.ts:1 — synthetic test entry
EOF
  mkdir -p tmp
  cat > tmp/sl.js <<'EOF'
#!/usr/bin/env node
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(0, 'utf8'));
const dir = data.workspace.current_dir;
console.log(`repo | ${dir}`);
EOF

  fi_run install-statusline --target tmp/sl.js --apply
  [ "$status" -eq 0 ]

  local sl_output
  sl_output="$(fi_synthetic_stdin "$(pwd)" | node tmp/sl.js 2>/dev/null)"

  echo "$sl_output" | grep -qE ' \| .*issue'
}

@test "runtime e2e (node): multi-branch statusline emits segment in both branches" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi

  # FOUND_ISSUES_BIN: cross-platform override so the shim's binary discovery
  # resolves on ALL platforms without relying on PATH (which node shims don't
  # use on Windows) or the plugin cache (which doesn't exist on bare CI runners).
  export FOUND_ISSUES_BIN="${TEST_REPO_ROOT}/bin/found-issues"
  # Also prepend repo bin/ for POSIX (command -v path, harmless elsewhere).
  PATH="${TEST_REPO_ROOT}/bin:$PATH"

  # Dynamic date: a hardcoded one goes stale after 30 days, relabeling the
  # segment from "1 issue" to "1 other · 1 stale" and breaking the greps.
  cat > .found-issues.md <<EOF
- [open] $(date +%Y-%m-%d) a.ts:1 — synthetic test entry
EOF
  mkdir -p tmp
  cat > tmp/sl.js <<'EOF'
#!/usr/bin/env node
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(0, 'utf8'));
const dir = data.workspace.current_dir;
if (data.session_id) {
  console.log(`branch-A | ${dir}`);
} else {
  console.log(`branch-B | ${dir}`);
}
EOF

  fi_run install-statusline --target tmp/sl.js --apply
  [ "$status" -eq 0 ]

  local out_a
  out_a="$(fi_synthetic_stdin "$(pwd)" | node tmp/sl.js 2>/dev/null)"
  echo "$out_a" | grep -q "branch-A"
  echo "$out_a" | grep -qE ' \| .*issue'

  local out_b
  out_b="$(printf '{"workspace":{"current_dir":"%s"}}' "$(pwd)/tmp" | node tmp/sl.js 2>/dev/null)"
  echo "$out_b" | grep -q "branch-B"
  echo "$out_b" | grep -qE ' \| .*issue'
}

@test "runtime e2e (python): single-branch statusline emits segment" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 not available"; fi

  # FOUND_ISSUES_BIN: cross-platform override so the shim's binary discovery
  # resolves on ALL platforms without relying on PATH (which python shims don't
  # use on Windows) or the plugin cache (which doesn't exist on bare CI runners).
  export FOUND_ISSUES_BIN="${TEST_REPO_ROOT}/bin/found-issues"
  # Force Python UTF-8 I/O on Windows. Without this, Windows Python uses the
  # system console code page for pipes; when that is UTF-16, each byte of ANSI
  # escape sequences is followed by a null byte, which bash command substitution
  # strips (with a warning), leaving a garbled string that fails the grep.
  # PYTHONUTF8 (Python 3.7+) + PYTHONIOENCODING (older fallback) + -X utf8 flag.
  export PYTHONUTF8=1
  export PYTHONIOENCODING=utf-8
  # Also prepend repo bin/ for POSIX (shutil.which path, harmless elsewhere).
  PATH="${TEST_REPO_ROOT}/bin:$PATH"

  # Dynamic date: a hardcoded one goes stale after 30 days, relabeling the
  # segment from "1 issue" to "1 other · 1 stale" and breaking the greps.
  cat > .found-issues.md <<EOF
- [open] $(date +%Y-%m-%d) a.ts:1 — synthetic test entry
EOF
  mkdir -p tmp
  cat > tmp/sl.py <<'EOF'
#!/usr/bin/env python3
import json, sys
data = json.loads(sys.stdin.read() or '{}')
dir = data.get('workspace', {}).get('current_dir', '/tmp')
print(f"repo | {dir}")
EOF

  fi_run install-statusline --target tmp/sl.py --apply
  [ "$status" -eq 0 ]

  local sl_output
  # Pipe through tr -d '\000' to strip any null bytes that Windows Python may
  # output when the console code page uses a wide encoding (e.g. UTF-16).
  sl_output="$(fi_synthetic_stdin "$(pwd)" | python3 -X utf8 tmp/sl.py 2>/dev/null | tr -d '\000')"
  echo "$sl_output" | grep -qE ' \| .*issue'
}

@test "runtime e2e (python): multi-branch statusline emits segment in both branches" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 not available"; fi

  # FOUND_ISSUES_BIN: cross-platform override so the shim's binary discovery
  # resolves on ALL platforms without relying on PATH (which python shims don't
  # use on Windows) or the plugin cache (which doesn't exist on bare CI runners).
  export FOUND_ISSUES_BIN="${TEST_REPO_ROOT}/bin/found-issues"
  # Force Python UTF-8 I/O on Windows (see single-branch test for full rationale).
  export PYTHONUTF8=1
  export PYTHONIOENCODING=utf-8
  # Also prepend repo bin/ for POSIX (shutil.which path, harmless elsewhere).
  PATH="${TEST_REPO_ROOT}/bin:$PATH"

  # Dynamic date: a hardcoded one goes stale after 30 days, relabeling the
  # segment from "1 issue" to "1 other · 1 stale" and breaking the greps.
  cat > .found-issues.md <<EOF
- [open] $(date +%Y-%m-%d) a.ts:1 — synthetic test entry
EOF
  mkdir -p tmp
  cat > tmp/sl.py <<'EOF'
#!/usr/bin/env python3
import json, sys
data = json.loads(sys.stdin.read() or '{}')
dir = data.get('workspace', {}).get('current_dir', '/tmp')
if data.get('session_id'):
    print(f"branch-A | {dir}")
else:
    print(f"branch-B | {dir}")
EOF

  fi_run install-statusline --target tmp/sl.py --apply
  [ "$status" -eq 0 ]

  local out_a
  # Pipe through tr -d '\000' to strip any null bytes from Windows Python output.
  out_a="$(fi_synthetic_stdin "$(pwd)" | python3 -X utf8 tmp/sl.py 2>/dev/null | tr -d '\000')"
  echo "$out_a" | grep -q "branch-A"
  echo "$out_a" | grep -qE ' \| .*issue'

  local out_b
  out_b="$(printf '{"workspace":{"current_dir":"%s"}}' "$(pwd)/tmp" | python3 -X utf8 tmp/sl.py 2>/dev/null | tr -d '\000')"
  echo "$out_b" | grep -q "branch-B"
  echo "$out_b" | grep -qE ' \| .*issue'
}

@test "runtime e2e (bash): multi-branch statusline emits segment in both branches" {
  # FOUND_ISSUES_BIN: cross-platform override (consistent with node/python tests above).
  export FOUND_ISSUES_BIN="${TEST_REPO_ROOT}/bin/found-issues"
  # Also prepend repo bin/ so the bash shim's `command -v found-issues` resolves on POSIX CI.
  PATH="${TEST_REPO_ROOT}/bin:$PATH"

  mkdir -p tmp
  # Dynamic date: a hardcoded one goes stale after 30 days, relabeling the
  # segment from "1 issue" to "1 other · 1 stale" and breaking the greps.
  cat > .found-issues.md <<EOF
- [open] $(date +%Y-%m-%d) a.ts:1 — synthetic test entry
EOF
  cat > tmp/sl.sh <<'EOF'
#!/usr/bin/env bash
input="$(cat)"
dir="$(echo "$input" | jq -r '.workspace.current_dir // ""')"
if [[ -n "$dir" ]]; then
  echo "branch-A | $dir"
else
  echo "branch-B | none"
fi
EOF
  chmod +x tmp/sl.sh

  fi_run install-statusline --target tmp/sl.sh --apply
  [ "$status" -eq 0 ]

  local out_a
  out_a="$(fi_synthetic_stdin "$(pwd)" | bash tmp/sl.sh 2>/dev/null)"
  echo "$out_a" | grep -q "branch-A"
  echo "$out_a" | grep -qE ' \| .*issue'

  local out_b
  out_b="$(printf '{}' | bash tmp/sl.sh 2>/dev/null)"
  echo "$out_b" | grep -q "branch-B"
  echo "$out_b" | grep -qE ' \| .*issue'
}

