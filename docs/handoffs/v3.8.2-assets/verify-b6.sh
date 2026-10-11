#!/usr/bin/env bash
# Drive batch-6 flows through ./bin/found-issues and the real hook in temp repos.
set -u
B6="$1"
T="$(mktemp -d "${TMPDIR:-/tmp}/fi-verify-b6.XXXXXX")"
export HOME="$T/home" FOUND_ISSUES_STATE_DIR="$T/state" FOUND_ISSUES_CACHE_DIR="$T/cache" FOUND_ISSUES_MODE=github-pr
mkdir -p "$HOME"
export PATH="$B6/bin:$B6/tests/bin-shims:$PATH"
unset FOUND_ISSUES_AUTOFIX FOUND_ISSUES_AUTOFIX_CHILD CLAUDECODE FOUND_ISSUES_HARNESS CLAUDE_PLUGIN_ROOT
git config --global user.name v; git config --global user.email v@v; git config --global init.defaultBranch main
FI="$B6/bin/found-issues"
mkrepo() {
  git init -q --bare -b main "$T/$1.git"
  mkdir -p "$T/$1" && cd "$T/$1" && git init -q -b main
  git remote add origin "https://github.com/foo/$1.git"
  git config url."$T/$1.git".insteadOf "https://github.com/foo/$1.git"
  mkdir -p src docs
  printf 'add() { echo $(( $1 - $2 )); }\n' > src/calc.sh
  printf '# found-issues\n\n- [open] 2026-10-01 src/calc.sh:1 — add subtracts (fix: small)\n' > docs/found-issues.md
  git add src docs && git commit -qm init && git push -q -u origin main
  git fetch -q origin && git remote set-head origin main >/dev/null
}
echo "===== A: old CLI on PATH; real hook, git commit route ====="
mkrepo hk
mkdir -p "$T/old"; printf '#!/usr/bin/env bash\ncase "$*" in *--hook-auto*) echo "unknown flag: --hook-auto" >&2; exit 2;; esac\nexec %s "$@"\n' "$FI" > "$T/old/found-issues"; chmod +x "$T/old/found-issues"
sed -i.bak 's/ - / + /' src/calc.sh; rm -f src/calc.sh.bak; git commit -qam "fix add"
pl='{"tool_name":"Bash","tool_input":{"command":"git commit -m fix"},"tool_response":{"stdout":"","exit_code":"0"}}'
echo "-- with the plugin's own CLI next to the hook:"
printf '%s' "$pl" | PATH="$T/old:$PATH" "$B6/hooks/post-bash-dispatch.sh" | head -6
echo "ledger: $(grep -c 'commit-auto:' docs/found-issues.md) commit-auto token(s)"
echo "-- hook copy with no bundled CLI:"
mkdir -p "$T/iso/hooks"; cp "$B6/hooks/post-bash-dispatch.sh" "$T/iso/hooks/"
git commit -q --allow-empty -m e2; sed -i.bak 's/ + / * /' src/calc.sh; rm -f src/calc.sh.bak; git commit -qam "fix add 2"
printf '%s' "$pl" | PATH="$T/old:$PATH" FOUND_ISSUES_LIB_DIR="$B6/lib" "$T/iso/hooks/post-bash-dispatch.sh" | head -8

echo "===== B: crashed sweep keeps its commits (real claim reaps it) ====="
mkrepo rp
git config found-issues.autofix true; git config found-issues.autofix.testCommand 'true'
"$FI" log --fix small 'src/calc.sh:3 — second bug' >/dev/null 2>&1
q=("$T"/state/autofix/foo__rp/queue/*); ID="$(basename "${q[0]}")"
"$FI" autofix claim "$ID" >/dev/null 2>&1; echo "claim rc=$?"
R="$T/state/autofix/foo__rp/running/$ID"; WT="$(sed -n 's/^wt=//p' "$R")"; BR="$(sed -n 's/^branch=//p' "$R")"
echo "fixed" >> "$WT/src/calc.sh"; git -C "$WT" commit -qam "fix: verified but unshipped"; SHA="$(git -C "$WT" rev-parse --short HEAD)"
sed -i.bak 's/^pid=.*/pid=999999/' "$R"; rm -f "$R.bak"
rmdir "$T/state/autofix/foo__rp/lock" 2>/dev/null || rm -rf "$T/state/autofix/foo__rp/lock"
"$FI" autofix claim "$ID" >/dev/null 2>&1; echo "re-claim (reaps first) rc=$?"
echo "rescued ref: $(git rev-parse --short "refs/heads/fi/rescued/$ID" 2>&1) (want $SHA); old branch: $(git branch --list "$BR" | wc -l | tr -d ' ') left"
"$FI" autofix status 2>&1 | grep -E 'commits kept|Running|Queued' | head -4
grep -c fi/rescued docs/found-issues.md | sed 's/^/ledger mentions of fi\/rescued: /'

echo "===== C: fix ship verdict line + PR body ====="
mkrepo shp
git config found-issues.autofix.testCommand 'echo 1..2; echo "ok 1 a"; echo "ok 2 b # skip win"'
export GH_MOCK_TRACE="$T/gh.trace" GH_MOCK_PR_CREATE_URL=https://github.com/foo/shp/pull/11 GH_MOCK_PR_VIEW=$'11\t{"number":11,"state":"OPEN","files":[]}' GH_MOCK_PR_BODY_COPY="$T/sent"
W="$("$FI" fix workspace | sed -n 's/^worktree=//p')"
sed -i.bak 's/ - / + /' "$W/src/calc.sh"; rm -f "$W/src/calc.sh.bak"; git -C "$W" commit -qam "fix: add subtracts"
printf 'My body\n' > "$T/body"
"$FI" fix ship "$W" --title "fix: add" --body-file "$T/body" --pick src/calc.sh:1; echo "ship rc=$?"
echo "sent body:"; sed 's/^/  | /' "$T/sent"
rm -rf "$T"
