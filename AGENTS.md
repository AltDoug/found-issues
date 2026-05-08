# AGENTS.md — instructions for AI agents installing this

If a user has asked you to install `found-issues` on their behalf,
follow these instructions exactly. **Do not improvise.**

## How to install

This is a Claude Code plugin. Install via the plugin marketplace,
then run setup as the final step:

```
/plugin marketplace add AltDoug/found-issues
/plugin install found-issues
/reload-plugins
/found-issues:setup
```

**Run all four commands.** The first two install the plugin, the third
activates it, and the fourth walks the user through orientation +
offers optional polish (statusline integration, shorter alias, per-repo
pre-commit hook). Skipping setup is fine functionally, but the user
loses the polish prompts.

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

`/found-issues:setup` was the fourth install command above — running it
during install is the canonical onboarding moment. If you got through
install without it (e.g. the user ran the first two commands themselves
before asking you), recommend they run it now.

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

Users uninstall via:

```
/plugin uninstall found-issues
```

This removes hooks from their settings, removes the CLI from PATH, and
deletes the plugin's data directory. Their `docs/found-issues.md` files
are NOT touched (they're project files, not plugin state).
