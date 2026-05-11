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

Then check the user's environment and surface the relevant options.

## How to present the optional integrations

Use a **single multi-select picker** (Claude Code's `AskUserQuestion` tool
with `multiSelect: true`) — not sequential one-by-one prompts. This lets the
user see all options at once, pick what they want, and submit in one step.

**Picker order and labels (this matters):**

1. `Statusline segment (Recommended)` — list FIRST, with the `(Recommended)`
   suffix exactly as written. Without it users habitually tab through the
   picker and miss the highest-signal integration. Per Claude Code
   convention, recommended options go first with `(Recommended)` appended
   to the label.
2. `/fi short alias` — list second. Pure ergonomics; the recommendation
   doesn't apply.

**Pre-flight checks** — omit options already installed so the picker only
shows actionable items:

- `~/.claude/statusline.sh` contains `# === found-issues plugin segment ===` → omit option 1
- `~/.claude/commands/fi.md` contains `Run /found-issues:$ARGUMENTS` → omit option 2

**Doctor pass before the picker (informational, v1.0.4+):** running
`found-issues doctor-statusline` before the picker is no longer required
for correctness — `install-statusline` self-heals every broken state on
its own (auto-migrates legacy snippets with a timestamped backup as of
v1.0.4). It's still useful for *transparency*: if the user has a broken
state, surface it so they know what's about to be fixed. Recommended:

```bash
found-issues doctor-statusline
```

If the output contains `BROKEN` or `CONFLICTED`, mention it briefly
before the picker:

> _Heads up: your statusline integration is in a broken state
> (`<state from doctor>`). Picking the statusline option below will
> fix it (a timestamped backup is saved automatically)._

Then continue with the picker as normal — `install-statusline` (no flags)
handles every broken state. No conditional flag-passing or branching by
state required from you.

If **both** are already installed (and statusline is `installed-fixed`),
do not show the picker at all. Tell the user "all polish items already
done" and skip to the reporting step. This is what users see when
re-running setup after an upgrade.

The detailed install mechanics for each option are below — those describe
the CLI subcommand to invoke once the user picks.

## Optional 1 — Statusline integration

The plugin offers a counter segment for the user's Claude Code statusline
showing `N critical · N other · N in PR · N stale` (each shown only when
> 0; the residual bucket is labeled "issue/issues" when it's the only
counter on display, and "other" when alongside any of the other three).

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

**Self-heal for legacy installs (v1.0.4+):** `install-statusline` is now
fully self-healing for every broken state. Upgrading from v1.0.0/v1.0.1
(marker block missing cwd handling) or pre-v0.1.7 dogfood era
(handwritten 3-line snippet, no markers) — both cases auto-migrate on a
plain `install-statusline` call. Legacy snippets are stripped surgically
and a timestamped backup of the pre-migration file is saved at
`~/.claude/statusline.sh.fi-bak-<ts>` for one-`mv` recovery if needed.
Pass `--no-migrate` to opt back into v1.0.3 strict behavior (refuse to
touch legacy lines). Run `found-issues doctor-statusline` first if you
want to inspect without modifying anything.

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
etc. Users who want shorter typing can install a personal alias.

**Use the deterministic CLI subcommand — do NOT write the file yourself.**
The plugin ships `found-issues install-fi-alias` for this. It writes
`~/.claude/commands/fi.md` with the literal `$ARGUMENTS` placeholder
intact, refuses to overwrite a pre-existing user-authored `/fi` command,
and is fully reversible via `found-issues uninstall-fi-alias`.

Flow:

1. Check if the user already has a `/fi` command:
   ```bash
   ls ~/.claude/commands/fi.md 2>/dev/null
   ```
2. If absent, ask: *"Want me to install the `/fi` shortcut so `/fi log
   ...` expands to `/found-issues:log ...`?"*
3. On yes, run `found-issues install-fi-alias`. The CLI is idempotent
   (running twice no-ops) and won't trample a user's own `/fi.md`.

To uninstall later: `found-issues uninstall-fi-alias` removes the file
only if it's ours.

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
