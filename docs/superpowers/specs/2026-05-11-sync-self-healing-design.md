# Sync Self-Healing for Stale Annotations — Design

**Date:** 2026-05-11
**Status:** Approved; awaiting implementation plan
**Author:** Claude Opus 4.7 (1M context) + Diogo Silva Sena (AltDoug)
**Related:** Gap research [`docs/superpowers/audits/2026-05-11-annotation-lifecycle-gaps.md`](../audits/2026-05-11-annotation-lifecycle-gaps.md); brainstorming session 2026-05-11

## Problem statement

`bin/found-issues sync` was built around a single happy path: a `(PR: org/repo#N)` annotation reaches `state=MERGED` on the default branch, and the entry flips to `[fixed]`. Anything that deviates from this — a closed-without-merge PR, a force-pushed/squash-merged commit, a renamed file, an unset `origin/HEAD` — falls into one of two failure modes:

1. **Silent stuck-`[open]`** — entry retains its annotation forever, inflates the `in PR` statusline counter permanently, and is blocked from both AI verification (Phase 2 skips annotated entries) and `defer` (blocks on any `(PR: ...)` regardless of PR state). The annotation graph rots; the user has no idea.

2. **False-positive `[fixed]`** — file rename triggers tombstone closure even though the bug followed the file to its new location. The plugin lies and the user's bug list is now wrong. This is the worst kind of failure: looks correct, isn't.

These gaps were enumerated and prioritized in the companion audit doc. The user-stated bar is *passive, AI-driven help* — no new commands the user has to remember, no manual cleanup rituals. Sync should be self-healing.

## Goals

1. **Demote stale PR annotations automatically.** Closed-without-merge PRs → `(PR-closed: org/repo#N)`. Entry becomes eligible for AI verification and `defer`; counter math becomes honest.
2. **Demote unreachable commit annotations automatically.** SHAs that no longer resolve or aren't ancestors of the default branch → `(commit-stale: <sha>)`. Same re-entry path.
3. **Auto-correct file renames before tombstone.** Detect `git mv` via `git log --follow`; rewrite the entry's path and record `(renamed-from: <old-path>)` rather than false-positively flipping to `[fixed]`.
4. **Stronger default-branch detection.** Replace the literal `"main"` fallback with a `gh repo view`-derived default, session-cached.
5. **Surface failures loudly when mutation is unsafe.** `gh` returning empty for a PR could be transient (auth, network, rate-limit); don't demote on first miss — warn instead.
6. **Stay backwards-compatible.** All new annotation forms are sibling parentheticals; existing format-enforcer (blocklist) accepts them automatically.

## Non-goals

- **Merged-then-reverted detection** — too rare, too expensive to detect reliably (would need to scan for revert commits on default branch).
- **Cherry-pick reachability** — partly covered by the `commit-stale` demotion flow which re-enables AI verification. No special case.
- **Repo rename/transfer** — GitHub's HTTP redirects cover the common case; deeper handling deferred until pain materializes.
- **GitHub Enterprise / non-`github.com` host** — `gh` already honors `GH_HOST`; revisit if a GHE user surfaces a concrete bug.
- **Counter cache layer** — sync's existing per-annotation `gh pr view` calls already happen at session start; one extra JSON field (`isDraft`, `mergedAt`) is free. No need for a new caching tier.
- **Auto-demoting unreachable PRs** (A9/A10) — transient gh failures shouldn't lose the link. Warn-only.
- **New user-facing subcommands.** All behavior changes route through the existing `sync` invocation.

## Design decisions

| Decision | Choice | Rationale |
|---|---|---|
| Mutate vs surface-only | **Mutate** (auto-demote stale annotations) | User constraint: maximize passive, AI-driven behavior. Surface-only keeps cleanup toil on the user. |
| New annotation forms | `(PR-closed: org/repo#N)`, `(commit-stale: <sha>)`, `(renamed-from: <old-path>)` | Preserves audit trail; distinguishable for counter math, defer logic, and AI verification; pattern-matches existing parenthetical conventions |
| Unreachable-PR handling | **Warn only, never demote** | Transient gh failures (auth, network, rate-limit) shouldn't permanently lose the PR link |
| File-rename detection | **Auto-correct entry path** + record old path | False-positive `[fixed]` on rename is the worst-case failure; auto-correct beats auto-flip-then-recover |
| Counter semantics | `in PR` excludes `(PR-closed: ...)` and `(PR-unreachable: ...)`; draft PRs older than `stale_days` count as `stale` | Counter must mean "in flight" to be trustworthy |
| Idempotency | All demotions check the leading annotation token (`(PR: ` vs `(PR-closed: `) before mutating | Sync runs every SessionStart — must be safe to run repeatedly |
| Default-branch detection | `gh repo view --json defaultBranchRef.name` with 1h session cache; falls back to `main` only when gh is unavailable | Removes silent footgun for `master`/`trunk`/`develop` repos |
| Version impact | Minor bump (v1.1.x → v1.2.0) | Counter semantics change is user-visible; aligns with v1.1.0 SemVer precedent |
| Phasing | Single spec, multi-phase implementation plan | Matches `defer-recurrence-flow` precedent |

## Architecture & data model

### Entry format additions

Three new sibling annotations extend the existing format without breaking it:

```
- [open] 2026-05-11 src/auth.ts:88 — race on session refresh (PR-closed: AltDoug/found-issues#42)
- [open] 2026-05-11 src/queue.py:42 — possible memory leak (commit-stale: a1b2c3d)
- [open] 2026-05-11 lib/api/handler.ts:120 — null check missing (renamed-from: src/handler.ts)
```

All three are append-only — sync writes them; nothing else mutates them. They're parsed by `lib/parse-entries.sh` (existing regex parser, extended) and emitted only via `bin/found-issues sync` (existing mutation path, extended).

### State machine — annotated entry lifecycle

```
                  ┌──────────────────────────────────────────┐
                  │                                          │
                  ▼                                          │
[open] (PR: …) ──MERGED──> [fixed] (PR: …) (fixed: today)    │
       │                                                     │
       ├──CLOSED──> [open] (PR-closed: …)  ──AI verification──┤
       │                       │                              │
       │                       └─symptom-gone? ─yes─> [fixed] │
       │                                       └─no─> stay    │
       │                                                      │
       └──gh empty──> WARN (no mutation)                       │
                                                              │
[open] (commit: …) ──ancestor──> [fixed] (commit: …)          │
       │                                                       │
       └──unreachable──> [open] (commit-stale: …) ──AI verify──┘

[open] path:N — file missing ──renamed?──┬──yes──> [open] new/path:N (renamed-from: old)
                                          └──no───> [fixed] (closure: tombstone)
```

### Counter math (new semantics)

```
in PR    = entries with `(PR: org/repo#N)` (active form only)
stale    = entries older than FOUND_ISSUES_STALE_DAYS
           + entries with active PR in DRAFT state older than stale_days
           + entries with (PR-closed: ...) or (commit-stale: ...) annotations
critical = entries with [!] flag (unchanged)
issues   = total_open - in_pr - critical (unchanged residual math)
```

The `stale` bucket absorbs everything that's "tracked but not actively progressing" so the existing `stale` counter does double duty without introducing a new segment.

## Components

### `bin/found-issues` — `cmd_sync` extensions

For each `[open]` entry with annotations, the existing per-entry loop classifies and acts:

```
For each (PR: org/repo#N) annotation:
  Fetch gh pr view --json state,baseRefName,mergedAt,isDraft  (one call per PR)
  - state == "MERGED" && base == default_branch
      → flip [open] → [fixed], break (existing behavior)
  - state == "CLOSED" && mergedAt == null
      → demote annotation: (PR: …) → (PR-closed: …)
      → continue to other annotations on same entry
  - state == "OPEN" && isDraft == true && entry_age > stale_days
      → no mutation; classification only (counter logic picks it up)
  - gh returns empty
      → emit one-line warning; no mutation
      → continue
  - any other state
      → no mutation

For each (commit: <sha>) annotation:
  - git rev-parse --verify "$sha" succeeds AND
    git merge-base --is-ancestor "$sha" "$default_branch" succeeds
      → flip [open] → [fixed], break (existing behavior)
  - git rev-parse --verify fails (SHA gone — force-push, squash-merge that removed it)
      → demote annotation: (commit: <sha>) → (commit-stale: <sha>)
  - SHA exists but not ancestor
      → no mutation (unmerged feature branch — today's behavior)

For tombstone candidates (file missing):
  - Run rename detection via git's rename-tracking:
      git log --diff-filter=R --follow --name-status --pretty=format: -- "$old_path"
    Each rename event appears as `R<score>\told_path\tnew_path` (reverse-chronological).
    Take the first line and parse the third tab-separated field for the most-recent rename target.
  - If a candidate new_path is returned AND that path exists in the working tree:
      → rewrite entry path: old_path → new_path
      → append (renamed-from: $old_path) annotation
      → entry stays [open]
  - Else:
      → flip [open] → [fixed] with (closure: tombstone) (existing behavior)

Default-branch detection (called once per sync):
  default_branch =
    1. git symbolic-ref refs/remotes/origin/HEAD (today's primary)
    2. gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'  ← NEW fallback
    3. literal "main" (last resort)
  Cache result per-session via ~/.cache/found-issues/default-branch-<repo>.txt with 1h TTL
```

### `lib/parse-entries.sh` — regex updates

```bash
# Active PR annotation (existing — unchanged regex)
RE_PR_ACTIVE='\(PR: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+\)'

# Closed-PR annotation (new)
RE_PR_CLOSED='\(PR-closed: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+\)'

# Active commit annotation (existing — unchanged)
RE_COMMIT_ACTIVE='\(commit: [a-f0-9]{7,40}\)'

# Stale commit annotation (new)
RE_COMMIT_STALE='\(commit-stale: [a-f0-9]{7,40}\)'

# Renamed-from annotation (new)
RE_RENAMED_FROM='\(renamed-from: [^)]+\)'
```

`fi_count_in_pr` updates to count only `RE_PR_ACTIVE`. `fi_count_stale` adds entries matching `RE_PR_CLOSED` OR `RE_COMMIT_STALE`, plus existing date-based stale logic, plus draft-PR-older-than-stale_days logic.

### `commands/sync.md` — Phase 2 AI verification update

Today's Phase 2 instruction (`commands/sync.md:30-31`) skips entries with any annotation. New rule:

> Phase 2 evaluates entries that are either:
> 1. Unannotated, OR
> 2. Annotated only with `(PR-closed: ...)` or `(commit-stale: ...)` — these mark "the linked work didn't land; re-evaluate the path:line."
>
> For demoted-annotation entries, apply the SAME conservative bias as unannotated entries. The demoted annotation is a hint that someone *tried* to fix this, not evidence that it's fixed. Verify by reading the code; flip only on clear evidence the symptom is gone. The demoted PR/commit ref stays on the line as audit trail in either outcome.

### `bin/found-issues` — `cmd_defer` blocker narrowing

Today's defer blocker (`bin/found-issues:554-563`) rejects any `(PR: ...)` annotation. New rule:

```
Block defer only on (PR: ...) active form.
Allow defer on (PR-closed: ...), (commit-stale: ...).
Updated error message: only fires for active in-flight PRs.
```

### `hooks/format-enforcer.sh` — verification only

The format-enforcer is a blocklist (specific malformed patterns), not an allowlist of valid annotations. New sibling annotations pass through automatically. **Action:** add bats tests confirming `(PR-closed: …)`, `(commit-stale: …)`, and `(renamed-from: …)` annotations do not trigger any of the five blocklist rules. No regex changes expected.

### `cmd_doctor` — additions

Add two checks to `bin/found-issues doctor`:

1. **`gh auth status`** — if not authenticated, report as a warning (not fail), explain that PR-state sync is degraded. Already partially present; promote to consistent format.
2. **`origin/HEAD` symref** — if unset, report as a warning. Suggest `git remote set-head origin --auto`. Explain that absent symref means sync falls back to the gh-based default-branch detection.

### `docs/format-spec.md` — documentation update

Document the three new annotation forms with semantics:

```markdown
| Annotation | Form | Meaning |
|---|---|---|
| (PR: …) | (PR: org/repo#N) | Active in-flight PR; sync checks state every run |
| (PR-closed: …) | (PR-closed: org/repo#N) | PR was closed without merge; entry re-eligible for AI verification |
| (commit: …) | (commit: <sha>) | Commit reachable from default branch closes the entry |
| (commit-stale: …) | (commit-stale: <sha>) | Commit no longer resolvable or not ancestor; entry re-eligible for AI verification |
| (renamed-from: …) | (renamed-from: old/path) | Sync auto-corrected the entry's path after detecting git mv |
```

## Behavior matrix (load-bearing reference)

| Input state | Sync action | Resulting entry state |
|---|---|---|
| `[open] (PR: o/r#N)` + MERGED + base=default | Flip + add `(fixed: today)` | `[fixed] (PR: o/r#N) (fixed: 2026-05-11)` |
| `[open] (PR: o/r#N)` + OPEN | No-op | unchanged |
| `[open] (PR: o/r#N)` + OPEN + isDraft + age > stale | No-op; counter reroutes | unchanged (now counted as `stale`) |
| `[open] (PR: o/r#N)` + CLOSED + !merged | Demote annotation | `[open] (PR-closed: o/r#N)` |
| `[open] (PR: o/r#N)` + gh empty | Warn; no mutation | unchanged |
| `[open] (PR-closed: o/r#N)` | Skip in PR-check loop; eligible for Phase 2 | unchanged unless Phase 2 verifies |
| `[open] (commit: sha)` + reachable + ancestor | Flip + add `(fixed: today)` | `[fixed] (commit: sha) (fixed: 2026-05-11)` |
| `[open] (commit: sha)` + reachable + !ancestor | No-op | unchanged |
| `[open] (commit: sha)` + !resolvable | Demote annotation | `[open] (commit-stale: sha)` |
| `[open] (commit-stale: sha)` | Skip in commit-check loop; eligible for Phase 2 | unchanged unless Phase 2 verifies |
| `[open] path:N` + file missing + git detects rename → new_path | Rewrite path + add `(renamed-from: old)` | `[open] new_path:N (renamed-from: old/path)` |
| `[open] path:N` + file missing + no rename | Flip + tombstone closure | `[fixed] (closure: tombstone) (fixed: 2026-05-11)` |

## Idempotency contract

Every sync run must be safe to re-run. Specifically:

- A demotion happens at most once per annotation — the gh-state check loop matches on the leading `(PR: ` token; demoted `(PR-closed: ` is not in the iteration set.
- A rename auto-correction happens at most once per entry — once the entry has `(renamed-from: ...)`, subsequent missing-file detections at the new path can re-trigger tombstone (this is correct: the new path going missing is a real signal).
- An entry with both `(PR-closed: ...)` and `(commit-stale: ...)` is still eligible for Phase 2 — both are demoted; both signal "the linked work didn't land."

## Testing strategy

`tests/cli-sync.bats` currently has zero coverage of PR-state branches because `gh` is hard to mock in bats. Strategy:

1. **Mock `gh` via a PATH shim.** Create a `tests/bin-shims/gh` script that reads expected output from an env-var-controlled fixture. Many existing test suites use this pattern.
2. **New bats files:**
   - `tests/cli-sync-pr-states.bats` — A1, A3, A9/A10 scenarios (closed-no-merge, stuck-draft, gh-empty)
   - `tests/cli-sync-commit-stale.bats` — B1/B2 scenarios (squash, force-push)
   - `tests/cli-sync-rename.bats` — C1 scenarios (`git mv`, `git mv + edit`, deletion-not-rename)
   - `tests/cli-sync-default-branch.bats` — E1 scenarios (origin/HEAD unset, non-main default)
   - `tests/format-enforcer-new-annotations.bats` — confirms new annotations pass the blocklist
3. **Idempotency tests** — run sync twice, assert no change on second invocation for every demotion case.

## Implementation phasing

The implementation plan (next step) should phase as follows:

1. **Read-only introspection.** Extend the gh-call and git-rev-parse paths to classify each annotation's state. No mutations. Output a sync `--dry-run` summary for testing.
2. **Mutation: annotation demotion.** PR-closed and commit-stale paths. Idempotency tests must pass.
3. **Mutation: rename auto-correction.** Tombstone path gets the rename pre-check.
4. **Counter + defer + Phase 2.** `fi_count_in_pr` / `fi_count_stale` updates; `cmd_defer` blocker narrows; `commands/sync.md` Phase 2 text updates.
5. **Default-branch detection + doctor.** gh-based fallback with session cache; doctor checks for gh-auth and origin/HEAD.
6. **Format spec + CHANGELOG + version bump.** Doc updates; `v1.2.0`.

Each phase commits independently and passes its bats suite before the next starts.

## Open questions for the plan phase

These are for `writing-plans` to resolve via implementation detail:

- Whether rename detection caches the `git log --follow` output across multiple missing-file entries in one sync run (likely yes — single `git log` call early in sync vs. per-entry calls).
- Whether the session cache for default-branch lives in `~/.cache/found-issues/` (consistent with mode-detection cache) or in the issues-file's own header.
- Whether `(PR-closed: ...)` entries get a dedicated Phase 2 hint string in `commands/sync.md`, or share the same instruction as unannotated entries. Spec leans toward "shared instruction with one note about how to read demoted annotations."
- Whether the gh-empty warning is one-line-per-entry or one-line-aggregate at end of sync. Spec leans aggregate to avoid log spam on N-entry repos.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Mutation bugs corrupt user's `docs/found-issues.md` | All mutations go through the same atomic `mv tmp file` pattern as today's flip logic; format-enforcer test suite expanded; sync phase 1 is read-only and used as feature gate during rollout |
| `gh` rate-limit hit on large repos | Sync already calls `gh pr view` per annotation; adding `isDraft` and `mergedAt` to the same call is free (one extra field, not one extra call). Existing rate-limit fallback (fail-open) unchanged |
| Rename detection false-positive: `git log --follow` may follow content-similarity matches that aren't true renames | Match is post-filtered: only treat as rename if (a) the candidate path currently exists in working tree, AND (b) it's the most-recent path returned by `--follow`. Edge cases (file split, file content drift) fall through to tombstone — same as today |
| Counter semantics change breaks user mental model | CHANGELOG entry explicit; minor version bump signals user-visible change; README "what the counters mean" stays in sync |
| Default-branch cache staleness | 1h TTL matches existing mode-detection cache; users with frequent default-branch renames are vanishingly rare |
