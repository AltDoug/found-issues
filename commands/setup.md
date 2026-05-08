---
description: First-run setup for found-issues — explains the system, surfaces optional config, walks user through statusline integration if desired
argument-hint: (no arguments)
allowed-tools: Bash(found-issues:*), Read
---

Walk the user through what `found-issues` does and the few optional things
they can enable. The plugin is already fully active — they don't need to
do anything for it to work. This command exists for orientation and
optional polish.

## What to tell the user

Print a short, friendly intro along these lines (adapt tone to the user):

> **found-issues is now active.**
>
> When I notice a bug, error, or warning outside the task we're working on,
> I'll log it to `docs/found-issues.md` automatically. Entries flip to
> `[fixed]` when a PR or commit addresses them. The count shows up at session
> start so we always know the open queue.
>
> You don't need to do anything — the system runs on its own. Below are a
> few optional polish items if you want them.

Then check the user's environment and surface only the relevant options.

## Optional 1 — Statusline integration

Run:

```bash
found-issues status --format=plain
```

If the output is non-empty, the system has open entries already. Tell the
user they can pipe this into their statusline by adding a single line to
their `~/.claude/statusline.sh` (or wherever their statusline lives):

```bash
$(found-issues status --format=segment 2>/dev/null)
```

This gives a colored counter like `1 critical · 3 issues · 2 in PR · 1 stale`.

If the user has **claude-hud** installed, statusline integration won't work
(claude-hud owns the slot). Tell them: the SessionStart hook still prints
the count once per session, so they'll still see it just less constantly.

## Optional 2 — Per-repo pre-commit hook

If the user works in a team where multiple people might edit `docs/found-issues.md`
manually (outside Claude Code), they can install a per-repo git pre-commit
hook that validates entries at commit time:

```bash
cd <their-repo>
found-issues install-precommit
```

(Available in a future release. For now, the in-Claude-Code format-enforcer
hook handles this. Skip mentioning if it's not yet implemented.)

## Optional 3 — Short alias

Plugin commands are namespaced as `/found-issues:log`, `/found-issues:sync`,
etc. Users who want shorter typing can create a personal alias by adding
this file to `~/.claude/commands/fi.md`:

```markdown
---
description: Shorthand for /found-issues commands
---

Run /found-issues:$ARGUMENTS
```

Then `/fi log src/foo.py:42 — bug` works as a shortcut for
`/found-issues:log src/foo.py:42 — bug`.

## Reporting

Show the user the current state:

```bash
found-issues status --format=plain
```

Tell them the rules file is auto-loaded into context (no further action
needed) and that the system is ready.

If they want to read more, point them at the project README:
<https://github.com/DougBTW/found-issues>.
