#!/usr/bin/env bats
# Ledger lib/autofix-ship.sh:329 (batch 4): a fix PR whose auto-merge was
# armed also gets a merge-when-green --guard watcher, so a ledger-only
# conflict (GitHub never fires an armed auto-merge on a CONFLICTING PR) is
# resolved. The guard never merges itself and exits once the PR merges.

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_fixture; fi_use_standins
  # The CLI under test, never a plugin-cache copy that may be on PATH.
  export PATH="$TEST_REPO_ROOT/bin:$PATH"
  export GH_MOCK_TRACE="$TMP/gh.trace" FOUND_ISSUES_AUTOFIX_MERGE_SLEEP=0 FOUND_ISSUES_AUTOFIX_MERGE_POLLS=3 FOUND_ISSUES_AUTOFIX_GUARD_POLLS=3
  export GH_MOCK_PR_VIEW=$'7\t{"number":7,"state":"OPEN","statusCheckRollup":[]}'
}
teardown() { fi_teardown_tmp; }

# A gh that reports the PR OPEN with <n> pending-check looks first, then MERGED.
seq_gh() {
  local n="$1"
  mkdir -p "$TMP/seqbin"
  cat >"$TMP/seqbin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_MOCK_TRACE"
if [[ "$1 $2" == "pr view" ]]; then
  c=0; [[ -f "$SEQ_COUNT" ]] && c="$(cat "$SEQ_COUNT")"
  c=$((c + 1)); printf '%s' "$c" >"$SEQ_COUNT"
  jq_filter=""; prev=""
  for a in "$@"; do [[ "$prev" == --jq ]] && jq_filter="$a"; prev="$a"; done
  if (( c > SEQ_OPEN_LOOKS )); then st=MERGED; else st=OPEN; fi
  printf '{"state":"%s","mergeable":"MERGEABLE","baseRefName":"main","headRefName":"x","statusCheckRollup":[{"conclusion":"","status":"IN_PROGRESS"}]}' "$st" | jq -r "$jq_filter"
  exit 0
fi
exec "$SEQ_SHIM" "$@"
SH
  chmod +x "$TMP/seqbin/gh"
  export SEQ_SHIM="$TEST_REPO_ROOT/tests/bin-shims/gh" SEQ_COUNT="$TMP/seq.count" SEQ_OPEN_LOOKS="$n"
  export PATH="$TMP/seqbin:$PATH"
}

@test "guard: an armed auto-merge also spawns a merge-when-green guard that exits once the PR is merged" {
  git branch --show-current >/dev/null
  fi_af_queue_fixture; ST="$FI_AF_ST"
  "$FI_BIN" autofix claim "$ID" >/dev/null
  WT="$REPO/.claude/worktrees/fi-autofix-$ID"
  sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"
  "$FI_BIN" autofix verify "$ID" >/dev/null
  export GH_MOCK_PR_VIEW=$'7\t{"number":7,"state":"MERGED","statusCheckRollup":[]}'
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -eq 0 ]
  grep -q '^pr merge 7 --auto --squash --repo foo/bar$' "$GH_MOCK_TRACE"
  # the detached guard looked at the PR and left because it was merged
  for _ in $(seq 1 40); do grep -q 'already MERGED' "$FI_AF_RUNS/spawn.log" 2>/dev/null && break; sleep 0.25; done
  grep -q 'PR #7 is already MERGED' "$FI_AF_RUNS/spawn.log"
  # the guard never merged by itself: only the armed --auto call exists
  ! grep -q '^pr merge 7 --squash' "$GH_MOCK_TRACE" || false
  grep -q 'merge: auto' "$FI_AF_RUNS/$ID.log"
}

@test "guard: --guard on a green PR waits and never calls gh pr merge" {
  export GH_MOCK_PR_VIEW=$'7\t{"state":"OPEN","statusCheckRollup":[{"conclusion":"SUCCESS"}]}'
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar --guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"still pending after 3 checks"* ]]
  ! grep -q '^pr merge' "$GH_MOCK_TRACE" || false
}

@test "guard: --guard on a check-less PR never merges it either" {
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar --guard
  [ "$status" -eq 1 ]
  ! grep -q '^pr merge' "$GH_MOCK_TRACE" || false
}

@test "guard: --guard exits 0 as soon as the PR merges underneath it" {
  seq_gh 2
  export FOUND_ISSUES_AUTOFIX_GUARD_POLLS=10
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar --guard
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #7 is already MERGED"* ]]
  [ "$(cat "$SEQ_COUNT")" -eq 3 ]
  ! grep -q '^pr merge' "$GH_MOCK_TRACE" || false
}

@test "guard: --guard exits 0 on a closed PR" {
  export GH_MOCK_PR_VIEW=$'7\t{"state":"CLOSED","statusCheckRollup":[]}'
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar --guard
  [ "$status" -eq 0 ]
  [[ "$output" == *"already CLOSED"* ]]
}

@test "guard: --guard watches through failed checks until its horizon (review c)" {
  export GH_MOCK_PR_VIEW=$'7\t{"state":"OPEN","statusCheckRollup":[{"conclusion":"FAILURE"}]}'
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar --guard
  [ "$status" -eq 1 ]
  [[ "$output" != *"checks failed"* ]] || false
  [[ "$output" == *"still pending after 3 checks"* ]]
}

@test "guard: a bad flag after --repo is a usage error" {
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage"* ]]
}

@test "guard: --guard resolves a ledger-only conflict without merging the PR" {
  printf -- '- [open] 2026-10-02 src/a.sh:1 — a breaks (fix: small)\n- [open] 2026-10-03 src/b.sh:1 — b breaks (fix: small)\n' >>docs/found-issues.md
  git commit -qam "two more entries" && git push -q origin main
  HEADB="fi/autofix/x"
  git switch -q -c "$HEADB"
  printf 'a() { :; }\n' >src/a.sh && git add src/a.sh && git commit -qm "fix: a breaks"
  sed -i.bak 's/a breaks (fix: small)$/a breaks (fix: small) (PR: foo\/bar#7)/' docs/found-issues.md && rm -f docs/found-issues.md.bak
  git commit -qam "docs(found-issues): annotate src/a.sh:1 with PR 7" && git push -q -u origin "$HEADB"
  git switch -q main
  sed -i.bak 's/b breaks (fix: small)$/b breaks (fix: small) (PR: foo\/bar#6)/' docs/found-issues.md && rm -f docs/found-issues.md.bak
  printf 'b() { :; }\n' >src/b.sh && git add src/b.sh
  git commit -qam "fix: b breaks (#6)" && git push -q origin main
  # A gh whose armed PR is CONFLICTING until its branch contains main.
  mkdir -p "$TMP/dynbin"
  cat >"$TMP/dynbin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_MOCK_TRACE"
if [[ "$1 $2" == "pr view" ]]; then
  if git -C "$DYN_REMOTE" merge-base --is-ancestor main "$DYN_HEAD" 2>/dev/null; then m=MERGEABLE; else m=CONFLICTING; fi
  jq_filter=""; prev=""
  for a in "$@"; do [[ "$prev" == --jq ]] && jq_filter="$a"; prev="$a"; done
  printf '{"state":"OPEN","mergeable":"%s","baseRefName":"main","headRefName":"%s","statusCheckRollup":[{"conclusion":"","status":"IN_PROGRESS"}]}' "$m" "$DYN_HEAD" | jq -r "$jq_filter"
  exit 0
fi
exec "$DYN_SHIM" "$@"
SH
  chmod +x "$TMP/dynbin/gh"
  export DYN_SHIM="$TEST_REPO_ROOT/tests/bin-shims/gh" DYN_REMOTE="$TMP/remote.git" DYN_HEAD="$HEADB"
  export PATH="$TMP/dynbin:$PATH"
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar --guard
  [ "$status" -eq 1 ]   # still pending at the end of the polls, never merged by the guard
  [[ "$output" == *"merged main into $HEADB"* ]]
  git -C "$TMP/remote.git" merge-base --is-ancestor main "$HEADB"
  git -C "$TMP/remote.git" show "$HEADB:docs/found-issues.md" | grep -q 'a breaks (fix: small) (PR: foo/bar#7)$'
  git -C "$TMP/remote.git" show "$HEADB:docs/found-issues.md" | grep -q 'b breaks (fix: small) (PR: foo/bar#6)$'
  ! grep -q '^pr merge' "$GH_MOCK_TRACE" || false
}
