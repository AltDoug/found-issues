# Format spec

Canonical entry format for `docs/found-issues.md` (or `<cwd>/.found-issues.md` in `local` mode). This is the authoritative reference. All hooks, the CLI, and slash commands validate against this spec.

## Grammar

```
- [STATUS] [!] YYYY-MM-DD [LOCATION] — SYMPTOM [(suggested: FIX)] [ANNOTATION]* [(fixed: YYYY-MM-DD)] [(verified: ai|review)]
```

Where `LOCATION` is either `path/file.ext`, `path/file.ext:LINE`, or an abstract topic without slashes (e.g., `dispatch/shutdown`, `workflow`). `ANNOTATION` is `(PR: ORG/REPO#N)` or `(commit: SHA)`. Multiple annotations are allowed (entry addressed by both a PR and a follow-up commit).

## Required parts

| Part | Format | Example |
|---|---|---|
| Bullet | `- ` | `- ` |
| Status | `[open]` / `[deferred]` / `[fixed]` (lowercase) | `[open]` |
| Date | ISO 8601 `YYYY-MM-DD` | `2026-05-06` |
| Separator | ` — ` (em-dash, U+2014, with spaces on both sides) | ` — ` |
| Symptom | Free-form prose, ≥1 character | `null check missing on falsy values` |

## Optional parts

| Part | Format | Example | When |
|---|---|---|---|
| Critical flag | `[!]` (immediately after status) | `[open] [!]` | Drop-everything priority |
| Path | Repo-relative path | `lib/foo.py` | When location is concrete |
| Line | `:N` (after path, no space) | `:42` | When line is concrete |
| Suggested fix | `(suggested: ...)` | `(suggested: add zero-check)` | Encouraged but optional |
| PR annotation | `(PR: ORG/REPO#N)` | `(PR: AltDoug/found-issues#5)` | Added by `/found-issues:annotate-pr` |
| PR-closed annotation | `(PR-closed: ORG/REPO#N)` | `(PR-closed: AltDoug/found-issues#5)` | Added by `/found-issues:sync` when linked PR closed without merge |
| Commit annotation | `(commit: SHA)` (7+ hex chars) | `(commit: a1b2c3d)` | Added by `/found-issues:annotate-commit` |
| Commit-stale annotation | `(commit-stale: SHA)` (7+ hex chars) | `(commit-stale: a1b2c3d)` | Added by `/found-issues:sync` when commit SHA no longer reachable |
| Renamed-from annotation | `(renamed-from: PATH)` | `(renamed-from: lib/old-name.py)` | Added by `/found-issues:sync` when entry path was git-mv'd |
| Fixed date | `(fixed: YYYY-MM-DD)` | `(fixed: 2026-05-08)` | Added by `/found-issues:sync` on closure |
| Verification | `(verified: ai)` or `(verified: review)` | `(verified: ai)` | Added when sync verifies via AI |

## Status semantics

| Status | Meaning | Set by |
|---|---|---|
| `open` | Active issue, not yet addressed | `/found-issues:log` (only path) |
| `deferred` | Intentionally postponed | User edit; system never auto-flips to deferred |
| `fixed` | Addressed and verified | `/found-issues:sync` (annotation match, tombstone, or AI verification); user edit |

Once `[fixed]`, an entry is historical. Don't auto-revert; if a bug regresses, log a fresh `[open]` entry.

## File location

| Mode | File path |
|---|---|
| `github-pr`, `github-direct`, `git` | `<repo-root>/docs/found-issues.md` |
| `local` (no `.git/`) | `<cwd>/.found-issues.md` |

If the file doesn't exist when `/found-issues:log` runs, it's created with this header:

```markdown
# found-issues

Issues noticed outside the current task scope. Format: `- [status] YYYY-MM-DD path:line — symptom (suggested: fix)`. Statuses: `open`, `deferred`, `fixed`.

Maintained automatically by Claude. See <https://github.com/AltDoug/found-issues> for docs.
```

## Examples

### Valid

```markdown
- [open] 2026-05-06 lib/foo.py:42 — null check missing
- [open] [!] 2026-05-06 src/auth.ts:88 — leaks session token in error message (suggested: redact in logger)
- [open] 2026-05-06 dispatch/shutdown — SIGTERM kills sessions silently (suggested: pre-shutdown check)
- [open] 2026-05-06 src/auth.ts:88 — race on session refresh (PR: AltDoug/found-issues#5)
- [fixed] 2026-05-06 src/auth.ts:88 — race on session refresh (PR: AltDoug/found-issues#5) (fixed: 2026-05-08)
- [fixed] 2026-05-06 lib/foo.py:42 — null check missing (commit: a1b2c3d) (fixed: 2026-05-08)
- [fixed] 2026-05-06 lib/bar.py:99 — typo in error message (verified: ai) (fixed: 2026-05-09)
- [deferred] 2026-05-06 docs/README.md — outdated API examples (suggested: regenerate from schema)
- [open] 2026-05-06 src/components/OldDashboard.tsx — dead code: zero importers (suggested: confirm intent and remove in dedicated cleanup PR)
```

### Invalid

```markdown
❌ - [open] 2026-05-06 src/foo.py:42 - null check missing
   ↳ Wrong separator. Must be ` — ` (em-dash with spaces), not ` - ` (hyphen).

❌ - [open] 2026-05-06 src/foo.py:42 — null check missing PR #5
   ↳ Bare PR reference. Must be `(PR: org/repo#N)` with full org/repo prefix and parentheses.

❌ - [open] 2026-05-06 src/foo.py:42 — null check missing (PR: foundissues#5)
   ↳ Missing `org/` prefix. PR annotation requires `org/repo#N`.

❌ - [open] 2026-05-06 src/foo.py:42 — null check missing (commit: abc)
   ↳ Commit SHA must be ≥7 hex chars.

❌ - [OPEN] 2026-05-06 src/foo.py:42 — null check missing
   ↳ Status must be lowercase.

❌ - [open] 5/6/26 src/foo.py:42 — null check missing
   ↳ Date must be ISO 8601 (YYYY-MM-DD).

❌ - [open] 2026-05-06 src/foo.py:42 — null check missing  PR: org/repo#5
   ↳ PR annotation must be wrapped in parentheses, not loose.

❌ - [open!] 2026-05-06 src/foo.py:42 — null check missing
   ↳ Critical flag is a separate token `[!]`, not bundled into status.
```

## Regex patterns

For programmatic validation in hooks and CLI:

```bash
# Match an entry start (any status, optional critical flag, with date)
'^- \[(open|deferred|fixed)\]( \[!\])? [0-9]{4}-[0-9]{2}-[0-9]{2}( [^ ].*?)? — '

# Extract PR annotation (active form)
'\(PR: ([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+)\)'

# Extract PR-closed annotation (demoted form)
'\(PR-closed: ([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+)\)'

# Extract commit annotation (active form, 7-40 hex chars)
'\(commit: ([a-f0-9]{7,40})\)'

# Extract commit-stale annotation (demoted form, 7-40 hex chars)
'\(commit-stale: ([a-f0-9]{7,40})\)'

# Extract renamed-from annotation (old path)
'\(renamed-from: ([A-Za-z0-9_./-]+)\)'

# Extract fixed date
'\(fixed: ([0-9]{4}-[0-9]{2}-[0-9]{2})\)'

# Extract verification source
'\(verified: (ai|review)\)'

# Detect bare PR (format violation — must be blocked by format-enforcer)
'PR #[0-9]+([^)]|$)'

# Match path:line location
'([A-Za-z0-9_./-]+\.[a-zA-Z0-9]+):([0-9]+)'
```

## Statusline counter rules

The CLI command `found-issues status` (used by statusline integrations) computes counts as:

| Counter | Definition |
|---|---|
| `critical` | Count of `[open] [!]` entries |
| `issues` | Count of `[open]` entries without any `(PR: ...)` annotation, minus critical (so they're not double-counted) |
| `in PR` | Count of `[open]` entries with `(PR: ...)` annotation |
| `stale` | Count of `[open]` entries where date is older than `stale_days` (default 30) |

Each is rendered only when > 0. Order: `critical · issues · in PR · stale`.

## Dedup rules

`/found-issues:log` deduplicates against existing `[open]` entries:

1. Paths are canonicalized: resolve to repo-relative, normalize separators, strip trailing whitespace.
2. **Dedup key**: `(canonical_path, line, first 50 chars of symptom)`.
3. If a matching `[open]` entry exists, the new log is silently skipped.
4. **`[fixed]` entries are not consulted for dedup** — a regression of a previously-fixed bug should re-log as a fresh `[open]`.
5. For abstract entries (no path:line), dedup key is `(first 80 chars of symptom)`.

## Annotation conflict resolution

If an entry has both `(PR: ...)` and `(commit: ...)` annotations, sync checks both. Closure happens when **either** resolves:

- PR merges → flip
- Commit lands on default branch → flip
- Neither → entry stays `[open]`

Both annotations are preserved through closure for traceability.

## Multiple PRs / commits per entry

A single entry may be addressed by multiple PRs over time (e.g., partial fix → revert → re-fix). All annotations are preserved:

```markdown
- [open] 2026-05-06 src/auth.ts:88 — race on session refresh (PR: AltDoug/found-issues#5) (PR: AltDoug/found-issues#7)
```

Sync checks each PR independently. Closure happens when any one merges to default branch.

## Annotation lifecycle

The `(PR: ...)` and `(commit: ...)` active forms are written by Claude or users via `/found-issues:annotate-pr` and `/found-issues:annotate-commit`. Sync normally flips them to `[fixed]` on merge or commit-reaches-default-branch.

However, if a linked PR is closed without merge or a commit SHA becomes unreachable (e.g., squash-merged, force-pushed), sync auto-demotes the annotation:

- `(PR: ...)` → `(PR-closed: ...)` — entry stays `[open]`, eligible for AI re-verification since the closure signal is stale
- `(commit: ...)` → `(commit-stale: ...)` — entry stays `[open]`, eligible for AI re-verification since the SHA no longer resolves on default branch

These demoted forms are written **only** by `found-issues sync` during its audit phase; they are never produced by user commands or `/found-issues:annotate-*` calls. They serve as an audit trail of link staleness.

The `(renamed-from: ...)` annotation is written **only** by sync when tombstone detection finds a file path that was git-moved. The entry's path is updated in-place and the old path is preserved here for traceability. Idempotent on subsequent syncs.
