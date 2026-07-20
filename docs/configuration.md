# Configuration

Every plugin behavior that's tunable from the environment is listed here.
Set an env var in your shell rc (`~/.zshrc`, `~/.bashrc`) so it persists
across sessions; set it inline (`FOO=bar found-issues …`) for one-off
overrides.

> The plugin runs sensible defaults out of the box — most users never
> touch this page. Reach for it when a hook is too loud / too quiet, or
> when a default threshold doesn't match your team's cadence.

## Hook opt-outs

The plugin registers 5 hooks in `hooks/hooks.json` (see
[architecture](architecture.md) for the full table): `format-enforcer`,
`pre-branch-delete`, `post-bash-dispatch`, `session-start`, and
`stop-reminder`. `post-bash-dispatch` is a router — it fires on every
PostToolUse `Bash` call and dispatches up to three independent routes
(auto-annotate after `gh pr create`, auto-annotate after `git commit`,
background sync after `gh pr merge`/`close`/`reopen`), so it has two
route-scoped opt-outs (`FOUND_ISSUES_AUTO_ANNOTATE`,
`FOUND_ISSUES_POST_PR_STATE`) instead of one whole-hook switch. Three
hooks (`stop-reminder`, `pre-branch-delete`, `format-enforcer`) have a
whole-hook `=off` switch, listed below alongside the route-scoped
switches, the opt-in git pre-commit hook's, and the SessionStart hook's
auto-migration switch. `session-start` and `post-bash-dispatch` are
informational/additive and never block a tool call, on top of their
individual opt-outs.

| Variable | Default | What it controls |
|---|---|---|
| `FOUND_ISSUES_STOP_REMINDER` | `on` | The Stop hook that requires `<!-- found-issues-checked: ... -->` in any assistant turn that did substantive tool use (Edit / Write / MultiEdit / Bash). Set to `off` if the marker friction outweighs the discipline-enforcement value. |
| `FOUND_ISSUES_REMINDER_VERBOSITY` | `auto` | Stop-hook message verbosity. `full` (8-line educational form), `terse` (1-line form), or `auto` (terse iff `~/.claude/found-issues/.onboarded` exists). |
| `FOUND_ISSUES_PROMOTE_GUARD` | `on` | The `pre-branch-delete` hook that hard-blocks `git branch -d` / `--delete` / `gh api ... DELETE` when the branch has `[open]` entries whose dedup key isn't on `main`. Set to `off` for a one-shot bypass (`FOUND_ISSUES_PROMOTE_GUARD=off git branch -D ...`). The inline prefix form is parsed from the command string itself, so it works inside Claude Code's Bash tool (where the hook subprocess otherwise would not inherit per-command env). The guard also auto-skips when the default branch does not track the issues file — repos using per-developer-local (gitignored) `docs/found-issues.md` get an exit-0 with a one-line note rather than a block. |
| `FOUND_ISSUES_FORMAT_ENFORCER` | `on` | The `PreToolUse` format-enforcer that validates entries written via `Write` / `Edit` / `MultiEdit`. In `local` mode it's already off; in `git` mode it warns-only; in `github-*` modes it hard-blocks. Set to `off` to disable globally. |
| `FOUND_ISSUES_PRE_COMMIT` | `on` | The optional per-repo `pre-commit.sh` git hook (installed manually: `cp <plugin-root>/hooks/pre-commit.sh .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit` — there is no installer subcommand). Same validation rules as the in-Claude-Code enforcer but at git commit time. Set to `off` to disable. |
| `FOUND_ISSUES_AUTO_ARCHIVE` | `on` | The auto-archive that runs after every `/found-issues:sync`. Moves old `[fixed]` entries to `docs/found-issues-archive.md` per the count + days thresholds. Set to `off` if you'd rather control archiving manually via `/found-issues:archive`. |
| `FOUND_ISSUES_AUTO_ANNOTATE` | `on` | The `post-bash-dispatch` routes that auto-annotate after `gh pr create` / `git commit`. Line-matched `[open]` entries (the PR/commit diff actually touches the cited line) annotate silently with `(PR: org/repo#N)` / `(commit: <sha>)`; entries needing judgment are surfaced as a candidate list instead. Set to `off` to fall back to the pre-2.0 behavior: the hook only prompts (`/found-issues:annotate-pr <N>` / `/found-issues:annotate-commit`), annotating nothing itself. |
| `FOUND_ISSUES_AUTO_ANNOTATE_MAX` | `3` | Mass-touch guard for `--hook-auto` mode. If a single PR or commit would silently auto-annotate more than this many entries (a sweep PR line-matching everything — the shape of the 2026-07-09 over-annotation incident), the hook annotates none of them and surfaces the full candidate list for manual `--pick`/`--all` instead. |
| `FOUND_ISSUES_POST_PR_STATE` | `on` | The `post-bash-dispatch` route that fires `found-issues sync` in the background after `gh pr merge` / `gh pr close` / `gh pr reopen`. Lets the statusline reflect the new state immediately instead of waiting for the next session start. Set to `off` to disable just this route — the hook's annotation routes above keep running. |
| `FOUND_ISSUES_AUTO_MIGRATE` | `on` | The SessionStart auto-migration of broken statusline marker blocks (v1.4.x POSIX-only and v1.5.0–v1.5.5 `--cwd`-less custom targets). Set to `off` to keep session start fully hands-off and migrate manually via `found-issues install-statusline --target <path> --apply`. |
| `FOUND_ISSUES_SESSION_INJECT_MAX` | `15` | Caps how many `[open]` entries the SessionStart hook injects into context. Critical (`[!]`) entries are always injected in full; the newest non-critical entries fill the remaining slots up to this cap; anything past the cap is summarized as a one-line count instead of injected verbatim. Raise it for repos with a large deliberate backlog you want fully visible every session; lower it to shrink the SessionStart token cost. |
| `FOUND_ISSUES_SEGMENT_AUTOSYNC` | `on` | Throttled in-segment background sync (default once per 10 min). Triggered from `found-issues status --format=segment` — runs detached, statusline returns immediately. Set to `off` to disable the auto-refresh entirely. |

Example — silence the Stop reminder and disable auto-archive, but keep
everything else:

```bash
export FOUND_ISSUES_STOP_REMINDER=off
export FOUND_ISSUES_AUTO_ARCHIVE=off
```

### Stop hook auto-skip for non-interactive sessions (v1.5.5+)

The Stop hook also auto-skips when Claude Code is running outside an
interactive `cli` session. Claude Code sets `CLAUDE_CODE_ENTRYPOINT` to:

- `cli` — interactive terminal session (the hook fires; operator is watching)
- `sdk-cli` — headless `claude -p` invocations (the hook skips)
- other values (`sdk`, future entrypoints) — direct SDK use (the hook skips)

The marker discipline is a human-operator habit: read each response, decide
whether anything out-of-scope deserves logging, ack via the marker.
Dispatched / headless sessions have no addressee for that discipline — the
model can't satisfy a requirement it has no context for, and `stop_hook_active`
only breaks immediate same-turn retry loops, not multi-turn confusion spirals.

You don't need to set anything to opt into this — the hook just notices when
`CLAUDE_CODE_ENTRYPOINT != "cli"` and exits 0 silently. If you need the
discipline-enforcement to fire in a headless context anyway, the existing
`FOUND_ISSUES_STOP_REMINDER` knob still wins: when it's unset/`on`, the
entrypoint check runs; if you ever wanted to *force* enforcement in headless
mode, that would require unsetting `CLAUDE_CODE_ENTRYPOINT` upstream of the
hook (not recommended — Claude Code uses it internally too).

## Defer-flow tunables

The defer-recurrence flow (v1.0.5+) ships with conservative defaults.
Override either knob to match your team's tolerance for nudge cadence.

| Variable | Default | What it controls |
|---|---|---|
| `FOUND_ISSUES_DEFER_TOUCH_THRESHOLD` | `3` | Base threshold for cycle 1. The first nudge fires when a `[deferred]` entry has been touched this many times. |
| `FOUND_ISSUES_DEFER_ESCALATION_FACTOR` | `2` | Multiplicative factor for subsequent cycles. Cycle N's threshold is `base × factor^(N-1)`. With defaults: cycle 1 = 3, cycle 2 = 6, cycle 3 = 12, cycle 4 = 24. |

Examples:

```bash
# More patient: nudge after 5 touches (cycle 1), 25 (cycle 2), 125 (cycle 3)
export FOUND_ISSUES_DEFER_TOUCH_THRESHOLD=5
export FOUND_ISSUES_DEFER_ESCALATION_FACTOR=5

# More aggressive: nudge on every other touch, no escalation
export FOUND_ISSUES_DEFER_TOUCH_THRESHOLD=2
export FOUND_ISSUES_DEFER_ESCALATION_FACTOR=1
```

Invalid values (non-numeric, ≤ 0) warn to stderr and fall back to the
defaults. The warning fires once per `found-issues log` invocation that
touches a deferred entry, not on shell startup.

## Status-segment tunables

| Variable | Default | What it controls |
|---|---|---|
| `FOUND_ISSUES_STALE_DAYS` | `30` | The "stale" counter in `found-issues status` flags `[open]` entries older than this many days. Drop it to surface bit-rot sooner; raise it for projects that genuinely revisit entries quarterly. |
| `FOUND_ISSUES_SEGMENT_AUTOSYNC_INTERVAL` | `600` | Seconds between background syncs fired from the statusline-segment renderer. Lower for fresher counts at the cost of more `gh pr view` calls; raise for long sessions where you don't need second-by-second accuracy. Has no effect when `FOUND_ISSUES_SEGMENT_AUTOSYNC=off`. |

```bash
# Surface stale entries after a week instead of a month
export FOUND_ISSUES_STALE_DAYS=7

# Tighter segment-autosync — refresh every 2 minutes instead of 10
export FOUND_ISSUES_SEGMENT_AUTOSYNC_INTERVAL=120
```

## Mode override

The plugin auto-detects which mode each repo is in (`local` / `git` /
`github-direct` / `github-pr`). The detection is cached per-repo for 1
hour at `~/.cache/found-issues/mode_<owner>_<repo>`.

| Variable | Default | What it controls |
|---|---|---|
| `FOUND_ISSUES_MODE` | (auto-detected) | Forces a specific mode for the current invocation. Useful for testing or for repos where auto-detection gets it wrong. Any non-empty value short-circuits detection (the value is used verbatim — valid values are `local`, `git`, `github-direct`, `github-pr`). |

```bash
# Force github-pr mode for a repo whose detection lands on github-direct
export FOUND_ISSUES_MODE=github-pr
```

## Internal / testing knobs

These exist for testing and edge cases. Most users never touch them.

| Variable | Default | What it controls |
|---|---|---|
| `FOUND_ISSUES_BIN` | (resolved via `command -v`) | Path to the `found-issues` CLI. Hooks use this to invoke the CLI when it's not on PATH. Set explicitly when running tests against an unpacked build. |
| `FOUND_ISSUES_LIB_DIR` | (resolved relative to `$FOUND_ISSUES_BIN`) | Path to the `lib/` directory. Hooks source `parse-entries.sh`, `canonicalize.sh`, and `detect-mode.sh` from here. Override when running tests outside the installed-plugin layout. |
| `CLAUDE_PROJECT_DIR` | (set by Claude Code) | Used as the search root by `found-issues status` when invoked from a statusline subprocess (which doesn't inherit the workspace as cwd). Falls back to `$PWD`. The `--cwd PATH` flag overrides this. |
| `CLAUDE_PLUGIN_ROOT` | (set by Claude Code) | Used by hooks to locate the plugin's `lib/` when `FOUND_ISSUES_LIB_DIR` isn't set. |
| `FOUND_ISSUES_AUTOSYNC_CMD` | (none) | Overrides the command dispatched by the segment-autosync and `post-bash-dispatch.sh` hooks. Tests set this to a marker-writer so they can verify dispatch without invoking real `gh pr view` traffic. Production users have no reason to set it. |
| `FOUND_ISSUES_CACHE_DIR` | `$HOME/.cache/found-issues` | Override the cache root that holds segment-autosync's timestamp file (`segment-autosync-ts`) and other plugin caches. Tests use this for isolation. |
| `FOUND_ISSUES_BASH` | (resolved via `PATH`) | Path to the `bash` binary used by the Python statusline shim on Windows, where PATH resolution can land on the WSL `bash` instead of Git Bash. Set it to Git Bash's `bash.exe` if the Python custom-target segment renders empty on Windows. |

## Discoverability

The plugin tries to surface friction in-band rather than expecting users
to find this page:

- The Stop hook's blocking message names `FOUND_ISSUES_STOP_REMINDER=off`
  in its stderr output when it fires.
- `pre-branch-delete` names `FOUND_ISSUES_PROMOTE_GUARD=off` when it
  blocks.
- Invalid defer-flow tunables warn to stderr with the variable name.

If a hook is misbehaving and there's no helpful message, that's a bug —
open an issue.

## Where to set these

| Where | Scope |
|---|---|
| Inline (`FOO=bar found-issues …`) | One command only |
| `~/.zshrc` / `~/.bashrc` | Every shell on this machine |
| `~/.config/claude-code/env` (if your CC install reads it) | Claude Code sessions only |
| Project-local `.envrc` (with [direnv](https://direnv.net/)) | One repo only |

The plugin reads them at invocation time — no restart needed beyond
opening a new shell after editing your rc file.
