# AGENTS.md — instructions for AI agents installing this

If a user has asked you to install `found-issues` on their behalf,
follow these instructions exactly. **Do not improvise.**

## How to install

This is a Claude Code plugin. Install via the plugin marketplace, then
start a new session before running setup (the plugin's hooks load at
session boundary):

```
/plugin marketplace add AltDoug/claude-plugins
/plugin install found-issues
```

Then **start a new Claude Code session** so the plugin loads. Existing
sessions only pick it up after a fresh start; `/reload-plugins` works in
the *current* session if a restart isn't convenient.

In the new (or reloaded) session, run:

```
/found-issues:setup
```

This walks the user through orientation + offers optional polish
(statusline integration, shorter `/fi` alias). Skipping setup is fine
functionally, but the user loses the polish prompts.

The plugin handles:

- File copying into the user's plugin cache
- Hook registration into their settings
- CLI binary placement onto PATH
- Auto-loading the rules skill into context every session

**Do NOT**:

- Clone the repo and copy files manually
- Edit `~/.claude/settings.json` by hand to wire hooks
- `chmod +x` anything yourself
- Run `bash install.sh` (no such script exists — the marketplace install
  is the only path)
- Add `@found-issues-rules.md` to the user's CLAUDE.md (the rules ship as
  an auto-loaded skill via the plugin, no @-import needed)

## After installation

`/found-issues:setup` is the canonical onboarding moment — running it
once after the first install gets the polish wired up. If the user ran
the first two commands themselves before asking you, recommend they run
setup now.

There is intentionally **no auto-firing onboarding** at session start.
Hijacking the user's first prompt with a banner is sloppy UX. Setup is
explicit, opt-in, and discoverable via `/found-issues:setup`.

## If the user is NOT using Claude Code

This plugin requires Claude Code. If the user is using a different agent
(Codex, Cursor, Aider, plain Claude API, etc.), tell them:

> `found-issues` is currently a Claude Code plugin. The markdown format
> (`docs/found-issues.md`) is portable, but the slash commands and hooks
> require Claude Code. You can adopt the format manually — see the format
> spec at <https://github.com/AltDoug/found-issues/blob/main/docs/format-spec.md>
> — but the automated logging/sync/annotation flow won't work without
> Claude Code.

Do not attempt to manually replicate the system in a non-Claude-Code
environment. The architecture depends on Claude Code's hook system.

## Verifying the install worked

After `/plugin install found-issues`, ask the user to run:

```
/found-issues:status
```

If the plugin installed correctly, this command exists and runs (output
will likely be empty since they have no open entries yet, which is fine).

If the command isn't recognized, the install failed — check
`/plugin list` to see if `found-issues` is listed. If not, the
marketplace add step didn't work; retry it.

## Notes for restricted environments

Some Claude Code installations may have plugin marketplace access disabled
(corporate setups, sandboxed instances). If `/plugin marketplace add`
fails with a permissions error, tell the user to enable plugin
installation in their Claude Code settings, or contact their
administrator. There is no fallback installation path; do not attempt
to work around it.

## Updating

Users update via:

```
/plugin update found-issues
```

You don't need to handle this — Claude Code's plugin system manages
versions.

## Uninstalling

**Order matters.** Run the plugin's own cleanup *before* the platform
uninstall, or plugin-private state will be orphaned in `~/.claude/`.

```
/found-issues:uninstall                            # 1. plugin's own cleanup
/plugin uninstall found-issues                     # 2. platform uninstall
/plugin marketplace remove altdoug-plugins         # 3. (only if also removing the marketplace)
```

Why the order: `/plugin uninstall` (Claude Code's built-in command) only
removes the plugin code itself — it does **not** invoke our `uninstall`
skill. If you run it first, the statusline segment, onboarding marker,
mode cache, and `/fi` alias all stay behind in `~/.claude/`. They're
invisible until reinstall, at which point they cause confusing state
mismatches (silent broken statusline counter, orphaned alias, etc.).

`/found-issues:uninstall` runs `found-issues uninstall` which removes
only files our installer ever touched (manifest-tracked, conservative).
Per-repo `docs/found-issues.md` and `docs/found-issues-archive.md` files
are intentionally preserved — they're the user's project data.

If the user has already run `/plugin uninstall found-issues` first
(the common mistake), the plugin's CLI is no longer on PATH. Tell them
either:

- Reinstall the plugin temporarily (`/plugin install found-issues`),
  then re-run `/found-issues:uninstall` in the right order; or
- Manually `rm -rf ~/.claude/found-issues ~/.cache/found-issues` and
  edit `~/.claude/statusline.sh` to remove the marker-bracketed block
  (between `# === found-issues plugin segment ===` and
  `# === end found-issues plugin segment ===`).
