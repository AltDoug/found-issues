# Changelog

All notable changes documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned

- Demo GIF embedded in README before public flip
- Public release (flip repo from private to public)
- Submission to official Claude Code marketplace

## [0.1.10] — 2026-05-09

### Added

- **Light first-run onboarding hint.** SessionStart hook now prepends a single italicized line to the user's first response after install: *"found-issues plugin is now active. Run `/found-issues:setup` for orientation + optional integrations."* Then never fires again (marker at `~/.claude/found-issues/.onboarded`). This closes the discoverability gap from v0.1.5: manual installers via `/plugin install` UI never read the README, so they had no signal that `/found-issues:setup` existed. The v0.1.4 verbose-directive approach was rejected as too "sloppy" (full block hijacked first response). v0.1.10 is the middle ground — visible enough to discover, light enough to not derail.

## [0.1.9] — 2026-05-09

### Changed

- **Archive is now enforced by default.** Sync auto-runs `archive` after the closure pass, surfacing output only when entries actually moved. Without enforcement, users forgot the command existed and active files grew unboundedly. Matches the rest of the plugin's "just works" model (sync auto-flips, format-enforcer auto-blocks, stop-reminder auto-fires).
- Opt-out via `export FOUND_ISSUES_AUTO_ARCHIVE=off`. When disabled, sync prints a hint instead so users still discover the command.

### Added

- 3 new bats tests covering auto-archive behavior (default-on, opt-out, no spurious output).

## [0.1.8] — 2026-05-09

### Added

- **`/found-issues:archive` command + `found-issues archive` CLI subcommand** — moves old `[fixed]` entries to `docs/found-issues-archive.md`. Triggers when EITHER threshold met:
  - Days: `(fixed: YYYY-MM-DD)` older than 30 days (default, `--days=N` to override)
  - Count: total `[fixed]` entries exceed 50 (default, `--count=N` to override) — oldest move first
- `--dry-run` flag previews what would move without modifying files
- Archive file is append-only — the plugin never modifies it after writing
- Open + deferred entries are never touched
- Sync now prints a one-line hint when archive thresholds are exceeded, so users discover the command organically
- 9 new bats tests covering all archive paths

### Why

Real-world entry rate during active development is ~25/day per repo, not "50–200/year" as initially scoped. At that pace, files grow fast and the active file becomes harder to scan. Archive keeps the active file lean while preserving full closure history in a separate append-only file. Single-source-of-truth model preserved (one active + one archive, both readable, no synchronization across multiple status-split files).

## [0.1.7] — 2026-05-09

### Added

- **`found-issues install-statusline`** — deterministic CLI subcommand that appends a marker-bracketed segment block to `~/.claude/statusline.sh`. Replaces the prior approach of asking Claude to read and edit the file in setup.md, which introduced variability across users (some got the `|| true` guard, some didn't). Idempotent (re-runs detect existing install via marker), uses `if/fi` not `&& chains` (so the block's final exit code is always 0), pre-pads the file's trailing newline if missing.
- **`found-issues uninstall-statusline`** — removes the marker block cleanly. Verified byte-identical-to-original via test.
- 8 new bats tests covering install/uninstall edge cases (missing file, idempotency, set -e survival, byte-identical roundtrip).

### Changed

- `commands/setup.md` no longer asks Claude to edit the statusline file. Setup just calls `found-issues install-statusline` after the user opts in. Removes the variability where Claude could miss the `|| true` guard and brick the user's statusline.

## [0.1.6] — 2026-05-08

### Fixed

- **Statusline integration safety**: `setup.md` now enforces `|| true` on the `found-issues status` command substitution. Prevents a `set -e` / `set -euo pipefail` statusline script from dying when the found-issues CLI isn't on PATH (the statusline runs as a raw shell exec outside Claude Code, where the plugin's auto-PATH doesn't apply). Also instructs Claude to insert inline at the LINE1 assembly point rather than appending, so the segment renders in the correct position.

## [0.1.5] — 2026-05-08

### Removed

- **Auto-firing onboarding** in SessionStart hook (added in v0.1.3, made visible in v0.1.4). Forcing every user's first prompt to be hijacked by an orientation block is bad UX. Onboarding belongs in the install ritual, not in a context hijack.

### Changed

- **Install ritual now four commands:** `/plugin marketplace add`, `/plugin install`, `/reload-plugins`, `/found-issues:setup`. Setup is the canonical onboarding moment — run during install, not later. README and AGENTS.md updated to make this explicit.
- AGENTS.md tells installing AIs to run all four steps; if the user already installed the first two themselves, the AI recommends `/found-issues:setup` immediately rather than waiting.

## [0.1.4] — 2026-05-08

### Fixed

- **First-run onboarding now actually visible.** SessionStart hook stdout is injected into Claude's *context*, not displayed to the user. v0.1.3's banner-style output got read by Claude but never spoken to the user. v0.1.4 reframes the output as a directive *to* Claude — telling the assistant to surface the orientation block at the top of its very next response. The user reliably sees the message now.

### Changed

- `commands/setup.md` statusline integration is now an actionable offer instead of just informational. Setup detects whether the user has a `~/.claude/statusline.sh`, asks for consent, then wires the segment append automatically. Detects existing counters to avoid duplicates.

## [0.1.3] — 2026-05-08

### Added

- **First-run onboarding nudge**: SessionStart hook prints a one-time orientation message inviting the user to run `/found-issues:setup`. Marker at `~/.claude/found-issues/.onboarded` blocks repeats. Without this, new users had no signal that `/found-issues:setup` existed.

### Changed

- `AGENTS.md`: install instructions now tell the installing AI to recommend `/found-issues:setup` after install (covers the agentic-install path; the SessionStart nudge covers the manual-install path)
- `commands/setup.md`: setup explicitly writes the onboarding marker on completion

## [0.1.2] — 2026-05-08

### Fixed

- **Stop-hook smart-fire**: only requires the `<!-- found-issues-checked: ... -->` marker on assistant turns that included substantive tool use (Edit/Write/MultiEdit/Bash/NotebookEdit). Pure-conversation turns (greetings, Q&A, brainstorm) no longer get blocked. This was the right behavior all along — a "Hello" reply has no code-change context to notice issues against.
- `bin/found-issues` `FI_VERSION` constant synced to manifest version (was hardcoded `0.1.0` regardless of release)

## [0.1.1] — 2026-05-08

### Fixed

- `marketplace.json` source schema corrected (`source: github, repo: owner/name` per Claude Code spec — previous `type/owner/repo` form failed install)
- `marketplace.json` missing required top-level `name` and `owner` fields
- `plugin.json` removed redundant `"hooks": "./hooks/hooks.json"` field — the standard `hooks/hooks.json` auto-loads via convention; explicit reference caused duplicate-load error on `/reload-plugins`

### Changed

- GitHub owner renamed `DougBTW` → `AltDoug` in all canonical refs (URLs, badges, LICENSE copyright, format-spec examples)

## [0.1.0] — 2026-05-08

Initial release. Built across 7 PRs in a single design + implementation
sprint.

### Added

**Plugin packaging**
- Claude Code plugin manifest (`.claude-plugin/plugin.json`)
- Marketplace listing (`.claude-plugin/marketplace.json`) for `/plugin marketplace add`
- Auto-loading rules skill (`skills/rules/SKILL.md` with `disable-model-invocation: true`)
- Hook event registration (`hooks/hooks.json`) using `${CLAUDE_PLUGIN_ROOT}`

**Slash commands** (all namespaced under `/found-issues:`)
- `/found-issues:log` — append a new `[open]` entry
- `/found-issues:sync` — annotation-driven flip + tombstone close + AI verification of unannotated entries
- `/found-issues:annotate-pr` — append `(PR: org/repo#N)` to matching entries
- `/found-issues:annotate-commit` — append `(commit: <sha>)` to matching entries (defaults to HEAD)
- `/found-issues:promote` — list branch-only entries needing consolidation
- `/found-issues:status` — print counters (critical / issues / in PR / stale)
- `/found-issues:setup` — first-run orientation

**Hooks**
- `format-enforcer.sh` (PreToolUse Write/Edit/MultiEdit) — mode-aware: hard-block in github-pr/github-direct, warn in git, off in local
- `session-start.sh` (SessionStart) — runs sync, injects `[open]` entries into context, prints count
- `stop-reminder.sh` (Stop) — forces `<!-- found-issues-checked: ... -->` marker on every assistant turn
- `post-pr-create.sh` (PostToolUse Bash) — surfaces matching entries after `gh pr create`
- `post-git-commit.sh` (PostToolUse Bash) — surfaces matching entries after `git commit`
- `pre-branch-delete.sh` (PreToolUse Bash) — hard-blocks branch deletion if entries unpromoted
- `pre-commit.sh` — per-repo git pre-commit hook (opt-in via `found-issues install-precommit` — planned)

**CLI** (`bin/found-issues`)
- All subcommands above plus `--version` and `--help`
- Three output formats for `status`: `segment` (ANSI), `plain`, `json`
- Lib resolution priority: `$FOUND_ISSUES_LIB_DIR` → `$CLAUDE_PLUGIN_ROOT/lib` → relative to bin/

**Shared libraries** (`lib/`)
- `canonicalize.sh` — path normalization, symptom canonicalization, dedup keys
- `parse-entries.sh` — file finding, entry parsing, count helpers
- `detect-mode.sh` — auto-detect mode with 1h per-repo cache

**Documentation**
- `README.md` with install, what-it-does, comparison table, format spec, modes
- `docs/format-spec.md` — canonical format with regex patterns
- `docs/architecture.md` — component map and data flow
- `docs/modes.md` — four-mode detection and behavior matrix
- `docs/faq.md` — common questions
- `docs/demo-storyboard.md` — VHS tape file for the demo GIF
- `AGENTS.md` — install instructions for AI agents
- `CONTRIBUTING.md` — contribution process

**CI / quality**
- 122 bats tests covering lib, CLI, hooks
- GitHub Actions matrix on Linux + macOS
- JSON manifest validation
- Advisory shellcheck

### Format spec — v1 lock-in

```
- [STATUS] [!] YYYY-MM-DD path:line — symptom (suggested: fix) [(PR: org/repo#N) | (commit: SHA)] [(fixed: YYYY-MM-DD)] [(verified: ai|review)]
```

- Statuses: `open`, `deferred`, `fixed` (lowercase only)
- `[!]` is the critical flag (separate token from status)
- ` — ` is U+2014 em-dash with spaces (not hyphen)
- Path can be absent for abstract entries
- Multiple `(PR: ...)` and `(commit: ...)` annotations allowed per entry

### Known limitations

- `detect-mode` `github-pr` vs `github-direct` distinction requires `gh` CLI authenticated
- Squash-merge / rebase-merge can break commit-annotation closure (workaround: also annotate with PR)
- Format-enforcer pattern lists in `format-enforcer.sh` and `pre-commit.sh` are duplicated (refactor to `lib/validate.sh` planned)
- No interactive setup wizard; `/found-issues:setup` is informational only

### Untested in CI (smoke-tested only)

- `post-pr-create.sh` end-to-end against a live PR
- `session-start.sh` integration with Claude Code's actual SessionStart event
- Skill auto-loading behavior in a real session
- `gh pr view` JSON output parsing edge cases

These are exercised in dogfood usage rather than CI.

[Unreleased]: https://github.com/AltDoug/found-issues/compare/v0.1.10...HEAD
[0.1.10]: https://github.com/AltDoug/found-issues/releases/tag/v0.1.10
[0.1.9]: https://github.com/AltDoug/found-issues/releases/tag/v0.1.9
[0.1.8]: https://github.com/AltDoug/found-issues/releases/tag/v0.1.8
[0.1.7]: https://github.com/AltDoug/found-issues/releases/tag/v0.1.7
[0.1.6]: https://github.com/AltDoug/found-issues/releases/tag/v0.1.6
[0.1.5]: https://github.com/AltDoug/found-issues/releases/tag/v0.1.5
[0.1.4]: https://github.com/AltDoug/found-issues/releases/tag/v0.1.4
[0.1.3]: https://github.com/AltDoug/found-issues/releases/tag/v0.1.3
[0.1.2]: https://github.com/AltDoug/found-issues/releases/tag/v0.1.2
[0.1.1]: https://github.com/AltDoug/found-issues/releases/tag/v0.1.1
[0.1.0]: https://github.com/AltDoug/found-issues/releases/tag/v0.1.0
