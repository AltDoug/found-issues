#!/usr/bin/env bats
# v3 auto-fix ship (spec §5 step 6, audit prompt-9).

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_fixture; fi_use_standins
  export GH_MOCK_TRACE="$TMP/gh.trace"
  export GH_MOCK_PR_VIEW=$'7\t{"number":7,"state":"OPEN","statusCheckRollup":[]}'
  fi_af_queue_fixture; ST="$FI_AF_ST"
  "$FI_BIN" autofix claim "$ID" >/dev/null
  WT="$REPO/.claude/worktrees/fi-autofix-$ID"
  BR="fi/autofix/src-calc-sh-1-$ID"
}
teardown() { fi_teardown_tmp; }

# ship only takes a verifier-approved tree (phase 3), so fixing includes verify.
fix_it() { sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"; "$FI_BIN" autofix verify "$ID" >/dev/null; }

@test "autofix ship: commits the fix, pushes, opens the PR, arms auto-merge" {
  fix_it
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #7"* ]]
  git -C "$TMP/remote.git" rev-parse --verify -q "refs/heads/$BR"
  msg="$(git -C "$TMP/remote.git" log -1 --format=%s "$BR~1")"
  [ "$msg" = "fix: add subtracts (found-issues src/calc.sh:1)" ]
  grep -q '^pr create --repo foo/bar --base main --head '"$BR" "$GH_MOCK_TRACE"
  grep -q '^pr merge 7 --auto --squash --repo foo/bar$' "$GH_MOCK_TRACE"
}

@test "autofix ship: a PR landing on the checkout's own branch annotates only the PR branch ledger" {
  fix_it
  [ "$(git branch --show-current)" = main ]
  "$FI_BIN" autofix ship "$ID"
  git -C "$TMP/remote.git" show "$BR:docs/found-issues.md" | grep -q 'add subtracts (fix: small) (PR: foo/bar#7)$'
  ! grep -q '(PR: foo/bar#7)' "$REPO/docs/found-issues.md" || false
  [ -z "$(git -C "$REPO" status --porcelain -- docs/found-issues.md)" ]
  grep -rq 'source ledger annotation skipped for src/calc.sh:1' "$FI_AF_RUNS"
}

@test "autofix ship: a PR landing on the checkout's own branch records the entry as in flight" {
  fix_it
  "$FI_BIN" autofix ship "$ID"
  [ "$(ls "$ST/inflight" | wc -l | tr -d ' ')" = 1 ]
  f="$ST/inflight/$(ls "$ST/inflight")"
  grep -q '^key=' "$f"
  grep -qx 'pr=7' "$f"
  grep -Eq '^ts=[0-9]+$' "$f"
}

@test "autofix ship: an entry in flight is not eligible again and a sweep skips it" {
  fix_it
  "$FI_BIN" autofix ship "$ID"
  entry="$(grep -m1 '^- \[open\]' docs/found-issues.md)"
  fi_af_context   # setup already sourced the CLI
  fi_entry_dedup_key_v "$entry" "$REPO"
  AFI_root="$REPO" AFI_key="$FI_KEY"
  rc=0; fi_af_eligible || rc=$?
  [ "$rc" -eq 1 ]
  [ "$FI_AF_WHY" = "fix in flight in PR #7" ]
  [ -z "$(fi_af_sweep_candidates docs/found-issues.md "$REPO" 10)" ]
  # a later log of the same entry does not queue a second spot fix
  rm -f "$ST"/queue/* "$ST"/running/*
  fi_af_queue_spot "$entry" >/dev/null
  [ -z "$(ls -A "$ST/queue")" ]
  [ -z "$(ls -A "$ST/running")" ]
}

@test "autofix ship: an in-flight record older than 14 days does not block" {
  fix_it
  "$FI_BIN" autofix ship "$ID"
  f="$ST/inflight/$(ls "$ST/inflight")"
  old=$(( $(date +%s) - 15 * 86400 ))
  sed -i.bak "s/^ts=.*/ts=$old/" "$f"; rm -f "$f.bak"
  entry="$(grep -m1 '^- \[open\]' docs/found-issues.md)"
  fi_af_context   # setup already sourced the CLI
  fi_entry_dedup_key_v "$entry" "$REPO"
  AFI_root="$REPO" AFI_key="$FI_KEY"
  fi_af_eligible
  [ -n "$(fi_af_sweep_candidates docs/found-issues.md "$REPO" 10)" ]
}

@test "autofix ship: a PR landing on another branch than the checkout's annotates both ledgers" {
  fix_it
  git switch -q -c elsewhere
  "$FI_BIN" autofix ship "$ID"
  git -C "$TMP/remote.git" show "$BR:docs/found-issues.md" | grep -q 'add subtracts (fix: small) (PR: foo/bar#7)$'
  grep -q 'add subtracts (fix: small) (PR: foo/bar#7)$' "$REPO/docs/found-issues.md"
}

@test "autofix ship: an entry that origin never saw annotates only the source ledger" {
  printf -- '- [open] 2026-10-02 src/calc.sh:1 — add ignores negatives (fix: small)\n' >> "$REPO/docs/found-issues.md"
  fi_af_context   # setup already sourced the CLI (a second source hits its readonly vars)
  fi_af_queue_spot "$(grep 'ignores negatives' docs/found-issues.md)" >/dev/null
  id2="$(ls "$ST/queue" | head -1)"
  "$FI_BIN" autofix release "$ID" --manual "test reshuffle" >/dev/null
  "$FI_BIN" autofix claim "$id2" >/dev/null
  wt2="$REPO/.claude/worktrees/fi-autofix-$id2"
  sed -i.bak 's/ - / + /' "$wt2/src/calc.sh"; rm -f "$wt2/src/calc.sh.bak"
  "$FI_BIN" autofix verify "$id2" >/dev/null
  run "$FI_BIN" autofix ship "$id2"
  [ "$status" -eq 0 ]
  br2="$(git -C "$TMP/remote.git" for-each-ref --format='%(refname:short)' "refs/heads/fi/autofix/*$id2")"
  [ "$(git -C "$TMP/remote.git" rev-list --count "main..$br2")" = 1 ]
  grep -q 'add ignores negatives (fix: small) (PR: foo/bar#7)$' "$REPO/docs/found-issues.md"
  # same file:line, different entry: left alone on both sides
  ! grep -q 'add subtracts .*(PR: foo/bar#7)' "$REPO/docs/found-issues.md" || false
  ! git -C "$TMP/remote.git" show "$br2:docs/found-issues.md" | grep -q '(PR: foo/bar#7)' || false
}

@test "autofix ship: ledger edits made in the worktree never reach the fix commit" {
  fix_it
  printf -- '- [open] 2026-10-03 junk.sh — child sync noise\n' >> "$WT/docs/found-issues.md"
  "$FI_BIN" autofix diff "$ID" > "$TMP/diff"
  ! grep -q 'child sync noise' "$TMP/diff" || false
  grep -qF '+add() { echo $(( $1 + $2 )); }' "$TMP/diff"
  "$FI_BIN" autofix ship "$ID"
  ! git -C "$TMP/remote.git" show "$BR~1" -- docs/found-issues.md | grep -q 'child sync noise' || false
  ! git -C "$TMP/remote.git" show "$BR:docs/found-issues.md" | grep -q 'child sync noise' || false
}

@test "autofix ship: red tests refuse to ship and push nothing" {
  fix_it
  sed -i.bak 's/ + / - /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"   # broken again after approval
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tests fail"* ]]
  ! git -C "$TMP/remote.git" rev-parse --verify -q "refs/heads/$BR" || false
  [ ! -s "$GH_MOCK_TRACE" ] || ! grep -q 'pr create' "$GH_MOCK_TRACE"
}

@test "autofix ship: auto-merge refused falls back to merge-when-green, which merges a check-less PR" {
  fix_it
  export GH_MOCK_PR_MERGE=fail FOUND_ISSUES_AUTOFIX_MERGE_SLEEP=0
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"merge-when-green"* ]]
  # the detached watcher inherited GH_MOCK_PR_MERGE=fail, so its merge call
  # exits 1 — the trace line proves it saw a check-less PR and tried to merge
  for _ in $(seq 1 40); do grep -q '^pr merge 7 --squash --repo foo/bar$' "$GH_MOCK_TRACE" && break; sleep 0.25; done
  grep -q '^pr merge 7 --squash --repo foo/bar$' "$GH_MOCK_TRACE"
}

@test "autofix merge-when-green: waits on pending, merges on green, refuses red" {
  export FOUND_ISSUES_AUTOFIX_MERGE_SLEEP=0 FOUND_ISSUES_AUTOFIX_MERGE_POLLS=2
  export GH_MOCK_PR_VIEW=$'7\t{"state":"OPEN","statusCheckRollup":[{"conclusion":"","status":"IN_PROGRESS"}]}'
  run "$FI_BIN" autofix merge-when-green 7
  [ "$status" -eq 1 ]
  [[ "$output" == *"still pending"* ]]
  export GH_MOCK_PR_VIEW=$'7\t{"state":"OPEN","statusCheckRollup":[{"conclusion":"FAILURE"}]}'
  run "$FI_BIN" autofix merge-when-green 7
  [ "$status" -eq 1 ]
  [[ "$output" == *"checks failed"* ]]
  export GH_MOCK_PR_VIEW=$'7\t{"state":"OPEN","statusCheckRollup":[{"conclusion":"SUCCESS"},{"state":"SUCCESS"}]}'
  run "$FI_BIN" autofix merge-when-green 7
  [ "$status" -eq 0 ]
  grep -q '^pr merge 7 --squash --repo foo/bar$' "$GH_MOCK_TRACE"
  export GH_MOCK_PR_VIEW=$'7\t{"state":"MERGED","statusCheckRollup":[]}'
  run "$FI_BIN" autofix merge-when-green 7
  [ "$status" -eq 0 ]
}

@test "autofix ship: a ledger the fixer deleted is restored, never shipped as a deletion" {
  fix_it
  rm "$WT/docs/found-issues.md"
  "$FI_BIN" autofix diff "$ID" > "$TMP/diff"
  ! grep -q 'deleted file' "$TMP/diff" || false
  "$FI_BIN" autofix ship "$ID"
  ! git -C "$TMP/remote.git" show --stat "$BR~1" | grep -q 'found-issues.md' || false
  git -C "$TMP/remote.git" show "$BR:docs/found-issues.md" | grep -q 'add subtracts'
}

@test "autofix ship: origin moving mid-run does not leak upstream changes into the diff" {
  fix_it
  git clone -q "$TMP/remote.git" "$TMP/other"
  (cd "$TMP/other" && git config user.email o@e.com && git config user.name O && echo up > upstream.txt && git add upstream.txt && git commit -qm up && git push -q origin main)
  git -C "$REPO" fetch -q origin
  "$FI_BIN" autofix diff "$ID" > "$TMP/diff"
  ! grep -q 'upstream.txt' "$TMP/diff" || false
  grep -qF '+add() { echo $(( $1 + $2 )); }' "$TMP/diff"
}

# kh2-midgar on Git for Windows, 2026-10-10: the fixer rewrote an untouched
# LF test block with CRLF and the verifier rejected an otherwise good fix.
@test "autofix diff: CRLF the fixer put into an LF file is stripped before tests and verify" {
  fix_it
  printf '%s\r\n' "$(cat "$WT/src/calc.sh")" > "$WT/src/calc.sh"
  awk '{ printf "%s\r\n", $0 }' "$WT/test.sh" > "$WT/test.sh.crlf" && cat "$WT/test.sh.crlf" > "$WT/test.sh" && rm "$WT/test.sh.crlf"
  grep -q $'\r' "$WT/test.sh"
  "$FI_BIN" autofix diff "$ID" > "$TMP/diff"
  ! grep -q $'\r' "$TMP/diff" || false
  ! grep -q 'test.sh' "$TMP/diff" || false
  grep -qF '+add() { echo $(( $1 + $2 )); }' "$TMP/diff"
  ! grep -q $'\r' "$WT/src/calc.sh" "$WT/test.sh" || false
}

@test "autofix diff: CRLF is kept in files that had it at base, and binary files are untouched" {
  printf 'a\r\nb\r\n' > crlf.txt
  printf 'x\000y\n' > blob.bin
  printf '#!/bin/sh\necho hi\n' > run.sh; chmod +x run.sh
  git add crlf.txt blob.bin run.sh && git commit -qm fixtures
  base="$(git rev-parse HEAD)"
  printf 'a\r\nc\r\n' > crlf.txt
  printf 'x\000z\r\n' > blob.bin
  printf '#!/bin/sh\r\necho bye\r\n' > run.sh
  fi_af_diff "$REPO" "$base" > "$TMP/diff"
  [ "$(od -An -c crlf.txt | tr -d ' \n')" = 'a\r\nc\r\n' ]
  [ "$(od -An -c blob.bin | tr -d ' \n')" = 'x\0z\r\n' ]
  [ "$(cat run.sh)" = $'#!/bin/sh\necho bye' ]
  [ -x run.sh ]
}

@test "autofix diff: a checkout git converts to CRLF itself keeps its CRLF" {
  printf 'one\n' > win.txt; printf 'two\n' > attr.txt
  printf 'attr.txt eol=crlf\n' > .gitattributes
  git add win.txt attr.txt .gitattributes && git commit -qm fixtures
  base="$(git rev-parse HEAD)"
  printf 'uno\r\n' > attr.txt
  fi_af_diff "$REPO" "$base" > /dev/null
  [ "$(od -An -c attr.txt | tr -d ' \n')" = 'uno\r\n' ]
  git config core.autocrlf true
  printf 'eins\r\n' > win.txt
  fi_af_diff "$REPO" "$base" > /dev/null
  [ "$(od -An -c win.txt | tr -d ' \n')" = 'eins\r\n' ]
}

# 3.6.0: agent-config #572, #576 and #592 were closed as duplicates of PRs an
# interactive session opened (or merged) for the same entries.
@test "autofix ship: an entry another open PR already fixes is retired stale, not shipped" {
  fix_it
  export GH_MOCK_PR_LIST='[{"number":571,"headRefName":"feat/wanda"},{"number":9,"headRefName":"fi/autofix/x"}]'
  export GH_MOCK_PR_DIFF='+- [open] 2026-10-01 src/calc.sh:1 — add subtracts (fix: small) (PR: foo/bar#571)'
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Not shipped"*"fix in flight in PR #571"* ]]
  grep -q '^result=stale: fix in flight in PR #571$' "$ST/done/$ID"
  ! git -C "$TMP/remote.git" rev-parse --verify -q "refs/heads/$BR" || false
  ! grep -q '^pr create' "$GH_MOCK_TRACE" || false
  ! grep -q '^pr diff 9 ' "$GH_MOCK_TRACE" || false
}

@test "autofix ship: an entry fixed on the base meanwhile is retired stale, not shipped" {
  fix_it
  sed -i.bak 's/^- \[open\] \(.*add subtracts (fix: small)\)$/- [fixed] \1 (PR: foo\/bar#587) (fixed: 2026-10-10)/' docs/found-issues.md
  rm -f docs/found-issues.md.bak
  grep -q '^- \[fixed\].*foo/bar#587' docs/found-issues.md
  git commit -qam "fixed by another session" && git push -q origin main
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -eq 0 ]
  grep -q '^result=stale: fixed on main meanwhile$' "$ST/done/$ID"
  ! git -C "$TMP/remote.git" rev-parse --verify -q "refs/heads/$BR" || false
}

@test "autofix ship: every gh call names the origin repo" {
  fix_it
  "$FI_BIN" autofix ship "$ID"
  grep -q '^pr create .*--repo foo/bar' "$GH_MOCK_TRACE"
  grep -q '^pr merge 7 --auto --squash --repo foo/bar$' "$GH_MOCK_TRACE"
}

@test "autofix merge-when-green: no checks on one look is not enough to merge" {
  export FOUND_ISSUES_AUTOFIX_MERGE_SLEEP=0 FOUND_ISSUES_AUTOFIX_MERGE_POLLS=1
  export GH_MOCK_PR_VIEW=$'7\t{"state":"OPEN","statusCheckRollup":[]}'
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 1 ]
  ! grep -q '^pr merge' "$GH_MOCK_TRACE" 2>/dev/null || false
  export FOUND_ISSUES_AUTOFIX_MERGE_POLLS=3
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 0 ]
  grep -q '^pr merge 7 --squash --repo foo/bar$' "$GH_MOCK_TRACE"
}
