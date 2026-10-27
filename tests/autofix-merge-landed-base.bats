#!/usr/bin/env bats
# 3.10.9 (ledger lib/autofix-ship.sh:658): a fix PR's landing branch was
# squash-merged into main but kept (delete_branch_on_merge off), so GitHub
# never retargeted the PR and it would merge into a branch already merged
# (sayciao #320 into gsd/phase-24-resume after #318). When the landing branch
# has nothing since its merged head, merge-when-green retargets the PR to the
# default branch and the 3.10.7 rebuild applies. A branch that moved on
# (sayciao's did, 2026-10-27) stays the base.

load 'helpers'
load 'autofix-helpers'

# A gh over the fixture: the PR's base lives in $LB_BASE_FILE (pr edit changes
# it); mergeable = the PR branch contains its base; `api graphql` reports a
# BaseRefChangedEvent once the PR was retargeted; `pr list --head phase`
# reports the merged phase PR #5; `api .../branches/<b>` reads the remote.
lb_gh() {
  mkdir -p "$TMP/lbbin"
  cat >"$TMP/lbbin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_MOCK_TRACE"
jq_filter=""; prev=""
for a in "$@"; do [[ "$prev" == --jq ]] && jq_filter="$a"; prev="$a"; done
base="$(cat "$LB_BASE_FILE")"
if [[ -n "${LB_MERGEABLE:-}" ]] || git -C "$LB_REMOTE" merge-base --is-ancestor "$base" "$LB_HEAD" 2>/dev/null; then m=MERGEABLE; else m=CONFLICTING; fi
case "$1 $2" in
  "pr view")
    printf '{"state":"OPEN","mergeable":"%s","baseRefName":"%s","headRefName":"%s","statusCheckRollup":[]}' "$m" "$base" "$LB_HEAD" | jq -r "$jq_filter" ;;
  "pr merge")
    [[ " $* " == *" --auto "* || " $* " == *" --disable-auto "* ]] && exit 0
    [[ "$m" == CONFLICTING ]] && { echo "GraphQL: Pull Request has merge conflicts (mergePullRequest)" >&2; exit 1; }
    exit 0 ;;
  "pr edit")
    [[ -n "${LB_EDIT_FAIL:-}" ]] && { echo "GraphQL: edit refused" >&2; exit 1; }
    nb=""; prev=""; for a in "$@"; do [[ "$prev" == --base ]] && nb="$a"; prev="$a"; done
    printf '%s' "$nb" >"$LB_BASE_FILE" ;;
  "repo view")
    if [[ -n "${LB_REPO_VIEW_FAIL_ONCE:-}" && ! -e "$LB_REPO_VIEW_FAIL_ONCE" ]]; then
      : >"$LB_REPO_VIEW_FAIL_ONCE"; echo "gh: HTTP 502" >&2; exit 1
    fi
    printf '{"defaultBranchRef":{"name":"main"}}' | jq -r "$jq_filter" ;;
  "pr list")
    if [[ " $* " == *" --head phase "* && -z "${LB_NO_MERGED:-}" ]]; then
      fork='' ; [[ -n "${LB_FORK:-}" ]] && fork='{"number":9,"headRefOid":"0000000000000000000000000000000000000009","baseRefName":"main","isCrossRepository":true},'
      printf '[%s{"number":5,"headRefOid":"%s","baseRefName":"main","isCrossRepository":false}]' "$fork" "$LB_OLD_TIP" | jq -r "$jq_filter"
    else printf '[]' | jq -r "$jq_filter"; fi ;;
  "api graphql")
    if [[ "$base" == main ]]; then nodes='[{"previousRefName":"phase","currentRefName":"main"}]'; else nodes='[]'; fi
    printf '{"data":{"repository":{"pullRequest":{"timelineItems":{"nodes":%s}}}}}' "$nodes" | jq -r "$jq_filter" ;;
  "api "*)
    ep=""; for a in "${@:2}"; do case "$a" in -*|.*) ;; *) [[ -z "$ep" ]] && ep="$a" ;; esac; done
    b="${ep#repos/foo/bar/branches/}"; b="${b//%2F//}"
    sha="$(git -C "$LB_REMOTE" rev-parse --verify -q "refs/heads/$b")" || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    printf '{"commit":{"sha":"%s"},"protected":%s}' "$sha" "${LB_PROTECTED:-false}" | jq -r "$jq_filter" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$TMP/lbbin/gh"
  export LB_REMOTE="$TMP/remote.git" LB_HEAD="fi/autofix/x" LB_BASE_FILE="$TMP/pr-base"
  printf 'phase' >"$LB_BASE_FILE"
  export PATH="$TMP/lbbin:$PATH"
}

setup() {
  fi_setup_tmp; fi_af_fixture
  export GH_MOCK_TRACE="$TMP/gh.trace" FOUND_ISSUES_AUTOFIX_MERGE_SLEEP=0 FOUND_ISSUES_AUTOFIX_MERGE_POLLS=8 FOUND_ISSUES_AUTOFIX_GUARD_SLEEP=0
  : >"$GH_MOCK_TRACE"
  lb_gh
  git config found-issues.autofix.testCommand 'true'
  L=docs/found-issues.md
  printf -- '- [open] 2026-10-02 src/a.sh:1 — a breaks (fix: small)\n- [open] 2026-10-03 src/b.sh:1 — b breaks (fix: small)\n' >>"$L"
  git commit -qam "two more entries" && git push -q origin main
  git switch -q -c phase
  printf 'p() { :; }\n' >src/p.sh && git add src/p.sh
  printf -- '- [open] 2026-10-04 src/p.sh:1 — p is new (fix: small)\n' >>"$L"
  git commit -qam "phase work" && git push -q -u origin phase
  git switch -q -c "$LB_HEAD"
  printf 'a() { :; }\n' >src/a.sh && git add src/a.sh && git commit -qm "fix: a breaks"
  sed -i.bak 's/a breaks (fix: small)$/a breaks (fix: small) (PR: foo\/bar#7)/' "$L" && rm -f "$L.bak"
  git commit -qam "docs(found-issues): annotate src/a.sh:1 with PR 7" && git push -q -u origin "$LB_HEAD"
  # PR #5 squash-merges phase into main; the branch is KEPT.
  LB_OLD_TIP="$(git rev-parse phase)"; export LB_OLD_TIP
  git -C "$TMP/remote.git" update-ref refs/pull/5/head "$LB_OLD_TIP"
  git switch -q main
  git merge -q --squash phase >/dev/null && git commit -qm "phase work (#5)"
  sed -i.bak 's/b breaks (fix: small)$/b breaks (fix: small) (PR: foo\/bar#6)/' "$L" && rm -f "$L.bak"
  git commit -qam "docs: annotate b (#6)" && git push -q origin main
}
teardown() { fi_teardown_tmp; }

@test "landed base: a fix PR into a kept, squash-merged landing branch is retargeted, rebuilt on main and merged" {
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 0 ]
  [[ "$output" == *"retargeted to main"* ]]
  [[ "$output" == *"squash-merged"* ]]
  [[ "$output" == *"merged PR #7"* ]]
  grep -q '^pr edit 7 --repo foo/bar --base main$' "$GH_MOCK_TRACE"
  [ "$(git -C "$TMP/remote.git" rev-parse "$LB_HEAD~1")" = "$(git -C "$TMP/remote.git" rev-parse main)" ]
  [ "$(git -C "$TMP/remote.git" diff --name-only main "$LB_HEAD" | sort | tr '\n' ' ')" = "docs/found-issues.md src/a.sh " ]
  git -C "$TMP/remote.git" show "$LB_HEAD:$L" | grep -qx -- '- \[open\] 2026-10-02 src/a.sh:1 — a breaks (fix: small) (PR: foo/bar#7)'
  grep -q '^pr merge 7 --squash --repo foo/bar$' "$GH_MOCK_TRACE"
  # the landing branch itself is untouched
  [ "$(git -C "$TMP/remote.git" rev-parse phase)" = "$LB_OLD_TIP" ]
  [ "$(git worktree list | wc -l | tr -d ' ')" -eq 1 ]
}

@test "landed base: a landing branch with work after its merge stays the base" {
  git switch -q phase
  printf 'q() { :; }\n' >src/q.sh && git add src/q.sh && git commit -qm "more phase work" && git push -q origin phase
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 0 ]
  ! grep -q '^pr edit' "$GH_MOCK_TRACE" || false
  grep -q '^pr merge 7 --squash --repo foo/bar$' "$GH_MOCK_TRACE"
  [ "$(cat "$LB_BASE_FILE")" = phase ]
}

@test "landed base: a landing branch never merged stays the base" {
  export LB_NO_MERGED=1
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 0 ]
  ! grep -q '^pr edit' "$GH_MOCK_TRACE" || false
  grep -q '^pr merge 7 --squash --repo foo/bar$' "$GH_MOCK_TRACE"
}

@test "landed base: the default branch is looked up once per watch" {
  export LB_NO_MERGED=1
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 0 ]
  [ "$(grep -c '^repo view' "$GH_MOCK_TRACE")" -eq 1 ]
}

@test "landed base: a refused retarget stops the watch without merging" {
  export LB_EDIT_FAIL=1
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 1 ]
  [[ "$output" == *"retargeting it to main failed"* ]]
  ! grep -q '^pr merge 7 --squash --repo foo/bar$' "$GH_MOCK_TRACE" || false
}

@test "landed base: the guard retargets, re-arms auto-merge and never merges itself" {
  export FOUND_ISSUES_AUTOFIX_GUARD_POLLS=3
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar --guard
  grep -q '^pr edit 7 --repo foo/bar --base main$' "$GH_MOCK_TRACE"
  grep -q '^pr merge 7 --auto --squash --repo foo/bar$' "$GH_MOCK_TRACE"
  ! grep -q '^pr merge 7 --squash --repo foo/bar$' "$GH_MOCK_TRACE" || false
  [ "$(git -C "$TMP/remote.git" rev-parse "$LB_HEAD~1")" = "$(git -C "$TMP/remote.git" rev-parse main)" ]
}

@test "landed base: the guard turns auto-merge off when the retarget is refused" {
  export LB_EDIT_FAIL=1 FOUND_ISSUES_AUTOFIX_GUARD_POLLS=3
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar --guard
  [ "$status" -eq 1 ]
  [[ "$output" == *"retargeting it to main failed"* ]]
  [[ "$output" == *"auto-merge turned off"* ]]
  grep -q '^pr merge 7 --disable-auto --repo foo/bar$' "$GH_MOCK_TRACE"
}

@test "landed base: a retargeted PR GitHub calls mergeable is still rebuilt on main before it merges" {
  export LB_MERGEABLE=1
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 0 ]
  [[ "$output" == *"retargeted to main"* ]]
  [[ "$output" == *"squash-merged"* ]]
  [ "$(git -C "$TMP/remote.git" rev-parse "$LB_HEAD~1")" = "$(git -C "$TMP/remote.git" rev-parse main)" ]
  [ "$(git -C "$TMP/remote.git" diff --name-only main "$LB_HEAD" | sort | tr '\n' ' ')" = "docs/found-issues.md src/a.sh " ]
  grep -q '^pr merge 7 --squash --repo foo/bar$' "$GH_MOCK_TRACE"
}

@test "landed base: a protected landing branch stays the base" {
  export LB_PROTECTED=true
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 0 ]
  ! grep -q '^pr edit' "$GH_MOCK_TRACE" || false
  [ "$(cat "$LB_BASE_FILE")" = phase ]
}

@test "landed base: a fork PR merged from a branch of the same name is ignored" {
  export LB_FORK=1
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 0 ]
  [[ "$output" == *"(PR #5) with nothing since; retargeted to main"* ]]
  [[ "$output" == *"squash-merged into main (PR #5)"* ]]
  grep -q '^pr merge 7 --squash --repo foo/bar$' "$GH_MOCK_TRACE"
}

@test "landed base: a failed default-branch lookup is tried again on the next poll" {
  export LB_REPO_VIEW_FAIL_ONCE="$TMP/repo-view-failed"
  run "$FI_BIN" autofix merge-when-green 7 --repo foo/bar
  [ "$status" -eq 0 ]
  [ "$(grep -c '^repo view' "$GH_MOCK_TRACE")" -eq 2 ]
  [[ "$output" == *"retargeted to main"* ]]
}
