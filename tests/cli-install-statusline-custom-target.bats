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
