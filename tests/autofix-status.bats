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

@test "autofix status: a sweep continuation shows its batch number" {
  QID=20991231-000000-00009
  fi_af_item_write "$ST/queue/$QID" "id=$QID" kind=sweep "root=$REPO" slug=foo/bar loc=sweep \
    engine=claude "queued=$(date +%Y-%m-%dT%H:%M:%S)" crashes=0 cont=3
  DID=20991231-000000-00008
  fi_af_item_write "$ST/done/$DID" "id=$DID" kind=sweep "root=$REPO" slug=foo/bar loc=sweep \
    cont=2 finished=1 "result=stale: sweep fixed nothing"
  run "$FI_BIN" autofix status
  [[ "$output" == *"$QID  sweep  sweep (batch 3)"* ]]
  [[ "$output" == *"$DID  sweep (batch 2) — stale"* ]]
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

@test "autofix status: a waiting queued item shows why it waits" {
  fi_af_item_set "$QITEM" waiting "src/calc.sh busy in $PWD"
  run "$FI_BIN" autofix status
  [[ "$output" == *"waiting: src/calc.sh busy in $PWD"* ]]
}

@test "autofix status: a running item shows its landing branch and why" {
  "$FI_BIN" autofix claim "$ID" >/dev/null
  fi_af_item_set "$ST/running/$ID" base "release/3.2"
  fi_af_item_set "$ST/running/$ID" base_why "the branch with the cited file"
  run "$FI_BIN" autofix status
  [[ "$output" == *"into release/3.2 (the branch with the cited file)"* ]]
}

@test "autofix status: a recent row shows the landing branch and why" {
  printf 'id=r1\nkind=spot\nloc=src/a.sh:1\nresult=fixed: t\nfinished=1000\nbase=release/3.2\nbase_why=the branch with the cited file\n' > "$ST/done/r1"
  printf 'id=r2\nkind=spot\nloc=src/b.sh:2\nresult=stale: t\nfinished=900\n' > "$ST/done/r2"
  run "$FI_BIN" autofix status
  [[ "$output" == *"into release/3.2 (the branch with the cited file)"* ]]
  [ "$(printf '%s\n' "$output" | grep -c 'into release/3.2')" = 1 ]
}

@test "autofix status: a codex run shows tokens against its cap" {
  export GH_MOCK_PR_VIEW=$'7\t{"number":7,"state":"OPEN","statusCheckRollup":[]}'
  export FI_STANDIN_EDIT="sed -i.bak 's/ - / + /' src/calc.sh && rm -f src/calc.sh.bak"
  git config found-issues.autofix.codexRunTokens 600000
  "$FI_BIN" autofix run "$ID" --engine codex >/dev/null
  run "$FI_BIN" autofix status
  [[ "$output" == *"3000/600000 tokens"* ]]
}

@test "autofix status: a codex run with no token cap shows its tokens alone" {
  export GH_MOCK_PR_VIEW=$'7\t{"number":7,"state":"OPEN","statusCheckRollup":[]}'
  export FI_STANDIN_EDIT="sed -i.bak 's/ - / + /' src/calc.sh && rm -f src/calc.sh.bak"
  "$FI_BIN" autofix run "$ID" --engine codex >/dev/null
  run "$FI_BIN" autofix status
  [[ "$output" == *" 3000 tokens"* ]]
  [[ "$output" != *"3000/"* ]]
}

@test "autofix status: a continuation's tokens row shows the whole chain against the sweep cap" {
  git config found-issues.autofix.codexSweepTokens 2400000
  printf 'id=c1\nkind=sweep\nloc=sweep\nengine=codex\ncont=3\ntokens=50000\nchain_tokens=2300000\nfinished=1000\nresult=shipped: PR #5, 8 fixed\n' > "$ST/done/c1"
  run "$FI_BIN" autofix status
  echo "$output" | grep -Fq '2350000/2400000 tokens (chain)'
  git config --unset found-issues.autofix.codexSweepTokens
  run "$FI_BIN" autofix status
  echo "$output" | grep -Fq '2350000 tokens (chain)'
  ! echo "$output" | grep -q '2350000/' || false
  # A first batch has no chain: its own tokens, unmarked.
  printf 'id=c0\nkind=sweep\nloc=sweep\nengine=codex\ntokens=70000\nfinished=900\nresult=shipped: PR #4, 8 fixed\n' > "$ST/done/c0"
  run "$FI_BIN" autofix status
  echo "$output" | grep -Eq '^ +70000 tokens$'
}
