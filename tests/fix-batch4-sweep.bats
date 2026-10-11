#!/usr/bin/env bats
# Ledger batch 4: the sweep chain's skip set lists both sides of a rename and
# the paths of entries dropped for touching it, and the skip check runs
# before the verifier is paid.

load 'helpers'
load 'autofix-helpers'

setup() { fi_setup_tmp; }
teardown() { fi_teardown_tmp; }

sweep_edit() { # the stand-in fixer fixes whichever entry its prompt names, with its own test file
  export FI_STANDIN_EDIT='mkdir -p tests; for f in src/f*.sh; do n="${f#src/f}"; n="${n%.sh}"; case "$FI_STANDIN_PROMPT" in *"src/f$n.sh:1"*) sed -i.bak "s/- 1/+ 0/" "$f"; rm -f "$f.bak"; printf "[ \"\$(f%s 2)\" = 2 ]\n" "$n" >> tests/t_f$n.sh ;; esac; done'
}
gh_mock() {
  export GH_MOCK_TRACE="$TMP/gh.trace" GH_MOCK_PR_CREATE_URL=https://github.com/foo/bar/pull/9
  export GH_MOCK_PR_VIEW=$'9\t{"number":9,"state":"OPEN","statusCheckRollup":[]}'
}
queue_cont() { # a continuation item whose skip_files is "$1"
  source "$FI_BIN"; fi_af_context
  QID=20991231-000000-00007
  fi_af_item_write "$FI_AF_ST/queue/$QID" "id=$QID" kind=sweep "root=$REPO" slug=foo/bar loc=sweep \
    engine=claude "queued=$(date +%Y-%m-%dT%H:%M:%S)" crashes=0 cont=2 "cap_day=$(date +%Y-%m-%d)" \
    "skip_files=$1" base=main
  ST="$FI_AF_ST"
}

@test "batch4 sweep: a rename in a batch puts both the old and the new path in skip_files" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock
  printf 'helper() { :; }\n' > src/helper.sh
  printf -- '- [open] 2026-10-09 src/helper.sh:1 — helper does nothing (fix: medium)\n' >> docs/found-issues.md
  git add -A && git commit -q -m helper && git push -q origin main
  # Fixing f1 also renames src/helper.sh, which no fixed entry cites.
  export FI_STANDIN_EDIT="$FI_STANDIN_EDIT"'; case "$FI_STANDIN_PROMPT" in *"src/f1.sh:1"*) git mv src/helper.sh src/helper2.sh ;; esac'
  git config found-issues.autofix.sweepBatch 2
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  SID="$(printf '%s\n' "$output" | sed -n 's/^AUTOFIX-SWEEP-DUE //p')"
  ST="$FOUND_ISSUES_STATE_DIR/autofix/foo__bar"
  "$FI_BIN" autofix run "$SID" --engine claude
  c="$(grep -l '^cont=2' "$ST"/done/*)"
  skip="$(sed -n 's/^skip_files=//p' "$c")"
  [[ ":$skip:" == *":src/helper2.sh:"* ]]
  [[ ":$skip:" == *":src/helper.sh:"* ]]
}

@test "batch4 sweep: a skipped-for-skip_files entry joins the next batch's skip set" {
  fi_af_sweep_fixture 6; fi_use_standins; sweep_edit; gh_mock
  git config found-issues.autofix.sweepBatch 2
  export FI_STANDIN_EDIT="$FI_STANDIN_EDIT"'; case "$FI_STANDIN_PROMPT" in *"src/f1.sh:1"*) echo "shared" >> shared.txt ;; esac'
  queue_cont shared.txt
  "$FI_BIN" autofix run "$QID" --engine claude
  grep -q "^src/f1.sh:1	skipped	.*	touches shared.txt (file in an earlier batch's PR)$" "$ST/sweeps/$QID.outcomes"
  c="$(grep -l '^cont=3' "$ST"/done/*)"
  skip="$(sed -n 's/^skip_files=//p' "$c")"
  [[ ":$skip:" == *":src/f1.sh:"* ]]
  [[ ":$skip:" == *":shared.txt:"* ]]
}

@test "batch4 sweep run: a skip_files hit is settled before the verifier is paid" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock
  export FI_STANDIN_EDIT="$FI_STANDIN_EDIT"'; case "$FI_STANDIN_PROMPT" in *"src/f2.sh:1"*) echo "shared" >> shared.txt ;; esac'
  queue_cont shared.txt
  "$FI_BIN" autofix run "$QID" --engine claude
  grep -q "^src/f2.sh:1	skipped	.*	touches shared.txt (file in an earlier batch's PR)$" "$ST/sweeps/$QID.outcomes"
  # Three entries were fixed and verified; the skipped one had no verifier call.
  [ "$(grep -c '^claude.*opus' "$FI_STANDIN_TRACE")" = 3 ]
}

@test "batch4 sweep b: verify settles a skip_files hit skipped without calling the verifier" {
  fi_af_sweep_fixture 4; fi_use_standins
  queue_cont shared.txt
  "$FI_BIN" autofix claim "$QID" >/dev/null
  WT="$REPO/.claude/worktrees/fi-sweep-$QID"
  : > "$FI_STANDIN_TRACE"
  loc="$("$FI_BIN" autofix next "$QID" | sed -n 's/^Entry [0-9]*\/[0-9]*: .* \(src\/f[0-9]*\.sh\):1 .*/\1/p')"
  [ -n "$loc" ]
  n="${loc#src/f}"; n="${n%.sh}"
  sed -i.bak 's/- 1/+ 0/' "$WT/$loc"; rm -f "$WT/$loc.bak"
  mkdir -p "$WT/tests"
  printf '[ "$(f%s 2)" = 2 ]\n' "$n" >> "$WT/tests/t_f$n.sh"
  echo shared >> "$WT/shared.txt"
  run "$FI_BIN" autofix verify "$QID"
  [ "$status" -eq 5 ]
  [[ "$output" == *"touches shared.txt (file in an earlier batch's PR)"* ]]
  grep -q "^$loc:1	skipped	" "$ST/sweeps/$QID.outcomes"
  ! grep -q 'opus' "$FI_STANDIN_TRACE" || false
  [ -z "$(git -C "$WT" status --porcelain)" ]
}
