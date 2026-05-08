# found-issues

Issues noticed outside the current task scope. Format: `- [status] YYYY-MM-DD path:line — symptom (suggested: fix)`. Statuses: `open`, `deferred`, `fixed`.

Maintained automatically by Claude. See <https://github.com/DougBTW/found-issues> for docs.

- [open] 2026-05-08 docs/demo-storyboard.md — gh repo create --push appears before source file creation, so the command fails on first run; reorder steps so commit happens before gh repo create (suggested: rewrite the bash setup block in the order: mkdir+cd, git init, mkdir src/docs + echo source, git add+commit, then gh repo create --source . --push) (PR: DougBTW/found-issues#11)
