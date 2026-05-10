---
description: Defer a [open] found-issue to [deferred] — suppresses it from the statusline counter and adds optional reason. Re-defers (after promotion) automatically increment the defer-cycle and escalate the touch threshold for the next nudge.
argument-hint: <match> [--reason "<text>"]
allowed-tools: Bash(found-issues:*)
---

The user wants to defer a `[open]` found-issue. Deferring means: keep the entry visible in `docs/found-issues.md` but suppress it from the statusline counter and exempt it from `[open]`-only checks. The entry stays in the file as a parking-lot record.

## Invocation

```bash
found-issues defer <match> [--reason "<text>"]
```

`<match>` is a substring matched case-insensitively against the entry's path or symptom. If the match is ambiguous (matches multiple `[open]` entries), the CLI lists all matches and exits 2 — surface them to the user and ask for a more specific match.

## Exit codes — what to tell the user

- **0**: Deferred successfully. Print the CLI's stdout (it includes cycle + threshold info).
- **1**: No match. The CLI prints the match string; suggest the user check `docs/found-issues.md` or run `/found-issues:status` for the current entry list.
- **2**: Ambiguous match. The CLI lists all matches; ask the user for a more specific substring (e.g., line number, distinctive part of the symptom).
- **3**: Already `[deferred]`. The CLI explains the re-defer-after-promote workflow. If the user actually wanted to promote it back, suggest `/found-issues:promote-deferred`.
- **4**: Entry has an active `(PR: ...)` annotation. Deferring would silently drop the entry from both the `issues` and `in PR` counters. The CLI prints the two-option recovery (wait for merge OR manually clear the annotation); surface it to the user verbatim.

## When to use defer

- **Out-of-scope but real**: a logged issue is genuine but you've decided not to address it in the current cycle (e.g., behind another work stream, blocked on external dep, low-priority cleanup).
- **NOT for "this isn't a real issue"**: those should be removed from the file entirely, not deferred.
- **NOT for in-flight PRs**: the plugin auto-flips entries to `[fixed]` when the referenced PR merges via `/found-issues:sync`. Defer would interfere.

## Re-defer behavior

If you defer an entry that was previously `[deferred]` → promoted → now `[open]` again (the touch history will be visible in the entry's `(touched: ...)` annotation), the CLI auto-increments the `defer-cycle` annotation and the threshold for the next promotion-nudge doubles (3 → 6 → 12 → ...). Each re-defer raises the bar.

## Optional `--reason "<text>"`

Captures a short human note explaining WHY this entry is being deferred. Stored as `(reason: ...)` on the entry. Replaces any existing `(reason: ...)` from a prior cycle. Helpful for future re-review.
