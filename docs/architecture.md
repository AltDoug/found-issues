# Architecture

How the pieces fit together.

## Component map

```
                    ┌─────────────────────────────────┐
                    │       Claude Code session        │
                    │                                  │
                    │  Skills auto-loaded:             │
                    │  • skills/rules/SKILL.md         │ ◀── rules guide
                    │                                  │     Claude's behavior
                    │  Slash commands:                 │     proactively
                    │  • /found-issues:log             │
                    │  • /found-issues:sync            │
                    │  • /found-issues:annotate-pr     │ ◀── user-invocable +
                    │  • /found-issues:annotate-commit │     agent-invocable
                    │  • /found-issues:promote         │
                    │  • /found-issues:status          │
                    │  • /found-issues:setup           │
                    │                                  │
                    │  Hooks (auto-fire):              │
                    │  • SessionStart  ──────► sync    │
                    │  • Stop  ─────────► force marker │
                    │  • PreToolUse(Write/Edit)        │
                    │      └► format-enforcer          │
                    │  • PreToolUse(Bash)              │
                    │      └► pre-branch-delete        │
                    │  • PostToolUse(Bash)             │
                    │      └► post-bash-dispatch       │
                    └────────────────┬─────────────────┘
                                     │
                                     │ shell out
                                     ▼
                    ┌─────────────────────────────────┐
                    │     bin/found-issues (CLI)       │
                    │                                  │
                    │  Subcommands:                    │
                    │  • log   ─── append entry        │
                    │  • sync  ─── annotation/tomb     │
                    │  • status ── counters            │
                    │  • annotate-pr/commit            │
                    │  • promote                       │
                    └────────────────┬─────────────────┘
                                     │
                                     │ source
                                     ▼
                    ┌─────────────────────────────────┐
                    │            lib/                  │
                    │                                  │
                    │  • canonicalize.sh — paths,      │
                    │    symptoms, dedup keys          │
                    │  • parse-entries.sh — read +     │
                    │    parse + count entries         │
                    │  • detect-mode.sh — mode         │
                    │    auto-detection (1h cache)     │
                    └────────────────┬─────────────────┘
                                     │
                                     │ reads/writes
                                     ▼
                    ┌─────────────────────────────────┐
                    │     <repo>/docs/found-issues.md  │
                    │     (or <cwd>/.found-issues.md   │
                    │      in local mode)              │
                    │                                  │
                    │  - [open] [!] 2026-05-08 ...     │
                    │  - [open] 2026-05-08 ... (PR:..)│
                    │  - [fixed] 2026-05-08 ... (..)   │
                    └─────────────────────────────────┘
```

## Layer responsibilities

### Skills (auto-loaded context)

`skills/rules/SKILL.md` is loaded into Claude's working context every
session via the plugin spec's auto-load mechanism (`disable-model-invocation: true`).
This is what makes Claude *proactively* log issues — without the rules
in context, Claude would only log when explicitly told to.

The rules answer: when to log, when not to log, when to annotate, when
to promote, what the format is.

### Slash commands (user/agent surface)

Markdown files in `commands/` invoked as `/found-issues:<name>`. Each is
a thin instruction file that tells Claude what to do — most just delegate
to the CLI. Two exceptions carry real procedure: `/found-issues:sync`
(Claude reads code and verifies unannotated entries) and
`/found-issues:fix` (verify → triage → gate → fix → ship over the open
entries, consuming `list --json`).

### Hooks (enforcement layer)

Bash scripts in `hooks/`, registered via `hooks/hooks.json` on Claude
Code (the plugin manifest) or via `found-issues install-codex-hooks`
into `$CODEX_HOME/hooks.json` on Codex — see Harness adapters below for
why registration differs by harness. They turn the CLAUDE.md rules into
mechanical behavior. Five lifecycle hooks plus one optional per-repo git
hook:

| Hook | Event | Job |
|---|---|---|
| `session-start.sh` | SessionStart | Run sync silently, inject `[open]` entries into context (fenced as untrusted data), auto-migrate broken custom statusline targets |
| `stop-reminder.sh` | Stop | Require the `<!-- found-issues-checked: ... -->` marker on turns with substantive tool use (Edit/Write/MultiEdit/Bash); pure-conversation turns and non-interactive (`CLAUDE_CODE_ENTRYPOINT != cli`) sessions pass through |
| `format-enforcer.sh` | PreToolUse Write/Edit | Block malformed entries before they land |
| `pre-branch-delete.sh` | PreToolUse Bash | Block branch deletion if entries unpromoted |
| `post-bash-dispatch.sh` | PostToolUse Bash | Auto-annotate PR/commit entries matching just-changed lines (`--hook-auto`), surfacing only judgment cases; background `sync` after `gh pr merge`/`close`/`reopen` |
| `pre-commit.sh` | git pre-commit (per-repo, opt-in) | Format check at commit time |

Hooks fail open — if anything goes wrong, they exit 0 silently rather
than break the session.

### Harness adapters

One CLI, one `lib/`, one ledger — two thin adapters translate the same
core into each harness's own UI conventions:

- **Claude Code adapter** — `commands/*.md` slash commands
  (`/found-issues:<name>`) plus the auto-loaded `skills/rules/SKILL.md`
  skill (rules injected into context every session via the plugin's
  auto-load mechanism).
- **Codex adapter** — `codex-skills/fi-<name>/SKILL.md`, generated from
  `commands/*.md` by `scripts/gen-codex-skills.sh` (invoked as `$fi-<name>`
  mentions or by description match), plus SessionStart rules injection:
  `hooks/session-start.sh` emits the rules body into context on Codex
  (wrapped in Codex's SessionStart JSON envelope — see below), since
  Codex has no auto-loaded-skill mechanism equivalent to Claude's.

The hook *scripts* themselves are shared, not adapted — every script in
`hooks/` runs unmodified on both harnesses; the same JSON payload shape
arrives on stdin either way. Registration differs, though: on Claude
Code, `hooks/hooks.json` (the plugin manifest) auto-wires them at
install time. On Codex, that path is dead — Codex CLI 0.144.5 removed
the `plugin_hooks` feature, so a plugin's `hooks.json` pointer never
loads (`.codex-plugin/plugin.json`'s `"hooks"` key is inert there). The
same scripts still work on Codex; they just have to be registered a
different way: `found-issues install-codex-hooks` copies the same four
non-Stop hook entries into Codex's own stable user-level
`$CODEX_HOME/hooks.json`, each command prefixed with `env
FOUND_ISSUES_HARNESS=codex` so the script self-identifies without
needing `PLUGIN_DATA` (which a hook run outside the plugin manifest
never receives). Re-running it after `codex plugin update` is required —
the installer strips-then-reinstalls its own entries every time, so
stale plugin-cache paths from a prior version self-heal.

`lib/harness.sh` is the one harness-detection point: `fi_detect_harness`
honors `FOUND_ISSUES_HARNESS` first, then falls back to
`CLAUDE_CODE_ENTRYPOINT` (Claude) vs `PLUGIN_DATA` (Codex). Two emit
helpers format hook output for whichever harness is running — plain text
on Claude either way; on Codex, `fi_emit_post_context` nests
`additionalContext` under `hookSpecificOutput` with
`hookEventName: "PostToolUse"`, and `fi_emit_session_context` does the
same for SessionStart with `hookEventName: "SessionStart"` (both mirror
Codex's `*.command.output` JSON Schema — flat top-level fields are
dropped, not extra data). Both adapters read and write the same
committed `docs/found-issues.md` — a repo worked on from both harnesses
shares one ledger with no migration step.

### CLI (`bin/found-issues`)

Single bash script with subcommands. Sourced by hooks; directly
invocable from any shell once the plugin is installed (plugin spec
auto-adds `bin/` to PATH).

Subcommands:

| Subcommand | Job |
|---|---|
| `log` | Append a new `[open]` entry with dedup |
| `sync` | Annotation-driven flips + tombstone close (no AI — that's the slash command's job) |
| `status` | Print counters in segment / plain / json format |
| `list [--status=...] [--json]` | Conflict-aware entry listing (default: open); `--json` emits structured entries feeding `/found-issues:fix` |
| `annotate-pr <N> [--pick <loc>,...] [--all]` | Append `(PR: org/repo#N)` to matching entries; ambiguous file-level matches require explicit selection |
| `annotate-commit [<sha>]` | Append `(commit: <sha>)` to matching entries |
| `promote` | List branch-only `[open]` entries needing consolidation |
| `archive` | Move old `[fixed]` entries to `docs/found-issues-archive.md` |
| `defer` / `promote-deferred` | Flip `[open]` ⇄ `[deferred]` with touch/cycle bookkeeping |
| `install-statusline` / `uninstall-statusline` | Install or remove the statusline counter segment (canonical or `--target` custom shims) |
| `doctor` / `doctor-statusline` / `doctor-statusline-runtime` | Health checks: general, statusline integration, runtime probe |
| `install-fi-alias` / `uninstall-fi-alias` | Manage the personal `/fi` shortcut |
| `install-codex-hooks` / `uninstall-codex-hooks [--codex-home PATH]` | Merge/remove found-issues' own hook entries in Codex's user-level `$CODEX_HOME/hooks.json` (see Harness adapters below) |
| `uninstall` | Wipe plugin-private state before `/plugin uninstall` |

### lib (shared bash)

Pure-function libraries sourced by the CLI and (some) hooks:

| File | Functions |
|---|---|
| `canonicalize.sh` | path/symptom normalization, dedup key generation |
| `parse-entries.sh` | find file, parse one line, filter by status, count by category |
| `detect-mode.sh` | auto-detect mode (`local`/`git`/`github-direct`/`github-pr`) with 1h cache |

## Data flow: one issue, end to end

The lifecycle of a single issue from observation to closure:

1. **Notice** — Claude is working on task X. While reading `lib/foo.py`, sees a null check is missing at line 42. The CLAUDE.md rules (auto-loaded skill) say: log it.

2. **Log** — Claude runs `/found-issues:log src/foo.py:42 — null check missing (suggested: add guard)`. The slash command shells out to `bin/found-issues log ...`. The CLI:
   - Sources `lib/parse-entries.sh` (for `fi_find_issues_file`)
   - Sources `lib/canonicalize.sh` (for `fi_dedup_key`)
   - Resolves the issues file (`docs/found-issues.md` or creates it)
   - Computes dedup key, scans existing `[open]` entries
   - If no match, appends the new entry with today's date
   - Returns success + count

3. **Format check** — Claude's session ends; the next time Claude edits `docs/found-issues.md` directly via Write/Edit, the `format-enforcer` PreToolUse hook fires. If the edit would introduce a malformed line, it blocks (exit 2) with a helpful error.

4. **PR opens** — Some session later, Claude fixes the bug as part of task Y. After `gh pr create --title "fix: null check"`:
   - `post-bash-dispatch.sh` (PostToolUse on Bash) fires and extracts the PR number from stdout (`https://github.com/.../pull/42`)
   - It runs `found-issues annotate-pr 42 --hook-auto`, which cross-references the PR's diff against `[open]` entries. For each entry whose cited `path:line` falls inside a line the diff actually **modifies** (removes), the CLI appends `(PR: org/repo#42)` silently and reports the annotation in one line — no round-trip through Claude
   - Entries that match a touched file but whose cited line the diff did *not* change — or where several entries contest the same file — are **not** annotated. They surface as candidates: the hook prints them with the exact `found-issues annotate-pr 42 --pick <path:line>` (or `--all`) command for Claude to run after a symptom-level judgment call
   - Only under `FOUND_ISSUES_AUTO_ANNOTATE=off` does the hook fall back to the legacy flow of merely prompting Claude to run `/found-issues:annotate-pr 42` itself

5. **PR merges** — On GitHub, the PR merges to main. Claude isn't running.

6. **Next session** — Claude opens in the same repo. The `session-start.sh` SessionStart hook fires:
   - Runs `bin/found-issues sync` silently
   - The CLI's sync logic checks `[open]` entries with `(PR: ...)` annotations
   - For each: `gh pr view 42 --json state` → state is `MERGED`, base is the default branch
   - Flips the entry to `[fixed] (PR: org/repo#42) (fixed: 2026-05-08)`
   - SessionStart hook re-reads the (now smaller) `[open]` list, injects it into Claude's context

7. **Status display** — At the same time, the SessionStart hook calls `found-issues status --format=plain` and includes the count in its output ("3 issues open"). The user sees this on session start.

8. **Done** — The entry is now `[fixed]` and stays as a historical record. The `[open]` count went down by one. Neither the user nor Claude touched the file directly — the loop closed automatically.

## Failure modes and fail-open philosophy

Hooks should never break a Claude session for environmental reasons.
Every hook implements one of these patterns:

```bash
if [[ -z "$REQUIRED_THING" ]]; then
  exit 0  # fail open
fi
```

Specifically, hooks fail open when:
- The CLI binary isn't found on PATH or in `${CLAUDE_PLUGIN_ROOT}/bin/`
- `lib/` isn't sourceable
- `gh` is not installed or not authenticated
- Required JSON fields are missing from the hook's stdin
- jq isn't installed (where used)

The cost of fail-open: a hook that silently no-ops because of a missing
prerequisite. The cost of fail-closed: a user can't get any work done
because a hook is broken. The latter is much worse.

The exception is `format-enforcer.sh` and `pre-branch-delete.sh` — these
exist *to* block. They block on actual format violations / missing
promotions, not on environmental issues. They still fail open if the
plugin can't even initialize (no lib available, etc.).

## Extension points

The system is designed to extend cleanly:

- **New annotation forms** — add a regex pattern to `lib/parse-entries.sh:fi_parse_entry`, update the format spec, update the format-enforcer's allowed-patterns list. Sync logic checks all annotations independently.

- **New hook events** — add a new `.sh` script in `hooks/`, register it in `hooks/hooks.json`. Source `lib/` files for parsing. Follow the fail-open pattern.

- **New CLI subcommand** — add a `cmd_xxx` function in `bin/found-issues`, dispatch in `main()`. Add a slash command file in `commands/` that delegates to it.

- **New mode** — extend `lib/detect-mode.sh:fi_detect_mode` with a new branch. Update `format-enforcer.sh`'s mode-aware behavior table. Document in `docs/modes.md`.

## What's NOT in the system

Worth being explicit about non-goals:

- **No web UI / dashboard.** The file is the interface. If you want a
  visual, render markdown.
- **No central server / sync across machines.** Each repo's
  `docs/found-issues.md` is the source of truth, committed to git.
- **No notifications.** SessionStart printout + statusline counter +
  Stop-hook acknowledgment are the only surfacing mechanisms.
- **No issue assignment / ownership / milestones.** This is a defect
  log, not a project management tool. If you need those, use GitHub
  issues.
- **No auto-priority sorting.** `[open]` entries are listed in the order
  they were logged. Critical entries are flagged with `[!]` but not
  re-sorted.
