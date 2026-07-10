# /found-issues:fix — design

**Date**: 2026-07-10 · **Status**: approved (operator, this date) · **Target**: found-issues plugin (public), v1.7.0

## Goal

Complete the plugin lifecycle: log → track → **fix** → close. A `commands/fix.md` slash command
(`/found-issues:fix`) works through the repo's `[open]` entries with an encoded
verify → triage → gate → fix → ship procedure. Natural-language asks ("go fix the found issues")
route into the same procedure via the command description — the command is the procedure, not a
different entry point.

Design driver: ad-hoc fix runs have documented failure modes this procedure exists to prevent —
false closures from over-broad annotation (the 2026-07-09 annotate-pr incident: 12 tagged, 3 fixed,
9 manually de-annotated), "fixing" already-fixed ghosts, and guessing at fixes the entries
themselves say are gated on live/external data.

## Command surface

```
/found-issues:fix            # verify → triage report → operator approves → fix → PR
/found-issues:fix --auto     # same, but skips the approval gate; executes ONLY the auto-fixable bucket
/found-issues:fix --only <path-or-glob>   # restrict to entries whose path matches
```

- Scope: `[open]` entries only. `[deferred]` entries are **surfaced, never fixed**: the triage
  report lists any whose recorded blocker looks resolved (mute-until date passed, revisit trigger
  text now true) under "worth un-deferring?" — the user promotes via
  `/found-issues:promote-deferred`; a later run fixes them.
- `--auto` never widens autonomy: needs-decision and not-code-fixable buckets are reported, not acted on.

## Data flow

```
found-issues list --json          (new CLI subcommand — structured entries, no eyeball parsing)
  → Phase 1  verify each entry against the current tree   (read-only)
  → Phase 2  triage buckets + report                      (gate here unless --auto)
  → Phase 3  fix loop on a dedicated branch
  → Phase 4  PR + precise annotation; merge → existing sync flips entries
```

### Phase 1 — Verify (read-only)

For each in-scope entry, re-derive status from current evidence (the symptom, not just the line
number — lines move). When the pile is >5 entries, dispatch parallel read-only subagents (Agent
tool, general-purpose) with the verification prompt embedded in fix.md; otherwise verify inline.
Verdicts:

- `STILL-VALID` — fresh file:line citation required
- `ALREADY-FIXED` — evidence the symptom is gone (+ what fixed it, if discoverable)
- `CITATION-MOVED` — symptom exists elsewhere; carry the corrected location forward
- `UNVERIFIABLE` — state what's missing

### Phase 2 — Triage buckets

1. **already-fixed** — never "re-fix". Close per format-spec rule 6: append the verification
   token (`(verified: ai)` + one-line evidence) or `(commit: <sha>)` when the fixing commit is
   identifiable. These closures happen on the fix branch like any other change.
2. **auto-fixable** — code/doc change contained in this repo, verifiable by tests/build, no
   external dependency. The only bucket `--auto` executes.
3. **needs-decision** — fix requires a design choice or tradeoff. Presented as numbered questions
   at the gate; unanswered ⇒ untouched.
4. **not-code-fixable** — signals: fix targets an external surface (DNS, dashboards, third-party
   accounts), requires captured live payloads, or the entry says it is operator-gated. Reported
   with what unblocks each; the run offers to convert them to `[deferred]` with a proper
   `(reason:)` so the open count reflects reality.

The triage report numbers every entry (verdict, bucket, planned one-line fix, blast radius) so the
user can approve all, or exclude by number. Default mode waits here; `--auto` proceeds.

### Phase 3 — Fix loop

- Dedicated branch `fix/found-issues-<YYYYMMDD>` — never on the current or default branch.
- Order: critical `[!]` first; entries sharing a file are fixed together (one group); then oldest first.
- Per entry/group: regression test first where the repo has a harness; fix; run the repo's tests +
  build; **one commit per entry** whose message references the entry (path:line + symptom fragment).
- Failure rule: a fix that won't go green within ~2 attempts is fully reverted and reported
  `SKIPPED: <reason>` — never left half-applied.
- Surgical-changes discipline: fix the cited symptom only; new out-of-scope observations get logged
  as new entries, not fixed.

### Phase 4 — Ship & close

- Full test suite + build on the branch; evidence (summary lines) quoted in the PR body.
- One PR per run, body listing per-entry outcomes (FIXED / SKIPPED / CLOSED-ALREADY-FIXED).
- `annotate-pr <N> --pick` for exactly the entries fixed — never `--all` (over-matching lesson).
- Merge → existing `sync` machinery flips annotated entries to `[fixed]`. No new closure logic.
- **Resume**: a re-run's Phase 1 skips entries already carrying `(PR:)`/`(commit:)` annotations —
  the ledger is its own checkpoint; a dead session loses nothing.

## Final report — output contract (operator: "ADHD-proof")

The fix run's last message is a scan target, not an essay. fix.md mandates:

1. **Scoreboard first line**: `Fixed 9 · Closed already-fixed 3 · Skipped 1 · Suggested deferrals 2 · PR #<N>`.
2. **One compact block per fixed entry**: one-line header (`path:line — symptom fragment`), then a
   minimal **Before / After** snippet pair — only the load-bearing lines (≤ ~6 lines each, fenced),
   then one evidence line (`test: <name> PASS · commit <sha>`).
3. **Skipped/needs-decision entries**: one line each with the reason — no snippet.
4. No prose paragraphs between blocks; anything narrative goes in the PR body, not the summary.

## CLI addition: `found-issues list`

`bin/found-issues list [--status=open|deferred|fixed|all] [--json]`

- Built on `lib/parse-entries.sh` (`fi_entries` / `fi_parse_entry`) — conflict-aware, one source of
  parsing truth.
- JSON fields per entry (1:1 with the parse layer, plus `mute_until` via the existing
  `fi_extract_mute_until` and `raw`): `line_no` (number), `status`, `critical` (bool), `date`,
  `path`, `line` (number|null), `symptom`, `suggested`, `prs`, `prs_closed`, `commits`,
  `commits_stale`, `verified`, `fixed_date`, `renamed_from`, `mute_until` — strings, `null` when
  absent — and `raw` (the full entry line; exotic annotations like `(reason:)`/`(closure:)` are
  read from `raw`, not parsed into fields).
- Human format (no `--json`): the entry lines as-is, filtered.
- Generally useful beyond fix (statusline debugging, scripting); ships with bats coverage.

## Explicitly out of scope (YAGNI)

- Parallel fixing in worktrees / workflow orchestration (fixes cluster on shared files; debris risk).
- Cross-repo runs — the command is per-repo like every other plugin command.
- Auto-merge of the fix PR; touching `[deferred]` entries; `--ffi`-style aliases.
- New hooks. The existing format-enforcer/annotate/sync machinery is reused unchanged.

## Testing

- bats: `list --json` output shape (status filter, critical flag, annotation extraction, conflict-aware
  counts, path-less entries, ASCII-only test names per CI guard).
- bats: fix.md ↔ docs consistency row in `tests/docs-consistency.bats` (command inventory).
- Dogfood: first real run on this repo's next open pile; agent-config and sayciao as second targets.
- Docs to update in the same PR: README command table, `docs/architecture.md` subcommand inventory,
  `docs/configuration.md` if any env knob is added (none planned), CHANGELOG (v1.7.0 — minor bump for a new command + subcommand, operator-confirmed).

## Shipping

Standard release coupling: source PR in AltDoug/found-issues, then marketplace version PR in
AltDoug/claude-plugins, in that order.
