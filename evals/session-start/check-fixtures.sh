#!/usr/bin/env bash
# check-fixtures.sh -- offline sanity check of the three eval fixtures (no claude, no cost).
#
# For each fixture, in a throwaway copy:
#   1. test.sh FAILS before the task fix;
#   2. the planted.txt lines hold the expected defect text;
#   3. after a manual task fix test.sh PASSES, with the planted bugs still
#      unfixed and still on the same lines (a task edit must not shift them).
# Prints the commands' output so it can be pasted as evidence. Exit 1 on any miss.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp:?}"' EXIT
fail=0

say() { printf '%s\n' "$*"; }
ok()  { say "  ok   $*"; }
bad() { say "  FAIL $*"; fail=1; }

# expect_line <repo> <path:line> <fixed-string>
expect_line() {
  local repo="$1" loc="$2" want="$3" p n got
  p="${loc%:*}"; n="${loc##*:}"
  got="$(sed -n "${n}p" "$repo/$p")"
  if [[ "$got" == *"$want"* ]]; then ok "$loc holds: $got"; else bad "$loc expected '$want', got '$got'"; fi
}

check() {  # <fixture> <planted-needle-1> <planted-needle-2> <fix-function>
  local fx="$1" n1="$2" n2="$3" fix="$4" repo="$tmp/$1" l1 l2
  say "== $fx"
  bash "$HERE/fixtures/$fx/setup.sh" "$repo" >/dev/null || { bad "setup"; return; }
  l1="$(sed -n 1p "$HERE/fixtures/$fx/planted.txt")"
  l2="$(sed -n 2p "$HERE/fixtures/$fx/planted.txt")"
  say " before the fix:"
  expect_line "$repo" "$l1" "$n1"
  expect_line "$repo" "$l2" "$n2"
  if (cd "$repo" && sh test.sh >/dev/null 2>&1); then bad "test.sh passed BEFORE the fix"; else ok "test.sh fails before the fix (exit $(cd "$repo" && sh test.sh >/dev/null 2>&1; echo $?))"; fi
  "$fix" "$repo"
  say " after the manual task fix:"
  if (cd "$repo" && sh test.sh >/dev/null 2>&1); then ok "test.sh passes after the fix (exit 0)"; else bad "test.sh still fails after the fix"; fi
  expect_line "$repo" "$l1" "$n1"
  expect_line "$repo" "$l2" "$n2"
}

fix_calc()   { sed -i.bak 's/echo \$(( \$1 - \$2 ))/fmt_result $(( $1 + $2 ))/' "$1/src/calc.sh" && rm -f "$1/src/calc.sh.bak"; }
fix_queue()  { python3 -I - "$1/src/queue.js" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("  pop() {\n    const item = this.items.shift();", "  pop() {\n    const item = this.items.pop();")
open(p, "w").write(s)
EOF
}
fix_parser() { python3 -I - "$1/src/parse.py" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("from datetime import datetime, timezone", "from datetime import datetime, timedelta, timezone")
s = s.replace("    return naive.replace(tzinfo=timezone.utc)",
              "    sign = -1 if offset.startswith('-') else 1\n"
              "    delta = timedelta(hours=int(offset[1:3]), minutes=int(offset[3:5]))\n"
              "    return (naive - sign * delta).replace(tzinfo=timezone.utc)")
open(p, "w").write(s)
EOF
}

check calc   'fmt_result $(( $1 / $2 ))'          'awk '"'"'{ printf "%d\n", $1 + 0.5 }'"'"'' fix_calc
check parser 'except:'                            'def collect(item, acc=[]):'               fix_parser
check queue  'return this.items[this.items.length];' 'fs.promises.writeFile(file, JSON.stringify(items));' fix_queue

if (( fail )); then say "FIXTURE CHECK FAILED"; exit 1; fi
say "FIXTURE CHECK OK"
