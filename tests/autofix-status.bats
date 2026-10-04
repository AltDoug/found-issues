#!/usr/bin/env bats
# autofix status: queue, running, caps, decisions, recent results with PR
# links and cost (spec §8).

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_fixture; fi_use_standins; fi_af_queue_fixture
  ST="$FI_AF_ST"
  export GH_MOCK_TRACE="$TMP/gh.trace"
}
teardown() { fi_teardown_tmp; }

@test "autofix status: a shipped run shows its PR link and cost" {
  export GH_MOCK_PR_VIEW=$'7\t{"number":7,"state":"OPEN","statusCheckRollup":[]}'
  export FI_STANDIN_EDIT="sed -i.bak 's/ - / + /' src/calc.sh && rm -f src/calc.sh.bak"
  "$FI_BIN" autofix run "$ID" --engine claude >/dev/null
  run "$FI_BIN" autofix status
  [[ "$output" == *"https://github.com/foo/bar/pull/7"* ]]
  [[ "$output" == *'($0.5000)'* ]]
  [[ "$output" == *"Spent today: \$"* ]]
}

@test "autofix status: finished items carry a finished stamp" {
  "$FI_BIN" autofix cancel "$ID" >/dev/null
  grep -qE '^finished=[0-9]+$' "$ST/done/$ID"
}

@test "autofix status: running items show the launcher" {
  "$FI_BIN" autofix claim "$ID" >/dev/null
  run "$FI_BIN" autofix status
  [[ "$output" == *"Running (1)"* ]]
  [[ "$output" == *"launcher B"* ]]
}

@test "autofix status: decisions waiting are counted from the ledger" {
  printf -- '- [open] 2026-10-02 src/calc.sh:1 — which rounding? (decide: floor or round?)\n' >> docs/found-issues.md
  run "$FI_BIN" autofix status
  [[ "$output" == *"Decisions waiting: 1"* ]]
}

@test "autofix status: recent results are newest first and at most five" {
  for i in 1 2 3 4 5 6; do
    printf 'id=x%s\nkind=spot\nloc=src/a.sh:%s\nresult=stale: t\nfinished=%s\n' "$i" "$i" "$((1000 - i))" > "$ST/done/x$i"
  done
  # finished order is the reverse of id order: x1 is the newest
  run "$FI_BIN" autofix status
  [[ "$output" == *"src/a.sh:1 "*"src/a.sh:5 "* ]]
  [[ "$output" != *"src/a.sh:6 "* ]]
}

@test "fi_count_decide: counts open entries with a decide tag only" {
  printf '# f\n\n- [open] 2026-10-01 a.sh:1 — q (decide: x?)\n- [fixed] 2026-10-01 b.sh:1 — q (decide: y?)\n- [open] 2026-10-01 c.sh:1 — mentions decide: in text\n' > l.md
  [ "$(fi_count_decide l.md)" = 1 ]   # the CLI was sourced by setup
}

@test "autofix status: spend reads as dollars and cents with nothing finished" {
  run "$FI_BIN" autofix status
  [[ "$output" == *'Spent today: $0.00 '* ]]
}
