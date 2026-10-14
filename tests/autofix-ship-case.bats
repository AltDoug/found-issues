#!/usr/bin/env bats
# 3.10.1 (#164): auto-fix ship against a ledger spelled Docs/Found-Issues.md.

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_fixture; fi_use_standins
  mkdir -p Docs && git mv docs/found-issues.md Docs/Found-Issues.md
  git commit -qm "recase ledger" && git push -q origin main
  export GH_MOCK_TRACE="$TMP/gh.trace"
  export GH_MOCK_PR_VIEW=$'7\t{"number":7,"state":"OPEN","statusCheckRollup":[]}'
  source "$FI_BIN"
  fi_af_context
  fi_af_queue_spot "$(grep -m1 '^- \[open\]' Docs/Found-Issues.md)" >/dev/null
  ST="$FI_AF_ST"
  ID="$(ls "$ST/queue" | head -1)"
  "$FI_BIN" autofix claim "$ID" >/dev/null
  WT="$REPO/.claude/worktrees/fi-autofix-$ID"
  BR="fi/autofix/src-calc-sh-1-$ID"
}
teardown() { fi_teardown_tmp; }

fix_it() { sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"; "$FI_BIN" autofix verify "$ID" >/dev/null; }

@test "autofix ship: the PR branch annotation lands in a recased Docs/Found-Issues.md (#164)" {
  fix_it
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #7"* ]]
  git -C "$TMP/remote.git" show "$BR:Docs/Found-Issues.md" | grep -q 'add subtracts (fix: small) (PR: foo/bar#7)$'
  # no second, lowercase ledger was created on the PR branch
  ! git -C "$TMP/remote.git" cat-file -e "$BR:docs/found-issues.md" 2>/dev/null || false
}
