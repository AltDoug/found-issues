# Auto-fix readiness gate + superseded retire (3.9.0)

Operator go: Wanda thread `found-issues`, 2026-10-12 04:50Z ("Go 3.9"), after the
reliability answer. Proposal: auto-fix runs only where the repo is ready, sizes its
own watchdog from a measured suite, and stops shipping fixes a live session already
made. Ledger entry `lib/autofix-ship.sh:206` (decide) ships with the recommended
variant, retire as superseded. The operator did not pick a variant, so the
recommendation stands.

## Evidence (2026-10-04..10-11)

- 157 finished items, 89 stale. Setup gaps: no test command 39, red base 26,
  watchdog timeouts 10.
- kh2-midgar base suite took 39m44s, then 42m41s, and it keeps growing. The operator
  had to raise `runTimeoutMin` by hand twice (20 -> 40 -> 60). A fixer run timed out
  at 40 too (rc 124), because it runs the same suite under the same limit.
- kh2-midgar#19 shipped a fix that a live session had already committed
  (`6cdefeb`) mid-run without annotating the ledger, so the 3.6.0
  `fi_af_fixed_elsewhere` ledger check missed it.

## Design

1. **Readiness record** `autofix/ready/<key>` (keyed like `stuck/`, by main worktree).
   Every base-test run that actually ran writes one record: `green|red|timeout`,
   seconds (green: measured duration; timeout: the limit that fired), epoch, test
   command, root. The known-red shortcut writes nothing. A record with a different
   test command than today's is ignored.
2. **Watchdog sized from the measurement** (`fi_af_timeout_secs`).
   `FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS` still wins. Otherwise
   `max(runTimeoutMin, min(cap, auto))`, where `auto` is
   2 x the measured green duration, rounded up to a minute.
   After a timeout, `auto` is 2 x the limit that fired, so a slow suite steps up
   20 -> 40 -> 80 -> 120. A red run sizes it like a green one, since the suite ran
   to the end. A pass on the flake re-run counts one run's time. A record older
   than a week still sizes the limit but no longer gates the queue. The cap is
   120 min. A `runTimeoutMin` set above the cap is honoured.
   `runTimeoutMin` becomes a floor, never a ceiling, so a growing suite never needs
   a hand raise again.
3. **Queue gate.** A spot or sweep is not queued while the repo's last base run
   timed out at a limit >= today's limit (only at the cap, or with the env override
   pinned). The queue message gives the reason. No test command was already a gate
   (spot 3.6.0, sweep). A red base is NOT gated: the known-red cache already retires
   it for $0, and the 3.8.0 STUCK streak needs consecutive retires to fire.
4. **One visible line.** At SessionStart (`autofix summary`), a repo with auto-fix
   on, at least one open entry it could take (`(fix: small|medium)` or untagged), and
   no test command or a gated timeout
   prints one "Auto-fix is waiting in this repo: <reason>. <remedy>." line. A red
   base keeps its STUCK line.
5. **`found-issues autofix ready`** prints the readiness report: test command, last
   base run, effective limit and how it was derived, and the verdict (ready or
   waiting: why).
6. **Superseded retire** (`lib/autofix-ship.sh:206`). A spot run checks whether
   `origin/<base>` changed the cited code since its `base_sha`, at two points: before
   the fixer starts, and again at ship (inside `fi_af_fixed_elsewhere`, the first
   attempt only). What counts as a change depends on the location:
   - `path:line`: a diff hunk within 3 lines of the cited lines. Another entry's
     fix elsewhere in the same file does not count (review finding 2026-10-12).
   - `path:name`: a changed line that names it.
   - A bare path: any change.

   If the code changed, the run retires `stale: superseded: <path> changed on <base>
   since <sha7>` and the entry stays `[open]`, so a later run re-checks it against
   the new base. A topic entry (no file path) skips the check.

## Out of scope

- The superseded check for sweeps. A sweep ships several entries as one commit
  stack, so dropping one entry needs a rebase. It is logged as a follow-up ledger
  entry.
- Writing tests or CI for a repo. That stays a session's job, with the operator's
  approval.
- An eager `ready --run` measure. The first queued item measures the suite, for $0
  of engine spend.
