# found-issues

> Your AI agent has a blind spot. This fixes it.

When Claude notices a bug, error, or warning while working on something
else, it usually shrugs and moves on — *"pre-existing, not our problem,
let's continue."* `found-issues` makes it stop, log the observation, and
surface it later. Automatically. Across sessions. Without the user lifting
a finger.

## Install

```
/plugin marketplace add DougBTW/found-issues
/plugin install found-issues
```

Two commands inside Claude Code. That's it. The plugin auto-loads its
rules into context every session, registers all hooks, and adds the CLI
to PATH. No configuration required.

For optional polish (statusline integration, short alias):

```
/found-issues:setup
```

## How it works

The agent maintains a `docs/found-issues.md` file in each repo:

```
- [open] 2026-05-08 lib/foo.py:42 — null check missing (suggested: add guard)
- [open] [!] 2026-05-08 src/auth.ts:88 — leaks token in error (suggested: redact)
- [open] 2026-05-08 src/queue.py:12 — race on flush (PR: org/repo#42)
- [fixed] 2026-05-06 src/auth.ts:88 — race on session refresh (PR: org/repo#41) (fixed: 2026-05-08)
```

The closure loop runs automatically:

| When | What happens |
|---|---|
| Claude notices an out-of-scope issue | Logs it via `/found-issues:log` per the [rules](skills/rules/SKILL.md) |
| Claude opens a PR addressing an entry | PostToolUse hook prompts `/found-issues:annotate-pr <N>` |
| The PR merges to main | Next session's `SessionStart` hook flips `[open]` → `[fixed]` |
| The referenced file/line is deleted | Tombstone detection auto-closes the entry |
| Branch with un-promoted entries about to be deleted | `pre-branch-delete` hook blocks until `/found-issues:promote` runs |

The user does almost nothing. The count appears at session start, the
file stays accurate, and `[fixed]` history accumulates as a record of
what got addressed.

## Slash commands

All namespaced under `/found-issues:` (Claude Code plugin convention):

| Command | Use |
|---|---|
| `/found-issues:log <path:line> — <symptom>` | Log a new entry (Claude does this proactively) |
| `/found-issues:sync` | Reconcile with PR/commit history + AI-verify unannotated entries |
| `/found-issues:annotate-pr <N>` | Link an entry to a PR (auto-prompted by hooks) |
| `/found-issues:annotate-commit [<sha>]` | Link an entry to a commit (defaults to HEAD) |
| `/found-issues:promote` | Carry branch-only entries into main before branch deletion |
| `/found-issues:status` | Print current counts |
| `/found-issues:setup` | Optional first-run orientation |

Want shorter typing? Add `~/.claude/commands/fi.md` with `Run /found-issues:$ARGUMENTS` and use `/fi log` etc.

## Format spec

```
- [STATUS] [!] YYYY-MM-DD path:line — symptom (suggested: fix) (PR: org/repo#N) (fixed: YYYY-MM-DD)
```

- Statuses: `open` / `deferred` / `fixed`
- `[!]` optional critical flag
- ` — ` is U+2014 em-dash, **not** a hyphen
- Annotations are optional but enable auto-flipping; both `(PR: ...)` and `(commit: ...)` are supported and can coexist on one entry

Full grammar, regex patterns, and edge cases: [`docs/format-spec.md`](docs/format-spec.md).

## Workflow modes

found-issues auto-detects which mode each repo is in. You don't configure this — it just does the right thing per repo:

| Mode | Detected when | Closure mechanism |
|---|---|---|
| `local` | No `.git/` directory | Manual `[open]` → `[fixed]` edits + tombstone |
| `git` | Git repo, no GitHub remote | `(commit: <sha>)` annotations + tombstone |
| `github-direct` | GitHub remote, no recent merged PRs (push-to-main workflow) | `(commit: <sha>)` annotations + tombstone |
| `github-pr` | GitHub remote with recent merged PRs | `(PR: org/repo#N)` annotations + commit + tombstone |

Mixed workflow (sometimes PR, sometimes direct push) is fully supported — both annotation forms always work; mode just sets the default.

## Status

🚧 **Pre-release.** Private repo while v1 is built. Will go public when
ready to launch.

## License

MIT — see [LICENSE](LICENSE)

## Author

[DougBTW](https://github.com/DougBTW)

## For AI agents installing this

See [AGENTS.md](AGENTS.md). TL;DR: use `/plugin install found-issues`,
do not copy files manually.
