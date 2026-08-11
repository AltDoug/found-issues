---
name: fi-promote
description: Consolidate [open] entries from current branch into the default branch before deletion
---
<!-- loc-override: generated 1:1 from commands/promote.md by scripts/gen-codex-skills.sh; length is owned by the source command file -->

Move `[open]` entries that exist only on the current branch over to the
default branch, so they survive when this branch gets deleted.

The `pre-branch-delete` hook will hard-block branch deletion until this
runs successfully — that's the enforcement that prevents silent loss of
tracked observations.

## What to do

### Step 1 — Identify what needs promoting

```bash
found-issues promote
```

The CLI:
- Confirms you're on a non-default branch
- Compares this branch's `docs/found-issues.md` against the default branch's version
- Lists `[open]` entries on this branch not yet on the default
- Prints zero or more entries that need to be carried over

### Step 2 — If there are entries to promote

The CLI does NOT auto-edit the default branch — that would violate the
"no direct push to main" guarantee. You guide the user through opening a
PR.

For each listed entry, you have two paths:

**Option A — Stay on current branch, open PR with `docs/found-issues.md` updated**

If the current branch will be merged anyway via PR, just commit the
existing entries on the current branch and open the PR normally. The
entries land on the default branch through that PR.

**Option B — Open a dedicated promotion PR**

If the current branch won't be merged (it's exploratory, abandoned, etc.):

1. Note the source branch name: `git branch --show-current`
2. Switch to the default branch: `git checkout main` (or whatever the default is)
3. Pull latest: `git pull`
4. Create a new branch: `git checkout -b chore/promote-found-issues-from-<branch>`
5. Copy the entries across with the CLI:

   ```bash
   found-issues promote --apply --from <source-branch>
   ```

   This reads the source branch's ledger with `git show` and appends its
   `[open]` entries **verbatim**, so original dates survive and entry age
   stays honest. It is idempotent, so a re-run adds nothing. `[fixed]` and
   `[deferred]` entries are deliberately left behind.

   **Never append to `docs/found-issues.md` with `Edit` or `Write`.** The
   ledger is a shared file that concurrent sessions also write; a direct edit
   loses writes and bypasses the guards. Re-logging with `found-issues log`
   is also wrong here: it stamps today's date, which resets entry age and
   corrupts the stale-entry counts.
6. Commit: `git commit -m "chore: promote found-issues entries from <branch>"`
7. Push and open a PR: `gh pr create --base main --title ...`

After the promotion PR merges, the original branch can be safely deleted —
the `pre-branch-delete` hook will allow it.

## Reporting

Tell the user:
- How many entries need promoting (from CLI output)
- Which path (A or B) is appropriate based on the current branch's status
- The PR URL once you've opened the promotion PR

## When to invoke

Typically triggered by the `pre-branch-delete` hook blocking a deletion
and instructing the user to run `$fi-promote`. The user can also invoke
it proactively before deleting a feature branch.

Not applicable in `local` mode (no branches) or `git`-without-GitHub
(can't open a PR via `gh`). The CLI's `promote` subcommand will refuse
gracefully in those modes.
