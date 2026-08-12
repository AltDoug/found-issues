# Extracting `cmd_*` into `lib/` — Session Handoff

**Date:** 2026-08-11 · **Session:** "fix the two range follow-ups (v2.2.4)"
**Status:** v2.2.4 shipped, green on all three OSes, 2 PRs merged (#141, #142), 0 open PRs. **1 open ledger entry remains** — the loc-validator one, which is the next session's whole job.
**Re-verification rule (operator's standing feedback):** do NOT act on this
doc's claims without re-verifying against the repo / live state first.
Ground truth: `git fetch && git log --oneline -4 origin/main`, and
`./bin/found-issues list --status=open` (1 entry expected). Use
`./bin/found-issues`, not the CLI on your PATH — see hazard 1.

## TL;DR for the next session

1. Read this doc, then run `./bin/found-issues list --status=open` — **1 entry** expected: `bin/found-issues:4811`.
2. Merged and released: **v2.2.4** (`log` accepts line-range locations; auto-annotate matches range overlap). Green on ubuntu + macOS + Windows, run `31556559372`.
3. **The whole next session is one job:** extract the `cmd_*` groups out of `bin/found-issues` into `lib/` so the file drops under the §12 500-line refactor signal, then delete the `loc-override` marker at `bin/found-issues:7`.
4. **Re-wording the `loc-override` marker to close the entry is NOT acceptable** (operator, twice). The marker is deliberately worded "TRACKED, not justified" so it cannot be closed that way. Extraction is the only close.
5. **#1 hazard:** this is a 5,209-line mechanical move with 750 tests as the only safety net. Move code verbatim, one group per commit, full suite between each. See hazard 2.

## What was done (verify via PR descriptions / commits)

**v2.2.4 — the two range follow-ups (#141, commit `57bcfa7`); ledger flip (#142, commit `9cffc31`).**

**1. `bin/found-issues:507` — `cmd_log` rejected range specs the parser accepts.**
v2.2.3 taught `fi_parse_entry`, `fi_entry_loc` and `--pick` to round-trip
`path:23-49`, but `cmd_log`'s guard predated range support. `log` now accepts
`^[0-9]+(-[0-9]+)?$`, matching `re_path_line`, and rejects non-increasing
ranges (`49-23`, `10-10`) at the writer.

**The obvious implementation would have broken dedup, and this is worth
knowing before touching that code again.** The dedup scan builds an *existing*
entry's key from `fi_parse_entry`'s `line`, which is the **numeric start**
(`bin/found-issues:552`). Keeping the range verbatim in the writer's key would
produce `path:23-49:sym` where the scan computes `path:23:sym` — never a match,
so every re-log of a range entry would silently duplicate it. The range is
rejoined **only at render**, mirroring `fi_entry_loc`; the dedup key keeps the
numeric start. Locked by "log: range entry dedups on second log (writer key
matches parser key)".

**2. `bin/found-issues:1569` — `fi_line_matched` matched only a range's start.**
It now takes `line_end` as a fourth argument and tests hunk overlap
(`start <= hunk_end && end >= hunk_start`), falling back to the identical
single-line comparison when `line_end` is empty.

**One out-of-scope fix, deliberate:** the rewritten comparison coerces the
entry-side values with `10#`. They come from ledger text, and a zero-padded
`path:08` is a base-8 literal that errors under bash 3.2 — which macOS CI runs
(`((: 08: value too great for base`, reproduced locally on `/bin/bash 3.2.57`).
That bare-`ln` bug predates v2.2.4 but sat on the exact line being rewritten,
so it was fixed rather than reintroduced.

**Deliberately NOT done:** the loc-validator entry. Untouched by instruction.

## Remaining work

**`bin/found-issues:4811` — extract the `cmd_*` groups into `lib/`.**
The file is **5,209 lines** against the 500-line refactor signal. (The entry
cites `:4811` and the marker text says "~4800" — both predate v2.2.3/v2.2.4
growth. The location token stays `bin/found-issues:4811` because `--pick`
matches ledger text, not current code. Do not "fix" the number; that is
re-wording the marker.)

### Why this is lower-risk than it looks

- **`lib/` is already the split mechanism and is already wired.** Resolution
  order is documented at `bin/found-issues:53-63`: `$FOUND_ISSUES_LIB_DIR` →
  `$CLAUDE_PLUGIN_ROOT/lib` → `$FI_BIN_DIR/../lib`. Adding a file means one
  `source` line next to the three at `bin/found-issues:66-71`.
- **Packaging needs no change.** The plugin cache is a whole-repo copy
  (verified 2026-08-11: `~/.claude/plugins/cache/altdoug-plugins/found-issues/2.2.3/`
  contains `bin codex-skills commands docs hooks lib scripts skills tests`).
  There is no manifest allowlist in either `plugin.json`, so new `lib/*.sh`
  files ship automatically.
- **Enforcement follows the code.** `tests/source-guards.bats:108` iterates
  `lib/*.sh`, `hooks/*.sh`, `scripts/*.sh` as well as the CLI — its own header
  (lines 35-39) says this exists precisely so "scheduled `cmd_*` extraction into
  `lib/` would [not] quietly move code out of scope". The READ-LOOP GUARD
  convention keeps its teeth as code moves.
- **#132 restored three-OS verification**, which a refactor this size needs.

### Suggested extraction order (largest, most self-contained first)

Measured 2026-08-11 from `rg -n "^cmd_[a-z_]*\(\)" bin/found-issues`:

| Group | Members | Approx lines |
|---|---|---|
| **statusline** | `cmd_install_statusline*` (×6), `cmd_uninstall_statusline*` (×3), `cmd_doctor_statusline*` (×2) | **~1,700** |
| **install/uninstall** | `cmd_install_codex_hooks`, `cmd_install_fi_alias`, `cmd_uninstall_codex_hooks`, `cmd_uninstall_fi_alias`, `cmd_uninstall` | ~320 |
| **doctor** | `cmd_doctor` (~260) + its helpers | ~400 |
| **archive/status** | `cmd_archive` (~554), `cmd_status` (~624) | ~1,180 |
| **ledger core** | `cmd_log`, `cmd_defer`, `cmd_resolve`, `cmd_list`, `cmd_sync`, `cmd_promote*`, `cmd_annotate_*` | ~1,300 |

The statusline family alone takes 5,209 → ~3,500 and is the most isolated
(it barely touches ledger parsing). Getting under 500 means doing essentially
all of them, so treat each as an independently shippable PR rather than
planning one giant diff.

### Method that fits this repo

- One group per PR, patch bump each, `### Fixed` only (hazard 4).
- **Move verbatim.** No renames, no signature changes, no "while I'm here"
  cleanups — a pure move keeps the 750-test suite meaningful as the oracle.
  Anything you notice mid-move goes to `docs/found-issues.md`, not the diff.
- Full `bats tests/` between every group; `bash scripts/check-version.sh`.
- Only delete the `loc-override` marker (`bin/found-issues:7-12`) in the PR
  that actually brings the file under 500 — its own text says "Remove this line
  when the `cmd_*` groups are extracted."
- Close the entry with `annotate-pr <N> --pick bin/found-issues:4811` on that
  final PR. Never `--all`.

## Known live hazards (verify each before relying on it)

1. **Your `found-issues` on PATH may be stale.** Claude Code injects a
   version-pinned plugin bin dir at session start, so a session started before a
   release keeps resolving the OLD version indefinitely. `zsh -lc` is useless as
   a test (it inherits the session env). Check with `command -v found-issues`,
   or just run `doctor` — since v2.2.3 it reports the mismatch itself. Use
   `./bin/found-issues` for anything that must exercise your changes.
2. **Hooks resolve the CLI from PATH, not `FI_BIN_DIR`.** `post-bash-dispatch.sh:52`
   is `FI_BIN="${FOUND_ISSUES_BIN:-found-issues}"`, falling back to a
   repo-relative path only when that is not on PATH. Bit this session: an
   end-to-end drive of the hook with `FI_BIN_DIR` set silently exercised the
   *installed* 2.2.3 and read as "my fix doesn't work". Export
   `FOUND_ISSUES_BIN=<repo>/bin/found-issues`, and print
   `$("$FOUND_ISSUES_BIN" --version)` inside the drive so the binary under test
   is in the evidence.
3. **Old bin + new lib is a false negative.** Comparing old-vs-new with
   `FOUND_ISSUES_LIB_DIR` pointed at the working tree runs an old binary against
   *fixed* lib code. Use `git archive <ref> | tar -x -C <dir>`, or run the
   installed version's own bin+lib from its cache dir.
4. **PATCH bumps must not add a `### Added` CHANGELOG heading** —
   `scripts/check-version.sh` fails the PR.
5. **macOS CI runs bash 3.2.** Local dev is bash 5.x and will not catch it.
   Guard `set -u` array expansions against the empty case, and use `10#` on any
   ledger-derived number entering `(( ))` — a zero-padded value is octal.
   Test directly with `/bin/bash` (3.2.57 on this Mac).
6. **Windows bats takes ~20-34 min.** PR runs are ubuntu-only; macOS + Windows
   run post-merge. Do not call a change verified before the post-merge run.
7. **Pin CI monitors to a run ID, not `--branch main --limit 1`.** Bit this
   session: a docs-only ledger PR merging behind the code PR would have moved
   `--limit 1` onto a run that *skips* bats, reporting green from the wrong run
   — the exact failure class #132 fixed. Use `gh run view <RID>`.
8. **A peer session may hold this repo.** The claim-conflict checker reported
   session `50d12216` on `main` at this session's start. Check `git status` /
   `git stash list` before any commit or branch op in a dirty tree. There are
   3 pre-existing stashes on this repo from earlier sessions — leave them alone.
9. **The Stop hook requires** a `<!-- found-issues-checked: ... -->` marker on
   any turn with substantive tool use (`none-noticed` | `logged` | `deferred`).

## State snapshot (re-verify)

- Branch `main`, commit `9cffc31`, clean tree, **0 open PRs**
- `FI_VERSION="2.2.4"`; release v2.2.4 published 2026-08-12T02:20:42Z
- **750 tests** (`bats tests/`), all passing; README line 11 carries the count
  and `docs-consistency.bats` fails if it drifts
- Ledger: **1 open, 0 critical** — `bin/found-issues:4811` (loc-validator)
- v2.2.4 post-merge matrix (run `31556559372`): bats ubuntu ✅ macOS ✅
  Windows ✅, shellcheck ✅, `ci` ✅
- `bin/found-issues` is **5,209 lines**; `lib/` totals 1,170 across 5 files
- ~20 stale local branches from this and earlier sessions — `/endofday` prunes
  them; branch deletion needs an operator checkpoint

## Resume prompt (also placed on clipboard)

> Work in ~/Documents/projects/found-issues (main, clean at 9cffc31). Read
> docs/handoffs/cmd-extraction-loc-validator-handoff-2026-08-11.md end to end,
> then re-verify per its re-verification rule before acting on anything it
> claims — in particular `git fetch && git log --oneline -4 origin/main`,
> `./bin/found-issues list --status=open` (1 expected), and `wc -l
> bin/found-issues` against the 5,209 figure.
>
> The job is the one remaining open entry: bin/found-issues:4811 — extract the
> cmd_* groups into lib/ so the CLI drops under the §12 500-line signal, then
> remove the loc-override marker at bin/found-issues:7-12. Re-wording that
> marker to close the entry is explicitly NOT acceptable; extraction is the
> only close.
>
> Start with the statusline family (~1,700 lines, most isolated) as its own PR,
> then reassess. Move code VERBATIM — no renames, signature changes, or
> cleanups; the 750-test suite is the oracle and only a pure move keeps it
> meaningful. Anything you notice mid-move gets logged to docs/found-issues.md,
> not folded into the diff.
>
> Per group: patch version bump across bin/found-issues FI_VERSION + both
> plugin.json + CHANGELOG (### Fixed only — check-version.sh rejects ### Added
> on a PATCH), update README's test count if it moves, `bash
> scripts/check-version.sh`, full `bats tests/`, then branch off origin/main →
> PR → `gh pr merge <N> --auto --squash`. Never push to main. Watch the
> post-merge macOS + Windows runs (pin the monitor to the run ID) before
> calling any group done. Only the PR that actually gets the file under 500
> deletes the marker and annotates the entry with
> `annotate-pr <N> --pick bin/found-issues:4811`.
