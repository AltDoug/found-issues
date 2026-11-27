# found-issues features

Every user-facing feature, one file each. Find it by the command or the message on screen, open the file, follow **Driving it**. When a feature was last proven is in its file (`proven:`). Each `Driving it` block works pasted alone from the repo root; the usual way to run them is the kit checker's `--run` (see Features in `../SKILL.md`).

| Feature | Also called |
|---|---|
| [Log an issue](logging.md) | /found-issues:log, fi-log |
| [Counts and list](counts-and-list.md) | status, list, /found-issues:status |
| [Resolve by hand and archive](close-and-archive.md) | resolve, /found-issues:archive |
| [Defer and revive](defer.md) | /found-issues:defer, promote-deferred |
| [Fix tags and the decision queue](tags-and-decisions.md) | tag, /found-issues:decide, decisions waiting |
| [Link an entry to a PR or commit](annotate.md) | annotate-pr, annotate-commit, unannotate |
| [Suggestions after a commit or PR](commit-pr-hook.md) | post-bash-dispatch, commit-auto, PR-auto |
| [Sync closes fixed entries](sync.md) | /found-issues:sync, tombstone, held |
| [Branch delete guard and promote](branch-guard.md) | pre-branch-delete, /found-issues:promote |
| [Ledger format guard](format-guard.md) | format-enforcer, pre-commit |
| [Ledger entries shown to the agent](agent-context.md) | session-start, first-touch |
| [Stop reminder](stop-reminder.md) | stop-reminder, prompt-nudge, Stop hook error |
| [Statusline counter](statusline.md) | install-statusline, segment |
| [Health check](doctor.md) | /found-issues:doctor |
| [Auto-fix settings and status](autofix-settings.md) | config, autofix ready |
| [Auto-fix runs and the fix batch](autofix-runs.md) | auto-fix, sweep, /found-issues:fix |
| [Codex hook wiring](codex-install.md) | install-codex-hooks |
| [Setup, the /fi shortcut and uninstall](install-and-uninstall.md) | /found-issues:setup, /fi, /found-issues:uninstall |

## Shared code

- `bin/found-issues` the command line every CLI feature goes through
- `lib/parse-entries.sh` reads ledger entries for every command and hook
- `lib/canonicalize.sh` paths and the key that spots a duplicate
- `lib/repo-id.sh` which GitHub repo a PR link belongs to
- `lib/detect-mode.sh` decides between GitHub, plain git and local mode
- `lib/harness.sh` tells Claude Code from Codex inside the hooks
- `lib/hook-gate.sh` the early exits the Bash hooks share
- `lib/help.sh` the help text
- `hooks/hooks.json` registers every hook
- `.claude-plugin/` the plugin manifests and version

## Not features

- `.github/` CI and release workflows
- `evals/` model evals, nothing a user runs
- `docs/` documentation, demo and handoff scripts
- `assets/` pictures
- `scripts/check-version.sh` a release check
- `hero.tape` the README recording
- `LICENSE`
- `.gitattributes`
