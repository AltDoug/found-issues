---
name: fi-promote-deferred
description: Revive a [deferred] entry back to [open], preserving every annotation (touch history, defer-cycle, reason) as evidence of recurrence. Use when a parked issue starts biting again or its mute window expired. Inverse of $fi-defer. Despite the similar name it is unrelated to $fi-promote, which copies branch-only entries onto the default branch before a branch is deleted.
---
<!-- loc-override: generated 1:1 from commands/promote-deferred.md by scripts/gen-codex-skills.sh; length is owned by the source command file -->

The user wants to promote a `[deferred]` found-issue back to `[open]`. This usually happens after the touch counter has triggered a nudge (3 touches in cycle 1; 6 in cycle 2; etc.) — the deferred entry has been bitten enough times that it warrants real attention.

## Invocation

```bash
found-issues promote-deferred <match>
# or
found-issues promote-deferred --match <match>
```

`<match>` is a substring matched case-insensitively against the entry's path or symptom. Same matching rules as `defer`.

## Exit codes — what to tell the user

- **0**: Promoted successfully. Print the CLI's stdout. All annotations (touch history, defer-cycle, reason) are preserved as evidence on the now-`[open]` entry.
- **1**: No `[deferred]` match. The user might have already promoted it, or the substring doesn't hit anything.
- **2**: Ambiguous match. List the matches and ask for a more specific substring.
- **3**: Match hits an `[open]` entry, not `[deferred]`. The user may have meant to promote a different match — suggest `$fi-status` to see the current state.

## When to use promote-deferred

- **Threshold nudge fired** in your `found-issues log` output: "Touched deferred entry (now Nx, threshold N)" → promote and address.
- **Manual re-evaluation** during periodic review of the deferred parking lot.
- **Critical [!] auto-promotion is reserved for the plugin** (it happens automatically on Nth touch); you don't need to promote-deferred those — they flip on their own.

## What promotion does

- Flips status `[deferred]` → `[open]`.
- Preserves `(touched: ...)`, `(defer-cycle: N)`, `(reason: ...)` byte-identical.
- The promoted entry appears in the `issues` count of the statusline counter.
- If you re-defer this entry later, the next defer-cycle bump uses the existing `(defer-cycle: N)` value as the starting point (escalating the threshold geometrically).

## What it doesn't do

- Doesn't fix the bug. That's still your job after promotion.
- Doesn't trigger any sync, archive, or annotation flow. Strictly a status flip.
