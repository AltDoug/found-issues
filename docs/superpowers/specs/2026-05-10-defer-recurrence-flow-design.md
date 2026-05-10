# Defer Recurrence Flow — Design

**Date:** 2026-05-10
**Status:** Approved (brainstorming complete; awaiting implementation plan)
**Author:** Claude Opus 4.7 (1M context) + Diogo Silva Sena (AltDoug)
**Related:** Brainstorming session 2026-05-10; found-issues v1.0.4

## Problem statement

The plugin's `[deferred]` status is currently a one-way trip. There is no defer subcommand (status flips require hand-editing markdown), no signal when a deferred issue recurs, and no path back to `[open]` short of another manual edit. In practice this means deferred entries become a true parking lot — issues that bite the user repeatedly stay invisible to the plugin's automation surface (statusline counter, SessionStart context, log-time dedup), and the only reminder is the operator's own memory.

The dedup machinery (`lib/canonicalize.sh:fi_dedup_key` + `bin/found-issues:217-249`) already produces a stable canonical key per entry and uses it to skip duplicate `log` invocations against `[open]` entries. **It does not check `[deferred]` entries** — so when a new `log` matches a deferred entry, the plugin silently creates a fresh `[open]` entry instead of recognizing recurrence. That's the natural touch signal we're not using.

## Goals

1. First-class lifecycle: `defer` and `promote-deferred` subcommands replace hand-editing.
2. Passive recurrence signal: extend the existing dedup loop so `log` invocations matching a `[deferred]` entry append a touch annotation rather than creating a duplicate.
3. Hybrid promotion: critical (`[!]`) entries auto-promote on Nth touch; non-critical entries nudge the operator to promote manually.
4. Loop prevention: defer→touch→promote→re-defer cycles preserve full touch history and escalate the threshold geometrically each cycle, so the plugin shuts up faster on entries the operator genuinely doesn't want to address.
5. Surgical: extend existing affordances; don't add a new statusline segment.

## Non-goals

- No statusline segment for "watch" / touched-deferred entries. Promotion (auto or manual) is the visibility event; the existing `issues` count handles ambient awareness through the existing pipeline.
- No bulk operations (`defer --pattern <regex>`). YAGNI for solo use.
- No `review-deferred` skill. The auto-loaded doc already lets Claude surface deferred entries on demand. Add later if pain materializes.
- No concurrent-write protection. Out of scope (single-user tool; existing `log` doesn't lock either).

## Design decisions

| Decision | Choice | Rationale |
|---|---|---|
| Trigger model | Recurrence (touch counter) | Aligns with how recurrence actually surfaces; reuses dedup infrastructure |
| Promotion mechanism | Hybrid: critical `[!]` auto-promote; non-critical nudge | Preserves operator control on routine items; auto-escalates the items most likely to bite |
| Loop prevention | Persist touch history + escalate threshold (3 → 6 → 12 → 24) | Self-regulating; honors operator intent ("fine, I really don't want to deal with this") while keeping evidence visible |
| Statusline | No new segment | Promotion bumps existing `issues` count; ambient awareness handled by existing `issues` segment + Claude reading auto-loaded doc |
| Subcommand scope | Minimal: `defer` + `promote-deferred` + extend `log` | Smallest viable surface |
| Touch annotation format | `(touched: <date>[, <date>...]; <date>...)` with `;` cycle separator | Backwards-compatible parenthetical; minimal parsing complexity |
| Same-day touches | Always append (raw evidence) | Same-day re-logs are valid signal; debouncing hides accidents and adds complexity |
| Defer of in-PR entry | Block with explanation (exit 4) | Deferring an in-flight PR creates silent state-loss across both `issues` and `in PR` counts |

## Architecture & data model

The existing entry format is extended with three optional parenthetical annotations, all backwards-compatible with the current parser:

```
- [deferred] 2026-05-10 src/foo.py:42 — null check missing (suggested: add guard) (touched: 2026-05-21, 2026-05-28, 2026-06-04; 2026-07-15) (defer-cycle: 2) (reason: tracked in JIRA-1234)
```

- **`(touched: <list>)`** — comma-separated ISO dates, optionally with `;` separators marking defer-cycle boundaries. Append-only; most recent date last in each cycle segment.
- **`(defer-cycle: N)`** — integer count of defer→promote→re-defer cycles. Absent on first defer (implicit `1`); present from cycle 2 onward.
- **`(reason: ...)`** — optional human note from `defer --reason "..."`. Replaced (not appended) on each re-defer.

Threshold formula (with defaults):

```
threshold(cycle N) = $FOUND_ISSUES_DEFER_TOUCH_THRESHOLD * $FOUND_ISSUES_DEFER_ESCALATION_FACTOR^(N-1)
                   = 3 * 2^(N-1)
                   → cycle 1: 3, cycle 2: 6, cycle 3: 12, cycle 4: 24, ...
```

The threshold is checked against the count of dates **in the current cycle's segment** (after the last `;` in `touched: ...`) — not cumulative across history. Persistent history serves as evidence for future maintainers, not as a count toward the next nudge.

## Components

### New CLI subcommands (`bin/found-issues`)

```
found-issues defer <match> [--reason "<text>"]
  - <match>: substring of entry path or symptom (case-insensitive, post-canonicalization).
    Same matching style as annotate-pr. Multiple matches → exit 2 with list.
  - Flips status [open] → [deferred].
  - First defer: no defer-cycle annotation.
  - Re-defer (entry has prior touched: history):
    * Increments defer-cycle (or sets to 2 if absent).
    * Appends ; separator to (touched: ...) annotation, marking start of new cycle.
    * Replaces existing (reason: ...) with new --reason value (or removes if no --reason).
    * Touch history preserved untouched.
  - Exits: 0 ok, 1 no match, 2 ambiguous, 3 already deferred, 4 has active PR annotation.

found-issues promote-deferred <match>
  - Flips [deferred] → [open]. All annotations preserved.
  - Touch history serves as evidence of recurrence; reason annotation provides historical context.
  - Exits: 0 ok, 1 no match, 2 ambiguous, 3 not deferred.
```

### Extended subcommand: `cmd_log` (existing, in `bin/found-issues:158`)

The dedup loop (currently scanning only `[open]` entries via `fi_entries "$file" open`) extends to also scan `[deferred]`. On match against a `[deferred]` entry:

1. Compute today's touch count = count of comma-separated dates in current cycle's segment + 1.
2. Append today's date to `(touched: ...)` annotation — create the annotation if absent, append after last `;` if present.
3. Determine defer-cycle (default 1 if no `(defer-cycle: N)` annotation).
4. Compute threshold for this cycle.
5. Branch on count + criticality:
   - count < threshold: brief stderr line "Touched deferred entry (Nx of M for promotion): <hint>".
   - count == threshold AND entry is `[!]` critical: auto-promote inline; print "Touched [!] critical deferred entry — auto-promoted to [open] (Nx in cycle N)".
   - count == threshold AND not critical: print stderr nudge with `promote-deferred --match <hint>` suggestion.
   - count > threshold: same nudge as `==` case (each subsequent touch re-fires the nudge until promotion).
6. **No new `[open]` entry is created.** The touch is the response.

### New lib helpers (extend `lib/parse-entries.sh`)

```
fi_extract_touched_segment <entry>     → echoes the (touched: ...) value (or empty)
fi_current_cycle_touch_count <entry>   → echoes count of dates after last ';' (or all dates if no ';'); 0 if no annotation
fi_extract_defer_cycle <entry>         → echoes integer (1 if absent or non-numeric)
fi_extract_reason <entry>              → echoes the (reason: ...) value (or empty)
fi_compute_threshold <cycle>           → echoes BASE * FACTOR^(cycle-1); env vars override BASE/FACTOR
fi_append_touch <file> <entry> <date>  → mutates file (atomic temp+mv); appends date to entry's (touched: ...)
fi_increment_defer_cycle <file> <entry> → mutates file; bumps defer-cycle annotation; appends ';' to touched
```

### New skills (markdown wrappers)

```
commands/defer.md            → /found-issues:defer <match> [reason]
commands/promote-deferred.md → /found-issues:promote-deferred <match>
```

Pattern mirrors existing `commands/log.md` and `commands/annotate-pr.md`: short prose explaining when to invoke, then the canonical CLI invocation.

### Unchanged

`cmd_status`, `cmd_archive`, `cmd_sync`, `cmd_annotate_pr`, all hooks (SessionStart, format-enforcer, pre-commit, stop-reminder, etc.), statusline integration. The format-enforcer + pre-commit hook regexes get extended to recognize new annotation patterns and treat them as valid (not flag as malformed).

## Data flow walkthrough

### Scenario A — Happy path

```
Day 1:  $ found-issues log src/auth.py:88 — leaks session token in error path
        → Logged: [open] src/auth.py:88 ...

Day 5:  $ found-issues defer src/auth.py:88 --reason "tracked in JIRA-1234, behind retention work"
        → Deferred 1 entry. (cycle 1, threshold for nudge: 3 touches)
        → Entry: [deferred] ... (reason: tracked in JIRA-1234, behind retention work)

Day 12: $ found-issues log src/auth.py:88 — leaks session token in error path
        → stderr: "Touched deferred entry (1x of 3 for promotion): src/auth.py:88"
        → Entry: [deferred] ... (reason: ...) (touched: 2026-05-21)
        → No new [open] created.

Day 19: same → 2x of 3
Day 26: 3x → nudge fires
        → stderr: "Touched deferred entry (now 3x, threshold 3): src/auth.py:88
                   Consider: found-issues promote-deferred --match auth.py"
        → Entry: ... (touched: 2026-05-21, 2026-05-28, 2026-06-04)

Day 27: $ found-issues promote-deferred --match auth.py
        → Promoted [deferred] → [open]: src/auth.py:88
        → Touch history (3 touches across 21 days) preserved as evidence.
        → Entry: [open] ... (reason: ...) (touched: 2026-05-21, 2026-05-28, 2026-06-04)
```

### Scenario B — Critical [!] auto-promote

Same as A but entry was logged with `--critical`. On 3rd touch:
```
$ found-issues log src/auth.py:88 — auth bypass
→ stderr: "Touched [!] critical deferred entry — auto-promoted to [open] (3x in cycle 1)"
→ Entry flips automatically. Statusline `critical` count bumps from 0 → 1.
```

### Scenario C — Re-defer cycle (loop prevention)

Continuing A after promotion (cycle 1 done, 3 touches in history):
```
Day 30: $ found-issues defer src/auth.py:88 --reason "rescoped, parking for v2"
        → Re-deferred. (cycle 2, threshold for next nudge: 6 touches)
        → Entry: [deferred] ... (reason: rescoped, parking for v2)
                 (touched: 2026-05-21, 2026-05-28, 2026-06-04; ) (defer-cycle: 2)

Day 35..120: 6 touches accumulate AFTER the ; marker; nudge fires at 6
        → Entry: ... (touched: 2026-05-21, 2026-05-28, 2026-06-04; 2026-07-15, 2026-07-22, 2026-08-01, 2026-08-15, 2026-09-01, 2026-09-15)
                  (defer-cycle: 2)
```

If promoted then deferred AGAIN (cycle 3), threshold becomes 12. The bar to bug the operator rises geometrically while history compounds as visible evidence.

### Scenario D — Error paths

```
$ found-issues defer nonexistent
Error: no [open] entries match "nonexistent". (exit 1)

$ found-issues defer auth      # multiple matches
Error: ambiguous match — 3 [open] entries match "auth": <list>
       Use a more specific match. (exit 2)

$ found-issues defer already-deferred
Error: already [deferred]. To re-defer (after promote), use found-issues defer
       — defer-cycle increments automatically. (exit 3)

$ found-issues defer src/auth.py:88   # entry has (PR: foo#42)
Error: entry has an active PR annotation (PR: AltDoug/foo#42).
       Deferring an in-flight PR creates a confusing state. Either:
       1. Wait for the PR to merge (entry will auto-flip to [fixed] via /found-issues:sync).
       2. Manually remove the (PR: ...) annotation if the PR was abandoned, then re-run defer.
(exit 4)
```

### Scenario E — Same-day double touch

```
$ found-issues log src/auth.py:88 — leaks session token   # touch, appends 2026-05-21
$ found-issues log src/auth.py:88 — leaks session token   # touch, appends 2026-05-21 again
→ Entry: ... (touched: 2026-05-21, 2026-05-21)
```

Always-append. Same-day touches count as separate signal; the threshold model handles "spam" gracefully (you'd hit threshold sooner, get nudge, promote). Documented behavior.

## Error handling

| Condition | Handling |
|---|---|
| `defer`/`promote-deferred` no match | Exit 1, clear stderr with the exact match string |
| Multiple matches | Exit 2, list all matches with their dedup keys, suggest more-specific substring |
| `defer` of already-deferred | Exit 3, suggest the re-defer-after-promote workflow |
| `defer` of in-PR entry | Exit 4, two-option recovery message (wait for merge OR remove annotation) |
| `promote-deferred` of [open] entry | Exit 3, helpful message |
| Promote-deferred of entry whose path no longer exists | Succeed; markdown record is independent of file existence |
| Malformed annotations (hand-edited corruption) | Defensive parsing: regex-match well-formed dates only; non-matching tokens count as 0; defer-cycle defaults to 1 |
| `FOUND_ISSUES_DEFER_TOUCH_THRESHOLD` invalid | Warn to stderr, fall back to default (3) |
| `FOUND_ISSUES_DEFER_ESCALATION_FACTOR` invalid | Warn to stderr, fall back to default (2) |
| Empty `docs/found-issues.md` | Defer/promote hit no-match path → exit 1 |
| Concurrent writes | Last-writer-wins (out of scope, documented limitation) |

All file mutations use the existing temp-file + `mv` pattern (`bin/found-issues:1442`, `bin/found-issues:1158`) for atomicity on a single FS.

## Testing strategy

Mirrors the density of `cli-statusline.bats` (28 tests for 5 states + 6 transitions).

**New bats files:**
- `tests/cli-defer.bats` — ~9 tests
- `tests/cli-promote-deferred.bats` — ~6 tests

**Extended bats file:**
- `tests/cli-log.bats` — ~10 new touch-detection cases
- `tests/cli-status.bats` — ~3 regression cases

**Hook test extensions:**
- `tests/format-enforcer.bats` + `tests/pre-commit.bats` — assert new annotation patterns `(touched: ...)`, `(defer-cycle: N)`, `(reason: ...)` are accepted, not flagged as malformed.

**Full test inventory** (~28 new tests, total goes from current ~184 → ~212):

```
cli-defer.bats:
  1. flips [open] → [deferred], no defer-cycle annotation on first defer
  2. --reason captures (reason: ...) annotation
  3. no match → exit 1
  4. ambiguous match → exit 2 with listing
  5. already deferred → exit 3 with re-defer-after-promote suggestion
  6. has active (PR: ...) annotation → exit 4 with two-option recovery
  7. re-defer (entry has prior touched: history) increments defer-cycle, appends ;
  8. re-defer with new --reason replaces old reason
  9. preserves all other annotations (suggested:, PR:, etc. that aren't reason:)

cli-promote-deferred.bats:
  1. flips [deferred] → [open], all annotations preserved byte-identical
  2. no match → exit 1
  3. ambiguous → exit 2
  4. promote of [open] → exit 3 with helpful message
  5. preserves (touched: ...) byte-identical
  6. preserves (defer-cycle: ...) as evidence

cli-log.bats new cases:
  1. log matching [deferred] appends today's date to (touched: ...), no new [open]
  2. log matching [deferred] without prior (touched: ...) creates the annotation
  3. count below threshold prints brief stderr "Nx of M for promotion"
  4. count == threshold non-critical prints nudge with promote-deferred command
  5. count == threshold critical [!] auto-promotes inline, statusline `critical` bumps
  6. cycle 2 threshold = 6 (default base 3, factor 2) — fires at 6 NEW touches after ;
  7. cycle 3 threshold = 12
  8. same-day double touch appends twice
  9. log matching neither [open] nor [deferred] adds new [open] (existing behavior intact)
  10. FOUND_ISSUES_DEFER_TOUCH_THRESHOLD=5 overrides default; invalid value warns + defaults

cli-status.bats new cases:
  1. [deferred] entries count as 0 in status (no regression)
  2. promoted entry counts in [open]
  3. critical [!] post-auto-promote bumps `critical` not `issues`

format-enforcer.bats + pre-commit.bats new cases (~3 total):
  - new annotation patterns accepted as valid
```

**E2E test:** one full-lifecycle scenario in `cli-log.bats` walking log → defer → 3x log → verify nudge → promote-deferred → re-defer → 6x log → verify cycle-2 nudge → final state assertions.

## Implementation phases

Suggested sequencing (one PR per phase, reviewable independently):

**Phase 1 — Lib helpers + format-enforcer/pre-commit extensions** (foundational, no behavior change yet)
- Add `fi_extract_touched_segment`, `fi_current_cycle_touch_count`, `fi_extract_defer_cycle`, `fi_extract_reason`, `fi_compute_threshold`, `fi_append_touch`, `fi_increment_defer_cycle` to `lib/parse-entries.sh`.
- Extend hook regexes to accept new annotation patterns.
- Tests for all helpers; hook tests confirm acceptance.

**Phase 2 — Defer + promote-deferred subcommands** (additive, no impact on existing flows)
- `cmd_defer`, `cmd_promote_deferred` in `bin/found-issues`.
- Skill wrappers `commands/defer.md`, `commands/promote-deferred.md`.
- Full test coverage per Section 5.

**Phase 3 — Extend `cmd_log` dedup to scan [deferred]** (the actual recurrence-detection feature)
- Modify dedup loop to also iterate `[deferred]` entries.
- Branch on critical/non-critical + threshold check.
- New `cli-log.bats` cases.

**Phase 4 — Documentation** (CHANGELOG entry, README section, design doc cross-link)
- Bump version (1.0.5 if no other features land first).
- CHANGELOG entry with rationale + worked example.
- README section under "What it does" describing the lifecycle.

## Open questions / future work

- **`/found-issues:review-deferred` skill** — periodic triage walkthrough. Defer until felt friction; the auto-loaded doc + Claude in-session recommendations may already cover the use case.
- **Touch decay** — should touches older than M days be discounted? Adds complexity; the geometric escalation already self-regulates without needing decay. Defer.
- **Cross-repo touch correlation** — "this deferred entry is touched in 3 different repos" could be a stronger signal than 3 touches in one. Out of scope for v1; per-repo state is sufficient for the solo workflow.
- **Annotation cleanup on `archive`** — when an entry eventually flips to `[fixed]` and gets archived, do we strip touch annotations to keep the archive clean? Or preserve as historical evidence? Tentative: preserve. Revisit if archive files get noisy.

## References

- Brainstorming session: 2026-05-10 (this conversation)
- Existing dedup machinery: `lib/canonicalize.sh`, `bin/found-issues:217-249`
- Existing entry parser: `lib/parse-entries.sh:fi_parse_entry`
- Atomic write pattern: `bin/found-issues:1442` (`cmd_uninstall_statusline`), `bin/found-issues:1158` (`fi_strip_legacy_handwritten`)
- Format enforcement: `hooks/format-enforcer.sh`, `hooks/pre-commit.sh`
