#!/usr/bin/env bats
# v3 sweep: candidates, trigger, claim, run, ship (spec §4.1, §6, §7; phase 4 plan).

load 'helpers'
load 'autofix-helpers'

setup() { fi_setup_tmp; }
teardown() { fi_teardown_tmp; }

@test "sweep: candidates are fixable-now entries, critical first, then file groups, then oldest" {
  fi_af_fixture
  cat > docs/found-issues.md <<'LEDGER'
# found-issues

- [open] 2026-10-02 src/b.sh:1 — b late (fix: medium)
- [open] 2026-10-01 src/a.sh:1 — a oldest (fix: small)
- [open] [!] 2026-10-05 src/c.sh:1 — c critical (fix: medium)
- [open] 2026-10-03 src/a.sh:9 — a later (decided: yes)
- [open] 2026-09-01 src/d.sh:1 — d large (fix: large)
- [open] 2026-09-01 src/e.sh:1 — e question (decide: which?)
- [open] 2026-09-01 src/f.sh:1 — f in a PR (fix: medium) (PR: foo/bar#3)
- [open] 2026-09-01 src/g.sh:1 — g failed before (fix: small) (autofix-failed: tests fail)
- [deferred] 2026-09-01 src/h.sh:1 — h deferred (fix: medium)
LEDGER
  source "$FI_BIN"; fi_af_context
  run fi_af_sweep_candidates docs/found-issues.md "$REPO" 10
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
  [[ "${lines[0]}" == *"c critical"* ]]
  [[ "${lines[1]}" == *"a oldest"* ]]
  [[ "${lines[2]}" == *"a later"* ]]
  [[ "${lines[3]}" == *"b late"* ]]
  run fi_af_sweep_candidates docs/found-issues.md "$REPO" 2
  [ "${#lines[@]}" -eq 2 ]
}

@test "sweep: candidates skip an entry with a queued spot item" {
  fi_af_fixture
  fi_af_queue_fixture
  run fi_af_sweep_candidates docs/found-issues.md "$REPO" 10
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sweep: the fifth fixable entry queues one sweep and prints the marker" {
  fi_af_sweep_fixture 4
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUTOFIX-SWEEP-DUE "* ]]
  id="$(printf '%s\n' "$output" | sed -n 's/^AUTOFIX-SWEEP-DUE //p')"
  f="$FOUND_ISSUES_STATE_DIR/autofix/foo__bar/queue/$id"
  grep -q '^kind=sweep$' "$f"
  grep -q '^loc=sweep$' "$f"
}

@test "sweep: four fixable entries do not queue a sweep" {
  fi_af_sweep_fixture 3
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  [ "$status" -eq 0 ]
  [[ "$output" != *"AUTOFIX-SWEEP-DUE"* ]]
}

@test "sweep: untagged entries count toward the threshold" {
  fi_af_sweep_fixture 0
  for i in 1 2 3 4; do printf -- '- [open] 2026-09-0%s src/u%s.sh:1 — old untagged %s\n' "$i" "$i" "$i" >> docs/found-issues.md; done
  run "$FI_BIN" log 'src/u5.sh:1 — old untagged 5'
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUTOFIX-SWEEP-DUE "* ]]
}

@test "sweep: sync re-checks an untagged backlog with nothing to wake" {
  fi_af_sweep_fixture 0
  for i in 1 2 3 4 5; do printf -- '- [open] 2026-09-0%s src/u%s.sh:1 — old untagged %s\n' "$i" "$i" "$i" >> docs/found-issues.md; done
  git add -A && git commit -q -m backlog && git push -q origin main
  export PATH="$TEST_REPO_ROOT/tests/bin-shims:$PATH"
  run "$FI_BIN" sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUTOFIX-SWEEP-DUE "* ]]
}

@test "sweep: untagged entries the classifier was already shown stop counting" {
  fi_af_sweep_fixture 0
  for i in 1 2 3 4 5; do printf -- '- [open] 2026-09-0%s src/u%s.sh:1 — old untagged %s\n' "$i" "$i" "$i" >> docs/found-issues.md; done
  git add -A && git commit -q -m backlog && git push -q origin main
  source "$FI_BIN"; fi_af_context
  [ "$(_fi_af_untagged_count docs/found-issues.md "$REPO")" -eq 5 ]
  : > "$TMP/list"
  for i in 1 2 3 4; do printf 'U%s\t- [open] 2026-09-0%s src/u%s.sh:1 — old untagged %s\n' "$i" "$i" "$i" "$i" >> "$TMP/list"; done
  AFI_root="$REPO" _fi_af_classify_mark_offered "$TMP/list"
  [ "$(_fi_af_untagged_count docs/found-issues.md "$REPO")" -eq 1 ]
  export PATH="$TEST_REPO_ROOT/tests/bin-shims:$PATH"
  run "$FI_BIN" sync
  [[ "$output" != *"AUTOFIX-SWEEP-DUE"* ]]
}

@test "sweep: four untagged entries do not queue a sweep, nor do decide or manual ones" {
  fi_af_sweep_fixture 0
  for i in 1 2 3; do printf -- '- [open] 2026-09-0%s src/u%s.sh:1 — old untagged %s\n' "$i" "$i" "$i" >> docs/found-issues.md; done
  printf -- '- [open] 2026-09-05 src/d.sh:1 — needs a call (decide: which?)\n' >> docs/found-issues.md
  printf -- '- [open] 2026-09-06 src/m.sh:1 — untestable (manual: hardware)\n' >> docs/found-issues.md
  run "$FI_BIN" log 'src/u4.sh:1 — old untagged 4'
  [ "$status" -eq 0 ]
  [[ "$output" != *"AUTOFIX-SWEEP-DUE"* ]]
}

@test "sweep: a critical fix medium queues a sweep on its own" {
  fi_af_fixture
  printf '# found-issues\n\n' > docs/found-issues.md
  run "$FI_BIN" log --critical --fix medium 'src/calc.sh:1 — add subtracts'
  [[ "$output" == *"AUTOFIX-SWEEP-DUE "* ]]
}

@test "sweep: a pending sweep or today's cap blocks a second sweep" {
  fi_af_sweep_fixture 5
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  [[ "$output" == *"AUTOFIX-SWEEP-DUE "* ]]
  run "$FI_BIN" log --fix medium 'src/calc.sh:2 — add is slow'
  [[ "$output" != *"AUTOFIX-SWEEP-DUE"* ]]
  rm -f "$FOUND_ISSUES_STATE_DIR"/autofix/foo__bar/queue/*
  printf 'x\n' > "$FOUND_ISSUES_STATE_DIR/autofix/foo__bar/day/$(date +%Y-%m-%d).sweep"
  run "$FI_BIN" log --fix medium 'src/calc.sh:3 — add is loud'
  [[ "$output" != *"AUTOFIX-SWEEP-DUE"* ]]
}

@test "sweep: a sweep left queued from an earlier day is retired and a fresh one queued" {
  fi_af_sweep_fixture 5
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  old="$(printf '%s\n' "$output" | sed -n 's/^AUTOFIX-SWEEP-DUE //p')"
  [ -n "$old" ]
  st="$FOUND_ISSUES_STATE_DIR/autofix/foo__bar"
  sed -i.bak 's/^queued=.*/queued=2020-01-01T00:00:00/' "$st/queue/$old"
  rm -f "$st/queue/$old.bak" "$st"/day/*.sweep
  run "$FI_BIN" log --fix medium 'src/calc.sh:2 — add is slow'
  [[ "$output" == *"AUTOFIX-SWEEP-DUE "* ]]
  new="$(printf '%s\n' "$output" | sed -n 's/^AUTOFIX-SWEEP-DUE //p')"
  [ "$new" != "$old" ]
  [ ! -f "$st/queue/$old" ]
  [ -f "$st/done/$old" ]
  [ -f "$st/queue/$new" ]
}

@test "sweep: auto-fix off queues nothing" {
  fi_af_sweep_fixture 5
  git config found-issues.autofix false
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  [[ "$output" != *"AUTOFIX-SWEEP-DUE"* ]]
}

@test "sweep: tag and decide also trigger" {
  fi_af_sweep_fixture 4
  # Logged manual so the entry does not count yet (untagged ones now do).
  run "$FI_BIN" log --manual 'unsure' 'src/calc.sh:1 — add subtracts'
  [[ "$output" != *"AUTOFIX-SWEEP-DUE"* ]]
  run "$FI_BIN" tag 'add subtracts' --fix medium
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUTOFIX-SWEEP-DUE "* ]]
}

@test "sweep: an answered decision triggers through decide" {
  fi_af_sweep_fixture 4
  "$FI_BIN" log --decide 'which way?' 'src/calc.sh:1 — add subtracts' >/dev/null
  run "$FI_BIN" decide 'add subtracts' --answer 'add them'
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUTOFIX-SWEEP-DUE "* ]]
}

@test "sweep: inside a fixer no sweep is queued (its root would be the fixer worktree)" {
  fi_af_sweep_fixture 4
  FOUND_ISSUES_AUTOFIX_CHILD=1 run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  [ "$status" -eq 0 ]
  [[ "$output" != *"AUTOFIX-SWEEP-DUE"* ]]
  [[ "$output" != *"sweep queued"* ]]
  ! grep -lq '^kind=sweep$' "$FOUND_ISSUES_STATE_DIR"/autofix/foo__bar/queue/* 2>/dev/null || false
}

@test "sweep: an entry sync wakes can make a sweep due" {
  fi_af_sweep_fixture 4
  export PATH="$TEST_REPO_ROOT/tests/bin-shims:$PATH"
  printf -- '- [deferred] 2026-09-01 src/calc.sh:1 — add subtracts (fix: medium) (until: date:2026-01-01)\n' >> docs/found-issues.md
  run "$FI_BIN" sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"Woke: 1."* ]]
  [[ "$output" == *"AUTOFIX-SWEEP-DUE "* ]]
}

@test "sweep: status shows today's sweeps against the cap" {
  fi_af_fixture
  run "$FI_BIN" autofix status
  [[ "$output" == *"Today: 0/1 sweeps"* ]]
}

sweep_queue() { # queue a sweep for the fixture; sets SID and ST
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  SID="$(printf '%s\n' "$output" | sed -n 's/^AUTOFIX-SWEEP-DUE //p')"
  ST="$FOUND_ISSUES_STATE_DIR/autofix/foo__bar"
  [ -n "$SID" ]
}

@test "sweep claim: a worktree on fi/sweep/<date>-<n>, the ordered entry list, cur 1" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_queue
  run "$FI_BIN" autofix claim "$SID"
  [ "$status" -eq 0 ]
  WT="$REPO/.claude/worktrees/fi-sweep-$SID"
  [ "$output" = "$WT" ]
  [ "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" = "fi/sweep/${SID%%-*}-${SID##*-}" ]
  [ "$(wc -l < "$ST/sweeps/$SID.entries" | tr -d ' ')" = 5 ]
  grep -q '^cur=1$' "$ST/running/$SID"
  grep -q '^fixed=0$' "$ST/running/$SID"
  [ "$(sed -n 's/^head=//p' "$ST/running/$SID")" = "$(git -C "$WT" rev-parse HEAD)" ]
  [ -s "$ST/day/$(date +%Y-%m-%d).sweep" ]
}

@test "sweep claim: takes every fixable entry, no count limit" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_queue
  git config found-issues.autofix.sweepMax 2
  "$FI_BIN" autofix claim "$SID" >/dev/null
  # The 4 fixture entries plus the one sweep_queue logged; the old
  # sweepMax-sized claim would have kept 2.
  [ "$(wc -l < "$ST/sweeps/$SID.entries" | tr -d ' ')" = 5 ]
}

@test "sweep claim: nothing fixable any more finishes the sweep stale" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_queue
  sed -i.bak 's/(fix: medium)/(fix: large)/' docs/found-issues.md; rm -f docs/found-issues.md.bak
  run "$FI_BIN" autofix claim "$SID"
  [ "$status" -eq 5 ]
  [ -f "$ST/done/$SID" ]
  grep -q '^result=stale: nothing fixable now$' "$ST/done/$SID"
}

@test "sweep claim: no test command retires stale without taking the day's sweep slot or classifying" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_queue
  git config --unset found-issues.autofix.testCommand
  run "$FI_BIN" autofix claim "$SID"
  [ "$status" -eq 5 ]
  grep -q '^result=stale: no test command$' "$ST/done/$SID"
  [ ! -s "$ST/day/$(date +%Y-%m-%d).sweep" ]
  [ ! -s "$FI_STANDIN_TRACE" ]
  [ ! -d "$REPO/.claude/worktrees/fi-sweep-$SID" ]
}

@test "sweep state: commit moves head and advances; settle resets and tags the source ledger" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_queue
  "$FI_BIN" autofix claim "$SID" >/dev/null
  WT="$REPO/.claude/worktrees/fi-sweep-$SID"
  source "$FI_BIN"; fi_af_context
  fi_af_item_read "$ST/running/$SID"
  fi_af_sweep_load "$SID"
  first="$AFI_loc"
  sed -i.bak 's/- 1/+ 0/' "$WT/${AFI_loc%%:*}"; rm -f "$WT/${AFI_loc%%:*}.bak"
  git -C "$WT" add -A; FI_AF_TREE="$(git -C "$WT" write-tree)"
  fi_af_sweep_commit "$SID"
  grep -q '^cur=2$' "$ST/running/$SID"
  grep -q '^fixed=1$' "$ST/running/$SID"
  [[ "$(git -C "$WT" log -1 --format=%s)" == "fix: "*"(found-issues $first)" ]]
  [ "$(sed -n 's/^head=//p' "$ST/running/$SID")" = "$(git -C "$WT" rev-parse HEAD)" ]
  fi_af_item_read "$ST/running/$SID"
  fi_af_sweep_load "$SID"
  second="$AFI_loc"
  printf 'junk\n' > "$WT/junk.txt"
  fi_af_sweep_settle "$SID" failed "tests fail after 2 attempts"
  [ ! -e "$WT/junk.txt" ]
  grep -q '^cur=3$' "$ST/running/$SID"
  grep -F "$second — " docs/found-issues.md | grep -q '(autofix-failed: tests fail after 2 attempts)'
  grep -q "^$first	fixed	" "$ST/sweeps/$SID.outcomes"
  grep -q "^$second	failed	" "$ST/sweeps/$SID.outcomes"
}

@test "sweep state: commit refuses a tree the verifier did not approve" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_queue
  "$FI_BIN" autofix claim "$SID" >/dev/null
  WT="$REPO/.claude/worktrees/fi-sweep-$SID"
  source "$FI_BIN"; fi_af_context
  fi_af_item_read "$ST/running/$SID"; fi_af_sweep_load "$SID"
  sed -i.bak 's/- 1/+ 0/' "$WT/${AFI_loc%%:*}"; rm -f "$WT/${AFI_loc%%:*}.bak"
  git -C "$WT" add -A; FI_AF_TREE="$(git -C "$WT" write-tree)"
  printf 'late\n' > "$WT/late.txt"
  ! fi_af_sweep_commit "$SID" || false
  grep -q '^cur=1$' "$ST/running/$SID"
}

@test "sweep claim: the kill switch refuses it like a spot claim" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_queue
  "$FI_BIN" autofix off >/dev/null
  run "$FI_BIN" autofix claim "$SID"
  [ "$status" -eq 1 ]
  [ -f "$ST/queue/$SID" ]
}

sweep_edit() { # the stand-in fixer fixes whichever entry its prompt names, with its own test file
  export FI_STANDIN_EDIT='mkdir -p tests; case "$FI_STANDIN_PROMPT" in *"src/calc.sh:1"*) sed -i.bak "s/ - / + /" src/calc.sh; rm -f src/calc.sh.bak; printf "[ \"\$(add 2 3)\" = 5 ]\n" >> tests/t_calc.sh ;; esac; for f in src/f*.sh; do n="${f#src/f}"; n="${n%.sh}"; case "$FI_STANDIN_PROMPT" in *"src/f$n.sh:1"*) sed -i.bak "s/- 1/+ 0/" "$f"; rm -f "$f.bak"; printf "[ \"\$(f%s 2)\" = 2 ]\n" "$n" >> tests/t_f$n.sh ;; esac; done'
}
gh_mock() {
  export GH_MOCK_TRACE="$TMP/gh.trace" GH_MOCK_PR_CREATE_URL=https://github.com/foo/bar/pull/9
  export GH_MOCK_PR_VIEW=$'9\t{"number":9,"state":"OPEN","statusCheckRollup":[]}'
}

@test "sweep run: fixes every entry, one commit each, one PR, every entry annotated" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock; sweep_queue
  run "$FI_BIN" autofix run "$SID" --engine claude
  [ "$status" -eq 0 ]
  [ -f "$ST/done/$SID" ]
  grep -q '^result=shipped: PR #9, 5 fixed' "$ST/done/$SID"
  br="fi/sweep/${SID%%-*}-${SID##*-}"
  [ "$(git -C "$TMP/remote.git" log --format=%s "main..$br" | grep -c '^fix: ')" = 5 ]
  [ "$(grep -c '^pr create' "$GH_MOCK_TRACE")" = 1 ]
  # The PR lands on main, the checkout's own branch: the four entries origin
  # has are annotated on the PR branch only (no uncommitted copy here that
  # would abort the next pull); the entry origin never saw is annotated here.
  [ "$(grep -c '(PR: foo/bar#9)' docs/found-issues.md)" = 1 ]
  grep -F 'add subtracts' docs/found-issues.md | grep -q '(PR: foo/bar#9)'
  [ "$(git -C "$TMP/remote.git" show "$br:docs/found-issues.md" | grep -c '(PR: foo/bar#9)')" = 4 ]
  grep -q '^pr merge 9 --auto --squash --repo foo/bar$' "$GH_MOCK_TRACE"
  grep -q 'found-issues sweep (5 entries)' "$GH_MOCK_TRACE"
  [ ! -d "$REPO/.claude/worktrees/fi-sweep-$SID" ]
}

@test "sweep run: a rejected entry is reset and the next entry's diff is clean" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock
  printf '%s\n' '{"approve":false,"reason":"no"}' '{"approve":false,"reason":"no"}' > "$TMP/verdicts"
  export FI_STANDIN_VERDICTS="$TMP/verdicts"
  sweep_queue
  "$FI_BIN" autofix run "$SID" --engine claude
  first="$(head -1 "$ST/sweeps/$SID.entries")"
  grep -F -- "${first% (fix: medium)}" docs/found-issues.md | grep -q '(autofix-failed: verifier rejected: no after 2 attempts)'
  [ "$(grep -c '	fixed	' "$ST/sweeps/$SID.outcomes")" = 4 ]
  f1="$(printf '%s' "$first" | sed -E 's/^.* (src\/[^:]+):1 .*$/\1/')"
  br="fi/sweep/${SID%%-*}-${SID##*-}"
  [ -z "$(git -C "$TMP/remote.git" log --format=%H "main..$br" -- "$f1")" ]
}

@test "sweep run: nothing fixed ends stale with no PR" {
  fi_af_sweep_fixture 4; fi_use_standins; gh_mock
  export FI_STANDIN_RESULT='FI-RESULT: manual cannot test'
  sweep_queue
  "$FI_BIN" autofix run "$SID" --engine claude
  grep -q '^result=stale: sweep fixed nothing (5 manual)' "$ST/done/$SID"
  ! grep -q '^pr create' "$GH_MOCK_TRACE" 2>/dev/null || false
  [ "$(grep -c '(manual: cannot test)' docs/found-issues.md)" = 5 ]
}

@test "sweep run: ship refuses a tree that differs from the approved commits" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock
  # $$ differs per run: the ship-time test run rewrites the artifact.
  git config found-issues.autofix.testCommand 'sh test.sh && echo $$ > artifact.out'
  git config found-issues.autofix.sweepMax 1
  sweep_queue
  "$FI_BIN" autofix run "$SID" --engine claude
  source "$FI_BIN"; fi_af_context
  grep -q 'ship failed (the tree differs' "$FI_AF_RUNS/$SID.log"
  grep -q '^ship_tries=1$' "$ST/queue/$SID"
  ! grep -q '^pr create' "$GH_MOCK_TRACE" 2>/dev/null || false
}

@test "sweep run: the run budget stops the sweep without failing the current entry" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock
  git config found-issues.autofix.sweepBudget 0.60
  sweep_queue
  "$FI_BIN" autofix run "$SID" --engine claude
  grep -q '^result=shipped: PR #9, 1 fixed' "$ST/done/$SID"
  ! grep -q 'autofix-failed' docs/found-issues.md || false
}

@test "sweep run: a spot item for an entry the sweep shipped retires stale" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock; sweep_queue
  # Runs ON the landing branch (main): the source ledger is not annotated, the
  # in-flight record keeps the shipped entry from being fixed a second time.
  "$FI_BIN" autofix run "$SID" --engine claude
  entry="$(grep -m1 'f1 subtracts' docs/found-issues.md)"
  source "$FI_BIN"; fi_af_context
  fi_entry_dedup_key_v "$entry" "$REPO"
  QID=20991231-000000-00001
  fi_af_item_write "$ST/queue/$QID" "id=$QID" kind=spot "root=$REPO" slug=foo/bar loc=src/f1.sh:1 "key=$FI_KEY" "entry=$entry" engine=claude crashes=0
  run "$FI_BIN" autofix claim "$QID"
  [ "$status" -eq 5 ]
}

@test "sweep run: two fixed entries on one line are each annotated once" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock
  run "$FI_BIN" log --fix medium 'src/f1.sh:1 — f1 ignores its argument'
  SID="$(printf '%s\n' "$output" | sed -n 's/^AUTOFIX-SWEEP-DUE //p')"
  ST="$FOUND_ISSUES_STATE_DIR/autofix/foo__bar"
  "$FI_BIN" autofix run "$SID" --engine claude
  grep -q '^result=shipped: PR #9, 5 fixed' "$ST/done/$SID"
  # On main (the PR's base) only the entry origin never saw is annotated here,
  # the freshly logged f1 duplicate; the other four ride the PR branch.
  [ "$(grep -c '(PR: foo/bar#9)' docs/found-issues.md)" = 1 ]
  ! grep -q '(PR: foo/bar#9) (PR: foo/bar#9)' docs/found-issues.md || false
  grep -F 'f1 ignores its argument' docs/found-issues.md | grep -q '(PR: foo/bar#9)'
}

@test "sweep run: switching auto-fix off mid-sweep requeues it and ships nothing" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock
  export FI_STANDIN_EDIT="$FI_STANDIN_EDIT; touch '$FOUND_ISSUES_STATE_DIR/autofix/disabled'"
  sweep_queue
  run "$FI_BIN" autofix run "$SID" --engine claude
  [ "$status" -eq 0 ]
  ! grep -q '^pr create' "$GH_MOCK_TRACE" 2>/dev/null || false
  [ -f "$ST/queue/$SID" ]
  [ ! -f "$ST/done/$SID" ]
  [ ! -d "$REPO/.claude/worktrees/fi-sweep-$SID" ]
}

@test "sweep claim: a sweep requeued today re-claims without a second cap" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_queue
  "$FI_BIN" autofix claim "$SID" >/dev/null
  "$FI_BIN" autofix off >/dev/null
  run "$FI_BIN" autofix ship "$SID"
  [ "$status" -eq 8 ]
  [ -f "$ST/queue/$SID" ]
  "$FI_BIN" autofix on >/dev/null
  run "$FI_BIN" autofix claim "$SID"
  [ "$status" -eq 0 ]
  [ "$(grep -c . "$ST/day/$(date +%Y-%m-%d).sweep")" = 1 ]
}

@test "sweep run: a sweep over today's cap retires stale and leaves spot fixes running" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_queue
  mkdir -p "$ST/day"
  printf 'other-sweep\n' > "$ST/day/$(date +%Y-%m-%d).sweep"
  run "$FI_BIN" autofix run "$SID" --engine claude
  [ "$status" -eq 0 ]
  grep -q "^result=stale: today's sweep cap" "$ST/done/$SID"
  [ ! -e "$ST/day/$(date +%Y-%m-%d).capped" ]
}

@test "sweep claim: over today's cap the claim names the sweep cap" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_queue
  mkdir -p "$ST/day"
  printf 'other-sweep\n' > "$ST/day/$(date +%Y-%m-%d).sweep"
  run "$FI_BIN" autofix claim "$SID"
  [ "$status" -eq 5 ]
  [[ "$output" == *"today's sweep cap"* ]]
  [[ "$output" != *"spot-fix"* ]]
}

# 3.2.1 (ledger lib/autofix.sh:127): the suite runs once at base, before the
# classifier. A failing base spends the day's slot, or every Stop would queue
# a fresh sweep and re-run the whole suite.
@test "sweep claim: tests that fail at base retire stale before classifying, spending the day's slot" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_queue
  git config found-issues.autofix.testCommand 'exit 1'
  run "$FI_BIN" autofix claim "$SID"
  [ "$status" -eq 5 ]
  [[ "$output" == *"tests fail at base"* ]]
  grep -q '^result=stale: tests fail at base$' "$ST/done/$SID"
  [ -s "$ST/day/$(date +%Y-%m-%d).sweep" ]
  [ ! -s "$FI_STANDIN_TRACE" ]
  [ ! -d "$REPO/.claude/worktrees/fi-sweep-$SID" ]
}

# 3.2.1 (ledger lib/autofix-sweep.sh:387): a failed ship keeps the branch and
# requeues the sweep; the next run ships the same commits without fixing again.
sweep_branch() { printf 'fi/sweep/%s-%s' "${SID%%-*}" "${SID##*-}"; }

@test "sweep run: a failed push keeps the branch and requeues the sweep; the next run only ships" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock; sweep_queue
  git config remote.origin.pushurl "$TMP/nowhere.git"
  run "$FI_BIN" autofix run "$SID" --engine claude
  [ "$status" -eq 0 ]
  [ -f "$ST/queue/$SID" ]
  [ ! -f "$ST/done/$SID" ]
  grep -q '^ship_tries=1$' "$ST/queue/$SID"
  grep -q '^base=main$' "$ST/queue/$SID"
  [ "$(sed -n 's/^wait_next=//p' "$ST/queue/$SID")" -gt "$(date +%s)" ]
  [ "$(git log --format=%s "main..$(sweep_branch)" | grep -c '^fix: ')" = 5 ]
  [ ! -d "$REPO/.claude/worktrees/fi-sweep-$SID" ]
  ! grep -q '^pr create' "$GH_MOCK_TRACE" 2>/dev/null || false
  ! grep -q 'autofix-failed' docs/found-issues.md || false
  engine_calls="$(grep -c '^claude' "$FI_STANDIN_TRACE")"
  git config --unset remote.origin.pushurl
  source "$FI_BIN"; fi_af_context
  fi_af_item_set "$ST/queue/$SID" wait_next ""
  run "$FI_BIN" autofix run "$SID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '^result=shipped: PR #9, 5 fixed' "$ST/done/$SID"
  [ "$(grep -c '^claude' "$FI_STANDIN_TRACE")" = "$engine_calls" ]
  [ "$(git -C "$TMP/remote.git" log --format=%s "main..$(sweep_branch)" | grep -c '^fix: ')" = 5 ]
  [ "$(grep -c '(PR: foo/bar#9)' docs/found-issues.md)" = 1 ]   # only the entry origin never saw; the rest ride the PR
  [ -z "$(git branch --list "$(sweep_branch)")" ]
}

@test "sweep run: the last allowed failed ship ends failed and still keeps the branch" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock; sweep_queue
  export FOUND_ISSUES_AUTOFIX_SHIP_TRIES=2
  git config remote.origin.pushurl "$TMP/nowhere.git"
  "$FI_BIN" autofix run "$SID" --engine claude
  source "$FI_BIN"; fi_af_context
  fi_af_item_set "$ST/queue/$SID" wait_next ""
  "$FI_BIN" autofix run "$SID" --engine claude
  grep -q '^result=failed: ship: git push failed' "$ST/done/$SID"
  grep -q "$(sweep_branch) kept" "$ST/done/$SID"
  [ -n "$(git branch --list "$(sweep_branch)")" ]
  [ "$(git log --format=%s "main..$(sweep_branch)" | grep -c '^fix: ')" = 5 ]
}

@test "sweep run: a ship retry reuses the PR an earlier try opened" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock; sweep_queue
  git config remote.origin.pushurl "$TMP/nowhere.git"
  "$FI_BIN" autofix run "$SID" --engine claude
  git config --unset remote.origin.pushurl
  source "$FI_BIN"; fi_af_context
  fi_af_item_set "$ST/queue/$SID" wait_next ""
  export GH_MOCK_PR_LIST='[{"number":11}]'
  export GH_MOCK_PR_VIEW=$'11\t{"number":11,"state":"OPEN","statusCheckRollup":[]}'
  run "$FI_BIN" autofix run "$SID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '^result=shipped: PR #11, 5 fixed' "$ST/done/$SID"
  ! grep -q '^pr create' "$GH_MOCK_TRACE" || false
}

@test "sweep b: a failed ship says the sweep is requeued with its branch kept" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock; sweep_queue
  git config remote.origin.pushurl "$TMP/nowhere.git"
  "$FI_BIN" autofix run "$SID" --engine claude
  "$FI_BIN" autofix claim "$SID" >/dev/null
  run "$FI_BIN" autofix ship "$SID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"git push failed"*"requeued with its branch kept"* ]]
  grep -q '^ship_tries=2$' "$ST/queue/$SID"
}

# 3.3.0 (spec section 9): a sweep fixes every fixable entry and ships one PR
# per sweepBatch fixes; the rest waits in a continuation item.
@test "sweep run: ships a PR per batch and queues the next batch" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock
  git config found-issues.autofix.sweepBatch 2
  sweep_queue
  source "$FI_BIN"; fi_af_context
  "$FI_BIN" autofix run "$SID" --engine claude
  grep -q '^result=shipped: PR #[0-9]*, 2 fixed' "$ST/done/$SID"
  grep -q 'sweep: batch 1 closes at 2 fixes' "$FI_AF_RUNS/$SID.log"
  grep -q 'sweep: queued batch 2 as ' "$FI_AF_RUNS/$SID.log"
  grep -q 'found-issues sweep (2 entries, batch 1)' "$GH_MOCK_TRACE"
  # Launcher A drains the continuation in the same run.
  n="$(grep -l '^cont=2' "$ST"/done/* | wc -l | tr -d ' ')"
  [ "$n" = 1 ]
  c="$(grep -l '^cont=2' "$ST"/done/*)"
  grep -q '^engine=claude$' "$c"
  grep -q '^base=main$' "$c"
  grep -q 'found-issues sweep (2 entries, batch 2)' "$GH_MOCK_TRACE"
  ! grep -q 'autofix-failed' docs/found-issues.md || false
}

@test "sweep run: a continuation takes no second daily slot and carries the chain's spend" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock
  git config found-issues.autofix.sweepBatch 2
  git config found-issues.autofix.dailySweeps 1
  sweep_queue
  "$FI_BIN" autofix run "$SID" --engine claude
  c="$(grep -l '^cont=2' "$ST"/done/*)"
  grep -q '^result=shipped' "$c"
  [ "$(grep -c . "$ST/day/$(date +%Y-%m-%d).sweep")" = 1 ]
  # The chain's running total rides in chain_cost; the item's own cost is its batch only.
  awk -F= '$1=="chain_cost" && $2+0 > 0.5 { ok=1 } END { exit !ok }' "$c"
  # So summing the done items counts the chain's spend once: 5 entries at 0.50 each.
  total="$(awk -F= '$1=="cost" { s += $2 } END { printf "%.2f", s }' "$ST"/done/*)"
  [ "$total" = "2.50" ]
}

@test "sweep run: a batch closes only at a file boundary" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock
  git config found-issues.autofix.sweepBatch 1
  # A second entry on src/f1.sh: it sorts next to the first f1 entry.
  run "$FI_BIN" log --fix medium 'src/f1.sh:1 — f1 ignores its argument'
  SID="$(printf '%s\n' "$output" | sed -n 's/^AUTOFIX-SWEEP-DUE //p')"
  ST="$FOUND_ISSUES_STATE_DIR/autofix/foo__bar"
  [ -n "$SID" ]
  "$FI_BIN" autofix run "$SID" --engine claude
  grep -q '^result=shipped: PR #[0-9]*, 2 fixed' "$ST/done/$SID"
}

@test "sweep claim: a continuation skips files in skip_files" {
  fi_af_sweep_fixture 4; fi_use_standins
  source "$FI_BIN"; fi_af_context
  QID=20991231-000000-00003
  fi_af_item_write "$FI_AF_ST/queue/$QID" "id=$QID" kind=sweep "root=$REPO" slug=foo/bar loc=sweep \
    engine=claude "queued=$(date +%Y-%m-%dT%H:%M:%S)" crashes=0 cont=2 "cap_day=$(date +%Y-%m-%d)" \
    skip_files=src/f1.sh base=main
  run "$FI_BIN" autofix claim "$QID"
  [ "$status" -eq 0 ]
  grep -q "sweep: skip src/f1.sh:1 (file in an earlier batch's PR)" "$FI_AF_RUNS/$QID.log"
  [ "$(wc -l < "$FI_AF_ST/sweeps/$QID.entries" | tr -d ' ')" = 3 ]
  ! grep -q 'src/f1.sh' "$FI_AF_ST/sweeps/$QID.entries" || false
  # No classify pass and no second day slot for a continuation.
  [ ! -s "$FI_STANDIN_TRACE" ]
  [ ! -s "$FI_AF_ST/day/$(date +%Y-%m-%d).sweep" ]
}

@test "sweep run: a failed batch ship queues no continuation" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock
  git config found-issues.autofix.sweepBatch 2
  git config remote.origin.pushurl "$TMP/nowhere.git"
  sweep_queue
  "$FI_BIN" autofix run "$SID" --engine claude || true
  grep -q '^ship_tries=1$' "$ST/queue/$SID"
  [ "$(find "$ST/queue" "$ST/done" -type f | wc -l | tr -d ' ')" = 1 ]
  ! grep -q '^cont=' "$ST"/queue/* "$ST"/done/* 2>/dev/null || false
  # The retry ships the same commits; the rest waits for the next sweep.
  git config --unset remote.origin.pushurl
  source "$FI_BIN"; fi_af_context
  fi_af_item_set "$ST/queue/$SID" wait_next ""
  "$FI_BIN" autofix run "$SID" --engine claude
  grep -q '^result=shipped: PR #[0-9]*, 2 fixed' "$ST/done/$SID"
  [ "$(find "$ST/queue" "$ST/done" -type f | wc -l | tr -d ' ')" = 1 ]
  ! grep -q '^cont=' "$ST"/queue/* "$ST"/done/* 2>/dev/null || false
}

@test "config: sweepMax still sets the batch size when sweepBatch is unset" {
  fi_af_fixture
  source "$FI_BIN"; fi_af_context
  [ "$(fi_af_sweep_batch)" = 8 ]
  git config found-issues.autofix.sweepMax 3
  [ "$(fi_af_sweep_batch)" = 3 ]
  git config found-issues.autofix.sweepBatch 5
  [ "$(fi_af_sweep_batch)" = 5 ]
}

@test "sweep: a ship-retry sweep queued on an earlier day is not retired as never launched" {
  fi_af_sweep_fixture 4
  source "$FI_BIN"; fi_af_context
  QID=20991231-000000-00002
  fi_af_item_write "$FI_AF_ST/queue/$QID" "id=$QID" kind=sweep "root=$REPO" slug=foo/bar loc=sweep \
    engine=claude queued=2020-01-01T00:00:00 crashes=0 ship_tries=1
  _fi_af_sweep_retire_stale
  [ -f "$FI_AF_ST/queue/$QID" ]
}

@test "sweep: switching off a ship-retry sweep keeps its branch and base" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock; sweep_queue
  git config remote.origin.pushurl "$TMP/nowhere.git"
  "$FI_BIN" autofix run "$SID" --engine claude
  git config --unset remote.origin.pushurl
  run "$FI_BIN" autofix claim "$SID"
  [ "$status" -eq 0 ]
  WT="$REPO/.claude/worktrees/fi-sweep-$SID"
  [ "$output" = "$WT" ]
  [ "$(git -C "$WT" rev-parse HEAD)" = "$(git rev-parse "$(sweep_branch)")" ]
  run "$FI_BIN" autofix next "$SID"
  [[ "$output" == "No entries left. Run: found-issues autofix ship $SID" ]]
  "$FI_BIN" autofix off >/dev/null
  run "$FI_BIN" autofix ship "$SID"
  [ "$status" -eq 8 ]
  grep -q '^base=main$' "$ST/queue/$SID"
  [ "$(git log --format=%s "main..$(sweep_branch)" | grep -c '^fix: ')" = 5 ]
}

@test "sweep: a crashed ship-retry run is requeued with its branch kept" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock; sweep_queue
  git config remote.origin.pushurl "$TMP/nowhere.git"
  "$FI_BIN" autofix run "$SID" --engine claude
  "$FI_BIN" autofix claim "$SID" >/dev/null
  source "$FI_BIN"; fi_af_context
  fi_af_item_set "$ST/running/$SID" pid 999999
  fi_af_unlock "$SID"
  fi_af_lock reaper; fi_af_reap; fi_af_unlock reaper
  [ -f "$ST/queue/$SID" ]
  grep -q '^base=main$' "$ST/queue/$SID"
  [ -n "$(git branch --list "$(sweep_branch)")" ]
}

@test "sweep: a non-numeric ship wait still requeues and the retry ships" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock; sweep_queue
  export FOUND_ISSUES_AUTOFIX_SHIP_WAIT=15m
  git config remote.origin.pushurl "$TMP/nowhere.git"
  "$FI_BIN" autofix run "$SID" --engine claude
  grep -q '^ship_tries=1$' "$ST/queue/$SID"
  [ "$(sed -n 's/^wait_next=//p' "$ST/queue/$SID")" -gt "$(date +%s)" ]
  git config --unset remote.origin.pushurl
  source "$FI_BIN"; fi_af_context
  fi_af_item_set "$ST/queue/$SID" wait_next ""
  run "$FI_BIN" autofix run "$SID" --engine claude
  grep -q '^result=shipped: PR #9' "$ST/done/$SID"
}

@test "sweep: cancelling a queued ship retry names the kept branch; an old one retires" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock; sweep_queue
  git config remote.origin.pushurl "$TMP/nowhere.git"
  "$FI_BIN" autofix run "$SID" --engine claude
  cp "$ST/queue/$SID" "$TMP/item"
  run "$FI_BIN" autofix cancel "$SID"
  [[ "$output" == *"stay on branch $(sweep_branch)"* ]]
  source "$FI_BIN"; fi_af_context
  QID=20991231-000000-00003
  sed "s/^id=.*/id=$QID/" "$TMP/item" > "$FI_AF_ST/queue/$QID"
  touch -t 202001010000 "$FI_AF_ST/queue/$QID"
  _fi_af_sweep_retire_stale
  grep -q "^result=stale: ship retry never launched; branch $(sweep_branch) kept" "$FI_AF_ST/done/$QID"
}

@test "sweep run: the codex token cap stops the sweep and ships what it committed" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock
  # 1500 tokens per child: with or without a classify child, entry 1 is
  # fixed and verified and the cap stops entry 2 before its verifier.
  git config found-issues.autofix.codexSweepTokens 3500
  sweep_queue
  "$FI_BIN" autofix run "$SID" --engine codex
  grep -q '^result=shipped: PR #9, 1 fixed' "$ST/done/$SID"
  ! grep -q 'autofix-failed' docs/found-issues.md || false
}

@test "sweep run: a continuation keeps its own engine whatever --engine says" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock
  source "$FI_BIN"; fi_af_context
  QID=20991231-000000-00004
  fi_af_item_write "$FI_AF_ST/queue/$QID" "id=$QID" kind=sweep "root=$REPO" slug=foo/bar loc=sweep \
    engine=codex "queued=$(date +%Y-%m-%dT%H:%M:%S)" crashes=0 cont=2 "cap_day=$(date +%Y-%m-%d)" base=main
  "$FI_BIN" autofix run "$QID" --engine claude
  grep -q '^codex' "$FI_STANDIN_TRACE"
  ! grep -q '^claude' "$FI_STANDIN_TRACE" || false
  grep -q '^engine=codex$' "$FI_AF_ST/done/$QID"
  grep -q 'engine codex' "$FI_AF_RUNS/$QID.pr-body.md"
}

@test "sweep run: a fresh sweep still lets --engine override the queued engine" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock; sweep_queue
  source "$FI_BIN"; fi_af_context
  fi_af_item_set "$ST/queue/$SID" engine codex
  "$FI_BIN" autofix run "$SID" --engine claude
  ! grep -q '^codex' "$FI_STANDIN_TRACE" || false
  grep -q '^claude' "$FI_STANDIN_TRACE"
}

@test "sweep run: the engine a sweep ran on is persisted, so its PR body names no codex models for a claude run" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock; sweep_queue
  source "$FI_BIN"; fi_af_context
  fi_af_item_set "$ST/queue/$SID" engine codex
  "$FI_BIN" autofix run "$SID" --engine claude
  grep -q '^engine=claude$' "$ST/done/$SID"
  grep -q 'launcher A, engine claude' "$FI_AF_RUNS/$SID.pr-body.md"
  ! grep -q 'codex models' "$FI_AF_RUNS/$SID.pr-body.md" || false
}

@test "sweep run: a codex sweep's PR body names the model of each role" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock; sweep_queue
  "$FI_BIN" autofix run "$SID" --engine codex
  source "$FI_BIN"; fi_af_context
  grep -q '^engine=codex$' "$ST/done/$SID"
  grep -q 'Run cost: .*codex models: fixer gpt-6.1-sol (medium), verifier gpt-6-astra (high)' "$FI_AF_RUNS/$SID.pr-body.md"
}

@test "sweep run: a continuation carries the base reason, so status shows it for both batches" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock
  git config found-issues.autofix.sweepBatch 2
  sweep_queue
  "$FI_BIN" autofix run "$SID" --engine claude
  c="$(grep -l '^cont=2' "$ST"/done/*)"
  grep -q '^base_why=default branch$' "$ST/done/$SID"
  grep -q '^base_why=default branch$' "$c"
  run "$FI_BIN" autofix status
  [ "$(printf '%s\n' "$output" | grep -c 'into main (default branch)')" -ge 2 ]
  ! printf '%s\n' "$output" | grep -q '(?)' || false
}

@test "sweep run: a sweep after a spot item in one drain starts from zero spend, classify included" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock
  printf -- '- [open] 2026-10-01 src/calc.sh:1 — add subtracts (fix: small)\n' >> docs/found-issues.md
  printf -- '- [open] 2026-10-01 src/u1.sh:1 — nobody has tagged this\n' >> docs/found-issues.md
  git add -A && git commit -q -m calc && git push -q origin main
  git config found-issues.autofix.codexSweepTokens 3500
  source "$FI_BIN"; fi_af_context
  fi_af_queue_spot "$(grep -m1 'add subtracts' docs/found-issues.md)" >/dev/null
  SPOT="$(ls "$FI_AF_ST/queue" | head -1)"
  fi_af_new_id; SID="$FI_AF_ID"
  fi_af_item_write "$FI_AF_ST/queue/$SID" "id=$SID" kind=sweep "root=$REPO" slug=foo/bar loc=sweep \
    engine=codex "queued=2099-01-01T00:00:00" crashes=0
  ST="$FI_AF_ST"
  "$FI_BIN" autofix run "$SPOT" --engine codex
  grep -q '^result=shipped' "$ST/done/$SPOT"
  grep -q '^tokens=3000$' "$ST/done/$SPOT"
  [ -f "$ST/done/$SID" ]
  grep -q 'classify: rc=' "$FI_AF_RUNS/$SID.log"
  # 1500 per child: classify (1500), entry 1 fixed and verified (4500) meets
  # the 3500 cap before entry 2. The spot item's 3000 are not on top of it:
  # with them the classifier alone would have left 4500 and entry 1 never ran.
  grep -q '^result=shipped: PR #9, 1 fixed' "$ST/done/$SID"
  grep -q '^tokens=4500$' "$ST/done/$SID"
}

# Spec section 9: a full batch closes at the first file boundary, whatever the
# last outcome was; batch PRs never touch the same file or ledger lines.
@test "sweep run: a settled entry on the last file of a full batch lets the batch close at the boundary" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock
  git config found-issues.autofix.sweepBatch 1
  # A second entry on src/f1.sh: it sorts next to the first f1 entry. Its
  # verifier rejects twice, so it settles failed with the batch already full.
  run "$FI_BIN" log --fix medium 'src/f1.sh:1 — f1 ignores its argument'
  SID="$(printf '%s\n' "$output" | sed -n 's/^AUTOFIX-SWEEP-DUE //p')"
  ST="$FOUND_ISSUES_STATE_DIR/autofix/foo__bar"
  printf '%s\n' '{"approve":true,"reason":"ok"}' '{"approve":false,"reason":"no"}' '{"approve":false,"reason":"no"}' > "$TMP/verdicts"
  export FI_STANDIN_VERDICTS="$TMP/verdicts"
  source "$FI_BIN"; fi_af_context
  "$FI_BIN" autofix run "$SID" --engine claude
  grep -q '^result=shipped: PR #[0-9]*, 1 fixed' "$ST/done/$SID"
  grep -q 'sweep: batch 1 closes at 1 fixes' "$FI_AF_RUNS/$SID.log"
  grep -q 'sweep: queued batch 2 as ' "$FI_AF_RUNS/$SID.log"
  [ "$(grep -c '	fixed	' "$ST/sweeps/$SID.outcomes")" = 1 ]
  [ "$(grep -c '	failed	' "$ST/sweeps/$SID.outcomes")" = 1 ]
}

@test "sweep run: a continuation's PR leaves the PR branch ledger alone and still annotates the source ledger" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock
  git config found-issues.autofix.sweepBatch 2
  sweep_queue
  source "$FI_BIN"; fi_af_context
  "$FI_BIN" autofix run "$SID" --engine claude
  br1="fi/sweep/${SID%%-*}-${SID##*-}"
  c="$(grep -l '^cont=2' "$ST"/done/*)"
  br2="$(sed -n 's/^branch=//p' "$c")"
  [ -n "$br2" ]
  # Batch 1 keeps today's behaviour: one annotation commit on its branch.
  git -C "$TMP/remote.git" log --format=%s "main..$br1" | grep -q '^docs(found-issues): annotate 2 entries with PR 9'
  # The continuation commits no ledger change at all.
  ! git -C "$TMP/remote.git" log --format=%s "main..$br2" | grep -q 'docs(found-issues)' || false
  [ -z "$(git -C "$TMP/remote.git" log --format=%H "main..$br2" -- docs/found-issues.md)" ]
  grep -q 'PR-branch ledger annotation skipped for a continuation batch' "$FI_AF_RUNS/${c##*/}.log"
  # The source checkout's ledger is annotated for the continuation batches'
  # entries (f3, f4, calc). Batch 1's two entries (f1, f2) ride its PR branch
  # and are skipped here, because the PR lands on this checkout's branch.
  [ "$(grep -c '(PR: foo/bar#9)' docs/found-issues.md)" = 3 ]
  ! grep -E 'src/f[12]\.sh:1 .*\(PR: foo/bar#9\)' docs/found-issues.md || false
}

@test "sweep run: a continuation skips an entry whose file an earlier batch changed without citing it" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock
  printf 'helper() { :; }\n' > src/helper.sh
  printf -- '- [open] 2026-10-09 src/helper.sh:1 — helper does nothing (fix: medium)\n' >> docs/found-issues.md
  git add -A && git commit -q -m helper && git push -q origin main
  # Fixing f1 also edits src/helper.sh, which no fixed entry cites.
  export FI_STANDIN_EDIT="$FI_STANDIN_EDIT"'; case "$FI_STANDIN_PROMPT" in *"src/f1.sh:1"*) echo "# touched by the f1 fix" >> src/helper.sh ;; esac'
  git config found-issues.autofix.sweepBatch 2
  sweep_queue
  source "$FI_BIN"; fi_af_context
  "$FI_BIN" autofix run "$SID" --engine claude
  grep -q '^result=shipped: PR #[0-9]*, 2 fixed' "$ST/done/$SID"
  c="$(grep -l '^cont=2' "$ST"/done/*)"
  # skip_files holds the batch's whole diff: the cited source files, the
  # uncited helper and the fixers' test files.
  skip="$(sed -n 's/^skip_files=//p' "$c")"
  [[ ":$skip:" == *":src/helper.sh:"* ]]
  [[ ":$skip:" == *":tests/t_f1.sh:"* ]]
  grep -q "sweep: skip src/helper.sh:1 (file in an earlier batch's PR)" "$FI_AF_RUNS/${c##*/}.log"
  ! grep -q 'src/helper.sh' "$ST/sweeps/${c##*/}.entries" || false
  grep -q 'helper does nothing (fix: medium)$' docs/found-issues.md
}

@test "sweep run: a continuation's fix that edits a skip_files path is undone and settled skipped" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock
  export FI_STANDIN_EDIT="$FI_STANDIN_EDIT"'; case "$FI_STANDIN_PROMPT" in *"src/f2.sh:1"*) echo "shared" >> shared.txt ;; esac'
  source "$FI_BIN"; fi_af_context
  QID=20991231-000000-00005
  fi_af_item_write "$FI_AF_ST/queue/$QID" "id=$QID" kind=sweep "root=$REPO" slug=foo/bar loc=sweep \
    engine=claude "queued=$(date +%Y-%m-%dT%H:%M:%S)" crashes=0 cont=2 "cap_day=$(date +%Y-%m-%d)" \
    skip_files=shared.txt base=main
  ST="$FI_AF_ST"
  "$FI_BIN" autofix run "$QID" --engine claude
  grep -q '^result=shipped: PR #[0-9]*, 3 fixed' "$ST/done/$QID"
  grep -q "^src/f2.sh:1	skipped	.*	touches shared.txt (file in an earlier batch's PR)$" "$ST/sweeps/$QID.outcomes"
  br="$(sed -n 's/^branch=//p' "$ST/done/$QID")"
  [ -z "$(git -C "$TMP/remote.git" log --format=%H "main..$br" -- shared.txt)" ]
  [ "$(git -C "$TMP/remote.git" log --format=%s "main..$br" | grep -c '^fix: ')" = 3 ]
  # The entry is untouched on the ledger: not failed, not annotated.
  grep -q 'f2 subtracts one (fix: medium)$' docs/found-issues.md
  grep -q '1 skipped' "$FI_AF_RUNS/$QID.pr-body.md"
}

@test "sweep: a full batch closes before an entry that does not parse, whatever FE_path held" {
  fi_af_sweep_fixture 2
  source "$FI_BIN"; fi_af_context
  mkdir -p "$FI_AF_ST/sweeps"
  e1='- [open] 2026-10-01 src/f1.sh:1 — f1 subtracts one (fix: medium)'
  printf '%s\nnot an entry line\n' "$e1" > "$FI_AF_ST/sweeps/b1.entries"
  git config found-issues.autofix.sweepBatch 1
  AFI_fixed=1 AFI_cur=2 AFI_entry="$e1" AFI_id=b1
  FE_path=src/f1.sh
  run _fi_af_sweep_batch_closes b1
  [ "$status" -eq 0 ]
}
