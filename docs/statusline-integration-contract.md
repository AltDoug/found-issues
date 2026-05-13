# Statusline integration contract

`found-issues status --format=segment` is the **frozen public surface** that user statuslines depend on. Internal implementation is free to evolve; the surface below is not.

This contract exists because `/found-issues:setup` splices the segment call into user statusline scripts on their own machines (in `~/.claude/statusline.sh`, or — when integration lands for custom statuslines — into whatever script their `statusLine.command` points at). Those splices live in user environments, are not under our control after install, and silently render whatever bytes the segment command emits. Any change to the locked behavior below silently breaks every installed integration.

## Frozen behavior (v1)

| Property | Locked behavior |
| --- | --- |
| Invocation | `found-issues status --format=segment` (also accepts `--format segment`) |
| Exit code | `0` in normal operation, including all "no issues to show" cases |
| Output stream | stdout only; nothing on stderr in normal operation |
| Output when zero open issues to display | Empty string — no characters at all, no trailing newline |
| Output when ≥1 bucket has count | Begins with `' | '` (space, pipe, space); no trailing newline |
| Separator between buckets | `' · '` (space, U+00B7 middle-dot, space) |
| Colors | `\033[1;31m` critical · `\033[31m` issues · `\033[33m` in-PR · `\033[2m` stale; each segment terminated by `\033[0m` |
| Label policy | `N critical` / `N issue|issues` / `N in PR` / `N stale`. When ≥2 non-residual buckets are present, the residual bucket relabels from `issue/issues` to `other` (so users don't try to mentally sum overlapping counts) |
| Failure mode (file missing, parse error, etc.) | Empty stdout, exit 0 — silent-fail so the user's statusline never shows an error string |
| Latency | Bounded: subsecond on cache hit. The 10-minute autosync (`FOUND_ISSUES_SEGMENT_AUTOSYNC`) runs in the background and never blocks the foreground render |

## What is NOT part of the contract (free to change)

- The shape of `docs/found-issues.md` itself, the parser, the counting rules, the cache directory layout, the autosync mechanism, internal helper function names, file paths under `lib/`.
- The output of `--format=plain` and `--format=json` — those are separately documented surfaces with their own evolution rules.
- The colors when a future terminal or accessibility flag overrides them via `--no-color` (a future additive flag).

## How to evolve the contract (only allowed path)

If a new output shape is genuinely needed:

1. **Add a new format alongside the frozen one** — `--format=segment-v2` (or `-v3`, etc.). Do not modify v1's output.
2. **Update `/found-issues:setup`** so new installs splice in the new format. Existing installs continue running v1 until migrated.
3. **Ship a migration command** (`/found-issues:migrate-statusline`) that detects v1 splices in user statuslines and offers to upgrade them — same AI-mediated edit flow as initial install.
4. **Add snapshot tests for v2** in `tests/contract-segment.bats` (alongside, not replacing, the v1 snapshots).
5. **Append a v2 section** to this document with the new locked shape.

Additive flags (`--no-color`, `--max-width N`, etc.) are allowed without a new format version as long as the default output bytes are unchanged.

## Enforcement

Snapshot tests in `tests/contract-segment.bats` lock the v1 output bytes for the canonical cases. A code change that shifts the bytes fails the test in CI with a message pointing back to this document.

If a snapshot test fails after a code change, the fix lives in the code change — adjust the implementation so the locked output is preserved. The test file's header explains the reasoning in more detail.

## Related

- `bin/found-issues` line ~971 — segment branch of `cmd_status` (the emit point)
- `tests/cli-status.bats` — broader status format tests (label policy, plain/json formats)
- `tests/cli-statusline.bats` — install-statusline integration tests
- `commands/setup.md` — orchestrates the splice into user statuslines
