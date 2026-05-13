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
