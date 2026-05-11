# Deferring recurring issues

Sometimes a logged issue is real but not addressable now (out-of-scope,
blocked, low priority). The plugin treats `[deferred]` as a first-class
lifecycle state: tracked in the file, suppressed from the statusline
counter, and flagged when it recurs.

```bash
# Defer with optional reason
/found-issues:defer src/auth.py:88 --reason "tracked in JIRA-1234"

# Promote back to [open] when ready to address
/found-issues:promote-deferred src/auth.py:88
```

## Recurrence detection

When you `log` an issue that matches an existing `[deferred]` entry's
dedup key, the plugin appends today's date to a `(touched: ...)`
annotation on the deferred entry — no new `[open]` entry is created.

After 3 touches (cycle 1 default), it nudges:

```
Touched deferred entry (now 3x, threshold 3): src/auth.py:88
Consider: found-issues promote-deferred --match auth.py
```

## Critical entries auto-promote

Entries logged with `--critical` (the `[!]` flag) flip back to `[open]`
automatically on the Nth touch — no manual step.

## Loop prevention

If you promote and re-defer the same entry, the threshold for the next
nudge doubles:

| Cycle | Touches before nudge |
|---|---|
| 1 | 3 |
| 2 | 6 |
| 3 | 12 |
| 4 | 24 |

The history is preserved as evidence, but the bar to bug you about it
again rises geometrically. Both knobs are tunable — see
[`docs/configuration.md`](configuration.md) for
`FOUND_ISSUES_DEFER_TOUCH_THRESHOLD` (base, default 3) and
`FOUND_ISSUES_DEFER_ESCALATION_FACTOR` (factor, default 2).
