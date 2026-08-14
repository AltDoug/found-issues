# FAQ

## What does it actually do?

When Claude (or any AI agent) notices a bug, error, or warning while
working on something else, it usually shrugs: *"pre-existing, not the
code we touched, let's move on."* found-issues makes it stop, log the
observation to `docs/found-issues.md`, and surface it later. Entries
flip to `[fixed]` automatically when a PR or commit addresses them.

The user does almost nothing. The agent runs the whole loop.

## How is this different from GitHub Issues / Linear / Jira?

Different shape, different purpose:

| | found-issues | GitHub/Linear/Jira |
|---|---|---|
| What it tracks | Defects the AI noticed but didn't fix | Anything (features, bugs, tasks, ideas) |
| Who creates entries | The AI agent | Humans |
| Storage | Plain markdown in your repo | Database in someone else's cloud |
| Workflow | `[open]` → `[fixed]` (auto) | Triage → assign → states |
| Visibility | Wherever your code lives | Separate tool |

found-issues is for the long tail of *"I just noticed this and don't
want to lose it"*. Use real issue trackers for things that need
discussion, prioritization, or assignment.

## How is this different from Backlog.md / claude-mem?

- **Backlog.md** is a generic markdown kanban for any task. found-issues
  is specifically for *defects the AI agent noticed*, with PR-linked
  auto-closure and format enforcement that Backlog.md doesn't have.
- **claude-mem** captures session memory broadly. found-issues
  captures one specific thing — bugs/defects — and acts on them
  (auto-flipping on merge, surfacing during related work).

You can run all three. They don't overlap functionally.

## How does sync know what's fixed?

Three mechanisms, in priority order:

1. **Annotation match.** Entries with `(PR: org/repo#N)` get checked via
   `gh pr view`. Merged PRs flip the entry to `[fixed]`. Same for
   `(commit: <sha>)` — checked via `git merge-base --is-ancestor` against
   the default branch.

2. **Tombstone.** If git confirms the referenced file was **removed** — absent
   from `HEAD` and present in history — the entry auto-closes with
   `(closure: tombstone)`. Absence alone is never enough: a file that is merely
   shorter than the cited line, a path git never tracked (abstract locations,
   typos, gitignored paths), and an uncommitted deletion all leave the entry
   `[open]`. Closures cannot be undone, so sync fails toward keeping entries.

3. **AI verification** (only when you run `/found-issues:sync` inside
   Claude Code, not the background sync). Claude reads the code at each
   unannotated entry's `path:line` and decides if the symptom is still
   present. **Conservative bias is mandatory** — Claude only flips on
   confident "fixed" verdicts, leaves ambiguous cases as `[open]`.

## What if a teammate fixes the bug without annotating?

Two paths:

1. **AI verification catches it eventually.** Next time you run
   `/found-issues:sync`, Claude reads the code, sees the bug is gone,
   flips to `[fixed] (verified: ai)`.

2. **You manually edit the entry.** Open `docs/found-issues.md`, change
   `[open]` to `[fixed]`, append `(fixed: YYYY-MM-DD)`. The file is just
   markdown — humans can edit it directly.

## Can I use this without GitHub?

Yes. found-issues auto-detects which mode you're in and adapts:

- **No git at all** → `local` mode. File lives at `<cwd>/.found-issues.md`.
  Closures are manual or via tombstone.
- **Git but not GitHub** → `git` mode. Closures via `(commit: <sha>)`
  annotations.
- **GitHub but no PRs** → `github-direct` mode. Same as `git` mode
  closure-wise.
- **GitHub with PRs** → `github-pr` mode. Full PR-linked workflow.

See [`docs/modes.md`](modes.md) for details.

## Does this require Claude Code?

No — found-issues is dual-harness: the same plugin installs into both
Claude Code and OpenAI Codex. Claude Code gets slash commands
(`/found-issues:<name>`) plus the auto-loaded rules skill; Codex gets
generated skills (`$fi-<name>`) plus SessionStart rules injection. Both
run the same hooks and CLI underneath.

The markdown format itself (`docs/found-issues.md` with the canonical
entry shape) is portable beyond both. You could adopt the convention
manually with a different agent (Cursor, Aider, plain API) — but you'd
lose the automation; see [`docs/format-spec.md`](format-spec.md).

## Does the ledger stay in sync between Claude Code and Codex?

Yes, trivially — there's only ever one ledger. `docs/found-issues.md` is
a single committed file; whichever harness is running reads and writes
the same file, so a repo worked on from both Claude Code and Codex in
the same day shares one ledger with no migration or sync step required.

Two known v1 gaps on Codex specifically:

- **No statusline counter.** Codex has no statusline surface, so the
  `3 critical · 12 other` glance-view only exists in Claude Code. The
  SessionStart entry injection and `found-issues status` still work on
  Codex — you just don't get the always-visible segment.
- **No stop-hook marker discipline.** The `<!-- found-issues-checked:
  ... -->` enforcement is Claude-only in v1 — Codex's transcript format
  isn't parsed by the smart-fire logic, so the hook fails open (never
  blocks) on Codex. Logging still works via the auto-injected rules;
  it's just not mechanically enforced every turn.

## Will it work with Cursor / Aider / plain API?

Not currently. Beyond Claude Code and Codex, the architecture relies on
hook lifecycle events (PreToolUse, PostToolUse, SessionStart, Stop) that
other agents don't expose the same way.

If there's demand, the slash commands and CLI could be extracted into a
universal layer, with per-agent integration shims. Open an issue if you
want this.

## How do I uninstall?

Two steps, **in this order**:

```
/found-issues:uninstall
/plugin uninstall found-issues
```

Order matters. Step 1 removes the integrations that live OUTSIDE the
plugin directory — the statusline segment in `~/.claude/statusline.sh`,
the `/fi` alias, and plugin-private state under `~/.claude/found-issues/`.
Step 2 then removes the plugin itself: hooks from your settings, the CLI
from PATH, and the plugin cache directory. Running step 2 first strands
the statusline segment with no CLI behind it (the v1.0.3 leftover-counter
bug this order exists to prevent) — the segment fails soft (empty), but
you'd have to clean `~/.claude/statusline.sh` by hand.

Your `docs/found-issues.md` files are NOT touched by either step —
they're project files that belong to you.

If you want to fully purge the format and history, just `git rm
docs/found-issues.md` in each repo and commit.

## Can I customize the format?

Not in v1. The format is fixed because hooks, CLI, and slash commands
all validate against the same regex patterns — letting users customize
would break everything downstream.

What's optional within the format:
- Whether to include a path:line (abstract entries are fine)
- Whether to include `(suggested: ...)`
- Whether to use `[!]` for critical
- Stale threshold (`FOUND_ISSUES_STALE_DAYS`, default 30)

What's not customizable:
- Status set (`open`/`deferred`/`fixed`)
- Date format (ISO 8601)
- Separator (em-dash with spaces)
- Annotation forms (`(PR: ...)`, `(commit: ...)`, `(fixed: ...)`)

If you have a use case that needs format extension, open an issue —
might be worth a v2 feature.

## What happens if Claude flips an entry that wasn't actually fixed?

The entry shows `[fixed] (verified: ai)`. You'll notice during normal
work that the bug is still there. Two recoveries:

1. **Manually flip back.** Edit `docs/found-issues.md`, change
   `[fixed]` → `[open]`, remove the `(verified: ai)` and `(fixed: ...)`
   annotations. The file is plain markdown.

2. **Re-log.** Run `/found-issues:log <path:line> — <symptom>` again
   with a fresh observation. The system treats this as a regression.

The conservative bias in `/found-issues:sync` is supposed to prevent
false-positives. If you see them happen often, that's a bug in the
verification rules — please report.

## Does the SessionStart count clutter the conversation?

Only if you have open entries. If `[open]` count is zero, the
SessionStart hook is silent. So a fresh repo or a repo where everything's
been resolved gets no banner.

If you're in a repo with permanent backlog that you've consciously
deferred, set the entries to `[deferred]` and they won't count.

## Does it slow down sessions?

The SessionStart hook runs `bin/found-issues sync` at session start. In
practice this is <1 second unless `gh pr view` calls hit GitHub rate
limits — which they normally don't, since the system caches mode detection
for an hour.

The Stop-hook reminder runs every turn but is essentially instant (a
single `tail -c 8192` + grep).

The PostToolUse hook (post-bash-dispatch) only fires when its matched
commands run, so it doesn't add per-turn overhead.

## What about repos I don't want this for?

Set the env var:

```bash
export FOUND_ISSUES_STOP_REMINDER=off
```

…to disable just the Stop-hook marker (the most-visible piece). Or
uninstall the plugin entirely if you don't want any of it.

You can also disable individual hooks:
- `FOUND_ISSUES_FORMAT_ENFORCER=off`
- `FOUND_ISSUES_PROMOTE_GUARD=off`
- `FOUND_ISSUES_PRE_COMMIT=off`
- `FOUND_ISSUES_AUTO_ARCHIVE=off` — disables the auto-archive of old `[fixed]` entries that runs after each sync. Default behavior moves fixed entries older than 30 days (or oldest entries when count exceeds 50) to `docs/found-issues-archive.md` to keep the active file lean. Setting this off means the active file accumulates indefinitely; you'll need to run `/found-issues:archive` manually to reclaim space.

## How do I update?

```
/plugin update found-issues
```

Claude Code's plugin loader checks the marketplace for newer versions
and swaps them in. We bump `version` in the manifest on each release.

## How is this maintained?

Solo project, MIT-licensed. Built openly. Issues and PRs welcome — see
[CONTRIBUTING.md](../CONTRIBUTING.md). No SLA on responses, but the
system is small enough that maintainership is realistic for one person.

## I want a feature that isn't here

Open an issue. Concrete proposals (with use case + example) get
considered faster than vague requests. Smaller features ship faster than
big ones.
