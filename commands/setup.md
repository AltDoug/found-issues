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

The plugin can append a colored counter segment to the user's statusline
showing `N critical · N issues · N in PR · N stale` (each shown only when
> 0).

**Detect the user's statusline first:**

```bash
ls "$HOME/.claude/statusline.sh" 2>/dev/null
```

If it exists, ask the user: *"I can add a found-issues counter segment to
your statusline. Want me to wire it up?"* If they say yes:

1. Read the statusline file first (`Read ~/.claude/statusline.sh`).
2. Find where the output lines are assembled (look for `LINE1=`, `printf`,
   or `echo` calls that build the statusline output).
3. Insert these **two lines** into the LINE1 assembly section, right after
   the last segment that builds LINE1 (before peers, before LINE2):

```bash
# found-issues counter (added by /found-issues:setup)
FI_SEG=$(found-issues status --format=segment 2>/dev/null || true)
[[ -n "$FI_SEG" ]] && LINE1="$LINE1 ${DIM}|${RESET} $FI_SEG"
```

**CRITICAL: the `|| true` is mandatory.** Many statusline scripts use
`set -e` or `set -euo pipefail`. Without `|| true`, the `found-issues`
command-not-found exit code kills the entire statusline script (the
statusline runs as a raw shell exec, not inside Claude Code, so the
plugin's CLI may not be on PATH). The `|| true` makes the segment
silently absent when the CLI isn't available, instead of breaking
everything.

If the statusline doesn't use a `LINE1`-style variable assembly pattern
(e.g., it uses direct `printf` output), adapt the insertion to match the
file's existing structure — but ALWAYS use `|| true` on the command
substitution.

If the user already has a found-issues counter (search for `found-issues`
in the statusline file), tell them: *"You already have a counter. The
plugin's segment would duplicate. Skip this step or remove the existing
counter first."*

If they don't have a `~/.claude/statusline.sh`, they likely use the
default Claude Code statusline. Tell them: *"You'll see the count via the
SessionStart hook on session start regardless. To wire up a statusline
yourself, set up `~/.claude/statusline.sh` first then re-run setup."*

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
<https://github.com/AltDoug/found-issues>.

## Mark onboarding complete

After walking the user through setup, write the onboarding marker so the
first-run SessionStart nudge stops firing:

```bash
mkdir -p "$HOME/.claude/found-issues" && touch "$HOME/.claude/found-issues/.onboarded"
```

This is also touched automatically on first SessionStart — running setup
just makes it explicit.
