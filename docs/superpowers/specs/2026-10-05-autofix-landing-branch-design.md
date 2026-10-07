# Auto-fix lands on the session's branch — design

**Date:** 2026-10-05 · **Target release:** 3.2.0 (minor: default behaviour changes)
**Status:** approved in conversation section by section; this document is the written spec for review.

## Why

Every auto-fix today starts from `origin/<default>` (`lib/autofix-queue.sh:217-231`) and opens its PR against the default branch (`lib/autofix-ship.sh:161`). The operator's sessions almost never work on main:

- A read-only survey (2026-10-05) of every repo on the Mac and on dougstation found no direct pushes to main. Every sampled PR was a branch merged within minutes to hours (found-issues median 3 min, agent-config 39 min).
- AltDoug/kh2-midgar: PRs #2-#10 all merged into `gsd/phase-01-feasibility`; `origin/main` is still the 2026-10-01 init commit, 119 commits behind the main checkout. found-issues v3 stacked on `release/v3`.
- Many session branches are never pushed (`worktree-*`, subagent `worktree-agent-*`); many main checkouts sit on a merged branch whose upstream is gone.

Measured cost: on kh2-midgar, 5 spot fixes (2026-10-04/05) and 1 sweep fixed nothing. Every one parked because the cited file or the test command exists only on the working branch. Ledger entry `lib/autofix-queue.sh:102` (decide) records this.

**Operator decisions (2026-10-05):**
1. Fixes start from, and land into, the session's current branch/worktree, not main.
2. When the branch has unpushed commits, start from its pushed tip and PR back into it. Never publish unpushed work. An entry whose file exists only in unpushed commits waits until it is pushed.
3. Landing-branch rule: approach A (tracked branch with fallbacks), below.
4. An auto-fix PR closes its entry as soon as it merges into its landing branch.
5. A cited file with uncommitted or unpushed changes in the session's checkout is busy: the item waits instead of fixing it (section 2).

## Goal and success criteria

- kh2-midgar spot fixes and sweeps fix entries on `gsd/phase-01-feasibility` instead of parking.
- found-issues and every repo whose session sits on the default branch behave exactly as in 3.1.4.
- Every landing choice is visible: the item and the run log record the branch and why it was chosen.

Out of scope: the manual `/found-issues:fix` command (`lib/fix-plumbing.sh`) keeps using the default branch, and nothing here changes how a human-made stacked PR closes.

## 1. Landing-branch resolver

New function `fi_af_landing_branch` in `lib/autofix-queue.sh`. It is called by `fi_af_worktree_add` in place of `fi_resolve_default_branch`, and runs in the item's root (`AFI_root`, the session's checkout or worktree). It sets `AFI_base` (the landing branch) and `AFI_base_why`.

| Root checkout is on | Landing branch | `base_why` |
|---|---|---|
| the default branch, or detached HEAD | default | `default branch` / `detached` |
| branch X, X exists on origin (`git ls-remote --heads origin X`; a stale unpruned `origin/X` ref does not count) | X | `tracks origin/X` |
| branch X, upstream configured but `origin/X` gone | base of the newest merged PR with head X (`gh pr list --head X --state merged --json baseRefName`), if that base exists on origin; else default | `X merged into <base>` / `X gone, base unknown` (no merged PR, or `gh` unavailable) |
| branch X, no upstream | the `origin/*` branch B, excluding `fi/*`, with the smallest `git rev-list --count origin/B..HEAD`; ties go to the default branch; no candidate means default | `nearest pushed ancestor <B>` / `no pushed ancestor` |

Rules:
- The scan only considers branches that still exist on origin and whose merge-base with HEAD is not empty. It runs after one `git fetch -q origin` (all branches; no prune, existence is checked with `ls-remote`).
- The worktree is created from `origin/<landing>`, never from local HEAD (decision 2).
- `AFI_base` already feeds the PR `--base`, the diff/reset base (`autofix.sh:63,76,97,295`, `autofix-b.sh:124`) and the fixer/verifier briefs (`autofix-b.sh:59,191`). Those need no other change.
- The item gains `base_why=`. The claim log line and `autofix status` (running and recent rows) show `base` and `base_why`.

## 2. Waiting for a push

At claim time, before the spot cap is taken (`fi_af_claim`, `lib/autofix-queue.sh:302-311`), the claim resolves the landing branch, fetches it, and checks a spot item whose location names a file with `git -C "$AFI_root" cat-file -e "origin/$AFI_base:<path>"`. No worktree is needed for the check.

- **File present:** take the cap, create the worktree, and run as today.
- **File absent:** leave the item in `queue/` with `waiting=<path> not on origin/<base>`, `wait_since=<epoch>` (kept from the first wait) and `wait_next=<now+900>`, and release the lock. No cap is taken, no worktree is created, and no engine is launched.
- **File busy** (operator decision 5, 2026-10-05): the cited file differs between the session's checkout and the landing branch. That covers uncommitted edits (staged or not) and unpushed commits: `git -C "$AFI_root" diff --name-only "origin/$AFI_base" -- <path>` is non-empty. The item waits the same way, with `waiting=<path> busy in <root>`. This keeps a fix from auto-merging into a branch the session is mid-edit on and forcing a conflict on its next pull. Only the item's own root checkout is checked; another worktree on the same branch is not seen (accepted limit).
  - **Amendment, 2026-10-05 (final review):** the busy check is "uncommitted or unpushed", per decision 5, implemented once as `_fi_af_file_busy` (`lib/autofix-queue.sh`) and used by both the claim wait check and the sweep candidate filter. It replaces the literal `git diff --name-only "origin/$AFI_base" -- <path>` above, because a working-tree diff against the remote tip is non-empty whenever the file changed only on origin: a checkout merely behind origin read as busy and its items waited three days. Busy now means `git diff --name-only HEAD -- <path>` is non-empty (staged or not) or `git rev-list -1 <pushed>..HEAD -- <path>` is non-empty, where `<pushed>` is the branch's own upstream ref `refs/remotes/origin/<up>` when that ref exists (live or stale), else `origin/$AFI_base`. A successful claim also clears `wait_since` and `wait_next`, so a requeued item's next wait starts a fresh clock.
- `fi_afh_stop` (and the launcher B hook path) skip a queued item whose `wait_next` is in the future, so a waiting item costs at most one fetch plus `cat-file` per 15 minutes, and only while a session stops inside its root.
- When `now - wait_since > 3 days`, the next claim retires it as `stale: <path> never reached origin/<base>`.
- Abstract-topic locations (no file) skip the check.
- `autofix status` lists waiting items under Queued with their `waiting=` text.

This answers ledger entry `lib/autofix-queue.sh:102`, recorded with `found-issues decide --answer`.

## 3. Sweeps

- `fi_af_sweep_claim` uses the same resolver from the checkout the sweep was queued in. 3.1.4's test-command check runs on that worktree, so it sees the landing branch.
- In `fi_af_sweep_candidates` (claim time), an entry whose cited file is absent on `origin/<landing>` or busy in the sweep's root checkout (section 2) is skipped for this sweep, with the log line `sweep: skip <loc> (not on origin/<base>)` or `sweep: skip <loc> (busy)`. It is not tagged, not failed, and stays eligible for later sweeps.

## 4. Closing auto-fix PRs on merge

In `lib/sync.sh` (`_fi_pr_info`, ~line 135, and the landed check, ~line 220):
- Add `headRefName` to the existing `gh pr view` JSON.
- A MERGED PR whose head starts with `fi/autofix/` or `fi/sweep/` counts as landed whatever its base.
- Every other PR keeps today's rule (base is default, or base later merged into default).

**Base deleted before the fix PR merges.** With `delete_branch_on_merge` on, GitHub is expected to retarget the fix PR to the merged branch's own base. This is verified live (section 6). If GitHub closes the PR instead, the existing `fi_af_merge_when_green` output (`PR #N is already CLOSED`) and sync's existing `(PR-closed: …)` demotion leave the entry open and visible; the live check records which happens, and a closed case is logged as a found-issues `--decide` entry.

## 5. Errors

| Failure | Behaviour |
|---|---|
| `gh` missing or failing in the gone-upstream lookup | default branch, `base_why=X gone, base unknown` |
| no pushed ancestor | default branch, `base_why=no pushed ancestor` |
| fetch of the landing branch fails | item waits (rc 8, `waiting=git fetch failed`) like any other wait: no spot slot, no `autofix-failed` tag, rechecked on the next stop; the offline wait counts toward `FOUND_ISSUES_AUTOFIX_WAIT_MAX` (3.3.1; before, the item failed) |
| landing branch deleted between claim and PR | `gh pr create` fails, existing failure path |

Auto-fix never pushes to the landing branch. It only pushes its own `fi/*` branch and opens a PR.

## 6. Testing

Bats, using local bare-repo remotes and the existing stand-in `gh`, like the current autofix tests. Every new test is shown failing on the 3.1.4 code first.

- Resolver: one test per table row, plus the tie-to-default and no-candidate cases, and `fi/*` exclusion.
- Busy: an uncommitted edit, and separately an unpushed commit, to the cited file in the root checkout makes the item wait. It runs once the change is pushed (the diff is empty). A busy file in a sweep is skipped.
- Waiting: an absent file waits without taking a spot slot or launching the engine. It runs after the file is pushed to the landing branch. It retires stale when `wait_since` is more than 3 days old (set directly in the item). `wait_next` throttles the Stop launcher.
- Sweep: a candidate absent on the landing branch is skipped and logged. The others proceed.
- Sync: a merged `fi/autofix/*` PR into a non-default base closes the entry. A merged `feat/*` PR into `release/x` still waits for promotion.
- Status shows `base` / `base_why` / `waiting`.

Live, before release, on the throwaway repo AltDoug/fi-v3-e2e:
1. A session on a pushed branch logs a `fix: small` entry. The fix PR targets that branch and merges into it, and sync closes the entry.
2. The landing branch merges into main first, with auto-delete on. Record whether GitHub retargets the open fix PR. Section 4's fallback covers the case where it doesn't.

## 7. Release

3.2.0: CHANGELOG (`### Changed` for the landing branch, `### Added` for waiting/status fields), README status line and test count, both `plugin.json` files, `FI_VERSION`, then the claude-plugins marketplace bump. The post-merge main run must be green on macos-latest. After dougstation self-updates, the standing watch checks kh2-midgar's next fix or sweep lands in `gsd/phase-01-feasibility`.
