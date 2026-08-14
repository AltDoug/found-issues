---
name: fi-defer
description: Park an [open] entry as [deferred] — it stays in the ledger but leaves the statusline counter, optionally with a reason or mute-until window. Use for known-but-consciously-postponed work, NOT to silence an entry someone should fix (real fixes close via the annotate commands plus sync). Re-deferring after a promotion increments the defer-cycle and escalates the next nudge. Inverse of $fi-promote-deferred.
---
<!-- loc-override: generated 1:1 from commands/defer.md by scripts/gen-codex-skills.sh; length is owned by the source command file -->

The user wants to defer a `[open]` found-issue. Deferring means: keep the entry visible in `docs/found-issues.md` but suppress it from the statusline counter and exempt it from `[open]`-only checks. The entry stays in the file as a parking-lot record.

## Invocation

```bash
found-issues defer <match> [--reason "<text>"] [--mute-until YYYY-MM-DD]
```

`<match>` is a substring matched case-insensitively against the entry's path or symptom. If the match is ambiguous (matches multiple `[open]` entries), the CLI lists all matches and exits 2 — surface them to the user and ask for a more specific match.

## Exit codes — what to tell the user

- **0**: Deferred successfully. Print the CLI's stdout (it includes cycle + threshold info).
- **1**: No match. The CLI prints the match string; suggest the user check `docs/found-issues.md` or run `$fi-status` for the current entry list.
- **2**: Ambiguous match. The CLI lists all matches; ask the user for a more specific substring (e.g., line number, distinctive part of the symptom).
- **3**: Already `[deferred]`. The CLI explains the re-defer-after-promote workflow. If the user actually wanted to promote it back, suggest `$fi-promote-deferred`.
- **4**: Entry has an active `(PR: ...)` annotation. Deferring would silently drop the entry from both the `issues` and `in PR` counters. The CLI prints the two-option recovery (wait for merge OR manually clear the annotation); surface it to the user verbatim.

## When to use defer

- **Out-of-scope but real**: a logged issue is genuine but you've decided not to address it in the current cycle (e.g., behind another work stream, blocked on external dep, low-priority cleanup).
- **NOT for "this isn't a real issue"**: those should be removed from the file entirely, not deferred.
- **NOT for in-flight PRs**: the plugin auto-flips entries to `[fixed]` when the referenced PR merges via `$fi-sync`. Defer would interfere.

## Re-defer behavior

If you defer an entry that was previously `[deferred]` → promoted → now `[open]` again (the touch history will be visible in the entry's `(touched: ...)` annotation), the CLI auto-increments the `defer-cycle` annotation and the threshold for the next promotion-nudge doubles (3 → 6 → 12 → ...). Each re-defer raises the bar.

## Optional `--reason "<text>"`

Captures a short human note explaining WHY this entry is being deferred. Stored as `(reason: ...)` on the entry. Replaces any existing `(reason: ...)` from a prior cycle. Helpful for future re-review.

## Optional `--mute-until YYYY-MM-DD`

Suppresses the recurrence nudge (the "now Nx, threshold M" stderr message and the "consider promote-deferred" stdout flag) until the given date. Useful when an entry is genuinely blocked for a known period (legal review, third-party fix, post-Q3 launch window, etc.) and you don't want touch-driven nudges to interrupt during that window.

- Format **must** be ISO `YYYY-MM-DD` (e.g. `2026-08-01`). Garbage is rejected with exit 2.
- Past dates are accepted but warn — the mute is immediately a no-op, nudges resume on the next touch.
- Stored as `(mute-until: YYYY-MM-DD)` on the entry; replaces any existing mute-until from a prior cycle.
- Touches **are still recorded** during the mute (history preservation); only the nudge/auto-promote logic is short-circuited.
- The mute is stripped automatically on `promote-deferred` — an `[open]` entry doesn't have a nudge to suppress, so the annotation is no longer meaningful.
- Critical entries (`[!]`) **are** muted too. Auto-promote is suppressed during the mute. Re-promote manually if intent changes mid-mute.

Example:

```bash
found-issues defer src/auth.py:88 --reason "blocked on legal review (JIRA-1234)" --mute-until 2026-08-01
```
