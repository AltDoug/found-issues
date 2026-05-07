# found-issues

> Markdown-based issue tracker for AI agents working in your repos.

When Claude (or any AI coding agent) notices a bug, error, or warning while working on something else, it currently shrugs and moves on. `found-issues` makes it stop, log the observation, and surface it later — automatically.

The agent maintains a `docs/found-issues.md` file in each repo. Entries flip from `[open]` to `[fixed]` when a PR or commit addresses them. A statusline counter and SessionStart line keep the count visible. The user does almost nothing — the agent runs the whole loop.

## Status

🚧 **Pre-release.** Private repo while the foundation is built. Will go public when ready.

## What's planned for v1

- 6 slash commands: `/fi log`, `/fi sync`, `/fi annotate-pr`, `/fi annotate-commit`, `/fi promote`, `/fi status`
- 7 hooks: format enforcer, SessionStart sync + context inject, Stop-hook reminder, post-`gh pr create`, post-`git commit`, pre-branch-delete, optional per-repo pre-commit
- `found-issues` CLI binary for statusline integration and install/uninstall
- Auto-detected modes per-repo: `local` (no git), `git` (no GitHub), `github-direct` (push-to-main), `github-pr` (full PR workflow)
- AI-driven sync inside Claude Code: annotation flipping + tombstone close + verification of unannotated entries
- One-line install: `curl -sSL <url>/install.sh | bash`

## Format spec (preview)

```
- [open] [!] 2026-05-06 lib/foo.py:42 — null check missing (suggested: add guard)
- [open] 2026-05-06 src/auth.ts:88 — race on session refresh (PR: org/repo#42)
- [fixed] 2026-05-06 src/auth.ts:88 — race on session refresh (PR: org/repo#42) (fixed: 2026-05-08)
```

Statuses: `open`, `deferred`, `fixed`. Optional `[!]` flag for critical. Optional annotations: `(PR: org/repo#N)`, `(commit: <sha>)`, `(fixed: YYYY-MM-DD)`.

## License

MIT
