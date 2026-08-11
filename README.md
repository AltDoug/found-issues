# found-issues

> Your AI agent has a blind spot. **found-issues** is the Claude Code
> plugin that makes it log, track, and auto-close the bugs it would
> otherwise shrug at.

[![tests](https://github.com/AltDoug/found-issues/actions/workflows/test.yml/badge.svg)](https://github.com/AltDoug/found-issues/actions/workflows/test.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-orange.svg)](https://docs.claude.com/en/docs/claude-code/plugins)

**5 lifecycle hooks · 13 slash commands · 687 tests on Linux/macOS/Windows · zero manual bookkeeping**

![demo](hero.gif)

**Without found-issues:**

> *"Note: `parseConfig` swallows JSON errors silently — pre-existing, not
> related to our change. Continuing with the refactor."*

The observation is gone the moment the session ends.

**With found-issues:**

> *"Out of scope for this task — logging it."*

```
- [open] 2026-07-10 src/config.ts:88 — parseConfig swallows JSON errors (suggested: rethrow with path context)
```

The statusline ticks to `1 issue`, the entry survives every future
session, and it flips to `[fixed]` on its own the day a PR fixing that
line merges.

## Install

Run these in Claude Code, then start a new session:

```
/plugin marketplace add AltDoug/claude-plugins
/plugin install found-issues
```

Zero config — logging starts working immediately. One recommended step:

```
/found-issues:setup
```

That wires the statusline counter (so open issues stay visible at a
glance), the optional `/fi` shortcut, and the optional git pre-commit
hook. SSH install errors and update/uninstall details: [footnotes below](#install-notes).

### Codex

found-issues is dual-harness — the same plugin installs into OpenAI
Codex:

```
codex plugin marketplace add AltDoug/claude-plugins
codex plugin add found-issues
found-issues install-codex-hooks
```

`install-codex-hooks` is a required one-time step (re-run after `codex
plugin update`): Codex 0.144.5 removed plugin-bundled hooks, so
found-issues wires SessionStart / format-enforcer / branch-guard /
annotator into Codex's own `$CODEX_HOME/hooks.json` instead. Then start a
new Codex session. The ledger (`docs/found-issues.md`) is shared across
harnesses with no migration or sync step — a repo worked on from both
Claude Code and Codex is just one ledger. Skills are available as
`$fi-log`, `$fi-sync`, `$fi-status`, etc. Details and known v1 gaps (no
statusline, no stop-hook marker on Codex): [`AGENTS.md`](AGENTS.md#installing-for-codex).

## Quick start

Just work normally — Claude logs out-of-scope findings on its own. To
poke the system:

> *"What's open in found-issues?"* · *"Show me the critical ones"* ·
> *"Run /found-issues:fix"*

The ledger is auto-loaded into context every session, so plain-English
queries work without any command.

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
| Claude opens a PR addressing an entry | Hook auto-annotates line-matched entries silently; ambiguous cases surface as a candidate list for `/found-issues:annotate-pr <N> --pick` |
| Claude commits a fix directly to main | Hook auto-annotates line-matched entries silently; ambiguous cases surface for `/found-issues:annotate-commit` |
| PR merges or commit lands on main | Background sync flips `[open]` → `[fixed]` automatically — instantly when merged from inside the session, within ~10min for external merges, always at the next `SessionStart` as a fallback |
| Referenced file/line is deleted | Tombstone detection auto-closes the entry |
| Branch with un-promoted entries about to be deleted | `pre-branch-delete` hook blocks until `/found-issues:promote` runs |

You see a count at session start, and in your statusline:

![statusline showing 1 issue count](statusline.png)

The file stays accurate. `[fixed]` history accumulates as a record.

## Why not just tell Claude to log issues?

A CLAUDE.md rule gets you the logging — for a while. It doesn't get you:

- **Enforcement.** Hooks reject malformed entries, block branch deletion
  while entries would be orphaned, and re-prompt the check every working
  turn — the discipline survives long sessions and model drift, because
  it's mechanical, not remembered.
- **A closure loop.** Entries flip to `[fixed]` automatically when the
  fixing PR merges, or when the cited code is deleted. Prompt-only
  logging accumulates a stale file nobody trusts.
- **Visibility.** The statusline counter (`3 critical · 12 other`) keeps
  known debt in your face instead of in a file nobody opens.
- **The ledger fixes itself.** `/found-issues:fix` re-verifies every open
  entry against the *current* code, triages what's genuinely
  auto-fixable, fixes on a branch with tests, and ships a precisely
  annotated PR — with the guardrails (never re-fix ghosts, never guess
  at externally-gated fixes, never over-annotate) a bare prompt can't
  encode.

How it differs from Linear / Jira / Backlog.md: [`docs/faq.md`](docs/faq.md).

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
nudge threshold geometrically (loop prevention). Full lifecycle:
[`docs/deferring.md`](docs/deferring.md).

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

**v2.0.0** — actively developed and dogfooded (this repo's own ledger is
maintained by the plugin, including a `/found-issues:fix` run that
closed it to zero). End-to-end runtime probes exercise the generated
statusline shims against synthetic Claude Code stdin on every CI run.

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

## Install notes

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

## Contributing

Issues and PRs welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the
process. Quick PRs (typo fixes, small bugs) ship faster than big
proposals — for those, please open an issue first to discuss the design.

## License

MIT — see [LICENSE](LICENSE).

## Author

[AltDoug](https://github.com/AltDoug)
