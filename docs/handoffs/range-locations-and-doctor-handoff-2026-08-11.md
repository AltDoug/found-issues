# Line-range locations + doctor's stale-CLI check — Session Handoff

**Date:** 2026-08-11 · **Session:** "fix the two small found-issues entries"
**Status:** v2.2.3 shipped and verified on all three OSes. 3 PRs merged (#137–#139), 0 open. **3 open ledger entries remain** — the loc-validator one deliberately untouched, plus 2 new follow-ups logged by this session.
**Re-verification rule (operator's standing feedback):** do NOT act on this
doc's claims without re-verifying against the repo / live state first.
Ground truth: `git log --oneline -6` on `main`, and
`./bin/found-issues list --status=open` (NOT the statusline count, which can
lag a session).

## TL;DR for the next session

1. Read this doc, then run `./bin/found-issues list --status=open` — 3 entries expected.
2. Merged and released: **v2.2.3** (line-range locations + doctor's stale-CLI check). Green on ubuntu + macOS + Windows.
3. Next step, recommended: **the two range follow-ups as one PR** — `bin/found-issues:507` and `bin/found-issues:1569`. Same subsystem, both small, and together they close the range story. See Remaining work.
4. Do **not** attempt `bin/found-issues:4811` (loc-validator) as a `/found-issues:fix` job — it needs its own session, and re-wording its `loc-override` marker to close it is not acceptable.
5. **#1 hazard:** your shell's `found-issues` may be a STALE version. As of v2.2.3 `doctor` tells you — see hazard 1.

## What was done (verify via PR descriptions / commits)

**v2.2.3 — two ledger entries fixed (#137, commit `0de14c6`).**

**1. `lib/parse-entries.sh:118` — line-range locations.** `fi_parse_entry`
accepted only `^[0-9]+$` as a line spec, so `path:23-49` matched neither
location regex and parsed to `path='' line=''`. `fi_entry_loc` returns 1 on an
empty path, so range entries never entered the `--pick` candidate list —
`--pick` reported "no `[open]` entry matches" for an entry plainly present in
the file, reading as user error rather than a parser limit.

Measured against the real orchard ledger (7 range-form entries), each CLI run
with its own bin+lib:

| CLI | range entries with a parsed path | with `path=null` |
|---|---|---|
| v2.2.2 (installed) | **0** | 7 |
| v2.2.3 | **7** | 0 |

**The ledger entry's own suggested fix was overridden, deliberately.** It said
to keep `23-49` verbatim in the `line` field. Three consumers evaluate that
field arithmetically — the `10#` coercion in `fi_entry_to_json`, `cmd_sync`'s
tombstone `-lt` probe, and `fi_line_matched`'s `(( ))` — and bash silently
evaluates `"23-49"` as the **subtraction -26**:

```
$ line="23-49"; echo $((10#$line))
-26
```

Verbatim would have emitted `"line":-26` in `--json` and exited 0. So `line`
holds the numeric range **start** and a new `line_end` holds the end. All three
arithmetic sites stay correct with no change, and the failure direction
inverts: a location-reconstruction site that forgets to rejoin degrades to "no
match" (the visible failure that already existed) instead of a silently wrong
number. Rejoining happens in `fi_entry_loc` and in the annotate candidate list,
which must render the same token because `--pick` matches by exact string
equality.

`--json` gained `"line_end"` (null for single-line entries). `"line"` is
unchanged for every existing consumer.

**Scoped down from the original report:** PR/commit flips on range entries were
never broken — `fi_parse_entry` emits `prs=` from the annotation tail
independently of path parsing, and sync gates the flip on `$e_prs`, not
`$e_path`. Impact was unreachability, not data loss.

**2. `bin/found-issues:4157` — doctor's stale-CLI blind spot.** (The cited line
had drifted to `:4245`; the entry's own token was used for annotation, since
`--pick` matches ledger text, not current code.) doctor printed a bare
`✓ CLI: <path>` without comparing it to the *installed* plugin version, so it
read healthy while the session ran a stale binary. Now `fi_doctor_plugin_version`
reads `installPath` from `~/.claude/plugins/installed_plugins.json`, prefers the
`plugin.json` version on disk there, and warns on mismatch.

The advice is **direction-aware** — a dev checkout is legitimately ahead of the
installed plugin and must not be told to restart:

```
# dev checkout (this repo, post-bump) — expected, not a finding
! CLI version v2.2.3 does not match the installed plugin v2.2.2.
   Installed at: /Users/.../found-issues/2.2.2
   The running CLI is outside the plugin cache (dev checkout), so this is expected.
```

One subtlety the tests caught: `FI_BIN_DIR` is physical (`fi_script_dir` uses
`cd -P`) while `$HOME` is logical, so on macOS a symlinked or temp home makes a
plain prefix test misfire and hands a genuinely stale session the dev-checkout
message. The check compares against both forms.

**Deliberately NOT done:** the check is a silent no-op without a plugin
manifest (CI, non-plugin installs) or without `jq` — matching every other
jq-dependent probe in doctor. CI has no `~/.claude/plugins` on any of the three
OSes, so gating on it would have turned `cli-doctor.bats` red everywhere.

**Ledger PRs:** #138 (sync flip of the two fixed entries), #139 (two new
follow-up entries).

## Remaining work

**1. The two range follow-ups (recommended next, one PR).** Both were logged,
not fixed, to keep #137 surgical. Both citations verified against `0de14c6`.

- **`bin/found-issues:507`** — `cmd_log` still REJECTS range specs even though
  the parser, `fi_entry_loc` and `--pick` now round-trip them. The parser and
  the writer disagree about what a valid location is, so an agent that spots a
  multi-line symptom must narrow it to one line or hand-edit the ledger — and
  hand-edited entries are exactly the pre-guard shape v2.2.3 had to rescue. Not
  a regression; the guard has always behaved this way. Suggested: accept
  `^[0-9]+(-[0-9]+)?$` in cmd_log's line-spec validation to match
  `re_path_line`, rejecting only inverted ranges where end < start.

- **`bin/found-issues:1569`** — `fi_line_matched` tests only a range entry's
  START line against the diff's old-side hunks, so the PostToolUse hook's
  stricter auto-annotate rule misses an entry whose start sits outside every
  changed hunk while its body overlaps one. Fails SAFE (a missed annotation,
  never a wrong one) and `--pick` is unaffected — a reachability gap, not a
  correctness bug. Suggested: pass `line_end` through and test hunk OVERLAP
  (`start <= re && end >= rs`), falling back to the start-only test when
  `line_end` is empty.

**2. `bin/found-issues:4811` — ~4,900 lines vs the 500 signal. NOT a
`/found-issues:fix` job.** Unchanged from the previous handoff. This can only
close by extracting the `cmd_*` groups into `lib/`; the `loc-override` marker is
worded "tracked, not justified" specifically so it can't be closed by
re-wording. Its own project with its own session. Groundwork is in place:
`source-guards.bats` already scans `lib/`, so code keeps its data-loss
enforcement as it moves, and #132 restored the three-OS verification a refactor
that size needs.

## Known live hazards (verify each before relying on it)

1. **Your `found-issues` on PATH may be stale.** Claude Code injects a
   version-pinned plugin bin dir at session start, so a session started before a
   release keeps resolving the OLD version indefinitely. This session ended with
   `command -v found-issues` → `.../found-issues/2.2.2/bin` while installed was
   2.2.3. `zsh -lc` is useless as a test (it inherits the session env). Check with
   `command -v found-issues`, `FOUND_ISSUES_DEBUG_BIN=1`, or — new in v2.2.3 —
   just run `doctor`, which now says so. Use `./bin/found-issues` for anything
   that must exercise your changes.
2. **Old bin + new lib is a false negative.** Comparing old-vs-new behavior with
   `FOUND_ISSUES_LIB_DIR` pointed at the working tree runs an old binary against
   *fixed* lib code, making a real bug look absent. Use
   `git archive <ref> | tar -x -C <dir>`, or run the installed version's own
   bin+lib from its cache dir (what this session did).
3. **A handoff doc's "state snapshot" can be stale before you read it.** The
   previous handoff said "main, clean"; this session actually started on
   `docs/handoff-2026-08-11`, and `origin/main` had already moved — a peer
   session merged that handoff as #136 mid-session. Always `git fetch` and
   branch off `origin/main`, not local `main`.
4. **A peer session may hold this repo.** The claim-conflict checker reported
   session `82af3d99` on `chore/log-doctor-stale-cli-gap` at this session's
   start. Check `git status` / `git stash list` before any commit or branch op
   in a dirty tree.
5. **Windows bats takes ~20–34 min.** PR runs are ubuntu-only; macOS + Windows
   run post-merge. Do not call a change verified before the post-merge run.
   Docs-only pushes no longer cancel an in-flight matrix (#132) — re-confirmed
   live this session: #138 merged while v2.2.3's matrix was running and did not
   cancel it.
6. **PATCH bumps must not add a `### Added` CHANGELOG heading** —
   `scripts/check-version.sh` fails the PR. v2.2.3's `line_end` field was
   documented under `### Fixed` as the mechanism of a bug fix.
7. **The Stop hook requires** a `<!-- found-issues-checked: ... -->` marker on
   any turn with substantive tool use (`none-noticed` | `logged` | `deferred`).

## State snapshot (re-verify)

- Branch `main`, commit `dd34a5a`, clean tree, **0 open PRs**
- `FI_VERSION="2.2.3"`; release v2.2.3 published 2026-08-11T22:08:20Z
- **740 tests** (`bats tests/`), all passing; README line 11 carries the count
  and `docs-consistency.bats` fails if it drifts
- Ledger: **3 open, 0 critical** — `bin/found-issues:4811` (loc-validator),
  `bin/found-issues:507`, `bin/found-issues:1569`
- v2.2.3 post-merge matrix (run `31541088087`): bats ubuntu ✅ macOS ✅
  Windows ✅, `ci` ✅
- ~18 stale local branches from this and earlier sessions — `/endofday` prunes
  them; branch deletion needs an operator checkpoint

## Resume prompt (also placed on clipboard)

> Work in ~/Documents/projects/found-issues (main, clean at dd34a5a). Read
> docs/handoffs/range-locations-and-doctor-handoff-2026-08-11.md end to end,
> then re-verify per its re-verification rule before acting on anything it
> claims — in particular `git fetch && git log --oneline -6 origin/main`,
> `./bin/found-issues list --status=open` (3 expected), and `command -v
> found-issues` against hazard 1 (your shell's copy may be stale; use
> ./bin/found-issues, and note doctor now reports this itself).
>
> Then run `/found-issues:fix` scoped to the two range follow-ups only:
> bin/found-issues:507 (cmd_log still rejects range specs the parser now
> accepts) and bin/found-issues:1569 (fi_line_matched matches only a range's
> start line against diff hunks). Ship them as ONE PR — same subsystem, both
> small. Explicitly leave the bin/found-issues:4811 loc-validator entry alone —
> it needs its own session, and re-wording its loc-override marker to close it
> is not acceptable.
>
> TDD per repo convention: failing test first. Patch version bump (2.2.4)
> across bin/found-issues FI_VERSION + both plugin.json + CHANGELOG (keep it
> under ### Fixed — check-version.sh rejects ### Added on a PATCH), update
> README's test count, `bash scripts/check-version.sh`, then branch off
> origin/main → PR → `gh pr merge <N> --auto --squash`. Never push to main.
> Watch the post-merge macOS + Windows runs before calling it done.
