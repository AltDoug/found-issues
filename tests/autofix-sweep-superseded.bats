#!/usr/bin/env bats
# 3.9.1 (ledger lib/autofix-sweep.sh:747): the superseded check of 3.9.0
# (fi_af_superseded, spot runs only) for sweeps: an entry whose cited code a
# live session changed on the base is skipped before its fixer, and a fixed
# one is dropped from the commit stack before ship.

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_sweep_fixture 4; fi_use_standins
  export GH_MOCK_TRACE="$TMP/gh.trace" GH_MOCK_PR_CREATE_URL=https://github.com/foo/bar/pull/9
  export GH_MOCK_PR_VIEW=$'9\t{"number":9,"state":"OPEN","statusCheckRollup":[]}'
  ST="$FOUND_ISSUES_STATE_DIR/autofix/foo__bar"
  BR=""
}
teardown() { fi_teardown_tmp; }

# The stand-in fixer fixes whichever fN/calc entry its prompt names, with its
# own test; when its prompt names <trigger>, a live session first pushes a
# change to each <file> on origin/main (once).
sweep_edit_bumping() {
  local trigger="$1"; shift
  {
    printf '[ -f "%s/bumped" ] && exit 0\n: >"%s/bumped"\n' "$TMP" "$TMP"
    printf 'rm -rf "%s/other-clone"\ngit clone -q "%s/remote.git" "%s/other-clone"\n' "$TMP" "$TMP" "$TMP"
    for f in "$@"; do printf 'printf "# live session\\n" >>"%s/other-clone/%s"\n' "$TMP" "$f"; done
    printf 'git -C "%s/other-clone" add -A\n' "$TMP"
    printf 'git -C "%s/other-clone" -c user.email=o@x -c user.name=o commit -qm "live session"\n' "$TMP"
    printf 'git -C "%s/other-clone" push -q origin main\n' "$TMP"
  } >"$TMP/bump.sh"
  export FI_STANDIN_EDIT='case "$FI_STANDIN_PROMPT" in *"'"$trigger"'"*) bash "'"$TMP"'/bump.sh" ;; esac; mkdir -p tests; case "$FI_STANDIN_PROMPT" in *"src/calc.sh:1"*) sed -i.bak "s/ - / + /" src/calc.sh; rm -f src/calc.sh.bak; printf "[ \"\$(add 2 3)\" = 5 ]\n" >> tests/t_calc.sh ;; esac; for f in src/f*.sh; do n="${f#src/f}"; n="${n%.sh}"; case "$FI_STANDIN_PROMPT" in *"src/f$n.sh:1"*) sed -i.bak "s/- 1/+ 0/" "$f"; rm -f "$f.bak"; printf "[ \"\$(f%s 2)\" = 2 ]\n" "$n" >> tests/t_f$n.sh ;; esac; done'
}

sweep_queue() {
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  SID="$(printf '%s\n' "$output" | sed -n 's/^AUTOFIX-SWEEP-DUE //p')"
  [ -n "$SID" ]
  BR="fi/sweep/${SID%%-*}-${SID##*-}"
}

@test "sweep superseded: a fixed entry whose file changed on the base is dropped before ship" {
  sweep_edit_bumping src/f4.sh:1 src/f1.sh
  sweep_queue
  run "$FI_BIN" autofix run "$SID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '^result=shipped: PR #9, 4 fixed' "$ST/done/$SID"
  grep -Eq '^src/f1\.sh:1	skipped	.*	superseded: src/f1\.sh changed on main since [0-9a-f]{7}$' "$ST/sweeps/$SID.outcomes"
  # The branch carries no commit for f1 and the four others, each once.
  [ -z "$(git -C "$TMP/remote.git" log --format=%H "main..$BR" -- src/f1.sh)" ]
  [ "$(git -C "$TMP/remote.git" log --format=%s "main..$BR" | grep -c '^fix: ')" = 4 ]
  # The PR closes the four, not f1, and its table says why f1 is not in it.
  [ "$(git -C "$TMP/remote.git" show "$BR:docs/found-issues.md" | grep -c '(PR: foo/bar#9)')" = 3 ]
  ! git -C "$TMP/remote.git" show "$BR:docs/found-issues.md" | grep -F 'f1 subtracts one' | grep -q '(PR: ' || false
  grep -q 'found-issues sweep (4 entries)' "$GH_MOCK_TRACE"
  source "$FI_BIN"; fi_af_context
  grep -q '| `src/f1.sh:1` | skipped | superseded: src/f1.sh changed on main' "$FI_AF_RUNS/$SID.pr-body.md"
}

@test "sweep superseded: an entry whose file changed before its turn is skipped without a fixer" {
  sweep_edit_bumping src/f1.sh:1 src/f3.sh
  sweep_queue
  run "$FI_BIN" autofix run "$SID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '^result=shipped: PR #9, 4 fixed' "$ST/done/$SID"
  grep -Eq '^src/f3\.sh:1	skipped	.*	superseded: src/f3\.sh changed on main since [0-9a-f]{7}$' "$ST/sweeps/$SID.outcomes"
  # No fixer or verifier prompt ever named the skipped entry.
  ! grep -q 'src/f3.sh:1' "$FI_STANDIN_TRACE" || false
  grep -F 'f3 subtracts one' docs/found-issues.md | grep -q '^- \[open\]'
  ! grep -F 'f3 subtracts one' docs/found-issues.md | grep -q 'autofix-failed' || false
}

@test "sweep superseded: every fixed entry superseded ends stale with no PR" {
  sweep_edit_bumping src/calc.sh:1 src/f1.sh src/f2.sh src/f3.sh src/f4.sh src/calc.sh
  sweep_queue
  run "$FI_BIN" autofix run "$SID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '^result=stale: sweep fixed nothing (5 skipped)' "$ST/done/$SID"
  ! grep -q '^pr create' "$GH_MOCK_TRACE" 2>/dev/null || false
  [ "$(grep -c '(PR: ' docs/found-issues.md)" = 0 ]
}

@test "sweep superseded: a later fix that needs a dropped one is dropped with it" {
  # Two entries in one file: g.sh:1 (superseded) and g.sh:9 (far from the
  # live change), whose fix edits line 2, next to g.sh:1's fix.
  for i in 1 2 3 4 5 6 7 8 9 10; do printf 'g%s=%s\n' "$i" "$i"; done > src/g.sh
  printf -- '- [open] 2026-10-05 src/g.sh:1 — g1 is wrong (fix: medium)\n' >> docs/found-issues.md
  printf -- '- [open] 2026-10-06 src/g.sh:9 — g9 is wrong (fix: medium)\n' >> docs/found-issues.md
  git add -A && git commit -qm g && git push -q origin main
  sweep_edit_bumping src/g.sh:9 src/g.sh
  export FI_STANDIN_EDIT="$FI_STANDIN_EDIT"'; case "$FI_STANDIN_PROMPT" in *"src/g.sh:1 "*) sed -i.bak "s/^g1=1$/g1=one/" src/g.sh; rm -f src/g.sh.bak ;; *"src/g.sh:9 "*) sed -i.bak "s/^g2=2$/g2=two/" src/g.sh; rm -f src/g.sh.bak ;; esac'
  # The live change lands at the top of g.sh, within reach of g.sh:1 only.
  cat >"$TMP/bump.sh" <<EOF
[ -f "$TMP/bumped" ] && exit 0
: >"$TMP/bumped"
rm -rf "$TMP/other-clone"
git clone -q "$TMP/remote.git" "$TMP/other-clone"
{ printf '# live\n'; cat "$TMP/other-clone/src/g.sh"; } >"$TMP/g.new"
mv "$TMP/g.new" "$TMP/other-clone/src/g.sh"
git -C "$TMP/other-clone" -c user.email=o@x -c user.name=o commit -qam "live session"
git -C "$TMP/other-clone" push -q origin main
EOF
  sweep_queue
  run "$FI_BIN" autofix run "$SID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '^result=shipped: PR #9, 5 fixed' "$ST/done/$SID"
  grep -Eq '^src/g\.sh:1	skipped	.*	superseded: src/g\.sh changed on main since [0-9a-f]{7}$' "$ST/sweeps/$SID.outcomes"
  grep -Eq '^src/g\.sh:9	skipped	.*	dropped: does not apply without the superseded fixes$' "$ST/sweeps/$SID.outcomes"
  [ -z "$(git -C "$TMP/remote.git" log --format=%H "main..$BR" -- src/g.sh)" ]
}

@test "sweep superseded: launcher B commands other than next never move past the entry in progress" {
  sweep_queue
  "$FI_BIN" autofix claim "$SID" >/dev/null
  run "$FI_BIN" autofix next "$SID"
  [[ "$output" == "Entry 1/5: "*"src/f1.sh:1"* ]]
  rm -rf "$TMP/other-clone"; git clone -q "$TMP/remote.git" "$TMP/other-clone"
  printf '# live\n' >>"$TMP/other-clone/src/f1.sh"
  git -C "$TMP/other-clone" -c user.email=o@x -c user.name=o commit -qam live
  git -C "$TMP/other-clone" push -q origin main
  # The fixer is still on f1: search and release act on f1, not on f2.
  run "$FI_BIN" autofix search "$SID" --files src
  [ "$status" -eq 0 ]
  run "$FI_BIN" autofix release "$SID" --manual "cannot test"
  [ "$status" -eq 0 ]
  [[ "$output" == "Released src/f1.sh:1 (manual)."* ]]
  # The next hand-out checks f2 normally and serves it.
  run "$FI_BIN" autofix next "$SID"
  [[ "$output" == "Entry 2/5: "*"src/f2.sh:1"* ]]
}

@test "sweep superseded: a rebuilt stack that fails its ship tests ends failed without retries" {
  sweep_edit_bumping src/f4.sh:1 src/f1.sh
  # f2's fix only passes with f1's fix in place (a semantic dependency).
  git config found-issues.autofix.testCommand 'sh test.sh && { [ ! -f tests/t_f2.sh ] || [ -f tests/t_f1.sh ]; }'
  sweep_queue
  run "$FI_BIN" autofix run "$SID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '^result=failed: ship: tests fail after dropping superseded fixes (branch fi/sweep/' "$ST/done/$SID"
  [ ! -f "$ST/queue/$SID" ]
}

@test "sweep superseded: a full batch whose every fix was dropped still queues the next batch" {
  git config found-issues.autofix.sweepBatch 2
  sweep_edit_bumping never-matches src/f1.sh src/f2.sh
  # The live change lands right after f2's commit, before the batch ships.
  printf '#!/bin/sh\ngit log -1 --format=%%s | grep -q "src/f2.sh:1" && env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE bash "%s/bump.sh"\nexit 0\n' "$TMP" > .git/hooks/post-commit
  chmod +x .git/hooks/post-commit
  sweep_queue
  run "$FI_BIN" autofix run "$SID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '^result=stale: sweep fixed nothing (2 skipped)' "$ST/done/$SID"
  source "$FI_BIN"; fi_af_context
  grep -q 'sweep: queued batch 2 as ' "$FI_AF_RUNS/$SID.log"
  # Launcher A drains the continuation in the same run: it fixes the rest.
  c="$(grep -l '^cont=2' "$ST"/done/*)"
  grep -q '^result=shipped: PR #9, 2 fixed' "$c"
}
