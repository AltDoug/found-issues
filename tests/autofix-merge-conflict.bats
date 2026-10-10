#!/usr/bin/env bats
# 3.6.1 (ledger lib/autofix-ship.sh:231): merge-when-green merges the base
# into a PR whose only conflict is the ledger, instead of giving up.

load 'helpers'
load 'autofix-helpers'

# A gh that answers `pr view` from the fixture's remote: CONFLICTING (or, with
# GH_DYN_MERGEABLE set, that value) until the PR branch contains main, and a
# `pr merge` that fails like GitHub's on a branch that does not. The rest goes
# to the shared shim.
dyn_gh() {
  mkdir -p "$TMP/dynbin"
  cat >"$TMP/dynbin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_MOCK_TRACE"
if [[ "$1 $2" == "pr view" || "$1 $2" == "pr merge" ]]; then
  if [[ -z "${GH_DYN_ALWAYS_CONFLICT:-}" ]] && git -C "$DYN_REMOTE" merge-base --is-ancestor main "$DYN_HEAD" 2>/dev/null; then m=MERGEABLE; else m=CONFLICTING; fi
fi
if [[ "$1 $2" == "pr view" ]]; then
  jq_filter=""; prev=""
  for a in "$@"; do [[ "$prev" == --jq ]] && jq_filter="$a"; prev="$a"; done
  [[ "$m" == CONFLICTING && -n "${GH_DYN_MERGEABLE:-}" ]] && m="$GH_DYN_MERGEABLE"
  printf '{"state":"OPEN","mergeable":"%s","baseRefName":"main","headRefName":"%s","statusCheckRollup":[]}' "$m" "$DYN_HEAD" | jq -r "$jq_filter"
  exit 0
fi
if [[ "$1 $2" == "pr merge" && "$m" == CONFLICTING ]]; then
  echo "${GH_DYN_MERGE_ERR:-GraphQL: Pull Request has merge conflicts (mergePullRequest)}" >&2; exit 1
fi
exec "$DYN_SHIM" "$@"
EOF
  chmod +x "$TMP/dynbin/gh"
  export DYN_SHIM="$TEST_REPO_ROOT/tests/bin-shims/gh" DYN_REMOTE="$TMP/remote.git" DYN_HEAD="fi/autofix/x"
  export PATH="$TMP/dynbin:$PATH"
}

setup() {
  fi_setup_tmp; fi_af_fixture
  export GH_MOCK_TRACE="$TMP/gh.trace" FOUND_ISSUES_AUTOFIX_MERGE_SLEEP=0 FOUND_ISSUES_AUTOFIX_MERGE_POLLS=6
  printf -- '- [open] 2026-10-02 src/a.sh:1 — a breaks (fix: small)\n- [open] 2026-10-03 src/b.sh:1 — b breaks (fix: small)\n' >>docs/found-issues.md
  git commit -qam "two more entries" && git push -q origin main
  dyn_gh
  # The fix PR: a fix commit, then its annotation on the a.sh entry.
  git switch -q -c "$DYN_HEAD"
  printf 'a() { :; }\n' >src/a.sh && git add src/a.sh && git commit -qm "fix: a breaks"
  sed -i.bak 's/a breaks (fix: small)$/a breaks (fix: small) (PR: foo\/bar#7)/' docs/found-issues.md && rm -f docs/found-issues.md.bak
  git commit -qam "docs(found-issues): annotate src/a.sh:1 with PR 7" && git push -q -u origin "$DYN_HEAD"
  # Meanwhile another fix PR merged: it annotated the adjacent b.sh entry.
  git switch -q main
  sed -i.bak 's/b breaks (fix: small)$/b breaks (fix: small) (PR: foo\/bar#6)/' docs/found-issues.md && rm -f docs/found-issues.md.bak
  printf 'b() { :; }\n' >src/b.sh && git add src/b.sh
  git commit -qam "fix: b breaks (#6)" && git push -q origin main
}
teardown() { fi_teardown_tmp; }

remote_ledger() { git -C "$TMP/remote.git" show "$DYN_HEAD:docs/found-issues.md"; }

@test "merge-when-green: a ledger-only conflict is merged with both annotations kept, then the PR merges" {
  run git -C "$TMP/remote.git" merge-tree --write-tree main "$DYN_HEAD"
  [ "$status" -eq 1 ]   # the fixture really conflicts, on the ledger alone
  [[ "$output" == *"CONFLICT (content): Merge conflict in docs/found-issues.md"* ]]
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 0 ]
  [[ "$output" == *"merged PR #7"* ]]
  [[ "$output" == *"ledger"* ]]
  git -C "$TMP/remote.git" merge-base --is-ancestor main "$DYN_HEAD"
  remote_ledger | grep -qx -- '- \[open\] 2026-10-02 src/a.sh:1 — a breaks (fix: small) (PR: foo/bar#7)'
  remote_ledger | grep -qx -- '- \[open\] 2026-10-03 src/b.sh:1 — b breaks (fix: small) (PR: foo/bar#6)'
  ! remote_ledger | grep -q '^[<=>]\{7\}' || false
  [ "$(remote_ledger | grep -c '^- ')" -eq 3 ]
  git -C "$TMP/remote.git" show "$DYN_HEAD:src/a.sh" | grep -q 'a()'
  git -C "$TMP/remote.git" show "$DYN_HEAD:src/b.sh" | grep -q 'b()'
  grep -q '^pr merge 7 --squash --repo foo/bar$' "$GH_MOCK_TRACE"
  # the temporary worktree is gone
  [ "$(git worktree list | wc -l | tr -d ' ')" -eq 1 ]
}

@test "merge-when-green: a merge GitHub refuses for conflicts (mergeable not yet known) is resolved and retried" {
  export GH_DYN_MERGEABLE=UNKNOWN
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 0 ]
  [[ "$output" == *"merged PR #7"* ]]
  git -C "$TMP/remote.git" merge-base --is-ancestor main "$DYN_HEAD"
  remote_ledger | grep -q 'a breaks (fix: small) (PR: foo/bar#7)$'
  remote_ledger | grep -q 'b breaks (fix: small) (PR: foo/bar#6)$'
}

@test "merge-when-green: a conflict outside the ledger is not touched and the PR is not merged" {
  git switch -q main
  printf 'a() { echo base; }\n' >src/a.sh && git add src/a.sh && git commit -qm "base edits a" && git push -q origin main
  before="$(git -C "$TMP/remote.git" rev-parse "$DYN_HEAD")"
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 1 ]
  [[ "$output" == *"outside the ledger"*"src/a.sh"* ]]
  [ "$(git -C "$TMP/remote.git" rev-parse "$DYN_HEAD")" = "$before" ]
  ! grep -q '^pr merge 7 --squash' "$GH_MOCK_TRACE" || false
  [ "$(git worktree list | wc -l | tr -d ' ')" -eq 1 ]
}

@test "merge-when-green: a PR whose ledger change is more than its own annotation is not auto-resolved" {
  git switch -q "$DYN_HEAD"
  sed -i.bak 's/a breaks (fix: small)/a really breaks (fix: small)/' docs/found-issues.md && rm -f docs/found-issues.md.bak
  git commit -qam "reword" && git push -q origin "$DYN_HEAD"
  before="$(git -C "$TMP/remote.git" rev-parse "$DYN_HEAD")"
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 1 ]
  [[ "$output" == *"more than its"*"annotation"* ]]
  [ "$(git -C "$TMP/remote.git" rev-parse "$DYN_HEAD")" = "$before" ]
  ! grep -q '^pr merge 7 --squash' "$GH_MOCK_TRACE" || false
}

@test "merge-when-green: gh's own refusal wording for a conflicted PR is resolved too" {
  export GH_DYN_MERGEABLE=UNKNOWN GH_DYN_MERGE_ERR='X Pull request foo/bar#7 is not mergeable: the merge commit cannot be cleanly created.'
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 0 ]
  [[ "$output" == *"merged PR #7"* ]]
  remote_ledger | grep -q 'a breaks (fix: small) (PR: foo/bar#7)$'
}

@test "merge-when-green: an annotated entry that changed on the base is not resolved, so no annotation is lost" {
  git switch -q main
  sed -i.bak 's/src\/a.sh:1 — a breaks/src\/a.sh:2 — a breaks/' docs/found-issues.md && rm -f docs/found-issues.md.bak
  git commit -qam "re-anchor a" && git push -q origin main
  before="$(git -C "$TMP/remote.git" rev-parse "$DYN_HEAD")"
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 1 ]
  [[ "$output" == *"changed on main"*"cannot be carried over"* ]]
  [ "$(git -C "$TMP/remote.git" rev-parse "$DYN_HEAD")" = "$before" ]
  ! grep -q '^pr merge 7 --squash' "$GH_MOCK_TRACE" || false
}

@test "merge-when-green: a checkout whose origin is another repo resolves nothing" {
  before="$(git -C "$TMP/remote.git" rev-parse "$DYN_HEAD")"
  run "$FI_BIN" autofix merge-when-green 7 --repo someone/else
  [ "$status" -eq 1 ]
  [[ "$output" == *"origin is foo/bar, not someone/else"* ]]
  [ "$(git -C "$TMP/remote.git" rev-parse "$DYN_HEAD")" = "$before" ]
}

@test "merge-when-green: a stale CONFLICTING after the update is not another update" {
  export GH_DYN_ALWAYS_CONFLICT=1 FOUND_ISSUES_AUTOFIX_MERGE_POLLS=6
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 1 ]
  [[ "$output" == *"still pending after 6 checks"* ]]
  [[ "$output" != *"after 3 updates"* ]]
  [ "$(grep -c 'merged main into' <<<"$output")" -eq 1 ]
  git -C "$TMP/remote.git" merge-base --is-ancestor main "$DYN_HEAD"
}
