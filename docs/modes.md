# Workflow modes

found-issues auto-detects which mode each repo is in and adapts its
behavior. There's nothing to configure — just open Claude in the repo
and it does the right thing.

## The four modes

| Mode | When you're in it | Closure mechanism |
|---|---|---|
| `local` | No `.git/` directory at all | Manual `[open]` → `[fixed]` edits + tombstone |
| `git` | Git repo, but remote isn't on GitHub (or no remote at all) | `(commit: <sha>)` annotations + tombstone |
| `github-direct` | GitHub remote, but no recent merged PRs (you push to main directly) | `(commit: <sha>)` annotations + tombstone |
| `github-pr` | GitHub remote with recent merged PRs (last 30 days) | `(PR: org/repo#N)` annotations + commit + tombstone |

## Detection signals

The detection runs at the boundary of every command and caches per-repo
for one hour. Signals checked, in order:

1. **`git rev-parse --git-dir`** — if this fails, you're outside a git
   repo. Mode = `local`.
2. **`git remote get-url origin`** (with fallback to first remote) —
   if empty or doesn't contain `github.com`, mode = `git`.
3. **`gh auth status`** — if `gh` isn't installed or isn't authenticated,
   GitHub-specific features won't work. Degrade to `git` mode.
4. **Recent merged PRs** — `gh pr list --state merged --limit 5 --search "merged:>YYYY-MM-DD"` (where the date is 30 days ago). If any results, mode = `github-pr`. Otherwise mode = `github-direct`.

The 30-day window is intentionally short. A repo with one merged PR three
years ago shouldn't be classified `github-pr` if you've been pushing
straight to main lately.

## Per-mode behavior matrix

| Feature | `local` | `git` | `github-direct` | `github-pr` |
|---|---|---|---|---|
| File location | `<cwd>/.found-issues.md` | `<repo>/docs/found-issues.md` | `<repo>/docs/found-issues.md` | `<repo>/docs/found-issues.md` |
| `/found-issues:log` | yes | yes | yes | yes |
| `/found-issues:status` | yes | yes | yes | yes |
| `/found-issues:annotate-commit` | n/a (no git) | yes | yes | yes |
| `/found-issues:annotate-pr` | n/a | n/a | n/a (or rare) | yes |
| `/found-issues:promote` | n/a | yes (limited) | yes (limited) | yes |
| `/found-issues:sync` (annotation-driven) | tombstone only | commit-scan + tombstone | commit-scan + tombstone | PR-scan + commit-scan + tombstone |
| `/found-issues:sync` (AI verification) | yes | yes | yes | yes |
| Format-enforcer hook | off | passive warn | hard block | hard block |
| Pre-commit hook (if installed) | n/a | active | active | active |
| Pre-branch-delete hook | n/a | active | active | active |
| SessionStart count + sync | yes | yes | yes | yes |
| Stop-hook reminder | yes | yes | yes | yes |

## Harness-agnostic: same mode, same ledger, on Claude Code or Codex

Mode detection and the annotation/closure mechanisms above are entirely
about the *repo's* git/GitHub state — they don't care which agent harness
is driving. A repo detected as `github-pr` behaves identically whether
Claude Code or Codex opened the session, and both harnesses read and
write the same `docs/found-issues.md`.

One row in the behavior matrix above is harness-limited rather than
mode-limited: the **Stop-hook reminder** is Claude Code only in v1 —
Codex's transcript format isn't parsed by the smart-fire logic, so the
hook fails open there regardless of mode. **SessionStart count + sync**
runs on both harnesses, but only Claude Code has a statusline surface to
render the count as a segment; Codex gets the same entries injected into
context at session start with no persistent glance-view.

## Mixed workflows: PR sometimes, push direct sometimes

A repo where you sometimes open PRs (for big features) and sometimes
push direct (for small fixes) is fully supported. Both `(PR: ...)` and
`(commit: ...)` annotations are always valid; sync handles both regardless
of detected mode.

The mode in this case is `github-pr` (because PRs exist in your recent
history), but you can run `/found-issues:annotate-commit HEAD` whenever
you push direct — sync will flip the entry when the commit lands on the
default branch.

## Why detection happens automatically

Asking the user to declare a mode at install time would be friction. The
user would have to:

- Know what each mode means
- Remember which one they're in
- Re-declare if their workflow changes
- Re-declare per-repo for any monorepo

Auto-detection avoids all of this. The cost is one short shell command
at the boundary of each found-issues call (`git rev-parse`, sometimes
`gh auth status`). With a 1-hour cache per repo, the overhead is
negligible.

## Detection cache

Mode is cached in `~/.cache/found-issues/mode_<owner>_<repo>` for one
hour. The cache file contains the detected mode string (`github-pr`,
`github-direct`, `git`, `local`).

To force re-detection (e.g., after authenticating `gh` or after your
first merged PR makes you `github-pr`-eligible):

```bash
rm ~/.cache/found-issues/mode_*
```

Or programmatically via `fi_invalidate_mode_cache` if you're sourcing
`lib/detect-mode.sh`.

## Mode upgrades over time

Modes change as your workflow evolves. The system handles this without
any explicit user action:

- A new repo starts in `git` mode (no PRs yet)
- After your first PR opens and merges to main, the next mode-detect
  run (after cache TTL expires, ~1 hour) returns `github-pr`
- All future `/found-issues:annotate-pr` calls now make sense; older
  entries that were committed-but-not-PR'd retain their `(commit: ...)`
  annotations and still resolve correctly

You don't need to migrate or convert anything. Both annotation forms
coexist forever.

## Overrides for testing or opt-out

Two environment variables short-circuit detection:

| Variable | Effect |
|---|---|
| `FOUND_ISSUES_MODE=local` | Force local mode regardless of git state. Useful if you have a `.git/` you don't want found-issues to use. |
| `FOUND_ISSUES_MODE=github-direct` | Pin to push-direct workflow even if PRs exist. Useful for solo repos where you've experimented with PRs but want commit-annotation as default. |
| (any value) | Skips detection entirely; uses the value as-is |

Set in your shell profile (`.bashrc` / `.zshrc`) for persistent override,
or per-command for one-off.

## Edge cases

**Multi-repo monorepos** (e.g., orchard-style): each subdirectory is
detected independently if it has its own `.git/`. If subrepos share a
parent `.git/`, all of them inherit the parent's mode.

**Detached HEAD**: detection still works (git operations succeed). The
`promote` command will refuse, since there's no current branch to promote
from.

**Squash-merge gotcha**: if you annotate `(commit: abc1234)` locally,
then GitHub's squash-merge produces a different SHA on main, the
`is-ancestor` check will fail. Workaround: also annotate with `(PR:
org/repo#N)` if there's an associated PR, OR re-run
`/found-issues:annotate-commit <new-sha>` after the squash-merge with
the merged commit's actual SHA.

**Rebase-merge**: same issue as squash-merge. Same workarounds.

**Force-pushed PR**: if the PR is force-pushed and the original `(commit: ...)`
annotation now points to a commit that's not on main, sync will leave
the entry as `[open]`. The `(PR: ...)` annotation, if present, will
still resolve correctly when the (force-pushed) PR merges.
