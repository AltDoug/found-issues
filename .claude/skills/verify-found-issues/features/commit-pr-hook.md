---
feature: Suggestions after a commit or PR
also-called: post-bash-dispatch, commit-auto, PR-auto, annotation suggestions, annotate reminder, T3 pull request tool
sources:
  - hooks/post-bash-dispatch.sh
  - lib/annotate.sh
proven-with: hand-built hook payloads (no Claude Code or Codex), mock gh
proven: 2026-11-27
proven-hash: 37479ee44372
---

## What it is

After the agent runs `git commit` or `gh pr create`, or opens a pull request with T3 Code's own tool (`mcp__t3-code__pull_request_create`), the hook looks at what changed. When exactly one open entry cites a touched file **and** the change hits that entry's cited line, it writes a non-closing suggestion on it. Otherwise it writes nothing and lists the candidates for the agent to judge. After `gh pr merge`, `close` or `reopen` it starts a background `sync`.

## Parts

| What you see | When | Drive it by |
|---|---|---|
| `this commit produced annotation SUGGESTIONS`, ledger gains `(commit-auto: SHA)` | One entry on the file, cited line changed | a payload with command `git commit ...` and stdout `[branch __HEAD__] subject` |
| `PR #7 produced annotation SUGGESTIONS`, ledger gains `(PR-auto: org/repo#7)` | The same, for a PR | command `gh pr create --fill`, stdout the PR URL, and the three `GH_MOCK_PR_*` values |
| The same two lines, with no Bash call at all | A pull request opened with T3 Code's tool | a payload with `tool_name` `mcp__t3-code__pull_request_create` and the tool's result in `tool_response` |
| `needs annotation judgment`, `[shares a touched file with another entry]`, ledger unchanged | Two entries cite a touched file | log a second entry on the same file |
| `[cited line not touched by this change]`, ledger unchanged | One entry, other lines changed | a diff that misses the cited line |
| A prompt only, ledger unchanged. Commit: names `--pick`. PR: `PR #7 touches files referenced by [open] entries` | Suggestions switched off | `FOUND_ISSUES_AUTO_ANNOTATE=off` before the hook name |
| **No output**, and a background `sync` runs | A PR changed state | command `gh pr merge 7`, `close` or `reopen` |
| No output, no sync | That route switched off | `FOUND_ISSUES_POST_PR_STATE=off` before the hook name |

## How to get to it

Claude Code or Codex fires it after every Bash tool call (PostToolUse). Claude Code also fires it after T3 Code's `pull_request_create` tool; that tool has no command, so only the PR route can run. To make a suggestion closing, the agent runs the printed `--pick` command (annotate.md); sync then closes it once it lands (sync.md).

## Driving it

The payload is `tool_name`, `cwd`, `session_id`, `tool_input.command` and `tool_response.stdout`. For a commit, stdout must carry the **real** sha in git's `[branch sha] subject` form: `__HEAD__` fills it in.

Commit route: a suggestion, silence on a repeat, no closure by sync, the confirm, then a failing input.

```bash
set -eo pipefail
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new commit-hook)"; trap '$F rm "$SB"' EXIT
$F registered "$SB" PostToolUse post-bash-dispatch Bash
L=docs/found-issues.md
$F run "$SB" "found-issues log 'src/util.py:2 — divide has no zero check' && git add docs && git commit -qm ledger && git switch -qc fix/zero"
$F run "$SB" "sed -i.bak 's|return a / b|return a / b if b else 0|' src/util.py && rm src/util.py.bak && git commit -qam 'guard divide'"
SHA="$(git -C "$SB/repo" log -1 --format=%h)"
PAY='{"tool_name":"Bash","cwd":"__REPO__","session_id":"s1","tool_input":{"command":"git commit -am guard"},"tool_response":{"stdout":"[fix/zero __HEAD__] guard divide"}}'
$F hook "$SB" post-bash-dispatch "$PAY"
$F has "$SB" 'this commit produced annotation SUGGESTIONS'
$F has "$SB" "annotate-commit $SHA --pick"
$F has "$SB" "(commit-auto: $SHA)" "$L"
$F snap "$SB" after-hook
$F hook "$SB" post-bash-dispatch "$PAY"
$F silent "$SB"
$F run "$SB" 'found-issues sync'
$F has "$SB" 'Synced. Nothing to close.'
$F has "$SB" '- [open] ' "$L"
$F run "$SB" "found-issues annotate-commit $SHA --pick src/util.py:2"
$F has "$SB" "(commit: $SHA)" "$L"
$F lacks "$SB" 'commit-auto' "$L"
$F snap "$SB" after-pick
$F run "$SB" 'found-issues annotate-commit deadbee --pick src/util.py:2' || true
$F rc "$SB" 1
$F has "$SB" 'not a valid commit'
```

PR route against the `gh` mock: one entry whose line the diff misses (candidates), one whose line it hits (suggestion), then two entries on the file (candidates). A mock row is the PR number, a tab, then the answer. `GH_MOCK_PR_DIFF` is not a row: it is the diff itself, with newlines written as backslash-n. The last part sends the same pull request the way T3 Code's tool reports it: no command, the result as JSON text in `tool_response`. Then a pull request in another repository, and a create that failed.

```bash
set -eo pipefail
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new pr-hook --github)"; trap '$F rm "$SB"' EXIT
L=docs/found-issues.md
ROW=$'7\tsrc/util.py'
DIFF='diff --git a/src/util.py b/src/util.py\n--- a/src/util.py\n+++ b/src/util.py\n@@ -2 +2 @@\n-    return a / b\n+    return a / b if b else 0'
PAY='{"tool_name":"Bash","cwd":"__REPO__","session_id":"SID","tool_input":{"command":"gh pr create --fill"},"tool_response":{"stdout":"https://github.com/fi-sandbox/demo/pull/7"}}'
pr_hook() { $F hook "$SB" "GH_MOCK_PR_VIEW=$ROW" "GH_MOCK_PR_FILES=$ROW" "GH_MOCK_PR_DIFF=$DIFF" post-bash-dispatch "${PAY/SID/$1}"; }
$F run "$SB" "found-issues log 'src/util.py:6 — first() raises on an empty list'"
pr_hook s0
$F has "$SB" 'PR #7 needs annotation judgment'
$F has "$SB" '[cited line not touched by this change]'
$F lacks "$SB" 'PR-auto' "$L"
$F run "$SB" "rm docs/found-issues.md && found-issues log 'src/util.py:2 — divide has no zero check'"
pr_hook s1
$F has "$SB" 'PR #7 produced annotation SUGGESTIONS'
$F has "$SB" '(PR-auto: fi-sandbox/demo#7)' "$L"
$F lacks "$SB" '(PR: ' "$L"
$F snap "$SB" one-entry
$F run "$SB" "found-issues log 'src/util.py:6 — first() raises on an empty list' && sed -i.bak 's| (PR-auto: [^)]*)||' docs/found-issues.md && rm docs/found-issues.md.bak"
pr_hook s2
$F has "$SB" 'PR #7 needs annotation judgment'
$F has "$SB" 'src/util.py:2 [shares a touched file with another entry]'
$F has "$SB" 'src/util.py:6 [shares a touched file with another entry]'
$F lacks "$SB" 'PR-auto' "$L"
$F has "$SB" 'pr diff 7' "$SB/gh-calls.log"
$F snap "$SB" two-entries
$F registered "$SB" PostToolUse post-bash-dispatch mcp__t3-code__pull_request_create
T3='{"tool_name":"mcp__t3-code__pull_request_create","cwd":"__REPO__","session_id":"SID","tool_input":{"title":"guard divide","body":"b"},"tool_response":"{\"host\":\"github.com\",\"repository\":\"SLUG\",\"number\":7,\"url\":\"https://github.com/SLUG/pull/7\",\"created\":true}"}'
t3_hook() { local p="${T3/SID/$1}"; $F hook "$SB" "GH_MOCK_PR_VIEW=$ROW" "GH_MOCK_PR_FILES=$ROW" "GH_MOCK_PR_DIFF=$DIFF" post-bash-dispatch "${p//SLUG/$2}"; }
$F run "$SB" "rm docs/found-issues.md && found-issues log 'src/util.py:2 — divide has no zero check'"
t3_hook t0 other/thing
$F silent "$SB"
$F lacks "$SB" 'PR-auto' "$L"
t3_hook t1 fi-sandbox/demo
$F has "$SB" 'PR #7 produced annotation SUGGESTIONS'
$F has "$SB" 'found-issues annotate-pr 7 --pick'
$F has "$SB" '(PR-auto: fi-sandbox/demo#7)' "$L"
$F lacks "$SB" '(PR: ' "$L"
$F snap "$SB" t3-tool
$F run "$SB" "sed -i.bak 's| (PR-auto: [^)]*)||' docs/found-issues.md && rm docs/found-issues.md.bak"
$F hook "$SB" "GH_MOCK_PR_VIEW=$ROW" post-bash-dispatch '{"tool_name":"mcp__t3-code__pull_request_create","cwd":"__REPO__","session_id":"t2","tool_input":{"title":"t","body":"b"},"tool_response":"Source control provider github failed in createChangeRequest: Validation Failed"}'
$F silent "$SB"
$F lacks "$SB" 'PR-auto' "$L"
```

Merge route and both off switches. The hook prints nothing, so the proof is the ledger. The control runs first, with the route switched off. The last part turns suggestions off and sends a PR, then a commit.

```bash
set -eo pipefail
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new merge-hook --github)"; trap '$F rm "$SB"' EXIT
L=docs/found-issues.md
ROW=$'7\tsrc/util.py'
MERGED=$'7\t{"state":"MERGED","baseRefName":"main","mergedAt":"2026-01-01T12:00:00Z","isDraft":false}'
PAY='{"tool_name":"Bash","cwd":"__REPO__","session_id":"s1","tool_input":{"command":"gh pr merge 7 --squash"},"tool_response":{"stdout":""}}'
$F run "$SB" "found-issues log 'src/util.py:2 — divide has no zero check' && GH_MOCK_PR_VIEW=\$'7\\tsrc/util.py' GH_MOCK_PR_FILES=\$'7\\tsrc/util.py' found-issues annotate-pr 7 --pick src/util.py:2"
$F hook "$SB" FOUND_ISSUES_POST_PR_STATE=off "GH_MOCK_PR_VIEW=$MERGED" post-bash-dispatch "$PAY"
$F silent "$SB"
sleep 3
$F count "$SB" 1 '- [open] ' "$L"
$F hook "$SB" "GH_MOCK_PR_VIEW=$MERGED" post-bash-dispatch "$PAY"
$F silent "$SB"
$F run "$SB" 'for i in $(seq 1 40); do grep -q "^- \[fixed\]" docs/found-issues.md && break; sleep 0.25; done'
$F match "$SB" '^- \[fixed\] .*\(PR: fi-sandbox/demo#7\)' "$L"
$F snap "$SB" after-merge
$F run "$SB" "found-issues log 'src/app.sh:3 — greets with an empty name' && git add -A && git commit -qm ledger && echo '# x' >> src/app.sh && git commit -qam change"
$F hook "$SB" FOUND_ISSUES_AUTO_ANNOTATE=off "GH_MOCK_PR_VIEW="$'8\tsrc/app.sh' "GH_MOCK_PR_FILES="$'8\tsrc/app.sh' post-bash-dispatch '{"tool_name":"Bash","cwd":"__REPO__","session_id":"s3","tool_input":{"command":"gh pr create --fill"},"tool_response":{"stdout":"https://github.com/fi-sandbox/demo/pull/8"}}'
$F has "$SB" 'PR #8 touches files referenced by [open] entries'
$F lacks "$SB" 'PR-auto' "$L"
$F hook "$SB" FOUND_ISSUES_AUTO_ANNOTATE=off post-bash-dispatch '{"tool_name":"Bash","cwd":"__REPO__","session_id":"s2","tool_input":{"command":"git commit -am change"},"tool_response":{"stdout":"[main __HEAD__] change"}}'
$F has "$SB" '--pick'
$F lacks "$SB" 'commit-auto' "$L"
$F snap "$SB" annotate-off
```

## What proves it works

- Commit block: the first call prints JSON naming `(commit-auto: SHA)` and the `--pick` command, and the entry is still `[open]`; the repeat prints nothing; sync closes nothing; `--pick` turns the suggestion into `(commit: SHA)`; a bad sha exits 1.
- PR block: only the single-entry, line-hit case writes `(PR-auto: ...)`. The other two print `needs annotation judgment` with the reason and write nothing. The T3 Code payload gives the same suggestion and `--pick` line with no Bash command in it; a pull request in another repository and a failed create print nothing and write nothing; `hooks/hooks.json` registers the hook for that tool.
- Merge block: with the route off the entry stays open; with it on it becomes `[fixed] ... (PR: fi-sandbox/demo#7)`. With suggestions off, both routes print a prompt and write nothing.
- The first block also checks that `hooks/hooks.json` registers the hook for Bash: a hook nobody registers never fires.

## Gotchas

- Silence is ambiguous: a sha the repo does not have turns the commit route off with **no output** (`git cat-file -e`), and so does a rejected payload.
- The same HEAD is handled only once per session, so an identical second commit call is silent. The PR block gives each call its own `session_id` for the same reason.
- Two entries citing one file are never auto-suggested.
- The merge-route mock answers MERGED whatever the command was, so a `close` or `reopen` payload would show that a sync starts, not how a really closed PR is handled.
- Broken: with `FOUND_ISSUES_AUTO_ANNOTATE=off` the PR prompt says to run `/found-issues:annotate-pr N` without `--pick` (`hooks/post-bash-dispatch.sh:172`), and without it only a non-closing suggestion is written. The commit prompt names `--pick`. Logged in `docs/found-issues.md` on 2026-11-27.
- The PR candidate message gives the `--pick` / `--all` instructions twice. Cosmetic, and not logged.
- Not driven: `close` and `reopen`, and the auto-fix launch markers (auto-fix stays off). The `hooks.json` lines are read, not fired: only a real session shows the host calling the hook, and for T3 Code's tool only a real T3 thread shows which shape `tool_response` arrives in (the hook reads the JSON text, the object and content blocks alike; `tests/post-bash-dispatch.bats` has one test per shape).
