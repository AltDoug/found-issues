# Changelog

All notable changes documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned

- Demo GIF embedded in README before public flip
- Public release (flip repo from private to public)
- Submission to official Claude Code marketplace

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

[Unreleased]: https://github.com/AltDoug/found-issues/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/AltDoug/found-issues/releases/tag/v0.1.3
[0.1.2]: https://github.com/AltDoug/found-issues/releases/tag/v0.1.2
[0.1.1]: https://github.com/AltDoug/found-issues/releases/tag/v0.1.1
[0.1.0]: https://github.com/AltDoug/found-issues/releases/tag/v0.1.0
