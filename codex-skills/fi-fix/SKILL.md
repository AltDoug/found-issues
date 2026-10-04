---
name: fi-fix
description: "Work the open ledger as a batch: re-verify every [open] entry against the CURRENT code, triage into buckets, gate on approval, fix the approved ones on a dedicated branch with tests, and ship a precisely annotated PR. Use when asked to fix the found issues or burn down the ledger. Not for logging new issues ($fi-log) and not for closing a single entry an ordinary PR already fixed ($fi-annotate-pr covers that)."
---
<!-- loc-override: generated 1:1 from commands/fix.md by scripts/gen-codex-skills.sh; length is owned by the source command file -->

Work through this repo's `[open]` found-issues entries: verify → triage →
gate → fix → ship. You do the judgment; the CLI does the mechanics.

Flags in `<the user-provided arguments>`: `--auto` (see the Phase 2 gate) and
`--only <path-or-glob>` (restrict to entries whose path matches).

## Phase 1 — Verify (read-only)

1. `found-issues list --json --cwd <repo root>` for `[open]` entries;
   `found-issues list --status=deferred --json --cwd <repo root>` for the
   deferred surfacing below. Always pass `--cwd` with the repo root, so
   every read and annotation hits the same ledger even after you move into
   the fix worktree.
2. **Resume rule:** skip any open entry whose `prs` or `commits` field is
   non-null — a previous run already addressed it; `sync` will close it on
   merge.
3. Re-verify every remaining entry against the CURRENT tree. The cited
   line may have moved — search for the symptom's code pattern, not just
   the line number. When more than ~5 entries need verification, dispatch
   parallel read-only subagents; give each the entry's `raw`
   line and require a fresh `file:line` citation or counter-evidence back.
   Verdicts: `STILL-VALID` | `ALREADY-FIXED` (state what fixed it) |
   `CITATION-MOVED` (carry the corrected location) | `UNVERIFIABLE`.
   Caveat: the JSON `symptom`/`suggested` fields are display fragments —
   the parser truncates them at the first parenthesis. Always verify and
   match against `raw`, never against `symptom` alone.
4. An entry's location (what `--pick` takes) is `path:line`, or
   `path:line-line_end` when `line_end` is non-null, or bare `path` when
   `line` is null.

## Phase 2 — Triage + gate

Bucket every verified entry:

1. **already-fixed** — symptom gone. Do NOT re-fix, and do NOT edit the
   ledger by hand (hard rule: only the CLI writes it). If the fixing
   commit is identifiable, run
   `found-issues annotate-commit <sha> --pick <location>` and sync flips
   it. Otherwise close it with
   `found-issues resolve "<unique symptom fragment>" --verified ai`.
   Never run sync from this command (it archives, leaving a ledger and
   archive diff behind). Evidence belongs in the PR body and final
   report, never appended to the entry line.
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

- Run `found-issues fix workspace` first. It fetches the default branch
  and prints `worktree=`, `branch=`, `base=`, `source=` and `test=`
  lines: a fresh worktree on its own `fix/found-issues-<YYYYMMDD>-<n>`
  branch. Make every edit in that worktree, by absolute path; never fix
  on the current or default branch.
- Order: critical `[!]` first; entries sharing a file are one group;
  then oldest first.
- Per entry/group: write a failing regression test first when the repo
  has a test harness; apply the minimal fix; run the repo's tests with
  `found-issues fix test <worktree>` (it detects the stack's test
  command); commit with `git -C <worktree> commit` — one commit per
  entry, or one per file-group when entries share files, with the
  message naming every entry it closes
  (`fix: <symptom fragment> (found-issues <location>)`).
- **Failure rule:** if a fix won't go green within ~2 attempts, revert it
  completely and record `SKIPPED: <reason>`. Never leave a fix
  half-applied.
- Surgical: fix the cited symptom only. New out-of-scope problems you
  notice get logged as NEW entries (`found-issues log` style), not fixed.

## Phase 4 — Ship + close

1. Full test suite + build (`found-issues fix test <worktree>`); quote
   the summary lines in the PR body.
2. One PR for the run; body lists per-entry outcomes
   (FIXED / CLOSED-ALREADY-FIXED / SKIPPED / DEFER-SUGGESTED). Write it to
   a file, then run
   `found-issues fix ship <worktree> --title "<title>" --body-file <file> --pick <location>,<location>`
   with exactly the entries this PR fixes — never `--all` (file-level
   auto-match over-annotates: the 2026-07-09 incident false-closed 9
   entries that later needed manual de-annotation). It refuses a dirty
   worktree or red tests, then pushes, opens the PR, annotates the
   entries in the source ledger and commits the same annotation onto the
   PR branch, so it reaches the default branch on merge.
3. `fix ship` never merges: merge according to the repo's own policy.
4. NEVER flip `[open]` → `[fixed]` by hand. Entries fixed by this run
   close via annotate-pr + merge + sync; already-fixed entries close via
   annotate-commit or `resolve --verified ai` (Phase 2 bucket 1).

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
