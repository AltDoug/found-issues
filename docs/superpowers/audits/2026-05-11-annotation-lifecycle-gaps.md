# Annotation lifecycle gaps — research, 2026-05-11

Investigation triggered by the question: *"What happens when an issue is annotated as `(PR: org/repo#N)`, but the PR gets closed, replaced by another PR, or the issue was fixed by someone else?"*

Scope expanded mid-session to: *what other realistic scenarios are unhandled or silently wrong in the current annotation → closure pipeline?*

**This doc is research-only.** No code was changed. Next step: brainstorm + plan fixes for the P0/P1 gaps below.

---

## Context — current behavior, verified

| Claim | Evidence |
|---|---|
| Sync flips entries only on `state == "MERGED"` | `bin/found-issues:1100-1104` |
| `gh` reports `state=CLOSED, mergedAt=null` for closed-no-merge PRs | Empirically verified against `cli/cli` PRs (#13390, #13384, #13349, #13341, #13340) |
| `in PR` statusline counter is regex-only, never queries gh | `lib/parse-entries.sh:181-192` |
| `defer` is blocked for any `(PR: ...)` regardless of PR state | `bin/found-issues:554-563` |
| AI verification phase skips entries with ANY annotation | `commands/sync.md:30-31` |
| Sync tests have **zero coverage** of PR-state branches | `tests/cli-sync.bats` — 8 tests, all cover tombstone/commit/archive |
| Format-enforcer is a blocklist, not allowlist — new sibling annotations pass through | `hooks/format-enforcer.sh:75-122` |
| The only documented escape hatch ("manually remove the annotation") is inside `defer`'s error message | `bin/found-issues:561` |

### gh PR field reference (empirically verified)

| Field | Type | Values |
|---|---|---|
| `state` | enum | `OPEN` / `CLOSED` / `MERGED` — gh promotes MERGED to its own state |
| `mergedAt` | timestamp / null | Null iff PR didn't merge |
| `closedAt` | timestamp / null | Non-null when state ∈ {CLOSED, MERGED} |
| `isDraft` | bool | `true` for draft PRs (still `state=OPEN`) |
| `baseRefName` | string | Target branch, currently checked against `default_branch` |
| `mergeStateStatus` | enum | `CLEAN` / `BLOCKED` / `DIRTY` / `BEHIND` / `UNKNOWN` / `UNSTABLE` / `HAS_HOOKS` |

Cleanest discriminator for "closed without merge": `state == "CLOSED"`.

---

## Full gap inventory

Organized by lifecycle category. Each row: scenario → current behavior → severity assessment.

### A. PR lifecycle anomalies

| # | Scenario | Current behavior | Severity |
|---|---|---|---|
| **A1** | **PR closed without merge** (abandoned, superseded, reviewer rejected) | Entry stuck `[open]` + `(PR: ...)` forever; counted in `in PR`; AI verification skipped because annotation present; `defer` blocked | **P0** |
| **A2** | Replacement PR opens for same bug | Multi-PR support works; new merge correctly flips. Old stale link persists on `[fixed]` line as audit cruft | P2 (cosmetic) |
| **A3** | PR stuck in DRAFT indefinitely | `state=OPEN, isDraft=true` → sync waits forever; nothing surfaces this | **P1** |
| **A4** | PR reopened after closure → eventually merged | Final MERGED state resolves correctly. Limbo period not surfaced | P2 (eventually self-heals) |
| **A5** | Multi-PR entry with ALL PRs closed-no-merge | Same as A1 | **P0** (subsumed by A1 fix) |
| **A6** | PR merged then reverted on default branch | Entry stays `[fixed]`; bug returns silently | P2 (rare + expensive to detect) |
| **A7** | PR auto-closed by GitHub due to base-branch deletion | Identical to A1 | **P0** (subsumed) |
| **A8** | PR merged to non-default branch (release/X, hotfix) | Sync correctly doesn't flip via `baseRefName` check | Not a gap (intentional) |
| **A9** | Annotated PR number is typo'd / PR deleted | `gh pr view` returns empty → sync silently skips → stuck in `in PR` forever | **P1** |
| **A10** | Cross-repo PR but user not authenticated to that org | Same silent-skip as A9 | **P1** (subsumed) |
| **A11** | Repo renamed / transferred | GitHub HTTP redirects usually work via gh; brittle long-term | P2 |

### B. Commit lifecycle anomalies

| # | Scenario | Current behavior | Severity |
|---|---|---|---|
| **B1** | Squash-merge dropped the original SHA — `is-ancestor` fails on default branch | Entry stays `[open]` forever despite the fix being merged | **P0** (squash-merge is the default workflow at many orgs) |
| **B2** | Force-push removed the commit from history | Same as B1 | **P0** (subsumed) |
| **B3** | Commit SHA prefix becomes ambiguous after many commits | `git rev-parse` errors → sync skips | P2 (theoretical, very rare) |
| **B4** | Commit merged via cherry-pick to default | Original SHA usually isn't an ancestor of default; stuck unless fast-forward | P2 (subset of B1 fix) |

### C. Code-location lifecycle

| # | Scenario | Current behavior | Severity |
|---|---|---|---|
| **C1** | File renamed/moved (`git mv a → b`), bug still present at new path | Tombstone fires on old path → entry **false-positively** flips to `[fixed]`. **Silent regression cover-up.** | **P0** (worst kind of failure: looks like it worked) |
| **C2** | File deleted because feature removed (bug genuinely gone) | Tombstone correctly flips to `[fixed]` | Not a gap (intended) |
| **C3** | Lines added above; `path:line` still resolves but points to different code | Entry stays `[open]` with stale line ref; AI verification can't catch annotated entries | P2 (AI verification covers unannotated case) |
| **C4** | File rewritten, original bug fixed, Claude logged vague entry without line | Tombstone won't fire, AI verification handles it | Not a gap (works as designed) |
| **C5** | Path-only entry whose path is a directory | Tombstone's `[[ ! -f ]]` test returns true for dirs → false-positive `[fixed]` | P2 (depends on user input shape) |

### D. Annotation correctness

| # | Scenario | Current behavior | Severity |
|---|---|---|---|
| **D1** | `annotate-pr` matched on path but PR didn't actually fix the bug | PR merges → entry flips `[fixed]` → bug still there | Already in FAQ; manual recovery acceptable. P2 |
| **D2** | Claude annotated the wrong PR by mistake | Same as D1 | P2 (subsumed) |
| **D3** | PR fixes the bug but touches different files than the logged path | `annotate-pr` finds no match → AI verification eventually catches it | Not a gap (works) |
| **D4** | Two simultaneous PRs each annotated; one merges, other closes | Sync flips on first MERGED (correct). Stale closed-PR annotation remains on `[fixed]` line | P2 (audit cruft only, subsumed by A1) |

### E. Environment / branch model

| # | Scenario | Current behavior | Severity |
|---|---|---|---|
| **E1** | `origin/HEAD` symref unset (common on freshly cloned repos) → fallback hard-codes `main` | If actual default is `master`/`trunk`/`develop`, PR-merge detection silently fails | **P0** (silent footgun) |
| **E2** | `gh` not authenticated / not installed | All PR checks return empty → all `(PR: ...)` entries stuck. `doctor` covers this | P1 (already partly covered; could be louder at sync time) |
| **E3** | GitHub Enterprise / non-github.com host | `gh` honors `GH_HOST` if configured; otherwise silent failures | P2 (niche depending on user base) |

---

## Prioritized work list

### P0 — Ship-worthy gaps (silent failures or false positives, common workflows)

1. **A1 / A5 / A7 — Closed-no-merge PR detection.** Detect `state == "CLOSED"` and surface it; stop counting these in `in PR`; let AI verification or human re-engage with the entry.
2. **B1 / B2 — Squash-merge SHA loss.** When `(commit: <sha>)` no longer resolves on default branch, fall back to detecting the merge via a PR annotation, commit message reference, or content-aware match — not just `is-ancestor`.
3. **C1 — File rename false-positive tombstone.** Before declaring tombstone on a missing file, check `git log --follow` / `git status` to see if the file was renamed. If renamed, update the entry's path or surface for human review — do NOT silently flip to `[fixed]`.
4. **E1 — Default-branch fallback footgun.** Replace `default_branch="main"` fallback with a stronger detection (e.g., `gh repo view --json defaultBranchRef` before the literal "main" guess).

### P1 — Cheap bundle (improves observability with minimal surface area)

5. **A3 — Surface stuck-DRAFT PRs.** Single extra `isDraft` field in the existing `gh pr view` call; if entry is older than `stale_days` AND PR is draft, count it in `stale` instead of `in PR`.
6. **A9 / A10 — Loud silent-skip on gh failure.** When `gh pr view` returns empty for an annotated PR, sync should log a one-line warning (don't silently skip). Same call site as A1 fix.
7. **E2 — Surface gh-auth at sync time.** Reuse `doctor`'s gh-auth check inline in sync; if all annotated entries are stuck because `gh` is unauthenticated, say so.

### P2 — Deferred (rare, low-payoff, or already-acceptable behavior)

- A2, A4, A11, D1, D2, D4 — annotation cruft, eventual self-heal, or already-documented manual recovery.
- A6 — merged-then-reverted: too rare and expensive to detect reliably.
- A8 — non-default-branch merge: intentional.
- B3, B4 — subsumed or theoretical.
- C2, C4 — work as designed.
- C3, C5 — edge cases with low frequency.
- D3 — works (AI verification covers).
- E3 — niche depending on user base; revisit if GHE users surface.

**Skip rationale principle:** every P2 item is either (a) self-healing eventually, (b) currently working as intended, (c) so rare that detection cost outweighs payoff, or (d) already documented with manual recovery.

---

## Solution space (ranked by blast radius)

| # | Solution | Code touched | New annotations | Mutation risk |
|---|---|---|---|---|
| 1 | **Surface CLOSED PRs in sync output without mutating entries.** Sync prints `Warning: entry X has CLOSED PR #N — annotation may be stale.` Counter unchanged. | `cmd_sync` only | None | Lowest |
| 2 | **Exclude CLOSED-PR entries from `in PR` counter; report as `stale`.** Counter logic re-routes when gh reports CLOSED. Caches gh calls. | `fi_count_in_pr` + caching | None | Medium |
| 3 | **Sync rewrites stale `(PR: …)` → `(PR-closed: …)` as demotion annotation.** Counter ignores `PR-closed`; defer no longer blocks; AI verification picks up entry. | sync + parse-entries regexes + format-enforcer + defer | `(PR-closed: ...)` | Medium |
| 4 | **Loosen AI-verification skip rule** so entries with only CLOSED-PR annotations re-enter Phase 2. | `commands/sync.md` instructions | None | Medium (depends on Claude) |
| 5 | **Combination of 1 + 3:** demote annotation AND surface it loudly. Counter rolls into `stale`; `defer` unblocked; AI verification re-engages. | All of above | `(PR-closed: ...)` | Highest, but highest payoff |

### Pattern check against comparable tools

| Tool | Closed-without-merge handling |
|---|---|
| GitHub Issues (PR-linked) | Issue stays open; link rendered with grey "Closed" status badge. User decides. |
| Linear ↔ GitHub | Linked-PR state shown as sub-badge. Linear issue does NOT auto-transition. |
| Jira ↔ GitHub Smart Commits | Link record persists with state shown. No auto-transition. |

**Dominant pattern:** persist the link, surface the state, let human/agent decide. found-issues' current "ignore non-MERGED state and keep counting it as in-flight" is the outlier — opposite of what comparable tools do.

---

## Open design questions for brainstorm phase

1. **Mutation vs surface-only:** is the right default to (a) leave annotations alone and surface state, (b) demote annotations to `(PR-closed: …)` form, or (c) outright strip? Prior `defer` design (`bin/found-issues:554-563`) chose "block + surface manual instruction" — suggests the project leans conservative. Worth confirming.
2. **Performance budget for sync's gh calls:** sync currently calls `gh pr view` once per annotation. Adding `isDraft` is free (same call). Adding gh-auth check is one extra subprocess. Acceptable? Or do we need a per-session cache?
3. **AI verification re-entry for stale-annotated entries:** if A1 demotes annotations, the AI verification phase will see more entries. Phase 2 has strong conservative bias (`commands/sync.md:43-67`) — most stale entries will stay `[open]`. Is that acceptable, or do we need a "demoted-annotation" hint passed to the AI to bias it slightly less conservative?
4. **C1 (file rename) detection cost:** `git log --follow` per missing file is non-trivial. Cheaper alternative: read `git status --renamed=copies-harder` once at sync start. Worth scoping in plan phase.
5. **Counter semantics breakage:** today's "in PR" means "annotated, regardless of state." If P0 fix moves CLOSED-PR entries out of `in PR`, the counter meaning changes (`in PR` = "annotated AND open or merged"). Worth a version bump? Worth surfacing in CHANGELOG?
6. **Format-spec impact:** if we introduce `(PR-closed: …)` as a sibling annotation, the format spec, format-enforcer, parse-entries regexes, and defer blocker all need coordinated updates. Single PR or staged?

---

## Next steps

- Brainstorm fix design for P0 + P1 gaps using superpowers `brainstorming` skill
- Produce one or more implementation plans in `docs/superpowers/plans/`
- Each plan should optimize for passive, AI-driven behavior — the user should not need to do anything manually to benefit
