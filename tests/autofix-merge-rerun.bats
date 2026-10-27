#!/usr/bin/env bats
# Ledger lib/autofix-ship.sh:511 (seen on ByteTechSoftwares/sayciao#320,
# 2026-10-24): merge-when-green gave up on the first failed check, so a
# one-off CI infrastructure failure (an image pull rate limit) stranded the
# fix PR for good. Now the head's failed GitHub Actions runs are re-run once
# (after two red reads of the same head) and the watch goes on; a second
# failure on the same head stops as before.

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp
  export PATH="$TEST_REPO_ROOT/bin:$PATH" FOUND_ISSUES_CACHE_DIR="$TMP/cache"
  fi_af_fixture
  export GH_MOCK_TRACE="$TMP/gh.trace"; : >"$GH_MOCK_TRACE"
  export FOUND_ISSUES_AUTOFIX_MERGE_POLLS=10 FOUND_ISSUES_AUTOFIX_MERGE_SLEEP=0 FOUND_ISSUES_AUTOFIX_GUARD_SLEEP=0
  export SEQ_COUNT="$TMP/seq.count" SEQ_STATES="$TMP/seq.states" RUN_COUNT="$TMP/run.count" FOUND_ISSUES_AUTOFIX_RERUN_SETTLE=0
  mkdir -p "$TMP/seqbin"
  # gh whose PR view walks SEQ_STATES, one line per poll: "<rollup> <headsha>"
  # with rollup fail|pending|green|merged; the last line repeats.
  cat >"$TMP/seqbin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_MOCK_TRACE"
jq_filter=""; prev=""
for a in "$@"; do [[ "$prev" == --jq ]] && jq_filter="$a"; prev="$a"; done
case "$1 $2" in
  "pr view")
    c=0; [[ -f "$SEQ_COUNT" ]] && c="$(cat "$SEQ_COUNT")"
    c=$((c + 1)); printf '%s' "$c" >"$SEQ_COUNT"
    line="$(sed -n "${c}p" "$SEQ_STATES")"; [[ -n "$line" ]] || line="$(tail -1 "$SEQ_STATES")"
    read -r roll sha <<<"$line"
    st=OPEN; ck='[]'
    case "$roll" in
      fail) ck='[{"conclusion":"FAILURE","status":"COMPLETED"},{"conclusion":"SUCCESS","status":"COMPLETED"}]' ;;
      pending) ck='[{"conclusion":"","status":"IN_PROGRESS"},{"conclusion":"SUCCESS","status":"COMPLETED"}]' ;;
      green) ck='[{"conclusion":"SUCCESS","status":"COMPLETED"}]' ;;
      merged) st=MERGED ;;
    esac
    printf '{"state":"%s","mergeable":"MERGEABLE","baseRefName":"main","headRefName":"x","headRefOid":"%s","statusCheckRollup":%s}' "$st" "${sha:-aaaa}" "$ck" | jq -r "$jq_filter"
    ;;
  "run list")
    # RUN_IDS: "<id>[:<status>:<conclusion>:<workflow>] ..." (default a
    # completed failure of workflow wf<id>); RUN_STATES, when set, is a file
    # with one RUN_IDS value per call (the last repeats).
    ids="${RUN_IDS:-}"
    if [[ -n "${RUN_STATES:-}" ]]; then
      rc=0; [[ -f "$RUN_COUNT" ]] && rc="$(cat "$RUN_COUNT")"; rc=$((rc + 1)); printf '%s' "$rc" >"$RUN_COUNT"
      ids="$(sed -n "${rc}p" "$RUN_STATES")"; [[ -n "$ids" ]] || ids="$(tail -1 "$RUN_STATES")"
    fi
    out=""
    for t in $ids; do
      IFS=: read -r id rs rcn wf <<<"$t"
      [[ "$t" == *:* ]] || rcn=failure
      out+="$(printf '{"databaseId":%s,"status":"%s","conclusion":"%s","workflowName":"%s"},' "$id" "${rs:-completed}" "$rcn" "${wf:-wf$id}")"
    done
    printf '[%s]' "${out%,}" | jq -r "$jq_filter"
    ;;
  "run rerun") exit "${RERUN_RC:-0}" ;;
  "pr merge") exit 0 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$TMP/seqbin/gh"
  export PATH="$TMP/seqbin:$PATH"
}
teardown() { fi_teardown_tmp; }

states() { printf '%s\n' "$@" >"$SEQ_STATES"; }
reruns() { grep -c '^run rerun' "$GH_MOCK_TRACE" || true; }

@test "mwg rerun: a failed check is re-run once and the PR merges when it turns green" {
  states "fail aaaa" "fail aaaa" "pending aaaa" "green aaaa"
  export RUN_IDS="101 102"
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 0 ]
  [[ "$output" == *"re-running"* ]]
  grep -q '^run list --repo foo/bar --commit aaaa' "$GH_MOCK_TRACE"
  grep -q '^run rerun 101 --failed --repo foo/bar$' "$GH_MOCK_TRACE"
  grep -q '^run rerun 102 --failed --repo foo/bar$' "$GH_MOCK_TRACE"
  grep -q '^pr merge 7 --squash --repo foo/bar$' "$GH_MOCK_TRACE"
}

@test "mwg rerun: a second failure on the same head stops the watch, with one re-run only" {
  states "fail aaaa" "fail aaaa" "pending aaaa" "fail aaaa"
  export RUN_IDS="101"
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 1 ]
  [[ "$output" == *"checks failed"* ]]
  [ "$(reruns)" -eq 1 ]
  ! grep -q '^pr merge' "$GH_MOCK_TRACE" || false
}

@test "mwg rerun: the stale red read right after the re-run is not a second failure" {
  states "fail aaaa" "fail aaaa" "fail aaaa" "pending aaaa" "green aaaa"
  export RUN_IDS="101" FOUND_ISSUES_AUTOFIX_RERUN_SETTLE=120
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 0 ]
  [ "$(reruns)" -eq 1 ]
  grep -q '^pr merge 7 --squash --repo foo/bar$' "$GH_MOCK_TRACE"
}

@test "mwg rerun: checks that never leave red after the re-run stop the watch" {
  states "fail aaaa"
  export RUN_IDS="101"
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 1 ]
  [[ "$output" == *"checks failed"* ]]
  [ "$(reruns)" -eq 1 ]
  [ "$(cat "$SEQ_COUNT")" -lt 10 ]
}

@test "mwg rerun: no failed Actions run to re-run stops at the first failure" {
  states "fail aaaa" "fail aaaa" "green aaaa"
  export RUN_IDS=""
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 1 ]
  [[ "$output" == *"checks failed"* ]]
  [ "$(reruns)" -eq 0 ]
}

@test "mwg rerun: a re-run gh refuses stops at the first failure" {
  states "fail aaaa" "fail aaaa" "green aaaa"
  export RUN_IDS="101" RERUN_RC=1
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 1 ]
  [[ "$output" == *"checks failed"* ]]
  ! grep -q '^pr merge' "$GH_MOCK_TRACE" || false
}

@test "mwg rerun: FOUND_ISSUES_AUTOFIX_RERUN_CHECKS=off keeps the old stop" {
  states "fail aaaa" "green aaaa"
  export RUN_IDS="101" FOUND_ISSUES_AUTOFIX_RERUN_CHECKS=off
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 1 ]
  [[ "$output" == *"checks failed"* ]]
  ! grep -q '^run ' "$GH_MOCK_TRACE" || false
}

@test "mwg rerun: a new head after a re-run gets its own re-run" {
  states "fail aaaa" "fail aaaa" "pending aaaa" "fail bbbb" "fail bbbb" "pending bbbb" "green bbbb"
  export RUN_IDS="101"
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 0 ]
  [ "$(reruns)" -eq 2 ]
  grep -q '^run list --repo foo/bar --commit bbbb' "$GH_MOCK_TRACE"
}

@test "mwg rerun: the guard re-runs a failed check once and still leaves on MERGED" {
  states "fail aaaa" "fail aaaa" "fail aaaa" "pending aaaa" "fail aaaa" "fail aaaa" "merged aaaa"
  export RUN_IDS="101" FOUND_ISSUES_AUTOFIX_GUARD_POLLS=10
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar --guard
  [ "$status" -eq 0 ]
  [[ "$output" == *"already MERGED"* ]]
  [ "$(reruns)" -eq 1 ]
  ! grep -q '^pr merge' "$GH_MOCK_TRACE" || false
}

# Live e2e 2026-10-27 (AltDoug/fi-rerun-e2e PR #2): the first poll after a
# push still reported the previous head as red, and its run was re-run.
@test "mwg rerun: a red read of a head that is then replaced is never re-run" {
  states "fail aaaa" "pending bbbb" "green bbbb"
  export RUN_IDS="101"
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 0 ]
  [ "$(reruns)" -eq 0 ]
  grep -q '^pr merge 7 --squash --repo foo/bar$' "$GH_MOCK_TRACE"
}

# /code-review 2026-10-27: a run with one failed job while its other jobs
# still run has no conclusion yet, so there was nothing to re-run.
@test "mwg rerun: a red read while a run is still going waits for it, then re-runs" {
  states "fail aaaa" "fail aaaa" "fail aaaa" "pending aaaa" "green aaaa"
  printf '%s\n' "101:in_progress::ci" "101:completed:failure:ci" >"$TMP/runs"
  export RUN_STATES="$TMP/runs"
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 0 ]
  [ "$(reruns)" -eq 1 ]
  grep -q '^run rerun 101 --failed --repo foo/bar$' "$GH_MOCK_TRACE"
  grep -q '^pr merge 7 --squash --repo foo/bar$' "$GH_MOCK_TRACE"
}

@test "mwg rerun: an older cancelled run of the same workflow is not re-run" {
  states "fail aaaa" "fail aaaa" "pending aaaa" "green aaaa"
  export RUN_IDS="100:completed:cancelled:ci 101:completed:failure:ci"
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 0 ]
  [ "$(reruns)" -eq 1 ]
  grep -q '^run rerun 101 --failed --repo foo/bar$' "$GH_MOCK_TRACE"
  ! grep -q '^run rerun 100 ' "$GH_MOCK_TRACE" || false
}

@test "mwg rerun: the guard tries a refused re-run once per head, not every poll" {
  states "fail aaaa"
  export RUN_IDS="101" RERUN_RC=1 FOUND_ISSUES_AUTOFIX_GUARD_POLLS=8
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar --guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"still pending after 8 checks"* ]]
  [ "$(grep -c '^run list' "$GH_MOCK_TRACE")" -eq 1 ]
  [ "$(reruns)" -eq 1 ]
}

@test "mwg rerun: a branch name with a pipe does not shift the head sha" {
  states "fail aaaa" "fail aaaa" "pending aaaa" "green aaaa"
  export RUN_IDS="101"
  sed -i.bak 's/"headRefName":"x"/"headRefName":"fix|x"/' "$TMP/seqbin/gh" && rm -f "$TMP/seqbin/gh.bak"
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 0 ]
  grep -q '^run list --repo foo/bar --commit aaaa ' "$GH_MOCK_TRACE"
}
