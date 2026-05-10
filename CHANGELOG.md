# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned

- Demo GIF embedded in README
- Submission to official Claude Code marketplace

## [1.0.3] — 2026-05-10

### Fixed (silent-broken-statusline self-heal — completes the v1.0.2 fix for ALL pre-existing users)

- **`install-statusline` is now self-healing.** v1.0.2 fixed the cwd bug for *new* installs but left two cohorts of real users with silently-broken statusline counters: (1) public users who installed via v1.0.0/1.0.1 — they have a marker-bracketed segment that lacks `cd "$__FI_DIR"` handling; (2) early-adopter / dogfood users from pre-v0.1.7 — they have a 3-line handwritten snippet (no markers) embedded in their `~/.claude/statusline.sh` per the old setup.md template. Both cohorts see no counter even though install reported success.
- **The fix:**
  - `install-statusline` now classifies the existing state of `~/.claude/statusline.sh` (`none` / `installed-fixed` / `installed-broken` / `legacy-handwritten` / `legacy-and-installed`).
  - **`installed-broken` (v1.0.0/1.0.1 marker block missing cwd handling)**: auto-rewrites in place — no flag needed, because the markers give us deterministic block boundaries. Users just re-run `found-issues install-statusline` and it self-heals.
  - **`legacy-handwritten` (pre-v0.1.7 handwritten snippet)**: requires explicit `--migrate` flag. The CLI surgically removes the 3-line handwritten block (signature: a comment line containing `found-issues`, the `FI_SEG=$(found-issues status --format=segment ...)` invocation, and the LINE1 assembly follow-up) and inserts the canonical marker-bracketed block. Migration is opt-in because the heuristic could mismatch user-edited variants.
  - **`legacy-and-installed`**: cleans up both with `--migrate`.
- **New subcommand `doctor-statusline`**: dry-run diagnosis of the current state. Reports which of the 5 states the user's statusline is in and the recommended fix command. No file modifications.
- **SessionStart hook self-heal nudge**: detects broken/legacy statusline state at session start. If found, emits a one-time-per-day directive to Claude pointing at `found-issues doctor-statusline` and the migration command. Cost of breakage (silent broken counter) is high; cost of a one-line nudge is low.
- **`status` subcommand now accepts `--cwd PATH`** and falls back to `$CLAUDE_PROJECT_DIR` when no flag is passed. Defensive correctness for any caller that knows the workspace dir explicitly (hooks, scripts, future statusline integrations).
- **`found-issues uninstall` now also strips pre-v0.1.7 handwritten snippets** (in addition to the marker-bracketed block). Previously, dogfood-era users who ran the uninstall flow would still have the broken handwritten lines left behind in `~/.claude/statusline.sh`. Reuses the same `fi_strip_legacy_handwritten` helper that powers `install-statusline --migrate`.

### Added

- **13 new bats tests** covering: `--cwd` flag, `CLAUDE_PROJECT_DIR` fallback, all 5 classifier states via `doctor-statusline`, `--migrate` rewrites for `legacy-handwritten` / `installed-broken` / `legacy-and-installed`, idempotency after migration, true e2e proving pre-migration broken renders empty AND post-migration renders the count, and the new `uninstall` legacy-snippet cleanup. 180 tests total (was 167).

### Changed (release-channel consolidation from prior Unreleased section, no plugin code change)

- **Removed standalone marketplace at `AltDoug/found-issues`.** Deleted `.claude-plugin/marketplace.json` from this repo. The single canonical install path is now the aggregator at `AltDoug/claude-plugins`. Why: dual install paths created confusion (e.g. `/plugin marketplace add AltDoug/found-issues` would register under marketplace name `found-issues` while the aggregator registers as `altdoug-plugins`, leading to mismatches in `/plugin marketplace remove` commands). One marketplace, one install path, one canonical name.
- **README + AGENTS.md install instructions** now use `/plugin marketplace add AltDoug/claude-plugins`.
- **CI `json validation` step** no longer validates the removed marketplace.json.
- **Migration for users who installed via the standalone path**: `/plugin marketplace remove found-issues` then `/plugin marketplace add AltDoug/claude-plugins`. The plugin itself doesn't need reinstalling — same code, just a different marketplace registration.

### How existing users pick up the fix

- **v1.0.0/1.0.1 marker-bracketed installs**: `found-issues install-statusline` (no flag — auto-detects + auto-rewrites).
- **Pre-v0.1.7 handwritten installs**: `found-issues install-statusline --migrate` (explicit opt-in for surgical line removal).
- **Not sure**: `found-issues doctor-statusline` first to inspect, then run the recommended command it prints.
- **Auto-discovery**: SessionStart will nudge once per day until fixed.

## [1.0.2] — 2026-05-09

### Fixed

- **`install-statusline` segment now actually renders the count.** v1.0.1 (and every version before it) generated a segment block that called `found-issues status` from the statusline subprocess's cwd — which is **never the workspace dir**. As a result, the statusline counter silently rendered as empty for every user with a multi-line statusline that uses `git -C "$DIR"` rather than `cd` (i.e. the common pattern). The bug was discovered during a public-release dogfood run when the count didn't appear despite the segment block being correctly installed.
- v1.0.2 segment now extracts `workspace.current_dir` from the conventional `$input` JSON variable (the standard Claude Code statusline convention), and `cd`s into that directory before invoking `found-issues status`. Falls back to no-cd behavior if `$input` isn't defined or `jq` isn't available — same as v1.0.1, no regression.
- Both inline and standalone (append) forms updated. To pick up the fix, existing users must run `found-issues uninstall-statusline` then `found-issues install-statusline` (the marker-based idempotency means a fresh install would otherwise no-op).

### Added

- **2 new bats tests** in `tests/cli-statusline.bats`: (1) a structural test asserting the generated segment block contains the cwd handling (greps for `jq -r`, `.workspace.current_dir`, `cd "$__FI_DIR"`); (2) a true end-to-end test that pipes Claude-Code-style JSON input (`{"workspace":{"current_dir":"..."}}`) into the generated statusline.sh and asserts the count renders. The e2e test would have caught this bug before public release. 167 tests total (was 165).

## [1.0.1] — 2026-05-09

### Added

- **Windows support, verified by CI.** Added `windows-latest` to the bats matrix in `.github/workflows/test.yml` — runs under Git Bash. 165/165 tests pass. README now claims Linux + macOS + Windows in the new "Platform support" section. The plugin remains bash-based (`#!/usr/bin/env bash` shebang on every script); on Windows users need Git for Windows installed (Git Bash provides bash + GNU coreutils — near-universal install on Windows dev boxes). WSL also works.
- **README "How to use it day-to-day" section** surfacing the two usage patterns that weren't documented but are the actual day-to-day value: (1) plain-English queries work because `docs/found-issues.md` is auto-loaded into Claude's context every session — no slash command needed for *"what's open?"* / *"show me the critical ones"*; (2) the log can be treated as a work queue — ask an agent to triage and fix the easy ones in batch, the auto-annotate hooks + auto-flip-on-merge close the loop. Without this section, new readers saw a passive logger and missed the active-queue workflow.

### Fixed

- **`/found-issues:setup` picker now labels the statusline option as `(Recommended)`** and lists it first. Without the recommended marker, users habitually tab through the multi-select picker and skip the highest-signal integration. `commands/setup.md` previously described the install mechanics for each option but didn't specify the picker structure — the LLM was generating it ad-hoc with no recommendation cue. Now setup.md explicitly: (1) requires a single multi-select picker, (2) requires `(Recommended)` suffix on the statusline option, (3) requires statusline listed first, (4) requires omitting already-installed options from the picker, (5) requires skipping the picker entirely when both are installed.
- **Renamed `tests/cli-status.bats:49` test** from `"status: plain format uses '·' separator"` to `"status: plain format uses middle-dot separator"`. The Unicode middle dot in the test *name* (not the body) tripped bats' test-name parser on Git Bash for Windows. The body still asserts the `·` character in output — that's the actual contract being tested.

## [1.0.0] — 2026-05-09

**First stable public release.**

`found-issues` is now publicly available. The plugin spent v0.1.0–v0.1.16 in
private development being dogfooded across the author's own work; v1.0.0 is
the public-debut tag. No functional changes since v0.1.16 — same code,
same behavior, same 165-test suite. Just public-OSS hygiene + repo settings.

### Changed

- README "Status & roadmap" updated from stale `v0.1.0 / 122 tests passing` to current `v1.0.0 / 165 tests passing`.
- README slash-commands table now includes `/found-issues:archive` (was shipping since v0.1.8 but undocumented).
- CHANGELOG: added missing reference links for `[0.1.15]` and `[0.1.16]`; updated `[Unreleased]` compare link to `v1.0.0...HEAD`.
- Aggregator (`AltDoug/claude-plugins`): added a one-line note explaining the manifest-name (`altdoug-plugins`) vs repo-name (`claude-plugins`) asymmetry that confused at least one user during install/uninstall.

### Added

- `SECURITY.md` at repo root — vuln-reporting process surfaced as a GitHub Security tab.
- Aggregator now ships `CONTRIBUTING.md` explaining that plugin code lives in plugin repos; PRs against the aggregator just bump `marketplace.json`.
- GitHub repo metadata: topics (`claude-code`, `claude-code-plugin`, `ai-agents`, `issue-tracker`, `markdown`, `developer-tools`) for discoverability.
- Branch protection on `main`: PR-required + passing CI checks before merge.

### Fixed

- Removed first-name reference (`"like Diogo's"`) from the v0.1.11 CHANGELOG entry — privacy cleanup before public flip.

## [0.1.16] — 2026-05-09

### Fixed

- **`/fi` alias now installs deterministically via `found-issues install-fi-alias`.** v0.1.15 setup told the LLM to handcraft `~/.claude/commands/fi.md` from a markdown code block in `commands/setup.md`. On a real install the agent dropped `$ARGUMENTS` — `/fi log src/foo.py:42` would expand to `Run /found-issues:` with the subcommand and arguments lost. Same failure class statusline had pre-v0.1.11 (LLM editing files by hand). v0.1.16 ships dedicated CLI subcommands `install-fi-alias` / `uninstall-fi-alias` so the LLM just calls them — no more handcrafted content.

### Added

- **New CLI subcommands**: `install-fi-alias` (creates `~/.claude/commands/fi.md` with literal `$ARGUMENTS` baked in, idempotent, refuses to overwrite a user-authored `/fi` command) and `uninstall-fi-alias` (removes only if it's ours; preserves user-authored `/fi`).
- **README**: setup.png screenshot in the Installation section showing the optional-integrations picker.
- 10 new bats tests in `tests/cli-fi-alias.bats` covering install, idempotency, no-clobber, parent-dir creation, uninstall, user-authored preservation, no-op, round-trip — and explicitly: *the file contains literal `$ARGUMENTS`* (regression test for the v0.1.15 bug).

### Changed

- `commands/setup.md` Optional 3 now calls `found-issues install-fi-alias` instead of handing the LLM a markdown code block.
- `cmd_uninstall` now delegates `/fi` removal to `cmd_uninstall_fi_alias` so the "is this ours?" heuristic lives in one place — install and uninstall can't drift apart.

## [0.1.15] — 2026-05-09

### Added

- **`found-issues uninstall` cleanup command** and `/found-issues:uninstall` slash wrapper. Claude Code's `/plugin uninstall` removes the plugin itself but leaves plugin-private state behind under `~/.claude/` and `~/.cache/` (no pre/post-uninstall lifecycle hooks in the spec — see anthropics/claude-code#11240). The new command wipes only what we installed, in one go:
  - Statusline segment block in `~/.claude/statusline.sh` (preserves rest of file + executable bit, reuses `uninstall-statusline`)
  - Onboarding marker dir `~/.claude/found-issues/`
  - Mode-detection cache `~/.cache/found-issues/`
  - `/fi` alias at `~/.claude/commands/fi.md` *only if* it contains `Run /found-issues:` (won't touch a user's own `/fi` command)
  - Per-repo `docs/found-issues.md` and `docs/found-issues-archive.md` are intentionally preserved — that's user project data
- Prints `/plugin uninstall found-issues` and `/plugin marketplace remove altdoug-plugins` as next-steps (those can only run from inside Claude Code).
- 8 new bats tests in `tests/cli-uninstall.bats` covering no-op, each cleanup type individually, user's-own-`fi.md` preservation, statusline-block removal preserving rest of file + executable bit, next-steps reminder, and all-4-at-once.

### Why

User feedback during e2e uninstall+reinstall test: *"shouldnt that all be part of the uninstall? why is there left over"* — manual `rm -rf` cleanup is unacceptable UX. Plugin-side leftovers are our problem to solve.

## [0.1.14] — 2026-05-09

### Fixed

- **`install-statusline` and `uninstall-statusline` now preserve executable permission** on `~/.claude/statusline.sh`. Both commands edit via `awk > tmp; mv tmp file`, but `mktemp` creates files at mode 0600 (no execute bit). Without preservation, after running install-statusline the statusline file lost +x → Claude Code couldn't execute it → **statusline silently disappeared entirely** (not just the segment — the whole multi-line statusline). User caught this during a fresh-install e2e test.
- Both commands now `stat` the original mode before editing (cross-platform: BSD `-f '%Lp'` vs GNU `-c '%a'`) and `chmod` it back after. Falls back to `chmod +x` if stat fails.

### Added

- 2 new bats tests asserting executable permission survives both install and uninstall.

## [0.1.13] — 2026-05-09

### Fixed

- **Statusline fallback uses `sort -V` for semver-correct version selection.** v0.1.12's `for` loop iterated glob results and assigned the alphabetically-last match — which picks `0.1.9` over `0.1.10`/`0.1.11` because byte-wise sort puts `9` after `1`. Affects users who have updated through versions and have multiple cached. Now uses `ls -d ... | sort -V | tail -1`.
- **`|| true` on the cache-glob pipeline.** With `set -o pipefail` (common in statusline scripts), `ls -d` returning non-zero on no glob matches propagates through the pipe and triggers `set -e` exit. The fallback would silently kill the entire statusline whenever the plugin wasn't cached. Adding `|| true` after the pipeline makes it safe.

## [0.1.12] — 2026-05-09

### Fixed

- **Statusline integration is now robust to PATH variability.** Both inline and standalone insertion forms now try `found-issues` on PATH first, then fall back to globbing `~/.claude/plugins/cache/*/found-issues/*/bin/found-issues` for the latest installed binary. The statusline runs in a raw shell exec context where the plugin's auto-PATH may not apply (verified empirically — `command -v found-issues` fails in stripped-env subprocess but the cache glob succeeds). Without this fallback, users had a wired-but-silent statusline segment.

### Added

- New bats test asserting both insertion forms emit the `command -v` + cache-glob fallback pattern.

## [0.1.11] — 2026-05-09

### Fixed

- **`install-statusline` now inserts the segment inline on LINE1 when a LINE1 assembly pattern is detected** in `~/.claude/statusline.sh` (multi-line statuslines that build LINE1 across multiple assignments). Previously always appended at end-of-file, which made the segment render as an awkward standalone 4th line instead of inline next to repo/branch. Falls back to standalone-append for simple printf-style statuslines.
- **`commands/setup.md` "already integrated?" check uses the actual marker grep** (`# === found-issues plugin segment ===`), not a generic "found-issues" string match. Previous check produced false positives when the statusline file had any cleanup comments or other references containing the word "found-issues".

### Added

- New bats test confirming inline insertion when LINE1 pattern detected, distinct from the existing standalone-append test.

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

<!-- v0.1.x versions were private-development releases. v1.0.0 is the first
     publicly tagged release on GitHub. The CHANGELOG retains v0.1.x entries
     for transparency about how the plugin was built. -->

[Unreleased]: https://github.com/AltDoug/found-issues/compare/v1.0.2...HEAD
[1.0.2]: https://github.com/AltDoug/found-issues/releases/tag/v1.0.2
[1.0.1]: https://github.com/AltDoug/found-issues/releases/tag/v1.0.1
[1.0.0]: https://github.com/AltDoug/found-issues/releases/tag/v1.0.0
