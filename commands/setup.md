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

The plugin offers a counter segment for the user's Claude Code statusline
showing `N critical · N issues · N in PR · N stale` (each shown only when
> 0).

**Use the deterministic CLI subcommand — do NOT edit the file yourself.**
The plugin ships `found-issues install-statusline` for this. It's
idempotent (marker-based), uses `|| true` so it's safe under `set -e`,
and adds a clearly-bracketed block that's trivially removable.

Flow:

1. Check if the user has a statusline: `ls ~/.claude/statusline.sh`
2. **Check if the segment is already installed.** Use the marker grep
   (NOT a generic "found-issues" string match — comments and other
   references can produce false positives):
   ```bash
   grep -Fq "# === found-issues plugin segment ===" ~/.claude/statusline.sh && echo INSTALLED || echo NOT_INSTALLED
   ```
3. If NOT installed, ask: *"Want me to add the found-issues counter
   segment to your statusline? It inserts a small marker-bracketed
   block — fully reversible with `found-issues uninstall-statusline`."*
4. On yes, run `found-issues install-statusline`. The command auto-detects
   whether the user's statusline has a LINE1 assembly pattern:
   - **LINE1 pattern detected** (multi-line statuslines): inserts the
     segment inline so it appears next to repo/branch on the same line
   - **No LINE1 pattern** (simple printf statuslines): appends the
     segment as a standalone new line
   - Either way: idempotent (marker prevents double-install), reversible
     (`uninstall-statusline`), guarded against `set -e`
5. Tell the user to restart their session to see the segment render.

If `~/.claude/statusline.sh` doesn't exist, the user uses the default
Claude Code statusline. Tell them: *"You'll see the count via the
SessionStart hook on session start regardless. If you want a custom
statusline with the counter inline, create `~/.claude/statusline.sh`
first, then run `found-issues install-statusline`."*

If the user has **claude-hud** or another statusline tool that owns the
slot, integration won't show. Tell them the SessionStart hook still
prints the count once per session.

To uninstall later: `found-issues uninstall-statusline` removes the
block cleanly without touching the rest of the file.

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
<https://github.com/AltDoug/found-issues>.

## Mark onboarding complete

After walking the user through setup, write the onboarding marker so the
first-run SessionStart nudge stops firing:

```bash
mkdir -p "$HOME/.claude/found-issues" && touch "$HOME/.claude/found-issues/.onboarded"
```

This is also touched automatically on first SessionStart — running setup
just makes it explicit.
