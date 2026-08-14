# `sync` false-close hardening + the ledger backlog — Session Handoff

**Date:** 2026-08-14 · **Session:** "fix the 5 open issues + Jason's issue #151"
**Status:** v2.2.8, v2.2.9 and the loc-validator closure all **merged**. Jason's #151 **verified, answered and fixed** as v2.3.0 — **PR #153 is OPEN with auto-merge armed, CI still running.** Six ledger entries remain, each with a written fix plan below.

**Re-verification rule (operator's standing feedback):** do NOT act on this doc's claims without re-verifying against the repo / live state first. Ground truth:

```bash
git fetch && git log --oneline -4 origin/main
gh pr view 153 --json state,mergeStateStatus     # MERGED yet?
./bin/found-issues list --status=open            # expect 6 — see hazard 1
wc -l bin/found-issues                           # expect 335
```

Use `./bin/found-issues`, not the CLI on your PATH (hazard 3).

## TL;DR for the next session

1. Read this doc, then re-verify per the rule above.
2. **First: drive PR #153 to merged, then confirm its post-merge matrix actually EXECUTED bats** (`gh run view <RID> --json headSha,jobs`). A `skipped` bats with `ci: success` is a failure disguised as a pass — see hazard 2.
3. **Then work the six ledger entries.** Order and exact fix for each is in "Remaining work". Start with the CI concurrency entry — it protects every PR after it.
4. **#1 hazard:** peer sessions on pre-2.2.8 CLIs keep re-tombstoning ledger entries in this shared working tree. It happened **six times** this session. Restore with a targeted `perl -i -pe`, never `git checkout` the ledger.
5. **Jason is owed a follow-up**: he was asked whether `[!]` criticals should never auto-close at all. If he answers yes, that's a small follow-up PR.

## What was done (verify via PR descriptions / commits)

| PR | Version | What |
|---|---|---|
| #149 `1c53c32` | 2.2.8 | `sync` no longer false-closes an entry whose file merely **shrank** below the cited line |
| #150 `3d693e9` | 2.2.9 | Final §12 extraction: `bin/found-issues` **1,464 → 335 lines**, `loc-override` marker deleted |
| #152 `377ccdd` | — | loc-validator entry closed `(PR: #150) (fixed: 2026-08-13)` via the **PR path**, not a tombstone |
| **#153** (open) | **2.3.0** | **Git is the oracle** for tombstones + `sync` flag validation + `--dry-run` |

**All post-merge matrices green with bats genuinely executed:** v2.2.7 `31567113734`, v2.2.8 `31648840359`, v2.2.9 `31662867144` — ubuntu + macOS + Windows each.

### Issue #151 (Jason / jbelmana) — verified, answered, fixed

His headline "2.2.x regression" **does not hold**; the bugs underneath it are **real and pre-existing**. Evidence posted as a comment on #151.

Claims that did NOT reproduce:

- **`[!]` exclusion "dropped"** — never existed in any `v2.*` tag. His cited `2.1.1:2209` is inside `cmd_archive`; the real gate at `2.1.1:1884` is byte-identical to today's.
- **Git-guard table 1/1/4/1/2 → 0** — all zero in every version including 2.1.1. Nothing was dropped.
- **`runtime-integrity.sha256` / `lib/runtime-safety.sh` removed** — never existed in any tag's tree, in any release asset, or in any commit in full history (`git log --all -S`).
- **"9 of 13 false-closed vs 2.1.1"** — ran his probe on identical fixtures: same on 12 of 13, and 2.2.9 is *better* on the 13th.

Claims that DID reproduce (all fixed in #153):

- `sync --help` ran a **full mutating sync**; so did any typo'd flag.
- Abstract locations (`workflow/release-process`), **never-tracked/typo paths**, and **dirty-worktree deletions** were all tombstoned.
- `[!]` criticals were closed on unconfirmed absence.

**The fix:** git is the oracle — a tombstone fires only on a git-confirmed *committed removal* (absent from `HEAD` **and** present in history). Everything ambiguous stays `[open]`. On the 13-entry probe: 2.1.1 false-closes **4**, v2.3.0 false-closes **0**, while still closing both genuine removals.

**Deliberately NOT done:** no blanket `[!]` exemption (operator chose git-as-oracle; a critical whose file was truly `git rm`'d still closes). Jason was asked if he wants criticals fully exempt.

### Review caught two regressions I introduced

`/code-review medium` on #153 found five issues; **two were self-inflicted** by the `probe_path` change and would have shipped:

- `--dry-run` still mutated via the unconditional **auto-archive** (only the main `mv` was guarded).
- **Spaced renames were garbled**: `rename_source` stayed the truncated first token, so the substitution rewrote only the prefix — unrecoverable by hand.
- `path symbol ~range` locations silently lost **both** tombstone and rename handling.
- `sync -- --help` still ran a mutating pass.
- The `--dry-run` test could not fail (matched `"1"`, which `cmd_status` always prints).

All five fixed in `c0ef0de` with four regression tests. **762 tests.**

## Remaining work

Six `[open]` entries. Each waits for the previous post-merge matrix (hazard 2).

1. **`.github/workflows/test.yml:56` — CI concurrency. Do this first; it protects everything after.**
   Root cause is displacement of a *pending* run, not the aggregator: with `cancel-in-progress: false` GitHub still keeps only ONE pending run per group, so a third push cancels the queued one. Fix at source — give pushes a per-SHA group:
   ```yaml
   group: ${{ github.workflow }}-${{ github.event_name }}-${{ github.ref }}-${{ github.event_name == 'push' && github.sha || '' }}
   cancel-in-progress: ${{ github.event_name != 'push' }}
   ```
   PR events keep per-ref grouping so new commits still cancel stale PR runs. `tests/ci-workflow.bats` exists — extend it to pin the expression.

2. **`docs/versioning.md:7` + `lib/resolve.sh:139` — docs cluster (docs-only, no matrix).**
   `versioning.md` cites "FI_VERSION … (line 9)"; it is **line 31** and has drifted every release. `docs/statusline-integration-contract.md:48` cites "line ~971" for the `cmd_status` segment branch, now in `lib/list-status.sh`. Fix: cite **symbols**, not line numbers.
   `lib/resolve.sh:139` tracks comments saying "at the top of this file" for the READ-LOOP GUARD block and `fi_script_dir`, both of which stayed in `bin/found-issues`. **The entry says four; it is now seven** (`lib/sync.sh:51`, `lib/resolve.sh:142` and `:174`, `lib/codex-hooks.sh:80`, `lib/annotate.sh:142` and `:411`, `lib/defer.sh:150`).

3. **`bin/found-issues:1988` — annotate-commit false-close.**
   **The entry's path is STALE**: the code now lives in `lib/annotate-commands.sh` (the `[[ -z "$target" ]] && target="HEAD"` default) and `lib/sync.sh` (the ancestor closer). `annotate-commit` defaults to `HEAD`, and the closer flips on ANY ancestor SHA with no relation check — so running it on a fresh branch *before* committing closes the entry with a fix that never landed. `/found-issues:fix` Phase 3 prescribes exactly that branch-then-fix order, so the workflow sets the trap. Fix: reject a target already an ancestor of the default branch unless `--force`. TDD.

4. **`scripts/gen-codex-skills.sh:49` — Codex skill descriptions.**
   Add an optional `codex-description:` frontmatter key the generator prefers, falling back to `description:`. Keeps the Claude Code picker label short while giving model-routed Codex real when-to-use text. Fix at the **generator**, not the 13 generated files (they are overwritten every run).

5. **`lib/archive.sh:36` — unknown-flag sweep (logged this session).**
   Four more sites swallow unknown flags via `*) shift ;;`: `cmd_archive`, `cmd_promote`, `cmd_install_statusline`, `cmd_uninstall_statusline`, plus the loop at `bin/found-issues:298`. **`archive` is irreversible in the same way `sync` was** — it MOVES entries out of the ledger, so `archive --help` runs a real archive pass. Extract the rejection idiom from `cmd_sync` into a shared helper and apply to all five.

## Known live hazards (verify each before relying on it)

1. **Peer sessions re-tombstone the ledger in this shared checkout.** Not copies — the same files. Happened **six times** this session, once between a gate check and the `annotate-pr` that depended on it. Those sessions pin their plugin bin dir at startup, so they keep running pre-2.2.8 CLIs until restarted; v2.3.0 cannot reach into them. Restore surgically:
   ```bash
   perl -i -pe 'if (/^- \[fixed\] .* <path>:<line> /) { s/^- \[fixed\] /- [open] /; s/ \(closure: tombstone\) \(fixed: [0-9-]+\)$//; }' docs/found-issues.md
   ```
   **Never** `git checkout docs/found-issues.md`. **Never** `git add -A` — a peer's untracked `docs/audits/prompt-audit-2026-08-12.md` is on disk and is theirs.

2. **A queued post-merge matrix can be displaced — do not stack merges.** `cancel-in-progress: false` makes a second push *queue*, but a third push **cancels the queued one before it starts** (shows as `cancelled` with zero jobs). This voided v2.2.7's matrix entirely while `ci` reported success on a docs-only replacement. **After every merge, confirm bats actually EXECUTED for that SHA** (`gh run view <RID> --json headSha,jobs`) — a `skipped` bats with `ci: success` is the failure mode, not a pass. Entry 1 above fixes the root cause.

3. **Your `found-issues` on PATH may be stale.** Claude Code pins a plugin bin dir at session start. Use `./bin/found-issues`; export `FOUND_ISSUES_BIN=<repo>/bin/found-issues` when driving hooks.

4. **macOS CI runs bash 3.2.** Local dev is 5.x. Test with `/bin/bash` (3.2.57 here).

5. **`skills/rules/SKILL.md` has a hard 3,700-byte budget** (`docs-consistency.bats`). It is at **3,699**. Any addition must remove something.

6. **Windows bats takes ~20–34 min; PR runs are ubuntu-only.** macOS + Windows only run post-merge.

7. **The Stop hook requires** a `<!-- found-issues-checked: ... -->` marker on any turn with substantive tool use.

8. **`gh-pr-create-verify-gate`** blocks code PRs without verify/review telemetry. Run the `verify` skill and `/code-review` before `gh pr create`; docs-only diffs are exempt.

## State snapshot (re-verify)

- `origin/main` at `377ccdd` (v2.2.9 + ledger closure). **`bin/found-issues` = 335 lines**, `lib/` = 24 files.
- Branch `fix/tombstone-git-oracle-and-flag-validation` at `c0ef0de`, pushed. **PR #153 OPEN, auto-merge SQUASH armed**, CI running.
- Working tree: clean except the peer's untracked `docs/audits/prompt-audit-2026-08-12.md` (leave it).
- **762 tests**; README line 11 carries the count and `docs-consistency.bats` fails if it drifts.
- Ledger: **6 open** — `scripts/gen-codex-skills.sh:49`, `docs/versioning.md:7`, `bin/found-issues:1988`, `lib/resolve.sh:139`, `.github/workflows/test.yml:56`, `lib/archive.sh:36`.
- Issue **#151 open** by `jbelmana`, answered; keep open until #153 merges, then close referencing it.
- 3 pre-existing stashes — leave them alone.

## Resume prompt (also placed on clipboard)

> Work in ~/Documents/projects/found-issues. Read
> docs/handoffs/sync-false-close-and-ledger-backlog-handoff-2026-08-14.md end to
> end, then re-verify per its re-verification rule before acting on anything it
> claims — `git fetch && git log --oneline -4 origin/main`, `gh pr view 153
> --json state,mergeStateStatus`, `./bin/found-issues list --status=open`
> (expect 6), and `wc -l bin/found-issues` (expect 335).
>
> If the open count is below 6, that is hazard 1, not progress: a peer session
> on a pre-2.2.8 CLI re-tombstoned entries in this shared working tree. Restore
> them to [open] with the targeted perl in hazard 1 — never git checkout the
> ledger, and never git add -A.
>
> First: drive PR #153 (v2.3.0, auto-merge armed) to merged, then confirm its
> post-merge matrix actually EXECUTED bats on that SHA rather than skipping —
> `gh run view <RID> --json headSha,jobs`. A skipped bats with ci:success is the
> failure, not a pass. Once merged, close issue #151 referencing the PR.
>
> Then work the six open ledger entries in the order given under "Remaining
> work", each with its own PR: the CI concurrency fix FIRST (it protects every
> PR after it), then the docs cluster, then annotate-commit's HEAD-default
> false-close, then the codex-description generator key, then the unknown-flag
> sweep. Two entries carry stale text — bin/found-issues:1988 points at code
> that now lives in lib/annotate-commands.sh, and lib/resolve.sh:139 says four
> dangling comments when there are seven. Correct those as part of doing them.
>
> Per PR: TDD, patch/minor bump across FI_VERSION + both plugin.json +
> CHANGELOG, `bash scripts/check-version.sh`, full `bats tests/`, drive the
> affected flow end-to-end, `/code-review medium`, then branch off origin/main →
> PR → `gh pr merge <N> --auto --squash`. Never push to main. Stage explicit
> paths. Do not stack merges — let each post-merge matrix finish first.
>
> No decisions are outstanding. Drive all six to done.
