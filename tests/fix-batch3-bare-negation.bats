#!/usr/bin/env bats
# Guard: a bare "! cmd" line in the middle of a test asserts nothing (bats runs
# with set -e, which ignores negated pipelines unless it is the last command).
# Every mid-test negated assertion must end with "|| false".

@test "no mid-test bare negated assertion in tests/*.bats" {
  local dir="${BATS_TEST_DIRNAME}" f out="" r
  for f in "$dir"/*.bats; do
    r=$(awk '
      function endtest(   i,last) {
        if (!intest) return
        last = 0
        for (i = n; i >= 1; i--) if (L[i] !~ /^[ \t]*(#.*)?$/) { last = i; break }
        for (i = 1; i <= n; i++) if (C[i] && i != last) print FILENAME ":" S[i] ": " L[i]
        intest = 0; n = 0
      }
      FNR == 1 { endtest() }
      /^@test / { endtest(); intest = 1; n = 0; next }
      intest && /^}/ { endtest(); next }
      intest { n++; L[n] = $0; S[n] = FNR
               C[n] = ($0 ~ /^[ \t]*![ \t]/ && $0 !~ /\|\| false/) }
      END { endtest() }
    ' "$f")
    [ -z "$r" ] || out="$out$r"$'\n'
  done
  if [ -n "$out" ]; then
    echo "bare mid-test negation (append '|| false'):"
    echo "$out"
    false
  fi
}
