#!/usr/bin/env bats
# 3.10.7 (ledger lib/autofix-ship.sh:656): a fix PR cut from a session's
# branch is retargeted to main by GitHub when that branch is squash-merged
# and deleted. The PR then carries the branch's whole pre-squash history, so
# merging main into it conflicts on the ledger with more than the PR's own
# annotation. merge-when-green rebuilds the PR's own change on main instead.

load 'helpers'
load 'autofix-helpers'

# A gh that answers from the fixture: `pr view` reports base main and
# CONFLICTING until the PR branch contains main; `api graphql` reports the
# automatic base change (phase -> main) unless GH_SQ_NO_EVENT is set; `pr list
# --head phase` reports the merged phase PR #5 and its head. The rest goes to
# the shared shim.
sq_gh() {
  mkdir -p "$TMP/sqbin"
  cat >"$TMP/sqbin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_MOCK_TRACE"
jq_filter=""; prev=""
for a in "$@"; do [[ "$prev" == --jq ]] && jq_filter="$a"; prev="$a"; done
if [[ "$1 $2" == "pr view" || "$1 $2" == "pr merge" ]]; then
  if git -C "$SQ_REMOTE" merge-base --is-ancestor main "$SQ_HEAD" 2>/dev/null; then m=MERGEABLE; else m=CONFLICTING; fi
fi
if [[ "$1 $2" == "pr view" ]]; then
  printf '{"state":"OPEN","mergeable":"%s","baseRefName":"main","headRefName":"%s","statusCheckRollup":[]}' "$m" "$SQ_HEAD" | jq -r "$jq_filter"
  exit 0
fi
if [[ "$1 $2" == "pr merge" && "$m" == CONFLICTING ]]; then
  echo "GraphQL: Pull Request has merge conflicts (mergePullRequest)" >&2; exit 1
fi
if [[ "$1 $2" == "api graphql" ]]; then
  if [[ -n "${GH_SQ_NO_EVENT:-}" ]]; then nodes='[]'; else nodes='[{"oldBase":"phase","newBase":"main"}]'; fi
  printf '{"data":{"repository":{"pullRequest":{"timelineItems":{"nodes":%s}}}}}' "$nodes" | jq -r "$jq_filter"
  exit 0
fi
if [[ "$1 $2" == "pr list" && " $* " == *" --head phase "* ]]; then
  printf '[{"number":5,"headRefOid":"%s"}]' "$SQ_OLD_TIP" | jq -r "$jq_filter"
  exit 0
fi
exec "$SQ_SHIM" "$@"
EOF
  chmod +x "$TMP/sqbin/gh"
  export SQ_SHIM="$TEST_REPO_ROOT/tests/bin-shims/gh" SQ_REMOTE="$TMP/remote.git" SQ_HEAD="fi/autofix/x"
  export PATH="$TMP/sqbin:$PATH"
}

setup() {
  fi_setup_tmp; fi_af_fixture
  export GH_MOCK_TRACE="$TMP/gh.trace" FOUND_ISSUES_AUTOFIX_MERGE_SLEEP=0 FOUND_ISSUES_AUTOFIX_MERGE_POLLS=6
  sq_gh
  L=docs/found-issues.md
  printf -- '- [open] 2026-10-02 src/a.sh:1 — a breaks (fix: small)\n- [open] 2026-10-03 src/b.sh:1 — b breaks (fix: small)\n' >>"$L"
  git commit -qam "two more entries" && git push -q origin main
  # The session's branch: its own code and a ledger entry it logged.
  git switch -q -c phase
  printf 'p() { :; }\n' >src/p.sh && git add src/p.sh
  printf -- '- [open] 2026-10-04 src/p.sh:1 — p is new (fix: small)\n' >>"$L"
  git commit -qam "phase work" && git push -q -u origin phase
  # The fix PR, cut from the session's branch: a fix, then its annotation.
  git switch -q -c "$SQ_HEAD"
  printf 'a() { :; }\n' >src/a.sh && git add src/a.sh && git commit -qm "fix: a breaks"
  sed -i.bak 's/a breaks (fix: small)$/a breaks (fix: small) (PR: foo\/bar#7)/' "$L" && rm -f "$L.bak"
  git commit -qam "docs(found-issues): annotate src/a.sh:1 with PR 7" && git push -q -u origin "$SQ_HEAD"
  # The session's PR #5 is squash-merged and its branch deleted (GitHub keeps
  # its head as refs/pull/5/head); main then annotates the adjacent b entry.
  SQ_OLD_TIP="$(git rev-parse phase)"; export SQ_OLD_TIP
  git -C "$TMP/remote.git" update-ref refs/pull/5/head "$SQ_OLD_TIP"
  git switch -q main
  git merge -q --squash phase >/dev/null && git commit -qm "phase work (#5)"
  sed -i.bak 's/b breaks (fix: small)$/b breaks (fix: small) (PR: foo\/bar#6)/' "$L" && rm -f "$L.bak"
  printf 'b() { :; }\n' >src/b.sh && git add src/b.sh
  git commit -qam "fix: b breaks (#6)" && git push -q origin main
  git push -q origin --delete phase
}
teardown() { fi_teardown_tmp; }

remote_ledger() { git -C "$TMP/remote.git" show "$SQ_HEAD:$L"; }

@test "merge-when-green: a fix PR retargeted after its landing branch was squash-merged is rebuilt on main and merges" {
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 0 ]
  [[ "$output" == *"squash-merged"* ]]
  [[ "$output" == *"merged PR #7"* ]]
  # The PR branch is now main plus one commit: the fix and its annotation only.
  [ "$(git -C "$TMP/remote.git" rev-parse "$SQ_HEAD~1")" = "$(git -C "$TMP/remote.git" rev-parse main)" ]
  [ "$(git -C "$TMP/remote.git" diff --name-only main "$SQ_HEAD" | sort | tr '\n' ' ')" = "docs/found-issues.md src/a.sh " ]
  remote_ledger | grep -qx -- '- \[open\] 2026-10-02 src/a.sh:1 — a breaks (fix: small) (PR: foo/bar#7)'
  remote_ledger | grep -qx -- '- \[open\] 2026-10-03 src/b.sh:1 — b breaks (fix: small) (PR: foo/bar#6)'
  remote_ledger | grep -qx -- '- \[open\] 2026-10-04 src/p.sh:1 — p is new (fix: small)'
  [ "$(remote_ledger | grep -c '^- ')" -eq 4 ]
  git -C "$TMP/remote.git" show "$SQ_HEAD:src/a.sh" | grep -q 'a()'
  git -C "$TMP/remote.git" show "$SQ_HEAD:src/b.sh" | grep -q 'b()'
  grep -q '^pr merge 7 --squash --repo foo/bar$' "$GH_MOCK_TRACE"
  [ "$(git worktree list | wc -l | tr -d ' ')" -eq 1 ]
}

@test "merge-when-green: without an automatic base change the squash rebuild is not attempted" {
  export GH_SQ_NO_EVENT=1
  before="$(git -C "$TMP/remote.git" rev-parse "$SQ_HEAD")"
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 1 ]
  [[ "$output" == *"more than its"*"annotation"* ]]
  [ "$(git -C "$TMP/remote.git" rev-parse "$SQ_HEAD")" = "$before" ]
  ! grep -q '^pr merge 7 --squash' "$GH_MOCK_TRACE" || false
}

@test "merge-when-green: a squash rebuild whose ledger change is more than its annotation is refused" {
  git switch -q "$SQ_HEAD"
  sed -i.bak 's/a breaks (fix: small)/a really breaks (fix: small)/' "$L" && rm -f "$L.bak"
  git commit -qam "reword" && git push -q origin "$SQ_HEAD"
  before="$(git -C "$TMP/remote.git" rev-parse "$SQ_HEAD")"
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 1 ]
  [[ "$output" == *"squash-merged"*"more than its own annotation"* ]]
  [ "$(git -C "$TMP/remote.git" rev-parse "$SQ_HEAD")" = "$before" ]
  ! grep -q '^pr merge 7 --squash' "$GH_MOCK_TRACE" || false
  [ "$(git worktree list | wc -l | tr -d ' ')" -eq 1 ]
}

@test "merge-when-green: a squash rebuild whose fix no longer applies on main is refused" {
  git switch -q main
  printf 'a() { echo base; }\n' >src/a.sh && git add src/a.sh && git commit -qm "base edits a" && git push -q origin main
  before="$(git -C "$TMP/remote.git" rev-parse "$SQ_HEAD")"
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 1 ]
  [[ "$output" == *"squash-merged"*"does not apply"* ]]
  [ "$(git -C "$TMP/remote.git" rev-parse "$SQ_HEAD")" = "$before" ]
  ! grep -q '^pr merge 7 --squash' "$GH_MOCK_TRACE" || false
  [ "$(git worktree list | wc -l | tr -d ' ')" -eq 1 ]
}
