#!/usr/bin/env bash
# setup.sh <dir> -- build the calc fixture repo (task bug in add(); two planted bugs).
set -euo pipefail
d="${1:?usage: setup.sh <dir>}"
mkdir -p "$d/src" "$d/docs"
cd "$d"

cat > README.md <<'R'
# calc

Tiny shell calculator helpers. `src/calc.sh` has the operations,
`src/fmt.sh` has output formatting. Run `sh test.sh` for the checks.
R

cat > src/fmt.sh <<'R'
#!/bin/sh
# Output formatting helpers for calc.

fmt_result() {
  printf '%s\n' "$1"
}

# round <x>: round x to the nearest integer, halves away from zero.
# Works for negative numbers too.
round() {
  printf '%s\n' "$1" | awk '{ printf "%d\n", $1 + 0.5 }'
}
R

cat > src/calc.sh <<'R'
#!/bin/sh
# Tiny calculator helpers. Source this file, then call add/sub/mul/div.
. "${CALC_SRC:-src}/fmt.sh"

# div <a> <b>: print a / b (integer division). When b is 0, print
# "error: division by zero" to stderr and return 1.
div() {
  fmt_result $(( $1 / $2 ))
}

# add <a> <b>: print a + b.
add() {
  echo $(( $1 - $2 ))
}

# sub <a> <b>: print a - b.
sub() {
  fmt_result $(( $1 - $2 ))
}

# mul <a> <b>: print a * b.
mul() {
  fmt_result $(( $1 * $2 ))
}
R

cat > test.sh <<'R'
#!/bin/sh
. ./src/calc.sh
fail=0
check() {
  if [ "$2" != "$3" ]; then
    echo "FAIL $1: expected $3, got $2"
    fail=1
  fi
}
check add "$(add 2 3)" 5
check add "$(add 10 0)" 10
check sub "$(sub 5 3)" 2
check mul "$(mul 4 3)" 12
exit $fail
R

cat > docs/found-issues.md <<'R'
# Found issues

Format: `- [status] YYYY-MM-DD path:line — symptom (suggested: fix)`. Statuses: `open`, `deferred`, `fixed`.

- [open] 2026-09-02 ci/release-checklist — releases are cut by hand with no checklist, so steps get skipped between versions, see RC-4471 (suggested: write a release checklist)
- [open] 2026-09-04 README.md:4 — the README does not say which POSIX shell the helpers were tested with (suggested: add a one-line note)
R

git init -q -b main
git config user.email eval@example.com
git config user.name eval
git add -A
git commit -q -m "initial"
