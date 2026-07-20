---
name: fi-archive
description: Move old [fixed] found-issues entries to an archive file (count threshold 50 OR days threshold 30, whichever first)
---

Run `found-issues archive <the user-provided arguments>` to move old `[fixed]` entries from the
active `docs/found-issues.md` to `docs/found-issues-archive.md`.

## When to run this

**Usually you don't need to.** Auto-archive runs after every `$fi-sync`
by default, so old fixed entries get moved without you thinking about it. Run
this command manually when you want to:

- Use custom thresholds: `$fi-archive --days=14 --count=20`
- Preview what's eligible: `$fi-archive --dry-run`
- Force a one-time cleanup if you've disabled auto-archive

Disable auto-archive with `export FOUND_ISSUES_AUTO_ARCHIVE=off` in your shell rc.

The active file accumulates `[fixed]` entries as a closure record. Over time
(especially during heavy work — 25+ entries/day is normal during active
development), this can grow to hundreds of entries. The archive command keeps
the active file focused on what's still actionable while preserving the closure
history.

## Default behavior

`$fi-archive` with no args:

- Archives any `[fixed]` entry whose closure date (`(fixed: YYYY-MM-DD)`) is
  older than **30 days**
- AND/OR archives the oldest `[fixed]` entries when the total exceeds **50**
  (oldest move first until count is back at threshold)
- Entries are appended to `docs/found-issues-archive.md` (created on first run
  with a permanent header)
- The archive file is append-only — the plugin never modifies it again

## Options

| Flag | Effect |
|---|---|
| `--dry-run` | Print which entries would move; don't modify any files |
| `--days=N` | Override the 30-day threshold |
| `--count=N` | Override the 50-entry threshold |

## What's preserved

- All `[open]` and `[deferred]` entries — never touched
- Entry text, annotations, dates — preserved byte-for-byte during the move
- Original closure metadata (PR refs, commit refs, fixed dates, verified flags)

## Reporting

After running, report to the user:
- How many entries were archived
- New active file size (line count)
- Where the archive lives

If `--dry-run` was used, report what *would* have moved without touching files.
