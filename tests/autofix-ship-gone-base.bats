#!/usr/bin/env bats
# 3.4.2 (ledger lib/autofix-ship.sh:179): an item whose landing branch is
# deleted on origin after its claim (the session's branch merged mid-run)
# retargets to the branch it merged into instead of failing every ship.

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_fixture; fi_use_standins
  export GH_MOCK_TRACE="$TMP/gh.trace"
  export GH_MOCK_PR_VIEW=$'7\t{"number":7,"state":"OPEN","statusCheckRollup":[]}'
  # The session works on feat, pushed and tracked: the item lands there.
  git switch -q -c feat
  echo feat > feat.txt && git add feat.txt && git commit -q -m feat
  git push -q -u origin feat
  fi_af_queue_fixture; ST="$FI_AF_ST"
  "$FI_BIN" autofix claim "$ID" >/dev/null
  WT="$REPO/.claude/worktrees/fi-autofix-$ID"
  BR="fi/autofix/src-calc-sh-1-$ID"
  grep -q '^base=feat$' "$ST/running/$ID"
  sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"
  "$FI_BIN" autofix verify "$ID" >/dev/null
}
teardown() { fi_teardown_tmp; }

# feat squash-merges into main on origin and is deleted there.
merge_and_delete_feat() {
  git clone -q "$TMP/remote.git" "$TMP/other"
  (cd "$TMP/other" && git config user.email o@e.com && git config user.name O \
    && git merge -q --squash origin/feat && git commit -q -m 'feat (#1)' \
    && echo later > later.txt && git add later.txt && git commit -q -m later \
    && git push -q origin main && git push -q origin --delete feat)
}

@test "autofix ship: a landing branch merged and deleted mid-run retargets to its merge target" {
  merge_and_delete_feat
  export GH_MOCK_PR_LIST='[{"baseRefName":"main"}]'
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -eq 0 ]
  grep -q "^pr create --repo foo/bar --base main --head $BR" "$GH_MOCK_TRACE"
  # Only the fix commit was replayed, onto origin/main's tip.
  [ "$(git -C "$TMP/remote.git" rev-parse "$BR~2")" = "$(git -C "$TMP/remote.git" rev-parse main)" ]
  git -C "$TMP/remote.git" show "$BR:src/calc.sh" | grep -qF '$(( $1 + $2 ))'
  git -C "$TMP/remote.git" show "$BR:later.txt" >/dev/null
  grep -q '^base=main$' "$ST/done/$ID"
  grep -q 'landing branch feat is gone on origin (merged into main): rebased onto origin/main' "$FI_AF_RUNS/$ID.log"
}

@test "autofix ship: a deleted landing branch with no known merge target fails with the reason and opens no PR" {
  merge_and_delete_feat
  export GH_MOCK_PR_LIST='[]'
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -ne 0 ]
  ! grep -q '^pr create' "$GH_MOCK_TRACE" || false
  [[ "$output" == *"landing branch feat was deleted on origin and its merge target is unknown"* ]]
}

@test "autofix ship: a landing branch that still exists ships into it unchanged" {
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -eq 0 ]
  grep -q "^pr create --repo foo/bar --base feat --head $BR" "$GH_MOCK_TRACE"
  ! grep -q '^pr list .*--state merged' "$GH_MOCK_TRACE" || false
}

# Review of 3.4.2: ls-remote matches by suffix; a branch that only ends in
# the landing branch's name must not hide its deletion.
@test "autofix ship: a deleted landing branch is seen even when another branch ends in its name" {
  merge_and_delete_feat
  git push -q origin HEAD:refs/heads/users/x/feat
  export GH_MOCK_PR_LIST='[{"baseRefName":"main"}]'
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -eq 0 ]
  grep -q "^pr create --repo foo/bar --base main --head $BR" "$GH_MOCK_TRACE"
}

# A retarget re-records the approved tree, so a later ship try of the same
# commits (a sweep's ship retry) still matches it.
@test "autofix ship: a retarget records the rebased tree as the approved one" {
  merge_and_delete_feat
  export GH_MOCK_PR_LIST='[{"baseRefName":"main"}]'
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -eq 0 ]
  [ "$(sed -n 's/^verdict_tree=//p' "$ST/done/$ID")" = "$(git -C "$TMP/remote.git" rev-parse "$BR~1^{tree}")" ]
}

@test "autofix ship: tests that fail after the retarget put the branch back and name the reason" {
  merge_and_delete_feat
  export GH_MOCK_PR_LIST='[{"baseRefName":"main"}]'
  before="$(git -C "$WT" rev-parse HEAD)"
  # Red only once later.txt (main's newer commit) is in the tree.
  git config found-issues.autofix.testCommand '[ ! -f later.txt ]'
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -ne 0 ]
  [[ "$output" == *"tests fail after rebasing onto origin/main"* ]]
  [ "$(git -C "$WT" rev-parse "$BR~1")" = "$before" ]
  ! grep -q '^pr create' "$GH_MOCK_TRACE" || false
}

@test "autofix ship: a fix that is already on the merge target says so and opens no PR" {
  # main gets the same fix through another route before feat is deleted.
  git clone -q "$TMP/remote.git" "$TMP/other"
  (cd "$TMP/other" && git config user.email o@e.com && git config user.name O \
    && git merge -q --squash origin/feat && git commit -q -m 'feat (#1)' \
    && sed -i.bak 's/ - / + /' src/calc.sh && rm -f src/calc.sh.bak \
    && git commit -qam 'same fix' && git push -q origin main && git push -q origin --delete feat)
  export GH_MOCK_PR_LIST='[{"baseRefName":"main"}]'
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the fix is already on main"* ]]
  ! grep -q '^pr create' "$GH_MOCK_TRACE" || false
}

@test "autofix ship: a gh failure looking up the merge target is named as such" {
  merge_and_delete_feat
  mkdir -p "$TMP/ghfail"
  printf '#!/bin/bash\n[[ "$1 $2" == "pr list" ]] && { echo "HTTP 502" >&2; exit 1; }\nexec %q "$@"\n' "$TEST_REPO_ROOT/tests/bin-shims/gh" > "$TMP/ghfail/gh"
  chmod +x "$TMP/ghfail/gh"
  PATH="$TMP/ghfail:$PATH" run "$FI_BIN" autofix ship "$ID"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not look up where landing branch feat merged (gh pr list failed)"* ]]
}
