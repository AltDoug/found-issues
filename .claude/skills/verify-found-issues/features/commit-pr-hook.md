---
feature: Suggestions after a commit or PR
also-called: the post-bash hook, post-bash-dispatch, commit-auto, PR-auto, annotation suggestions
sources:
  - hooks/post-bash-dispatch.sh
  - hooks/hooks.json
  - lib/annotate.sh
  - lib/hook-gate.sh
proven: 2026-11-27
---

## What it is

After the agent runs `git commit` or `gh pr create`, the hook looks at what changed. When exactly one open entry cites a touched file **and** the change hits that entry's cited line, it writes a non-closing suggestion on it. Otherwise it writes nothing and lists the candidates for the agent to judge. After `gh pr merge`, `close` or `reopen` it starts a background `sync`.

## Parts

| What you see | When | Handle |
|---|---|---|
| `this commit produced annotation SUGGESTIONS`, ledger gains `(commit-auto: SHA)` | One entry on the file, cited line changed | commit route |
| `PR #7 produced annotation SUGGESTIONS`, ledger gains `(PR-auto: org/repo#7)` | The same, for a PR | PR route |
| `commit needs annotation judgment` or `PR #7 needs annotation judgment`, ledger unchanged | Two entries share a touched file (`[shares a touched file with another entry]`), or the cited line was not changed (`[cited line not touched by this change]`) | `fi_annotate_auto` |
| A prompt only, ledger unchanged. Commit: names `--pick`. PR: `PR #7 touches files referenced by [open] entries` | `FOUND_ISSUES_AUTO_ANNOTATE=off` (both routes) | `legacy_commit_prompt` |
| **No output.** A background `sync` runs | `gh pr merge, close, reopen` (`FOUND_ISSUES_POST_PR_STATE=off` stops it) | last route in the script |

## How to get to it

Claude Code or Codex fires it after every Bash tool call (PostToolUse). To make a suggestion closing, the agent runs the printed `--pick` command (annotate.md); sync then closes it once it lands (sync.md).

## Driving it

The payload is `tool_name`, `cwd`, `session_id`, `tool_input.command` and `tool_response.stdout`. For a commit, stdout must carry the **real** sha in git's `[branch sha] subject` form: `__HEAD__` fills it in. Run each block as one shell call.

Commit route: suggestion, repeat call, confirm, then a failing input.

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new commit-hook)"
$F run "$SB" "found-issues log 'src/util.py:2 — divide has no zero check' && git add docs && git commit -qm ledger && git switch -qc fix/zero"
$F run "$SB" "sed -i.bak 's|return a / b|return a / b if b else 0|' src/util.py && rm src/util.py.bak && git commit -qam 'guard divide'"
PAY='{"tool_name":"Bash","cwd":"__REPO__","session_id":"s1","tool_input":{"command":"git commit -am guard"},"tool_response":{"stdout":"[fix/zero __HEAD__] guard divide"}}'
$F hook "$SB" post-bash-dispatch "$PAY"
$F snap "$SB" after-hook
$F hook "$SB" post-bash-dispatch "$PAY"                     # same HEAD again: silent
$F run "$SB" 'found-issues sync'                            # a suggestion never closes
$F run "$SB" 'found-issues annotate-commit $(git rev-parse --short HEAD) --pick src/util.py:2'
$F snap "$SB" after-pick
$F run "$SB" 'found-issues annotate-commit deadbee --pick src/util.py:2' || true   # failing input
$F rm "$SB"
```

PR route, against the `gh` mock. The mock rows are the PR number, a tab, then the answer. `GH_MOCK_PR_DIFF` is not a row: it is the diff itself, with newlines written as backslash-n. First one entry (suggestion), then a second entry on the same file (candidate list).

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new pr-hook --github)"
ROW=$'7\tsrc/util.py'
DIFF='diff --git a/src/util.py b/src/util.py\n--- a/src/util.py\n+++ b/src/util.py\n@@ -2 +2 @@\n-    return a / b\n+    return a / b if b else 0'
PAY='{"tool_name":"Bash","cwd":"__REPO__","session_id":"s1","tool_input":{"command":"gh pr create --fill"},"tool_response":{"stdout":"https://github.com/fi-sandbox/demo/pull/7"}}'
$F run "$SB" "found-issues log 'src/util.py:2 — divide has no zero check'"
$F hook "$SB" "GH_MOCK_PR_VIEW=$ROW" "GH_MOCK_PR_FILES=$ROW" "GH_MOCK_PR_DIFF=$DIFF" post-bash-dispatch "$PAY"
$F snap "$SB" one-entry
$F run "$SB" "found-issues log 'src/util.py:6 — first() raises on an empty list' && sed -i.bak 's| (PR-auto: [^)]*)||' docs/found-issues.md && rm docs/found-issues.md.bak"   # reset the fixture
$F hook "$SB" "GH_MOCK_PR_VIEW=$ROW" "GH_MOCK_PR_FILES=$ROW" "GH_MOCK_PR_DIFF=$DIFF" post-bash-dispatch "$PAY"
$F snap "$SB" two-entries
$F rm "$SB"
```

Merge route and both off switches. The hook prints nothing, so the proof is the ledger. The control runs first, with the switch off.

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new merge-hook --github)"
ROW=$'7\tsrc/util.py'
MERGED=$'7\t{"state":"MERGED","baseRefName":"main","mergedAt":"2026-01-01T12:00:00Z","isDraft":false}'
PAY='{"tool_name":"Bash","cwd":"__REPO__","session_id":"s1","tool_input":{"command":"gh pr merge 7 --squash"},"tool_response":{"stdout":""}}'
$F run "$SB" "found-issues log 'src/util.py:2 — divide has no zero check' && GH_MOCK_PR_VIEW=\$'7\tsrc/util.py' GH_MOCK_PR_FILES=\$'7\tsrc/util.py' found-issues annotate-pr 7 --pick src/util.py:2"
$F hook "$SB" FOUND_ISSUES_POST_PR_STATE=off "GH_MOCK_PR_VIEW=$MERGED" post-bash-dispatch "$PAY"
$F run "$SB" 'sleep 3; grep -c "^- \[open\]" docs/found-issues.md'          # control: 1, still open
$F hook "$SB" "GH_MOCK_PR_VIEW=$MERGED" post-bash-dispatch "$PAY"
$F run "$SB" 'for i in $(seq 1 40); do grep -q "^- \[fixed\]" docs/found-issues.md && break; sleep 0.25; done; grep "^- \[fixed\]" docs/found-issues.md'
$F snap "$SB" after-merge
# annotate off switch: a prompt, and nothing written
$F run "$SB" "found-issues log 'src/app.sh:3 — greets with an empty name' && git add -A && git commit -qm ledger && echo '# x' >> src/app.sh && git commit -qam change"
$F hook "$SB" FOUND_ISSUES_AUTO_ANNOTATE=off post-bash-dispatch '{"tool_name":"Bash","cwd":"__REPO__","session_id":"s2","tool_input":{"command":"git commit -am change"},"tool_response":{"stdout":"[main __HEAD__] change"}}'
$F snap "$SB" annotate-off
$F rm "$SB"
```

## What proves it works

- Commit block: the first hook call prints JSON naming `(commit-auto: SHA)` and the `--pick` command; the second prints nothing. In `after-hook.found-issues.md` the entry citing `src/util.py:2` carries the suggestion and is still `[open]`; sync says `Nothing to close.`; `after-pick.found-issues.md` shows `(commit: SHA)`. The failing input exits non-zero with `not a valid commit`.
- PR block: `one-entry.found-issues.md` has `(PR-auto: fi-sandbox/demo#7)`. The second call prints `needs judgment` naming both entries, and `two-entries.found-issues.md` has no suggestion. `two-entries.gh-calls.log` shows `pr diff 7`.
- Merge block: with the switch off the count of open entries stays 1; without it the entry becomes `[fixed] ... (PR: fi-sandbox/demo#7)`. With annotate off, the output asks for `--pick` and `annotate-off.found-issues.md` gains no suggestion.

## Gotchas

- A sha the repo does not have turns the commit route off with **no output** (`git cat-file -e`).
- The same HEAD is handled only once, so an identical second commit call is silent. An identical second PR call, after a suggestion, was also silent (seen in one drive).
- The merge-route mock answers MERGED whatever the command was, so it shows that `close` and `reopen` start a sync, not how a really closed PR is handled.
- Not driven: the auto-fix launch markers (auto-fix stays off).
