# found-issues

> Your AI agent has a blind spot. This fixes it.

[![tests](https://github.com/AltDoug/found-issues/actions/workflows/test.yml/badge.svg)](https://github.com/AltDoug/found-issues/actions/workflows/test.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-orange.svg)](https://docs.claude.com/en/docs/claude-code/plugins)

![demo](hero.gif)

When Claude notices a bug, error, or warning while working on something
else, it usually shrugs and moves on — *"pre-existing, not the code we
touched, let's continue."* found-issues makes it stop, log the
observation, and surface it later. Automatically. Across sessions.
**Without the user lifting a finger.**

## What it does

The agent maintains a `docs/found-issues.md` file in each repo:

```
- [open] 2026-05-08 lib/foo.py:42 — null check missing (suggested: add guard)
- [open] [!] 2026-05-08 src/auth.ts:88 — leaks token in error (suggested: redact)
- [open] 2026-05-08 src/queue.py:12 — race on flush (PR: org/repo#42)
- [fixed] 2026-05-06 src/auth.ts:88 — race on session refresh (PR: org/repo#41) (fixed: 2026-05-08)
```

The closure loop runs **on its own**:

| When | What happens |
|---|---|
| Claude notices an out-of-scope issue | Logs it via `/found-issues:log` per the auto-loaded [rules](skills/rules/SKILL.md) |
| Claude opens a PR addressing an entry | Hook surfaces matching entries, prompts `/found-issues:annotate-pr <N>` |
| Claude commits a fix directly to main | Hook prompts `/found-issues:annotate-commit` |
| PR merges or commit lands on main | Background sync flips `[open]` → `[fixed]` automatically — instantly when merged from inside the session, within ~10min for external merges (web UI, teammate), and always at the next `SessionStart` as a fallback |
| Referenced file/line is deleted | Tombstone detection auto-closes the entry |
| Branch with un-promoted entries about to be deleted | `pre-branch-delete` hook blocks until `/found-issues:promote` runs |

You see a count at session start, and in your statusline if you have
one wired up:

![statusline showing 1 issue count](statusline.png)

The file stays accurate. `[fixed]` history accumulates as a record.
Nothing requires manual bookkeeping.

## Why this exists

Most AI coding agents have a **proactive blindspot**: they notice
defects in code they're reading, judge those defects as out-of-scope,
and silently move on. Then the bug stays in the codebase forever —
invisible to the user who'd never have spotted it themselves.

found-issues changes the contract. The agent maintains a tiny markdown
file as it works. Issues never disappear into the void. Eventually they
either get fixed (and auto-closed) or stay visible until they do.

## Install

Run these in Claude Code:

```
/plugin marketplace add AltDoug/claude-plugins
/plugin install found-issues
```

Then **start a new Claude Code session** so the plugin loads. The
plugin is now active.

<details>
<summary>Install fails with <code>Permission denied (publickey)</code>?</summary>

Claude Code's `/plugin install` currently shells out to git over SSH
for some marketplaces. Users without an SSH key set up for GitHub
will hit `Permission denied (publickey)` (even though
`/plugin marketplace add` worked — that fetch uses HTTPS).

Two paths forward:

1. **Set up SSH for GitHub.** Run `gh auth setup-git` or follow
   [GitHub's SSH key guide](https://docs.github.com/en/authentication/connecting-to-github-with-ssh).
2. **Refresh the marketplace.** As of v1.2.0, the `altdoug-plugins`
   marketplace metadata uses an explicit HTTPS clone URL. Re-run
   `/plugin marketplace add AltDoug/claude-plugins` to pick up the
   updated source, then retry `/plugin install found-issues`.

</details>

**Recommended next step** — run setup to wire up the statusline counter
(so you actually see open issues at a glance), the `/fi` shortcut, and
the optional per-repo git pre-commit hook:

```
/found-issues:setup
```

Without the statusline integration, the only visible signal is a count
at session start — easy to miss. If you're asking Claude to install
this for you, tell it to run `/found-issues:setup` after the install
completes.

<details>
<summary>Updates and uninstall</summary>

**Auto-update (recommended).** Run `/plugin`, open the **Marketplaces**
tab, pick `altdoug-plugins`, choose **Enable auto-update**. New versions
land silently at session start.

**Manual update:**

```
/plugin marketplace update altdoug-plugins
/plugin update found-issues
```

**Uninstall — order matters.** Run our cleanup *before* the platform
uninstall, or plugin-private state (statusline segment, `/fi` alias,
mode cache) will be orphaned in `~/.claude/`:

```
/found-issues:uninstall                            # 1. plugin's own cleanup
/plugin uninstall found-issues                     # 2. platform uninstall
/plugin marketplace remove altdoug-plugins         # 3. (only to remove the marketplace too)
```

Per-repo `docs/found-issues.md` files are intentionally preserved —
they're your project data.

</details>

## Quick start

After install, just work normally. To see the system in action:

> *"What's open in found-issues?"*

The file is auto-loaded into context every session, so plain-English
queries work — no special command needed. Try also: *"Show me the
critical ones"* or *"Read docs/found-issues.md, pick three entries you
can fix in under 10 minutes, and do them."*

## Slash commands

All namespaced under `/found-issues:` (Claude Code plugin convention):

| Command | Use |
|---|---|
| `/found-issues:log <path:line> — <symptom>` | Log a new entry (Claude does this proactively) |
| `/found-issues:sync` | Reconcile with PR/commit history + AI-verify unannotated entries |
| `/found-issues:fix [--auto] [--only <path>]` | Verify, triage, and fix the open entries — gated batch-fix that ships an annotated PR (`--auto` skips the gate, auto-fixable bucket only) |
| `/found-issues:annotate-pr <N>` | Link an entry to a PR (auto-prompted by hooks) |
| `/found-issues:annotate-commit [<sha>]` | Link an entry to a commit (defaults to HEAD) |
| `/found-issues:defer <path:line> [--reason <text>]` | Mark an entry as deferred (suppress from counter) |
| `/found-issues:promote-deferred <path:line>` | Promote a `[deferred]` entry back to `[open]` |
| `/found-issues:promote` | Carry branch-only entries into main before branch deletion |
| `/found-issues:status` | Print current counts |
| `/found-issues:archive` | Move old `[fixed]` entries to `docs/found-issues-archive.md` (50-entry / 30-day thresholds) |
| `/found-issues:setup` | Optional first-run orientation |
| `/found-issues:doctor` | General health check — CLI, statusline, gh, mode, hook opt-outs, issues file |
| `/found-issues:uninstall` | Clean up plugin-private state before `/plugin uninstall` |

`/found-issues:setup` offers an optional `/fi` shortcut so `/fi log
src/foo.py:42 — bug` works as a shortcut for the full namespaced form.

## Use the count as soft pressure

When the statusline reads `3 critical · 12 other`, it's a constant
reminder there's known work waiting. The critical flag (`[!]`) bubbles
drop-everything items to the top.

## Deferring recurring issues

`[deferred]` is a first-class state — tracked in the file, suppressed
from the statusline counter, and flagged when it recurs. Touch a
deferred entry enough times and the plugin nudges you to promote it
back to `[open]`. Critical entries auto-promote. Re-defer escalates the
nudge threshold geometrically (loop prevention).

Full lifecycle, formulas, and tunables: [`docs/deferring.md`](docs/deferring.md).

## Format

Entries are markdown checklist lines:

```
- [STATUS] [!] YYYY-MM-DD path:line — symptom (annotations…)
```

Statuses are `open` / `deferred` / `fixed`. `[!]` is the optional critical flag. Annotations like `(PR: org/repo#N)` and `(commit: <sha>)` are optional but enable auto-flipping. Full grammar, regex, and edge cases: [`docs/format-spec.md`](docs/format-spec.md).

## Workflow modes

Auto-detects 4 modes per repo: `local`, `git`, `github-direct`, `github-pr`. Mixed workflow (sometimes PR, sometimes direct push) is fully supported — mode just sets the default closure mechanism. Detection logic, mode table, and edge cases: [`docs/modes.md`](docs/modes.md).

## Platform support

| OS | Shell | Status |
|---|---|---|
| Linux (Ubuntu) | bash | ✅ Supported |
| macOS | bash | ✅ Supported |
| Windows | Git Bash | ✅ Supported |

The CLI and hooks are bash-based, so on Windows you need a bash
interpreter — that's what [Git for Windows](https://gitforwindows.org/)
(Git Bash) provides. WSL works too. CI runs the full test suite on all
three platforms.

## Status

**v1.6.0** — 542 tests passing in CI on Linux + macOS + Windows (Git Bash), including end-to-end runtime probes of the generated shim against synthetic Claude Code stdin. 7 lifecycle hooks + 1 opt-in git pre-commit hook, 12 slash commands, 1 CLI binary, all wired through the Claude Code plugin spec.

Have a use case the plugin doesn't cover? [Open an issue](https://github.com/AltDoug/found-issues/issues/new).

## Docs

- [`docs/architecture.md`](docs/architecture.md) — how the pieces fit together
- [`docs/format-spec.md`](docs/format-spec.md) — canonical entry format
- [`docs/modes.md`](docs/modes.md) — workflow modes and detection
- [`docs/deferring.md`](docs/deferring.md) — defer lifecycle, recurrence detection, loop prevention
- [`docs/configuration.md`](docs/configuration.md) — every env-var opt-out and tunable
- [`docs/versioning.md`](docs/versioning.md) — SemVer rules + when to bump which segment
- [`docs/faq.md`](docs/faq.md) — common questions, including "how is this different from Linear / Jira / Backlog.md / claude-mem?"
- [`AGENTS.md`](AGENTS.md) — instructions for AI agents installing this
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — how to propose changes
- [`CHANGELOG.md`](CHANGELOG.md) — version history

## Contributing

Issues and PRs welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the
process. Quick PRs (typo fixes, small bugs) ship faster than big
proposals — for those, please open an issue first to discuss the design.

## License

MIT — see [LICENSE](LICENSE).

## Author

[AltDoug](https://github.com/AltDoug)
