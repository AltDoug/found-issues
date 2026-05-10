# found-issues

Issues noticed outside the current task scope. Format: `- [status] YYYY-MM-DD path:line — symptom (suggested: fix)`. Statuses: `open`, `deferred`, `fixed`.

Maintained automatically by Claude. See <https://github.com/AltDoug/found-issues> for docs.

- [fixed] 2026-05-08 docs/demo-storyboard.md — gh repo create --push appears before source file creation, so the command fails on first run; reorder steps so commit happens before gh repo create (suggested: rewrite the bash setup block in the order: mkdir+cd, git init, mkdir src/docs + echo source, git add+commit, then gh repo create --source . --push) (PR: AltDoug/found-issues#11) (fixed: 2026-05-08)
- [open] 2026-05-09 bin/found-issues:1033 — install-statusline segment block calls 'found-issues status' without cd to workspace dir; fails on multi-line statuslines that use 'git -C $DIR' pattern (suggested: extract workspace dir from input JSON via jq, cd before invoking, or add --repo-dir flag to status subcommand) (PR: AltDoug/found-issues#37)
