#!/usr/bin/env bats
# Small ledger-entry fixes that have no better home: help layout.

load 'helpers'

setup() { fi_setup_tmp; fi_init_git; }
teardown() { fi_teardown_tmp; }

@test "help: every autofix line starts its description in the same column" {
  fi_run help
  [ "$status" -eq 0 ]
  cols="$(printf '%s\n' "$output" | grep '^  autofix ' | awk 'match($0, /[^ ] {2,}[^ ]/) { print RSTART + RLENGTH - 1 }' | sort -u)"
  [ "$(printf '%s\n' "$cols" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "capture_mode: a stat -f that succeeds with garbage falls through to the GNU form" {
  fi_source_lib statusline-core
  mkdir -p fakebin
  cat > fakebin/stat <<'SH'
#!/bin/sh
case "$1" in
  -f) printf '  File: "x"\n    ID: 1 Namelen: 255\n'; exit 0 ;;
  -c) printf '640\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x fakebin/stat
  : > target
  PATH="$PWD/fakebin:$PATH"
  [ "$(fi_capture_mode target)" = "640" ]
}

@test "capture_mode: falls back to 755 when neither stat form gives an octal mode" {
  fi_source_lib statusline-core
  mkdir -p fakebin
  printf '#!/bin/sh\nprintf "garbage\\n"\nexit 0\n' > fakebin/stat
  chmod +x fakebin/stat
  : > target
  PATH="$PWD/fakebin:$PATH"
  [ "$(fi_capture_mode target)" = "755" ]
}
