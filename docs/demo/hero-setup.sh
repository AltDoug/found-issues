# hero-setup.sh — sourced (hidden) by hero.tape before recording.
# Builds a throwaway repo and points found-issues at the repo's own CLI and
# the gh stand-in from tests/bin-shims, so the GIF shows the real commands
# and their real output with no GitHub account. Run from the repo root.
__fi_root="$(pwd -P)"
__fi_demo="$(mktemp -d "${TMPDIR:-/tmp}/fi-hero.XXXXXX")"
export HOME="$__fi_demo/home" FOUND_ISSUES_STATE_DIR="$__fi_demo/state"
export FOUND_ISSUES_MODE=github-pr FOUND_ISSUES_AUTOFIX=off
export PATH="$__fi_root/bin:$__fi_root/tests/bin-shims:$PATH"
export GH_MOCK_PR_FILES=$'42\tsrc/config.ts'
# PR #42 as already merged: annotate-pr only needs its files, sync its state.
export GH_MOCK_PR_VIEW=$'42\t{"number":42,"state":"MERGED","baseRefName":"main","headRefName":"fix/config","mergedAt":"2026-10-12T20:00:00Z"}'
mkdir -p "$HOME" "$__fi_demo/app/src" && cd "$__fi_demo/app" || return
git init -q -b main && git remote add origin https://github.com/acme/app.git
printf 'export function parseConfig(s) {\n  try { return JSON.parse(s) } catch { return {} }\n}\n' > src/config.ts
git add -A && git -c user.name=demo -c user.email=demo@example.com commit -qm init
PS1='$ '
