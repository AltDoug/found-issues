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
