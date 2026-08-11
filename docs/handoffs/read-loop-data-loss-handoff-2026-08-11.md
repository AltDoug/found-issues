# Read-loop data loss + CI verification gap — Session Handoff

**Date:** 2026-08-11 · **Session:** "fix the critical read-loop data-loss entry"
**Status:** v2.2.1 and v2.2.2 shipped and verified on all three OSes. 7 PRs merged (#129–#135), 0 open. **3 open ledger entries remain**, all logged-not-fixed on purpose.
**Re-verification rule (operator's standing feedback):** do NOT act on this
doc's claims without re-verifying against the repo / live state first.
Ground truth: `git log --oneline -12` on `main`, and
`./bin/found-issues list --status=open` (NOT the statusline count, which can
lag a session).

## TL;DR for the next session

1. Read this doc, then run `./bin/found-issues list --status=open` — 3 entries expected.
2. Merged and released: **v2.2.1** (read-loop data loss) and **v2.2.2** (CI cancel gap + hook CLI visibility). Both green on ubuntu + macOS + Windows.
3. Next step: **`/found-issues:fix`** scoped to the two small entries — the range parser and the doctor check. Do NOT let it attempt the `loc-validator` entry (see Remaining work).
4. **#1 hazard:** your shell's `found-issues` is probably a STALE version. See hazard 1 — it silently cost this session two wrong conclusions.

## What was done (verify via PR descriptions / commits)

**v2.2.1 — read-loop data loss (#129).** `read` returns non-zero on a final line
with no trailing newline, so `while IFS= read -r line` never ran its body for it
and the rewrite dropped that entry. The ledger entry described 3 commands in 1
file; it was **5 commands across 2 files**:

| Command | v2.2.0 | v2.2.1 |
|---|---|---|
| `defer` · `sync` · `annotate-commit` · `promote-deferred` · `log` | 2 entries → **1** | 2 |
| `annotate --pick <last>` | "no `[open]` entry matches" | annotates it |
| `promote` listing | omits it | lists it |

Each exited 0 reporting success. `log`'s path (`fi_append_touch`) lives in
`lib/parse-entries.sh` — outside every line number in the original brief. A fix
scoped to those lines would have shipped it intact and looked complete.

Guard applied at all rewrite + scan sites. **Deliberately NOT done:** a shared
`fi_rewrite_ledger` helper — the loop bodies diverge sharply and `cmd_sync`'s
~200-line body would need restructuring, which is the highest-blast-radius
function in the file and auto-runs at SessionStart. `tests/source-guards.bats`
gets the "idiom in one place" benefit by parsing the sources instead.

**v2.2.2 — CI cancel gap + hook CLI visibility (#132).** `cancel-in-progress`
was unconditional, so a push landing on main killed the previous push's matrix;
when that push was docs-only, every job skipped and `ci` reported success — main
read green having never run bats on macOS or Windows. This *happened* during the
v2.2.1 release (#130 cancelled #129's matrix), and v2.2.1 was verified only
because the run was re-triggered by hand. Now `cancel-in-progress: ${{ github.event_name != 'push' }}`.
Also added `FOUND_ISSUES_DEBUG_BIN=1`.

**Ledger PRs:** #130, #131, #133 (sync flips + new entries), #134, #135.

## Remaining work

**1. `lib/parse-entries.sh:118` — line-range locations (do this first).**
`fi_parse_entry` accepts only `^[0-9]+$` as a line spec, so `path:23-49` parses
to `path='' line=''`. Such entries are invisible to `annotate-pr`/`annotate-commit`
(both `--pick` and auto-match need a path), so `--pick` reports "no `[open]`
entry matches" for an entry plainly in the file. `cmd_log` now rejects range
specs, so only pre-guard entries are affected — they are stranded.

Suggested fix: accept `^[0-9]+(-[0-9]+)?$` in `re_path_line`, keeping the range
verbatim in `line`. No on-disk format change.

**Free real-world fixtures:** `~/Documents/projects/orchard/docs/found-issues.md`
has 12 entries, 6 range-form (`:23-49`, `:109-110`, `:45-99`, `:1-8`,
`:353-425`, `:72-75`, `:166-180`) plus a `~/.local/bin/orchard` abstract-ish
location. **Include that `~` one** — it exercises a different parse branch, so
it guards against a range fix regressing pathless/abstract locations.

**Scoped down from the original report:** PR/commit flips on range entries are
**NOT** broken. `fi_parse_entry` emits `prs=` from the annotation tail
independently of path parsing, and `cmd_sync:2024` gates the flip on `$e_prs`,
not `$e_path`. Verified. Impact is unreachability, not data loss.

**2. `bin/found-issues:4157` — doctor's stale-CLI blind spot.** `doctor` prints
`✓ CLI: <path>` without comparing it to the installed plugin version, so it
reads healthy while the session runs a stale binary. Suggested fix: compare the
resolved `FI_VERSION` against `plugin.json` at the `installPath` in
`~/.claude/plugins/installed_plugins.json`; warn "restart your session to pick
up vX.Y.Z". Note `tests/cli-doctor.bats` asserts on doctor's output contract.

**3. `bin/found-issues:4811` — ~4,900 lines vs the 500 signal. NOT a
`/found-issues:fix` job.** This can only close by extracting the `cmd_*` groups
into `lib/`; the `loc-override` marker is worded "tracked, not justified"
specifically so it can't be closed by re-wording. Treat it as its own project
with its own session. Groundwork is in place: `source-guards.bats` already scans
`lib/`, so code keeps its data-loss enforcement as it moves, and #132 restored
the three-OS verification a refactor that size needs.

## Known live hazards (verify each before relying on it)

1. **Your `found-issues` on PATH is probably stale.** Claude Code injects a
   version-pinned plugin bin dir at session start, so a session started before a
   release keeps resolving the OLD version indefinitely — `installPath` said
   `2.2.2` while `$PATH` still had `.../found-issues/2.2.0/bin`. No shell rc is
   involved, and `zsh -lc` is useless as a test (it inherits the session env).
   Check with `FOUND_ISSUES_DEBUG_BIN=1` or `command -v found-issues`; use
   `./bin/found-issues` for anything that must exercise your changes.
2. **Old bin + new lib is a false negative.** Comparing old-vs-new behavior with
   `FOUND_ISSUES_LIB_DIR` pointed at the working tree runs an old binary against
   *fixed* lib code, making a real bug look absent. Use
   `git archive <ref> | tar -x -C <dir>` and run that tree's bin with its own lib.
   This produced two wrong "no bug here" readings this session.
3. **Merging a docs-only PR no longer cancels an in-flight matrix** (fixed in
   #132, proven live by #133) — but if you revert that, the failure is silent.
   `tests/ci-workflow.bats` guards it.
4. **Windows bats takes ~20–34 min.** PR runs are ubuntu-only; macOS + Windows
   run post-merge. Do not call a change verified before the post-merge run.
5. **The Stop hook requires** a `<!-- found-issues-checked: ... -->` marker on
   any turn with substantive tool use.

## State snapshot (re-verify)

- Branch `main`, commit `62a9a1b`, clean tree, **0 open PRs**
- `FI_VERSION="2.2.2"`; releases v2.2.1 and v2.2.2 both published
- **724 tests** (`bats tests/`), all passing; README line 11 carries the count
  and `docs-consistency.bats` fails if it drifts
- Ledger: **3 open, 0 critical**
- ~12 stale local branches from this and earlier sessions — `/endofday` prunes
  them; branch deletion needs an operator checkpoint

## Resume prompt (also placed on clipboard)

> Work in ~/Documents/projects/found-issues (main, clean). Read
> docs/handoffs/read-loop-data-loss-handoff-2026-08-11.md end to end, then
> re-verify per its re-verification rule before acting on anything it claims —
> in particular run `./bin/found-issues list --status=open` and check
> `command -v found-issues` against hazard 1 (your shell's copy is likely a
> stale version; use ./bin/found-issues).
>
> Then run `/found-issues:fix` scoped to the two SMALL entries only:
> lib/parse-entries.sh:118 (line-range locations) and bin/found-issues:4157
> (doctor's stale-CLI blind spot). Do the range parser first. Explicitly leave
> the bin/found-issues:4811 loc-validator entry alone — it needs its own
> session, and re-wording its loc-override marker to close it is not acceptable.
>
> TDD per repo convention: failing test first. Use the orchard ledger fixtures
> named in the handoff, including the `~/.local/bin/orchard` location. Patch
> version bump (2.2.3) across bin/found-issues FI_VERSION + both plugin.json +
> CHANGELOG, update README's test count, `bash scripts/check-version.sh`, then
> branch → PR → `gh pr merge <N> --auto --squash`. Never push to main. Watch the
> post-merge macOS + Windows runs before calling it done.
