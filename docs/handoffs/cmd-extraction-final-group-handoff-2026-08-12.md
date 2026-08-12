# `cmd_*` extraction — final group — Session Handoff

**Date:** 2026-08-12 · **Session:** "extract the cmd_* groups into lib/ (loc-validator entry)"
**Status:** 3 of 4 groups shipped — v2.2.5 (#144) and v2.2.6 (#145) merged, v2.2.7 (#146) open with auto-merge armed. `bin/found-issues` is **5,209 → 1,466** lines. **One group remains** and it is the one that clears the 500 signal, deletes the `loc-override` marker, and closes the ledger entry.

**Re-verification rule (operator's standing feedback):** do NOT act on this doc's claims without re-verifying against the repo / live state first. Ground truth:

```bash
git fetch && git log --oneline -4 origin/main
./bin/found-issues list --status=open      # expect 6 — see hazard 1 before believing a smaller number
wc -l bin/found-issues                     # expect 1466 once #146 has merged
```

Use `./bin/found-issues`, not the CLI on your PATH (hazard 4).

## TL;DR for the next session

1. Read this doc, then re-verify per the rule above. **`./bin/found-issues list --status=open` will very likely show fewer than 6 entries — that is the bug in hazard 1, not progress.** Restore before doing anything else.
2. Merged tonight: **v2.2.5** (#144, `c0c1baf`) and **v2.2.6** (#145, `9c5a9d8`). **#146** (v2.2.7) is open with `--auto --squash` armed; check whether it landed.
3. **The whole remaining job is one PR:** move `bin/found-issues` lines **271–1404** into four `lib/` files, delete the `loc-override` marker at `bin/found-issues:7-12`, and close the entry with `annotate-pr <N> --pick bin/found-issues:4811`.
4. **#1 hazard — read hazard 1 before touching anything.** `cmd_sync` false-closes the tracking entry every time the CLI shrinks. It fired **four times** tonight and was committed into a PR once before a review caught it. There is no supported way to reopen a `[fixed]` entry, so a merged false close is permanent.
5. **Re-wording the marker to close the entry is NOT acceptable** (operator, twice). Extraction is the only close. Do not "fix" the `:4811` number either — `--pick` matches ledger text.

## What was done (verify via PR descriptions / commits)

Three PRs, each a **pure verbatim move**: no renames, no signature changes, no cleanups. Each PR body carries the `sed` ranges that reproduce the proof.

| PR | Version | CLI after | New `lib/` files |
|---|---|---|---|
| #144 `c0c1baf` | 2.2.5 | 3,443 | `statusline-core.sh` (400), `statusline-target.sh` (828), `statusline-install.sh` (492), `statusline-uninstall.sh` (133) |
| #145 `9c5a9d8` | 2.2.6 | 2,558 | `uninstall.sh` (93), `archive.sh` (155), `doctor.sh` (351), `codex-hooks.sh` (285), `fi-alias.sh` (84) |
| #146 `b419c0f` | 2.2.7 | 1,466 | `help.sh` (221), `log.sh` (217), `defer.sh` (190), `resolve.sh` (189+), `promote-deferred.sh` (109+), `list-status.sh` (255) |

**The verbatim proof, per group** — every extracted body diffs byte-clean against its origin, and the CLI's own diff is only the added `source` lines plus the version bump:

```bash
diff <(git show <base>:bin/found-issues | sed -n '<range>') <(tail -n +<headerlines> lib/<file>.sh)
diff <(git show <base>:bin/found-issues | sed '<delrange>d') bin/found-issues
```

Function inventories were checked identical each time (74→74, 46→46, 29→29). `/code-review medium` independently reconstructed old-vs-new on all three and confirmed zero content loss (#146's review: "all 108 function bodies byte-identical").

**Verification each PR:** `bats tests/` 750/750, `bash scripts/check-version.sh` OK, `bash -n` clean on the CLI + every lib file, CLI runs under `/bin/bash` 3.2.57, and the affected flows driven end-to-end against a scratch `$HOME` — including executing each patched `.sh`/`.js`/`.py` statusline and watching the counter render, `uninstall-*` restoring files byte-for-byte, `install/uninstall-codex-hooks` preserving a foreign `SessionStart` entry, and the **v2.2.1 data-loss shape** (ledger whose last line has no trailing newline) re-probed against `defer`.

**Deliberately NOT done:** the `loc-override` marker (untouched, wording and "~4800" figure both), the `:4811` citation, and the `cmd_sync` tombstone fix (hazard 1 — it changes product semantics and is the operator's call).

## Remaining work

### The final PR (v2.2.8)

Delete `bin/found-issues` **271–1404** (1,134 lines), one contiguous block. Verify boundaries first — each block ends `}` + blank, each header is preceded by a blank:

| Range on 1,466-line CLI | → `lib/` file | Lines |
|---|---|---|
| 271–704 | `annotate.sh` (shared engine) | 434 |
| 705–941 | `annotate-commands.sh` (`cmd_annotate_pr`, `cmd_annotate_commit`) | 237 |
| 942–1237 | `sync.sh` | 296 |
| 1238–1404 | `promote.sh` | 167 |

Result: **~341 lines**, then deleting marker lines **7–13** (block is 7–12 with `#` separators at 6 and 13) leaves **~334**. Under the 500 signal.

What stays in the CLI: header + READ-LOOP GUARD block (1–105), Utilities (106–270), `main()` dispatch (1405–1466), and the `source` lines.

### Method (unchanged — it worked three times)

- Branch off `origin/main`. Extract with `sed -n`, delete with one `sed -i '' '<a>,<b>d'`, add `source` + `# shellcheck source=` lines next to the existing ones.
- **Prove the move** with the two `diff`s above and a function-inventory `diff` before running any test.
- Bump `FI_VERSION` + both `plugin.json` + CHANGELOG (`### Fixed` only — `check-version.sh` rejects `### Added` on a PATCH).
- `bash scripts/check-version.sh`, `bats tests/`, `bash -n` on everything, drive the flows.
- **Verify `tests/diff-old-ranges.bats` explicitly.** It sources `bin/found-issues` directly to unit-test `fi_diff_old_ranges`, which moves into `lib/annotate.sh` in this group. The bottom guard (`[[ "${BASH_SOURCE[0]}" == "${0}" ]]`) means sourcing loads the lib chain, so it should pass — but it is the one test whose mechanism this move actually touches, so check it by name, not just the aggregate green.
- `/code-review medium` before opening the PR — it found real defects on all three groups, including the committed false close.
- PR → `gh pr merge <N> --auto --squash`. Never push to main.
- **Only this PR** deletes the marker and runs `/found-issues:annotate-pr <N> --pick bin/found-issues:4811`. Never `--all`.

### After the split lands (separate, docs-only)

`lib/resolve.sh:139` is logged: four comments inside moved code still say "at the top of this file" for the READ-LOOP GUARD block and `fi_script_dir`, both of which stayed in the CLI (`lib/resolve.sh:139` and `:171`, `lib/defer.sh:150`, `lib/codex-hooks.sh:80`). Left verbatim on purpose so the byte-identical proofs hold. Retarget them once no more moves are pending.

## Known live hazards (verify each before relying on it)

1. **`cmd_sync` false-closes the tracking entry every time the CLI shrinks. This is the blocker.**
   `cmd_sync`'s `file_lines -lt e_line` branch tombstones any `[open]` entry whose cited line is past EOF. `bin/found-issues:4811` has been past EOF since v2.2.5, so **every** `SessionStart` sync closes it — silently, with no user action and nothing in the output naming the entry. It fired four times tonight; entries at `:2215` and `:1988` are now in the same position. Once it was committed into #146 before `/code-review` caught it.
   **Why it blocks the final PR:** `annotate-pr --pick bin/found-issues:4811` needs the entry `[open]`. If sync closed it first, the pick fails — and there is no supported command to reopen a `[fixed]` entry, so a merged false close is permanent.
   **Mitigation until it is fixed** — gate the commit, do not just check at branch time (the flip happens mid-PR):
   ```bash
   git add docs/found-issues.md
   git show :docs/found-issues.md | grep -q '^- \[open\] .* bin/found-issues:4811 ' \
     || { echo "GATE FAIL"; exit 1; }
   ```
   Restore a flipped entry with a targeted `perl -i -pe` on that one line — **never** `git checkout docs/found-issues.md` (hazard 2). Logged as `[open]` at `bin/found-issues:2215`, reproduced deterministically on a fixture against both 2.2.4 and 2.2.5, so it is pre-existing.
   **Operator decision pending:** whether to fix it before the final PR. Recommendation given: yes, narrowly — treat a present-but-shorter file as line drift rather than closure, matching what the rename check and the `awk END{NR}` fix already do for the same false-close family. It changes when entries auto-close, which is product semantics, so it was not folded in silently.

2. **Peer sessions edit this same working tree live.** Not copies — the same files. Tonight a `git add -A` swept a peer's in-progress `docs/audits/prompt-audit-2026-08-12.md` into a commit (fixed via `git rm --cached` + `--amend`; still untracked on disk, theirs to land). **Stage explicit paths, never `-A`.** Carry their ledger entries (shared state), never their work products.

3. **Peer-logged ledger entries arrive malformed.** Two tonight (`scripts/gen-codex-skills.sh:49`, `bin/found-issues:1988`) were missing the mandatory ` — ` after the location and the `(suggested: …)` wrapper, so `fi_parse_entry` split on the first em-dash *inside the prose* and silently dropped the real symptom while leaving `suggested` null. One also quoted a literal `(fixed: …)` that the annotation regex read as a real closure date on an `[open]` entry. Both repaired (format only, wording kept). **Check with `./bin/found-issues list --json | jq`, not by eye** — correct `symptom`, non-null `suggested`, null `fixed_date`.

4. **Your `found-issues` on PATH may be stale.** Claude Code pins a plugin bin dir at session start, so a session started before a release keeps resolving the old version. `zsh -lc` is useless as a test. Use `./bin/found-issues`; export `FOUND_ISSUES_BIN=<repo>/bin/found-issues` when driving hooks, and print `$("$FOUND_ISSUES_BIN" --version)` inside the drive.

5. **`lib/*.sh` is NOT in loc-validator's scope** — the hook's `*.sh` branch only matches `*/hooks/*`; `lib/` files are unchecked at any size (which is why `lib/parse-entries.sh` at 816 was never flagged). That is why the split works, but it also means **the hook will not stop you recreating the problem inside `lib/`**. Keep new lib files under 500 by judgment. `lib/statusline-target.sh` (828) is the one deliberate exception — one dispatcher plus three language backends sharing the same contract; rationale is in #144's body.

6. **macOS CI runs bash 3.2.** Local dev is 5.x. Guard `set -u` array expansions against empty, use `10#` on ledger-derived numbers entering `(( ))`. Test with `/bin/bash` (3.2.57 here).

7. **Windows bats takes ~20–34 min; PR runs are ubuntu-only.** macOS + Windows run post-merge. **Pin monitors to a run ID** (`gh run view <RID>`), never `--branch main --limit 1`. `cancel-in-progress` is OFF for push-to-main (the #132 fix), so back-to-back merges each get their own complete matrix — they do not clobber each other.

8. **The Stop hook requires** a `<!-- found-issues-checked: ... -->` marker on any turn with substantive tool use (`none-noticed` | `logged` | `deferred`).

9. **`gh-pr-create-verify-gate`** blocks code PRs without verify/review telemetry. Run the `verify` skill (drive the flow) and `/code-review` before `gh pr create`; docs-only diffs are exempt.

## State snapshot (re-verify)

- **All three PRs merged. `origin/main` is at `4a16a9e` (v2.2.7), 0 open PRs.**
- **`bin/found-issues` = 1,466 lines**; `lib/` = 20 files
- Working tree clean apart from the peer's untracked `docs/audits/prompt-audit-2026-08-12.md`
- **v2.2.5 post-merge matrix (run `31563454241`): ubuntu ✅ macOS ✅ Windows ✅, `ci: success`** — fully verified
- **v2.2.6 post-merge matrix (run `31564662186`): ubuntu ✅ macOS ✅, Windows still running** at handoff time — check it
- **v2.2.7 post-merge matrix: run `31567113734`, queued** at handoff time — check it before calling group 3 done
- Ledger: **6 open** — `bin/found-issues:4811` (loc-validator, the job), `bin/found-issues:2215` (the tombstone bug), `bin/found-issues:1988` (annotate-commit false-close, peer), `scripts/gen-codex-skills.sh:49` (peer), `docs/versioning.md:7`, `lib/resolve.sh:139`
- **750 tests**; README line 11 carries the count and `docs-consistency.bats` fails if it drifts
- 3 pre-existing stashes on this repo from earlier sessions — leave them alone
- Many stale local branches — `/endofday` prunes them; deletion needs an operator checkpoint

## Resume prompt (also placed on clipboard)

> Work in ~/Documents/projects/found-issues. Read
> docs/handoffs/cmd-extraction-final-group-handoff-2026-08-12.md end to end,
> then re-verify per its re-verification rule before acting on anything it
> claims — `git fetch && git log --oneline -4 origin/main`, `wc -l
> bin/found-issues` (expect 1466 once #146 merged), and `./bin/found-issues
> list --status=open`. That last one will probably show fewer than 6 entries:
> that is hazard 1, not progress. Restore the tombstoned entries to [open]
> with a targeted perl -i -pe on each line — never git checkout the ledger,
> a peer session shares this working tree.
>
> First: confirm #146 (v2.2.7) merged and its post-merge macOS + Windows runs
> are green, pinned to the run ID.
>
> Then the last extraction group: move bin/found-issues 271–1404 into
> lib/annotate.sh (271–704), lib/annotate-commands.sh (705–941),
> lib/sync.sh (942–1237) and lib/promote.sh (1238–1404); that lands the CLI
> near 341 lines. Then delete the loc-override marker at bin/found-issues:7-13
> — re-wording it is explicitly NOT an acceptable close — and annotate the
> entry with /found-issues:annotate-pr <N> --pick bin/found-issues:4811,
> never --all.
>
> Move code VERBATIM. Prove it before running tests: diff each extracted body
> against `git show origin/main:bin/found-issues | sed -n '<range>'`, diff the
> CLI against the same file with the range deleted, and diff the function
> inventory. Verify tests/diff-old-ranges.bats by name — it sources the CLI to
> reach fi_diff_old_ranges, which moves in this group.
>
> Per the group: patch bump across FI_VERSION + both plugin.json + CHANGELOG
> (### Fixed only), `bash scripts/check-version.sh`, full `bats tests/`, drive
> the affected flows end-to-end, `/code-review medium`, then branch off
> origin/main → PR → `gh pr merge <N> --auto --squash`. Never push to main.
> Stage explicit paths, never `git add -A`, and gate the commit on the :4811
> entry still reading [open].
>
> One decision is waiting on the operator: whether to fix the cmd_sync
> tombstone bug (bin/found-issues:2215) before that final PR. It has
> false-closed the tracking entry four times and a merged false close is
> permanent. Ask once, then proceed.
