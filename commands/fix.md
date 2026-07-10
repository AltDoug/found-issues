---
description: Fix open found-issues entries — verify each against current code, triage into buckets, gate on approval, fix on a branch with tests, ship a PR with precise annotations. Runs when the user asks to "fix the found issues" or work through the open ledger.
argument-hint: [--auto] [--only <path-or-glob>]
allowed-tools: Bash(found-issues:*), Bash(git:*), Bash(gh:*), Bash(bats:*), Read, Edit, Write, Glob, Grep
---

Work through this repo's `[open]` found-issues entries: verify → triage →
gate → fix → ship. You do the judgment; the CLI does the mechanics.

Flags in `$ARGUMENTS`: `--auto` skips the approval gate (and then executes
ONLY the auto-fixable bucket). `--only <path-or-glob>` restricts to entries
whose path matches.

## Phase 1 — Verify (read-only)

1. `found-issues list --json` for `[open]` entries; `found-issues list
   --status=deferred --json` for the deferred surfacing below.
2. **Resume rule:** skip any open entry whose `prs` or `commits` field is
   non-null — a previous run already addressed it; `sync` will close it on
   merge.
3. Re-verify every remaining entry against the CURRENT tree. The cited
   line may have moved — search for the symptom's code pattern, not just
   the line number. When more than ~5 entries need verification, dispatch
   parallel read-only subagents (Agent tool); give each the entry's `raw`
   line and require a fresh `file:line` citation or counter-evidence back.
   Verdicts: `STILL-VALID` | `ALREADY-FIXED` (state what fixed it) |
   `CITATION-MOVED` (carry the corrected location) | `UNVERIFIABLE`.

## Phase 2 — Triage + gate

Bucket every verified entry:

1. **already-fixed** — symptom gone. Do NOT re-fix. Closure edit (on the
   fix branch, Phase 3): append `(verified: ai)` plus a one-line evidence
   note to the entry, or `(commit: <sha>)` when the fixing commit is
   identifiable.
2. **auto-fixable** — code/doc change contained in this repo, verifiable
   by the repo's tests/build, no external dependency.
3. **needs-decision** — the fix requires a design choice. Formulate the
   question with options; do not guess.
4. **not-code-fixable** — external surface (DNS, dashboards, third-party
   config), needs a captured live payload, or the entry says it is
   operator-gated. Propose converting to `[deferred]` with a `(reason:)`.

Also list `[deferred]` entries whose blocker looks resolved (`mute_until`
in the past, or the recorded revisit trigger is now true) under **"worth
un-deferring?"** — never fix them this run.

Present the numbered triage report (verdict, bucket, planned one-line fix,
blast radius per entry) and STOP for approval — approve all or exclude by
number. With `--auto`: print the report and proceed with bucket 2 only.

## Phase 3 — Fix loop

- Branch `fix/found-issues-<YYYYMMDD>` off the default branch. Never fix
  on the current or default branch.
- Order: critical `[!]` first; entries sharing a file are one group;
  then oldest first.
- Per entry/group: write a failing regression test first when the repo
  has a test harness; apply the minimal fix; run the repo's tests +
  build; commit — ONE commit per entry, message referencing the entry
  (`fix: <symptom fragment> (found-issues <path>:<line>)`).
- **Failure rule:** if a fix won't go green within ~2 attempts, revert it
  completely and record `SKIPPED: <reason>`. Never leave a fix
  half-applied.
- Surgical: fix the cited symptom only. New out-of-scope problems you
  notice get logged as NEW entries (`found-issues log` style), not fixed.

## Phase 4 — Ship + close

1. Full test suite + build; quote the summary lines in the PR body.
2. One PR for the run; body lists per-entry outcomes
   (FIXED / CLOSED-ALREADY-FIXED / SKIPPED / DEFER-SUGGESTED).
3. Annotate precisely: `found-issues annotate-pr <N> --pick <path:line>`
   for exactly the entries this PR fixes — never `--all` (file-level
   auto-match over-annotates: the 2026-07-09 incident false-closed 9
   entries that later needed manual de-annotation).
4. Merged PRs are closed by the existing sync machinery — do not flip
   `[open]` → `[fixed]` by hand for fixed entries.

## Final report (required format)

The last message is a scan target, not an essay:

1. First line scoreboard:
   `Fixed 9 · Closed already-fixed 3 · Skipped 1 · Suggested deferrals 2 · PR #N`
2. Per FIXED entry, one compact block:
   - header line: `path:line — symptom fragment`
   - **Before** / **After** fenced snippets — only the load-bearing lines
     (≤ ~6 lines each)
   - one evidence line: `test: <test name> PASS · commit <short-sha>`
3. SKIPPED / needs-decision / deferral suggestions: one line each with
   the reason. No snippet.
4. No prose paragraphs between blocks — narrative belongs in the PR body.

Example block:

    2. bin/found-issues:880 — status residual double-subtracts overlap

    Before:
    ```bash
    residual=$((total_open - in_pr - critical))
    ```
    After:
    ```bash
    residual=$((total_open - in_pr - critical + overlap))
    ```
    test: "status counts critical in-PR overlap once" PASS · commit ab12cd3
