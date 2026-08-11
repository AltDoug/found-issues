# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.2.3] - 2026-08-11

### Fixed

- **Entries whose location is a line range were unreachable by every annotate
  path.** `fi_parse_entry` accepted only `^[0-9]+$` as a line spec, so
  `path:23-49` matched neither location regex and parsed to `path='' line=''`.
  `fi_entry_loc` returns 1 on an empty path, so such entries never entered the
  `--pick` candidate list: `--pick` reported "no `[open]` entry matches" for an
  entry plainly present in the file, reading as user error rather than a parser
  limit. `log` rejects range specs, so the stranded entries are ones written
  before that guard, by hand, or by another repo's ledger — the orchard ledger
  is 6-of-11 range-form, and v2.2.2 parsed 0 of its 7 range entries.

  PR and commit flips were **not** affected: `fi_parse_entry` emits `prs=` from
  the annotation tail independently of path parsing, and sync gates the flip on
  `$e_prs` rather than `$e_path`. The impact was unreachability, not data loss.

  `line` stays a NUMBER — the range start — with the end in a new `line_end`
  field, rather than holding `23-49` verbatim. Three consumers evaluate that
  field arithmetically (the `10#` coercion in `fi_entry_to_json`, sync's
  tombstone `-lt` probe, and `fi_line_matched`'s `(( ))`), and bash silently
  evaluates `"23-49"` as the subtraction **-26** — a verbatim range would have
  emitted `"line":-26` in `--json` and exited 0. Splitting the field leaves all
  three sites correct untouched, and a location-reconstruction site that forgets
  to rejoin degrades to "no match" (the visible failure that already existed)
  instead of a silently wrong number.

  `--json` gains a `"line_end"` key, `null` for single-line entries. `"line"` is
  unchanged for every existing consumer.

- **`doctor` reported a healthy CLI while the session ran a stale binary.** It
  printed a bare `CLI: <path>` without comparing it to the *installed* plugin
  version. Claude Code injects a version-pinned plugin bin dir at session start,
  so a session started before a release keeps resolving the old version for its
  entire life (`installPath` said 2.2.2 while `$PATH` still had
  `.../found-issues/2.2.0/bin`). Two concurrent sessions ran 2.2.0 for hours
  after v2.2.1 shipped the read-loop data-loss fix, including 2.2.0's
  SessionStart auto-sync — doctor would have called that healthy, and it is the
  one command whose whole job is catching this class. The version directories
  accumulate rather than prune, which is why a stale path resolves quietly
  instead of failing loudly.

  The advice is direction-aware: a cache-resident CLI on the wrong version is
  told to restart the session, while a dev checkout — legitimately ahead of the
  installed plugin — is told it is outside the plugin cache. Silent no-op when
  there is no plugin manifest (CI, non-plugin installs) or no `jq`.

## [2.2.2] - 2026-08-11

### Fixed

- **A push landing on main could silently void the previous push's multi-OS
  verification.** `cancel-in-progress` was unconditional, so a commit landing
  while an earlier commit's matrix was still running cancelled it. The cancelled
  run's `ci` correctly reports failure, but the *newer* run owns the branch
  head's status — and when that newer push is docs-only, the path filter skips
  every job and `ci` reports success. Main then reads green having never run
  bats on macOS or Windows.

  Hit during the v2.2.1 release: a one-line ledger flip (#130) merged two
  minutes after the fix (#129) and cancelled its matrix mid-run. v2.2.1 was
  verified only because the run was re-triggered by hand.

  Push events no longer cancel; pull-request events still do, which is where
  fix-up commits arrive in quick succession and stale results are pure waste.
  This restores the quality floor the OS-matrix comment already promised: every
  commit that lands runs all three OSes.

  Fixing it at the aggregator instead was considered and rejected — `ci` already
  treats `cancelled` as blocking, so it was never the defect, and failing it on
  *skipped* bats would break the legitimate docs-only skip the path filter
  exists to provide. `tests/ci-workflow.bats` now guards both properties.

- **The SessionStart hook gave no way to tell which CLI it ran.** `FI_BIN`
  resolves to a `found-issues` on PATH — the *installed* plugin — before the
  co-located `FI_BIN_DIR` binary, so running the hook from a source checkout
  silently exercises the installed version: a local change looks like it had no
  effect, and a bug just fixed looks unfixed. This produced two false "no bug
  here" readings while investigating v2.2.1.

  `FOUND_ISSUES_DEBUG_BIN=1` now prints the resolved path to stderr. Resolution
  order is deliberately unchanged (PATH-first is correct for installed users);
  the override remains `FOUND_ISSUES_BIN`.

## [2.2.1] - 2026-08-11

### Fixed

- **Five shipped commands silently dropped the ledger's last entry when the
  file lacked a trailing newline.** `read` returns non-zero on a final partial
  line, so `while IFS= read -r line` never runs its body for it and the rewrite
  loses that entry. Verified by driving v2.2.0: a 2-entry ledger became 1 after
  `defer`, after `sync`, after `annotate-commit`, after `promote-deferred`
  (through `fi_promote_entry_to_open`), and after `log` (see the next entry).
  Each reported success — `defer` printed `Deferred 1 entry.` and exited 0.

  `sync` was the worst case — `SessionStart` runs it automatically, so the loss
  happened with no user action and no output saying anything was removed.
  Hand-edited ledgers and some editors produce exactly this file shape.

  All ledger-rewriting loops now carry the `|| [[ -n "$line" ]]` guard that
  `resolve` shipped with in v2.2.0 (`defer`, `sync`, `promote-deferred`, and
  both annotation rewrites).

- **`log` dropped the last entry when it touched a `[deferred]` entry.** The
  same defect in `fi_append_touch` (`lib/parse-entries.sh`), reached when a
  `log` call matches a deferred entry's dedup key and appends to its
  `(touched: ...)` annotation. Found by extending the sweep past
  `bin/found-issues` — a CLI-only fix would have shipped this one intact.
  `fi_increment_defer_cycle` is guarded alongside it: today it is safe only
  because `cmd_defer`'s own guarded rewrite normalizes the file first, and
  depending on a caller's side effect is not a safety property.

- **`annotate --pick` and `promote`'s listing missed a final entry with no
  trailing newline.** These loops scan rather than rewrite, so no data was lost,
  but the same input shape made the last entry unpickable (`--pick` reported "no
  `[open]` entry matches" for an entry plainly present) and omitted it from
  `promote`'s branch-only listing. Guarded alongside the rewrites, so a pick
  cannot select an entry the rewrite would then drop.

- **The guard is now enforced at author time, not just tested per command.**
  `tests/source-guards.bats` parses `bin/found-issues`, `lib/`, `hooks/` and
  `scripts/`, and fails CI with the `file:line` of any file-fed read loop
  missing the guard. Here-strings are exempt unconditionally (bash appends a
  trailing newline); process substitution is exempt only for producers known to
  emit newline-terminated output — today just `fi_entries`, which is awk. It is
  not safe in general: `< <(cat "$file")` hands a missing trailing newline
  straight through, so the check still requires a guard there. The rationale
  now lives in one place (the
  `READ-LOOP GUARD` note at the top of the CLI) instead of being restated per
  site.

  Scanning `lib/` is deliberate, not incidental: the scheduled extraction of
  the `cmd_*` groups out of `bin/found-issues` would otherwise move code out of
  the check's scope as it moved.

## [2.2.0] - 2026-08-11

### Added

- **`found-issues resolve <match> [--verified ai|human]`** — the serialized
  `[open]` → `[fixed]` flip, appending `(verified: ...) (fixed: <today>)`.
  This is what `/found-issues:sync` Phase 2 now calls. Match semantics and exit
  codes mirror `defer`: `1` no match, `2` usage or ambiguous (candidates are
  printed), `3` already `[fixed]`, `4` the entry carries an active `(PR: ...)`
  and is in-flight work that `sync` will close on merge.

  `resolve`'s rewrite loop is guarded with `|| [[ -n "$line" ]]`, so a ledger
  whose final line lacks a trailing newline keeps that entry. The shipped
  `defer`, `sync` and `annotate-commit` rewrites are **not** guarded and do
  drop it — verified by probe, and logged as a critical entry in
  `docs/found-issues.md` rather than fixed here, since it is a pre-existing
  repo-wide pattern across ~10 read loops.

- **`found-issues promote --apply --from <branch>`** — the transactional import
  path for `/found-issues:promote`. Run on the target branch (freshly cut from
  the default branch), it reads the source branch's ledger with `git show` and
  appends its `[open]` entries **verbatim**. Verbatim matters: re-logging with
  `log` would stamp today's date, resetting entry age and corrupting the
  stale-entry counts that drive the statusline and the sync nudges. Idempotent,
  and `[fixed]` / `[deferred]` entries are deliberately left behind.

### Fixed

- **The shipped command docs no longer instruct agents to hand-edit the ledger.**
  `commands/sync.md` Phase 2 step 4 told the agent to "edit the file: change
  `[open]` → `[fixed]` and append `(verified: ai) (fixed: YYYY-MM-DD)`", and
  shipped `Edit` in its `allowed-tools`. `commands/promote.md` step 5 told it to
  "append the entries to `docs/found-issues.md` (use `Edit` or `Write`)". Both
  are exactly the unserialized direct write the CLI exists to prevent: lost
  writes under concurrent sessions, format drift, guard bypass. Agents following
  the shipped docs were doing the wrong thing by the book. Both now call the CLI,
  and `Edit` / `Write` are dropped from both `allowed-tools` lists. Reported in
  #124.

## [2.1.3] - 2026-08-11

### Fixed

- **Legacy `Repo:path[:line]` locations are selectable again.** Ledger entries
  whose location uses the multi-repo colon shape
  (`LendMatrix-svc:src/services/foo.ts:42`, `LendMatrix-svc:node_modules/dotenv`)
  parsed with an *empty* path, because the location charsets exclude `:`.
  `fi_entry_loc` rejects an empty path, so these entries never entered the
  `--pick` candidate list and could not be closed through `annotate-pr` /
  `annotate-commit` at all — the only workaround was editing the ledger by
  hand, which the command-only discipline forbids. `log` writes the shape
  verbatim, so the CLI produced entries it could not then select. The parser
  now accepts the shape, splitting a trailing all-numeric segment off the last
  colon as the line number.

  The repo prefix stays *inside* the parsed path deliberately. Exposing the
  bare sub-path would make it look repo-relative to every caller that resolves
  paths against this repo. Two such callers are now explicitly guarded: `sync`
  skips the tombstone probe for any `:`-bearing path, since a repo-prefixed
  path can never resolve here and probing it would have made this the fifth
  member of the `~`/`$VAR`, glob, directory and whitespace false-closure
  family; and auto-annotate skips them too, because its comparison uses glob
  suffix tolerance, so a local `services/foo.ts` would otherwise match
  `LendMatrix-svc:src/services/foo.ts` and false-flip a foreign-repo entry on
  merge while wearing a plausible-looking annotation. Explicit `--pick` still
  selects them by exact location, which is the point of the fix.

  Abstract topic locations such as `topic:with:colons` are unaffected: the new
  branch only engages when the text after the first colon looks path-ish
  (contains `/` or `.`), the same heuristic the tombstone probe already uses.

  Reported in #123.

## [2.1.2] - 2026-07-31

### Fixed

- **Sync no longer tombstones entries whose path contains spaces.**
  `fi_parse_entry` takes the first whitespace-delimited token as the path — it
  has to, since the location field also carries `path symbol ~1982-1989`
  forms — so an entry citing a file whose name contains spaces
  (`docs/handoff/HO production env setup.md:88`) silently became a different,
  non-existent path (`docs/handoff/HO`) and was false-closed on every sync
  pass, *even though the cited file was present*. `log` creates such entries
  itself (the `*/*` location branch takes the value verbatim), so no
  hand-editing was needed to hit it. Reproduced live in a consumer ledger,
  where it closed a critical credential-exposure entry whose credential was
  still unrotated — caught only because that flip happened to sit uncommitted
  and was inspected before a reset. The tombstone probe now recovers the
  untruncated location from the raw entry line and re-probes before declaring
  a closure; the parser is deliberately unchanged, so dedup keys and
  `path symbol ~range` forms behave exactly as before. Fourth member of the
  same family as the `~`/`$VAR`, glob-token and directory guards.

## [2.1.1] - 2026-07-27

### Fixed

- **Sync no longer tombstones entries whose path is an existing
  directory.** The tombstone probe used `[[ ! -f ]]`, so an entry citing a
  directory (`.git/worktrees`, `src/utils`) read as "file missing" and was
  false-closed on every sync pass — reproduced live in a consumer ledger:
  a fresh directory-path entry flipped twice within minutes of landing,
  each hand-repair lost to the next pass. The probe is now `[[ ! -e ]]`,
  and the line-past-EOF check only runs for regular files (a directory
  cited with a line number is never line-probed).

## [2.1.0] - 2026-07-24

### Added

- **`annotate-pr` accepts cross-repo refs: `annotate-pr org/repo#N`.** An
  entry fixed by a PR in a different repo (e.g. an upstream plugin fix for
  a consumer-ledger entry) was un-annotatable — the CLI accepted only a
  numeric PR and resolved `org/repo` from the CWD repo — even though sync
  fully supports reading `org/repo#N` refs. Cross-repo refs require
  `--pick`: file-level auto-matching compares the PR's touched files
  against this repo's entry paths, which is meaningless when the PR lives
  in another repo's tree. Verification runs `gh pr view N --repo org/repo`.

## [2.0.2] - 2026-07-24

Two silence fixes in `status`, both hit live in a consumer session right
after a ledger was cleaned to zero open (silence read as a broken CLI).

### Fixed

- **`status --format=plain` printed nothing when a ledger exists with zero
  open entries.** It now prints `0 open` so a clean ledger is
  distinguishable from a failed invocation. The two neighboring contracts
  are unchanged and now pinned by tests: no-ledger plain stays silent
  (scripted use against repos that never adopted a ledger), and segment
  stays empty at zero (statusline quiet-at-zero).
- **`status --help` printed nothing and exited 0.** The flag fell into the
  status arg-loop's catch-all `shift`, leaving the default segment format
  to render — empty at zero open. `-h`/`--help` now print the usage text.

## [2.0.1] - 2026-07-20

Two false-flip fixes, both reproduced live in a consumer ledger the day
v2.0.0 shipped (four false closures of one entry in a single day).

### Fixed

- **Sync tombstoned `~`- and `$VAR`-prefixed locations on every run.** The
  tombstone probe guarded absolute (`/…`) and glob paths but not
  home-relative or env-var forms, so entries citing machine state outside
  the repo (`~/.claude.json`, `$HOME/.config/…`) were probed as
  repo-relative literals, always missed, and were closed as
  `(closure: tombstone)` at every sync — including the post-bash
  dispatcher's auto-sync, which re-closed hand-repairs within seconds.
  Such locations are now never filesystem-probed.
- **Annotation tokens quoted inside symptom text drove flips.** PR/commit
  annotations were extracted from the whole entry line, so a symptom that
  narrated another fix ("earlier repair shipped as `(commit: abc1234)`
  but…") flipped THIS entry when that artifact landed. Flip-driving
  annotations (`PR`, `PR-closed`, `commit`, `commit-stale`) are now read
  only from the entry's trailing annotation run (`fi_annotation_tail`);
  mid-symptom mentions are narrative.

## [2.0.0] - 2026-07-20

Dual-harness release: found-issues now installs into OpenAI Codex as well
as Claude Code, sharing one ledger, one CLI, and one hook set across
both. Paired with a usage diet on the Claude Code side (compressed rules
skill, capped session injection, hook-driven auto-annotation) that cuts
per-turn token overhead without losing enforcement.

### BREAKING

- **Three PostToolUse hooks merged into one dispatcher.** `hooks/post-pr-create.sh`,
  `hooks/post-git-commit.sh`, and `hooks/post-pr-state.sh` are removed.
  `hooks/post-bash-dispatch.sh` is now the plugin's only PostToolUse(Bash)
  hook and routes internally (PR-create annotate, commit annotate,
  merge/close/reopen background sync) — `hooks/hooks.json` registers 5
  hooks instead of 7. Anything referencing the old hook script paths
  directly needs to update; `FOUND_ISSUES_POST_PR_STATE` keeps its
  existing meaning as a route-scoped opt-out on the merged hook.
- **`annotate-pr` / `annotate-commit` exit 3 on ambiguous candidate lists**
  (previously exit 0). When a file-level match is ambiguous, the CLI
  prints the candidate list and a `--pick`/`--all` suggestion instead of
  annotating, and now signals that with exit 3 rather than a false
  success. Scripts or CI checking these subcommands' exit codes must
  treat 3 as "needs a `--pick`/`--all` re-run," not success.
- **Hook-driven auto-annotation is on by default.** The post-bash
  dispatcher now writes `(PR: org/repo#N)` / `(commit: <sha>)` directly
  for line-matched entries after `gh pr create` / `git commit`, instead
  of only prompting Claude to run the annotate command. Set
  `FOUND_ISSUES_AUTO_ANNOTATE=off` to restore the pre-2.0 prompt-only
  behavior verbatim (moved into the hook as a legacy fallback path).

### Added

- **Codex plugin support.** found-issues installs into OpenAI Codex
  alongside Claude Code, sharing one ledger, one CLI, and one hook set.
  - **Skills.** `codex-skills/fi-<name>/SKILL.md` — one generated skill
    per `commands/*.md`, produced by `scripts/gen-codex-skills.sh` (Claude
    slash syntax like `/found-issues:log` rewritten to Codex's `$fi-log`
    `$`-mention sigil) and kept in sync by `tests/codex-skills-drift.bats`.
    `.codex-plugin/plugin.json` is the Codex manifest (mirrors the Claude
    one; points `skills` at `./codex-skills`).
  - **Hooks install via `found-issues install-codex-hooks`.** Codex 0.144.5
    removed `plugin_hooks`, so the manifest's `hooks` pointer is inert on
    Codex — hooks are instead merged into Codex's user-level
    `$CODEX_HOME/hooks.json` by `install-codex-hooks` (and removed by
    `uninstall-codex-hooks`, which touches only found-issues' own entries).
    Each installed hook command is prefixed `env FOUND_ISSUES_HARNESS=codex`
    so it self-identifies without relying on `PLUGIN_DATA`.
  - **Harness adapter.** `lib/harness.sh` detects the running harness
    (`FOUND_ISSUES_HARNESS` override, else `CLAUDE_CODE_ENTRYPOINT` vs
    `PLUGIN_DATA`) and formats hook output for it: plain stdout on Claude
    Code (legacy contract), and the **`hookSpecificOutput` envelope** on
    Codex — `{hookSpecificOutput: {hookEventName, additionalContext}}` with
    `hookEventName` set to `PostToolUse` or `SessionStart` — the shape
    Codex 0.144.5's hook-output JSON Schema requires (a flat
    `{additionalContext}` is dropped). `hooks/session-start.sh` injects the
    rules-skill body into Codex context (Codex has no auto-loaded-skill
    mechanism), rewritten through the same `lib/codex-rewrite.sh` the skill
    generator uses, plus the same `[open]`-entry injection Claude Code gets.
  - **Env vars.** `FOUND_ISSUES_HARNESS` (`claude`|`codex`) forces the
    harness; `FOUND_ISSUES_CODEX_HOME` overrides the `$CODEX_HOME` default
    (`$HOME/.codex`) that the install/uninstall commands target.
- `--hook-auto` flag on `annotate-pr` / `annotate-commit`: a stricter
  auto-annotation mode used by the post-bash dispatcher — only annotates
  entries whose cited line falls inside the PR/commit diff's changed
  ranges, and only when unambiguous.
- New env vars: `FOUND_ISSUES_AUTO_ANNOTATE` (default `on`; `off` reverts
  to legacy prompt-only), `FOUND_ISSUES_AUTO_ANNOTATE_MAX` (default `3`;
  mass-touch guard — a sweep PR/commit line-matching more than this many
  entries auto-annotates none of them and surfaces all as candidates),
  `FOUND_ISSUES_SESSION_INJECT_MAX` (default `15`; caps how many `[open]`
  entries SessionStart injects into context — criticals always injected
  in full, newest non-criticals fill the rest, the remainder summarizes
  as a count line).

### Changed

- `skills/rules/SKILL.md` compressed from ~8.6KB to ~3.7KB — the
  always-on injection budget that ships on every session on both
  harnesses. Same rules content, denser prose.
- Docs caught up with the dispatcher consolidation: `docs/architecture.md`
  and `docs/configuration.md` now describe 5 registered hooks (not the
  stale 7/8) with `post-bash-dispatch`'s internal routes spelled out, plus
  a new "Harness adapters" section in `architecture.md` and a
  harness-agnostic note in `docs/modes.md`. `commands/doctor.md`'s
  dangling `/found-issues:doctor-statusline` reference now points at the
  real `found-issues doctor-statusline` CLI command. `docs/faq.md` gets a
  shared-ledger entry and drops the "Codex isn't supported" answer.
  `README.md` and `AGENTS.md` document the Codex install path.

## [1.7.1] - 2026-07-10

### Fixed

- `install-statusline --target` (bash): the segment block now lands AFTER
  the host script's stdin-capture line (`var=$(cat)`) and references the
  host's actual variable name — previously it was always inserted at the
  preamble, so `${input:-}` was empty at execution time and cwd resolution
  silently degraded to the `CLAUDE_PROJECT_DIR` fallback (the v1.5.6
  env-first bug, reintroduced for custom bash targets). Scripts that emit
  output before reading stdin keep the old placement.
- `doctor` runtime probe: cwd JSON-escaping now uses the shared
  `fi_json_escape` (tab/CR coverage) instead of a diverged inline copy.
- `help`: the `log` entry no longer advertises the opt-in `/fi` alias
  unconditionally.

### Changed

- `commands/fix.md`: commit granularity clarified (one commit per entry,
  or per file-group when entries share files).

## [1.7.0] - 2026-07-10

### Added

- `/found-issues:fix` command: works through `[open]` entries with a
  verify → triage → gate → fix → ship procedure. Re-verifies every entry
  against current code, buckets them (already-fixed / auto-fixable /
  needs-decision / not-code-fixable), gates on approval (`--auto` runs the
  auto-fixable bucket without the gate), fixes on a dedicated branch with
  one commit per entry, and ships a PR annotated via `annotate-pr --pick`
  (never `--all`). Deferred entries are surfaced ("worth un-deferring?")
  but never fixed. The final report is a fixed scannable format:
  scoreboard line + per-fix Before/After snippets + one-line evidence.
- `found-issues list [--status=open|deferred|fixed|all] [--json]`
  subcommand: conflict-aware entry listing (default: open). `--json`
  emits structured entries (`line_no`, path, line, symptom, suggested,
  annotations, `mute_until`, raw) with no new dependencies — JSON is
  hand-rolled, bash 3.2 safe.
- Parse layer: `fi_json_escape` / `fi_json_str` / `fi_entry_to_json`
  helpers and an optional numbered mode on `fi_entries` (the 2-arg form
  is byte-identical, statusline contract untouched).

## [1.6.0] - 2026-07-09

Zero-open-issues release: closes all 23 `[open]` entries from the 2026-07-09 audit of `docs/found-issues.md` — counter correctness, sync/annotate integrity, hook coverage gaps, CI filter holes, and doc-vs-code drift.

### Added
- `annotate-pr --pick <path:line>[,<path:line>...]` — annotate exactly the selected entries by location token, independent of file-level matching (a fix can land in a different file than the symptom; the picks apply even when the PR file-list fetch fails). Unknown picks are reported, never silently dropped. A pick matching SEVERAL co-located entries (same path:line, different symptoms) is refused with the collision listed — the extended form `--pick "<path:line> — <symptom fragment>"` selects between them (extended picks are never comma-split, which also covers comma-containing paths).
- `annotate-pr --all` — explicitly annotate every file-level match, for PRs that genuinely address every candidate (e.g. a release PR sweeping all open entries).
- `annotate-commit` gets the same selection machinery (`--pick`/`--all`, extended picks) — both commands now run one shared annotate engine, so the ambiguity guard cannot drift between them.

### Changed
- `annotate-pr` / `annotate-commit` no longer auto-annotate ambiguous matches. File-level matching alone over-annotates: a PR touching a hot file tagged every `[open]` entry citing that file, and sync then false-flipped them all to `[fixed]` on merge (production hit 2026-07-09: `annotate-pr 102` tagged 12 entries, 3 actually fixed, 9 manually de-annotated). Now a candidate auto-annotates only when NONE of the touched files it matches is also matched by another `[open]` entry; contested candidates are listed with locations + symptoms for symptom-level selection via `--pick`/`--all`. Two guard details that fell out of adversarial review: an entry matching several touched files is compared against its FULL match set (first-match grouping would let two entries sharing a file partition into separate "unambiguous" groups), and entries already annotated with the same reference still count as competitors (a plain re-run after an explicit `--pick` must not auto-annotate the deliberately-excluded sibling). The slash commands instruct the invoking agent to compare symptoms against the diff before picking.
- SessionStart context injection now fences the `[open]` entries as quoted untrusted DATA (code fence + explicit "not instructions" preamble). Entries come from the committed file of a possibly-cloned repo and were interpolated verbatim next to imperative directives — an indirect prompt-injection channel for any hostile repo. The entry grammar (`fi_entries` emits only `- [...` lines) guarantees no entry can close the fence early.
- CI paths-filter: `README.md` and `AGENTS.md` no longer skip the test matrix (`tests/docs-consistency.bats` exists precisely to catch their drift), and CHANGELOG-only PRs now run `version-check` via a new `meta` filter instead of skipping the one job built to validate the CHANGELOG.
- The statusline `issues` residual is computed by exclusion (open entries that are neither critical nor in-PR) instead of `total - in_pr - critical`, which double-subtracted entries that were BOTH critical and in-PR and made plain open entries vanish from every rendered counter (verified: 1 critical+in-PR entry + 1 plain open rendered "1 critical · 1 in PR" with no residual).

### Fixed
- `fi_count_stale` no longer mis-anchors on ISO dates inside symptom text: the greedy `^- \[open\].*<date>` regex captured the LAST space-flanked date in the line, so a fresh entry mentioning an old date counted stale and a stale entry mentioning a fresh date was missed. The capture is now anchored to the status prefix, like `fi_parse_entry`.
- `fi_count_in_pr`, `fi_count_critical`, and `fi_count_stale`'s demoted-term now count via conflict-aware `fi_entries` instead of raw-file greps, which counted BOTH sides of a merge conflict (verified: critical=2/in_pr=2 while total_open=0 on a conflicted file, contradicting the documented invariant).
- `sync` tombstone line-count uses `awk 'END { print NR }'` instead of `wc -l`, which counts newline characters and undercounts files lacking a trailing newline — an entry citing the LAST line of such a file was falsely auto-flipped to `[fixed]`.
- `fi_parse_entry`'s location charset now matches what `found-issues log` accepts (`[^:[:space:]]+`): paths with characters like `+` (`src/UIView+Ext.swift:42`) previously logged fine but round-tripped with an empty path — dedup silently double-logged, annotate-pr/annotate-commit never matched, tombstone sync never fired. Glob/brace location tokens the wider charset now parses (`tests/*.bats`, `config/{dev,prod}.yml`) are pattern descriptors, not filenames — sync's tombstone check skips them explicitly, since probing them as literal paths always misses and would false-flip the entry at every SessionStart.
- `fi_repo_id` preserves dotted repo names: the `[^/.]+` capture truncated `vercel/next.js` to `vercel/next`, writing wrong slugs into `(PR: ...)` annotations so sync queried the wrong repo. Trailing slashes are stripped first, then a literal `.git` suffix, then the last two path segments are taken verbatim — so pasted-URL remotes like `https://github.com/org/repo.git/` still resolve to `org/repo` (same fix applied to the duplicated regex in `lib/detect-mode.sh`).
- Segment-autosync and `post-pr-state.sh` dispatch the background sync as argv (`"$0" sync` / `"$FI_BIN" sync`) instead of embedding the path in a `bash -c` string — an install path containing a space (e.g. Windows `C:/Users/John Doe/...`) word-split and exited 127 silently, so autosync never fired.
- `fi_find_bash_splice_point` skips `echo`/`printf`/`LINE1=` lines that already reference `__FI_SEG` — they are user placements of the segment, and the multi-branch splice appended a second `${__FI_SEG}` that rendered the counter twice on that line (found during the v1.5.7 verify pass).
- SessionStart self-heal nudge classifier caught up with `fi_statusline_state`: v1.5.6 added the `--cwd` requirement for `installed-fixed` in the CLI, but the hook's inline classifier still only grepped `__FI_DIR`, so v1.0.2–v1.5.5 cd-only canonical blocks classified as fixed and the daily nudge never fired — the v1.5.6 "existing installs migrate automatically" claim was dead for users who never manually re-ran `install-statusline`. Hook-sync regression tests pin the two classifiers together.
- SessionStart custom-target auto-migration now detects v1.5.0–v1.5.5 `--cwd`-less marker blocks (mirroring `fi_target_is_v15x_broken`) and covers bash targets (`*.sh`/`*.bash`, possible since the v1.5.7 bash rewrite path) — previously only v1.4.x POSIX-only node/python blocks self-healed at session start. The canonical `~/.claude/statusline.sh` is explicitly excluded from the target branch: the daily nudge owns it.
- `pre-branch-delete` tokenizes every simple-command segment of the Bash command instead of position-matching the whole string, closing six bypass forms: `git branch --delete NAME`, `git push --delete REMOTE NAME`, `git push REMOTE -d NAME`, multi-branch deletes (`git branch -D b1 b2` guarded only b1), deletes hidden behind an earlier git push/branch in a compound command (`git push origin main && git push origin --delete feature-x`), and value-taking flags shifting the positional slots.
- `pre-commit.sh` validates only the lines a commit ADDS (via `git diff --cached -U0`), not the whole staged file — otherwise historical entries become retroactively subject to rules they predate, and one v1.5.x-era line blocks every future commit of the file. It also ports format-enforcer rule 6: `[fixed]` lines must carry a verification token (`(PR: org/repo#N)`, `(commit: <sha>)`, `(verified: ai|review)`, or `(closure: tombstone)`) — manual `[open]`→`[fixed]` flips committed outside Claude Code previously bypassed exactly the workflow the enforcer blocks.
- Format-enforcer (and the pre-commit mirror) rule 1 strips canonical `(PR: org/repo#N)` annotations before the bare-`PR #N` check — a bare ref coexisting with a canonical annotation previously passed both hooks while staying invisible to sync and the statusline, a pattern `docs/format-spec.md` declares blocked. `[fixed]` lines are exempt from rule 1 in both hooks: they are immutable history per the spec, and a full-file Write must not be blocked by grandfathered lines that were legal when written.
- Docs caught up with the code (7 pages): `configuration.md` (7 registered hooks not 8, per-hook off-switch reality, manual `.git/hooks` pre-commit install replacing the nonexistent `install-precommit` subcommand, `FOUND_ISSUES_AUTO_MIGRATE` + `FOUND_ISSUES_BASH` documented), `architecture.md` (seven lifecycle hooks incl. `post-pr-state.sh` in table + diagram, full 17-subcommand inventory, stop-reminder smart-fire semantics), `format-spec.md` (five missing annotation forms — `(closure: tombstone)`, `(touched:)`, `(defer-cycle:)`, `(reason:)`, `(mute-until:)` — in grammar/table/regex list, stale counter documented as date-stale ∪ demoted, `[deferred]` set-by `defer` subcommand, path:line charset synced to the parser), `faq.md` (uninstall answer rewritten to the ordered two-step), `AGENTS.md` (onboarding paragraph describes the actual first-run hint + daily nudge design), `skills/rules/SKILL.md` (enforcement-scope overclaims qualified: well-formed direct writes pass the enforcer; tombstone detection is file-level only), `statusline-integration-contract.md` (label policy: residual relabels to "other" at ANY non-residual bucket, matching the code the byte-snapshots lock in).

### Internal
- 60 new regression tests (542 total): counter overlap/conflict/anchor cases, no-trailing-newline tombstones, plus-charset round-trip, glob-location tombstone immunity, dotted-repo + trailing-slash annotation, spaced-path autosync dispatch (CLI + hook), `__FI_SEG`-aware splice, the full annotate selection matrix (ambiguity, picks, extended picks, re-run-after-pick, empty-fetch picks, annotate-commit parity), session-start hook-sync classifier parity + v1.5.x migrations + injection fencing, six branch-delete bypass forms, pre-commit rule parity + retroactivity exemptions.
- The branch itself went through an adversarial multi-agent review (4 finder angles, 36 verifier agents) before merge; all 10 confirmed findings are fixed in this release.
- gh test shim: `GH_MOCK_PR_VIEW` rows expand literal `\n` so one row can mock multi-line output (multi-file PR file lists).

## [1.5.8] - 2026-07-09

### Fixed
- `archive` no longer destroys entries that are superstrings of an archived line. The active-file rewrite used `grep -F -v` without `-x`, so an archived line that was a strict prefix of a newer entry substring-matched that entry too — deleting it from the active file without writing it to the archive (unrecoverable). Prefix pairs are structurally producible: `sync` appends `(fixed: <date>)` to the original line, so an entry fixed twice (e.g. re-verified after a revert) forms exactly this shape. Whole-line matching (`-x`) scopes the removal to the archived lines themselves.
- `sync`'s tombstone check no longer probes filesystem paths outside the repo. Entry paths come from the committed `docs/found-issues.md` of whatever repo is open — attacker-controlled in any cloned repo — and were joined to the repo root verbatim, so a `../`-laden or absolute path made sync `stat` and `wc -l` arbitrary files (existence/line-count oracle) and false-tombstone the entry, with no user action needed (SessionStart auto-runs sync). Absolute paths and paths with `..` components now skip the tombstone probes entirely and the entry is left untouched.

## [1.5.7] - 2026-07-09

### Fixed
- `install-statusline --target foo.sh` now migrates bash custom targets carrying a v1.5.0–v1.5.5 `--cwd`-less marker block (strip + re-splice) instead of no-op'ing on the existing markers — closes the v1.5.6 Known gap. `fi_strip_target_markers` gained a bash case (same `#` markers and `# found-issues:seg` trailer as python; splice form is the constant `${__FI_SEG}`), and the bash handler now runs `fi_target_is_v15x_broken` like the node/python handlers. No v1.4.x branch for bash — that shim was always POSIX-correct.
- Custom-target migration no longer mutates the target before backup/dry-run handling. Previously the node/python handlers stripped the old marker block from the target file *in place* before the mode check, so (1) a default dry-run on a v1.4.x/v1.5.x target silently destroyed the existing integration with no backup, and (2) in apply mode the timestamped backup captured the already-stripped file, not the user's original — and a re-splice failure after the strip left the target with no integration and no true backup. The strip now operates on a scratch copy (`fi_strip_to_scratch`); the target is untouched until the apply-mode atomic rename, and dry-run diffs original → migrated as one change.
- Custom-target splice awk (all three handlers): a splice point on line 1 of a file with no shebang/preamble got the segment splice but never the marker block that defines it — the `(NR in splice_set)` rule fired before the block-at-top rule, so a one-line statusline referenced an undefined `__FI_SEG`/`__fiSeg`/`_fi_seg` and every re-run appended another splice instead of no-op'ing. The block-at-top rule now falls through to the splice handling.
- `fi_strip_target_markers` only touches installer-emitted splice lines (tagged with the `found-issues:seg` trailer) — previously the v1.5.x literal strips ran on every non-block line, silently deleting user-authored segment references (extra placements, emitted snippets) during migration. All three languages also strip hand-edited splice variants the exact-literal match misses (bash: unbraced `$__FI_SEG`, `${__FI_SEG:-}`; node: `${__fiSeg(<any args>)}`; python: `{_fi_seg(<any args>)}`) — a leftover python variant was worst: the re-splice inserts at the first `")` on the line, corrupting a hand-edited splice into a SyntaxError (found by the v1.5.7 verify pass).
- Node/python apply paths now guard the final atomic rename like the bash handler does — an unwritable target directory previously aborted via `set -e` with no message, leaking three temp files next to the user's statusline.

### Changed
- Bash custom targets that contain a v1.5.x marker block but no recognizable splice point (AI-fallback installs with non-standard output patterns) now exit 11 with a "file is unchanged, use the AI fallback" message instead of the previous silent exit-0 no-op. The no-op left the broken `--cwd`-less block rendering an empty segment forever; the error is actionable and the file is never modified.

### Internal
- Test suite de-time-bombed: 12 tests (5 segment-contract byte-snapshots, the solo-residual label test, the autosync label test, and 5 custom-target runtime e2e tests) hardcoded fixture entry dates that crossed the 30-day stale threshold around 2026-06-12 — the stale counter appeared, the residual label flipped from "N issue(s)" to "N other", and the whole suite went silently red on main for almost a month (no bats CI ran between PRs). Date-sensitive fixtures now use `$(date +%Y-%m-%d)`. Deliberately-old dates in stale-specific tests are untouched.
- CI: weekly scheduled run (Mondays 06:00 UTC) + `workflow_dispatch` on the test workflow, so time-dependent breakage on an idle main surfaces within a week instead of ambushing the next PR. Scheduled/manual runs bypass the paths-filter and always run the full matrix. The concurrency group includes `github.event_name` so the canary and push-to-main runs can't cancel each other; GitHub's 60-day-inactivity auto-disable of schedules is documented next to the cron.
- 11 new regression tests: bash v1.5.x migration (happy path, shebang-less line-1 splice for fresh install + migration, unbraced `$__FI_SEG`, user-authored `${__FI_SEG}` preservation, dry-run-untouched, backup-is-original) and dry-run-untouched pins for the node/python v1.4.x AND v1.5.x migration branches.

## [1.5.6] - 2026-06-09

### Fixed
- Statusline segment templates now pass an explicit `--cwd` to `status --format=segment`. The blocks `cd` into the workspace dir, but `cmd_status`'s search-root priority is `--cwd` > `$CLAUDE_PROJECT_DIR` > `$PWD` — so a `CLAUDE_PROJECT_DIR` inherited from the statusline subprocess (= where the *session* started, often `$HOME`) silently overrode the `cd`, scoped the file walk to the wrong root, and rendered an empty segment for any session launched outside a project dir even while working inside one. Real-world hit 2026-06-09: a session launched from `$HOME` working in `agent-config` (2 open entries) showed no counter; the debug log proved `CLAUDE_PROJECT_DIR=$HOME` reached the subprocess while `workspace.current_dir` pointed at the repo. Applies to all four templates: canonical inline (LINE1 splice), canonical append, Node, and Python. The `cd` is kept deliberately — the segment-autosync background `$0 sync` inherits `$PWD`, not `--cwd`.
- Custom-target bash template (`fi_generate_bash_marker_block`) now resolves the workspace from `$input` JSON `workspace.current_dir` FIRST and falls back to `$CLAUDE_PROJECT_DIR` — the previous env-first order pinned the segment to the session's start dir instead of tracking the live workspace.
- Existing installs migrate automatically: `fi_statusline_state` now requires `--cwd` in the marker block for `installed-fixed`, so v1.0.2–v1.5.5 cd-only blocks classify as `installed-broken` and `install-statusline` (re-run by SessionStart self-heal / agent-sync post-hooks) rewrites them in place. Node/Python custom targets get the same treatment via the new `fi_target_is_v15x_broken` detector wired into both target handlers and the posix state branch.

### Known gaps
- Bash *custom-target* installs (`--target foo.sh`) with a v1.5.x block are still a no-op on re-run — `fi_strip_target_markers` has no bash strip support, so there is no safe rewrite path. Tracked in `docs/found-issues.md`; canonical `~/.claude/statusline.sh` installs are unaffected (they migrate via the uninstall/reinstall path above).

### Internal
- `fi_target_is_v15x_broken <path> <language>` — marker block present, invokes `status --format=segment`, lacks `--cwd`. Supports node/python/bash detection (bash used by the canonical state machine only, per the gap above).

## [1.5.5] - 2026-05-22

### Fixed
- `stop-reminder` hook now silently skips when `CLAUDE_CODE_ENTRYPOINT` is set to anything other than `cli` — the marker-discipline requirement only makes sense for interactive Claude Code sessions where a human operator reads each response and acks via `<!-- found-issues-checked: ... -->`. Headless `claude -p` invocations (`CLAUDE_CODE_ENTRYPOINT=sdk-cli`), direct SDK use, and orchestrator-dispatched sessions have no addressee for the discipline — the dispatched model receives the "Stop blocked" stderr without context, can't satisfy a requirement it doesn't know about, and burns turns trying to fix the wrong thing. `stop_hook_active` only breaks immediate same-turn retry loops; multi-turn confusion spirals slipped past it. Real-world incident 2026-05-22: an Orchard `proposals build` dispatch stalled 23 min with 0/23 tasks complete because the dispatched Claude couldn't satisfy the marker convention. The fix is conservative — only an explicit non-`cli` value triggers the skip, so empty/missing entrypoint (test invocations, manual hook runs) keeps the original enforcement.

### Internal
- 4 new regression tests in `tests/stop-reminder.bats` cover (1) skip on `sdk-cli`, (2) enforce on `cli`, (3) enforce when unset (backward compat for tests and direct runs), (4) skip on any other non-`cli` value (future-proofs against new SDK entrypoints).

## [1.5.4] - 2026-05-21

### Fixed
- `format-enforcer` hook now blocks `[fixed]` entries that lack a verification token. The hook validated format (em-dash, lowercase status, canonical PR/commit annotation shape) but did not validate workflow — so a direct `Edit` flipping `[open]` → `[fixed]` passed silently because the resulting line was well-formed. Bypassed `skills/rules/SKILL.md` hard rule #3 ("Never mark `[fixed]` without verification"). Real-world hit on 2026-05-21: an unrelated Claude Code session flipped an entry via raw `Edit` with no `(PR:…)` / `(commit:…)` / `(verified:…)` annotation, fix uncommitted-to-remote and unverified. The hook now rejects any `[fixed]` line missing at least one of `(PR: org/repo#N)`, `(commit: <sha>)`, `(verified: ai|review)`, or `(closure: tombstone)`. Demoted forms (`(PR-closed: …)`, `(commit-stale: …)`) do NOT count — they are weak evidence per the sync spec, not verification.

### Internal
- 11 new regression tests in `tests/format-enforcer.bats` cover the verification-token check (block-without-token, block-on-Edit-transition, allow each canonical token, block demoted-only forms, mode-tier silencing).
- One existing test in `tests/format-enforcer-new-annotations.bats` updated: the `(PR-closed: ...)` "happy path" example now pairs the demoted annotation with `(verified: ai)` to reflect the canonical post-sync shape.

## [1.5.3] - 2026-05-20

### Fixed
- `pre-branch-delete` hook now short-circuits when the default branch does not track the issues file at all (tested via `git cat-file -e`). The guard's "promote entries to the default branch before deleting" contract is incoherent in that regime — there is no canonical file on main to promote into. Surfaces when a repo transitions `docs/found-issues.md` from tracked to per-developer-local (gitignored): old feature branches still carry the tracked file, and prior to this fix the hook compared the branch-tracked content to an empty main keyset and false-positive-blocked every `git branch -d / -D` against those branches. Hook now emits a one-line "promote-guard skipped" note on stderr and exits 0.
- `pre-branch-delete` hook now parses a leading `FOUND_ISSUES_PROMOTE_GUARD=off ` prefix from the command string itself. `docs/configuration.md` advertised this prefix as a one-shot bypass, but inside Claude Code the hook subprocess never inherits per-command env from the command string — the prefix only takes effect when bash runs the inner git command. The documented escape hatch now works as advertised in the Claude Code Bash-tool context.

### Internal
- Two new regression tests in `tests/pre-branch-delete.bats` cover both fixes.

## [1.5.2] - 2026-05-15

### Fixed
- `fi_parse_entry` now extracts the path from entry-location forms that include a symbol name and/or approximate line range after the path token — e.g. `bin/found-issues fi_strip_target_markers ~1982-1989 — …`. Pre-fix, the location regex required the path token to stand alone before ` — `, silently breaking `annotate-pr` / `annotate-commit` matching for affected entries (they never got auto-flipped to `[fixed]` on PR merge). Discovered 2026-05-15 while annotating PR #92 against five 2026-05-13 entries; all five required manual `sed` annotation. Fix takes the first whitespace-delimited token as the path candidate. Regression coverage added in `tests/parse-entries.bats`.

## [1.5.1] - 2026-05-15

### Fixed
- `cmd_doctor` runtime probe now JSON-escapes the synthetic-stdin `current_dir` value. Paths containing `"` or `\` no longer produce malformed stdin and false-FAIL a working integration.
- `cmd_doctor` runtime-error detection now scans **stderr only** (previously combined stderr+stdout). Legitimate statusline stdout containing keywords like `undefined` (detached HEAD with `branch=undefined`) or path tokens like `cannot-wait` no longer trigger a false FAIL.
- Node + Python statusline shims pass cwd and CLI path to `bash -c` as positional argv (`$1`, `$2`) on Windows instead of interpolating them into the command string. Paths containing `"` or `'` can no longer break the invocation. The locked `--format=segment` output bytes are unchanged.

### Internal
- `fi_strip_target_markers` no longer carries dead-code `sub()` patterns (`${__fiSeg(...)}` / `{_fi_seg(...)}` with greedy `[^)]*`) that could never match the v1.5.x splice forms. Migration path is unchanged; cleanup only.
- Added `KEEP IN SYNC` comments above the duplicated v1.4.x discriminator `awk` programs in `bin/found-issues` (`fi_target_is_v14x_broken`) and `hooks/session-start.sh`. The hook cannot source the binary without re-triggering SessionStart, so the duplication is structural — comments flag the drift risk for future maintainers.

## [1.5.0] - 2026-05-13

### Added
- `doctor` runtime probe pipeline: pipes synthetic Claude Code stdin into the real statusline, captures stdout, asserts the segment string is present. Reports OK / INCONCLUSIVE (during conflict) / FAIL with sub-probes narrowing the cause.
- `doctor-statusline-runtime` subcommand: standalone runtime probe for iterative debugging (AI agents and humans).
- Doctor now reads `~/.claude/settings.json` for custom statusline targets (`statusLine.command`) and extends static state detection to Node + Python marker formats.
- `fi_has_conflict_markers` parser helper exposing merge-conflict source-file state.
- `FOUND_ISSUES_REMINDER_VERBOSITY` env var (`full`/`terse`/`auto`) controls stop-hook message verbosity. Default `auto` shrinks the 8-line educational message to a single line once `~/.claude/found-issues/.onboarded` exists.
- SessionStart auto-migration for v1.4.x marker blocks: existing custom Node/Python statusline integrations are rewritten in place on next session start, with timestamped backup. Opt-out: `FOUND_ISSUES_AUTO_MIGRATE=off`. Symlinks are skipped.

### Fixed
- **Bug 1** (Windows breakage): The generated Node and Python shim blocks no longer use POSIX-only commands (`command -v`, `ls | sort -V | tail -1`, `process.env.HOME` / `os.environ['HOME']`). They now use `os.homedir()` / `pathlib.Path.home()`, enumerate the plugin cache via filesystem APIs, and invoke `bin/found-issues` via `bash -c` on Windows (Git Bash mediation).
- **Bug 2** (cwd-from-stdin): The shim's segment invocation is now deferred via a function (`__fiSeg(dir)` in Node, `_fi_seg(_dir)` in Python). The splice form opportunistically captures the host statusline's in-scope workspace variable (`dir` or `cwd`) before falling through to env vars. Statuslines that parse stdin (claude-hud, GSD, dotfiles-managed scripts) now get accurate counts.
- **Bug 3** (multi-branch splice): `fi_find_<lang>_splice_point` now returns all line numbers matching the highest-priority pattern. Every output branch in a conditional statusline gets the segment, not just the first.
- **Bug 4** (parser conflict-blind): `fi_entries` skips lines inside `<<<<<<< / >>>>>>>` merge-conflict regions. Statusline counts no longer inflate during a merge.

### Changed
- Marker-block internal contract: `__fiSeg` is now a function, not a value (Node). `_fi_seg` is callable with optional `_dir` (Python). Bash unchanged. Existing v1.4.0/v1.4.1 installs are auto-detected on the next `install-statusline --target`, `doctor`, or session start and offered/applied a migration with timestamped backup.
- Splice form: `${__fiSeg}` → `${__fiSeg(typeof dir!=='undefined'?dir:(typeof cwd!=='undefined'?cwd:undefined))}`. The locked `--format=segment` output bytes are **not** changed; only the internal injection point.

### Internal
- New end-to-end CI test group runs the generated shim against synthetic Claude Code stdin on Linux, macOS, and Windows. Previously CI only verified syntax (`node --check`), which let the v1.4.x Windows regression through.
- Multi-branch statusline fixtures added for all three target languages.
- ~620 new lines of code + tests across `bin/found-issues`, `lib/parse-entries.sh`, `tests/cli-doctor.bats`, `tests/cli-install-statusline-custom-target.bats`, `tests/cli-status.bats`, `tests/session-start.bats`, `tests/stop-reminder.bats`, `tests/helpers.bash`.

## [1.4.1] - 2026-05-12

### Fixed

- **`hooks/stop-reminder.sh` + `hooks/session-start.sh` — `awk: towc: multibyte conversion failure`.** All 3 `awk` invocations in the hooks/ tree now run under `LC_ALL=C` so GNU awk treats input as opaque bytes rather than calling libc's `mbrtowc()` per byte. Without this, AI-response transcripts containing em-dashes, check marks, smart quotes, or any non-ASCII UTF-8 could trip awk's multibyte state machine on certain byte boundaries — the Stop hook then surfaced the raw `towc: multibyte conversion failure` error to the model and `last_turn` extraction was empty/garbled, breaking the marker-presence check silently across many sessions. Patterns matched in these awk scripts are all ASCII, so byte-mode is semantically correct (no character-class behavior is lost). Regression test in `tests/stop-reminder.bats` forces `LC_ALL=en_US.UTF-8` and asserts no `towc` error appears in hook output.

### Internal

- `bin/found-issues` awk calls in install/uninstall flows were NOT touched in this release. They operate on internally-controlled data shapes (statusline marker blocks, user splice scripts) and have not been reported as failing. If a user surfaces a multibyte failure in those code paths, follow up with the same `LC_ALL=C` prefix per-call.

## [1.4.0] - 2026-05-12

### Added

- **Custom-statusline auto-integration.** `/found-issues:setup` now offers to splice the counter into user statuslines at non-canonical paths (`statusLine.command` in `settings.json` pointing somewhere other than `~/.claude/statusline.sh`). Supports bash/sh, Node, Python — language detected from extension + shebang. Behind a new CLI flag: `found-issues install-statusline --target <path> --language=<auto|bash|node|python> [--dry-run|--apply]`. Mirrors all canonical-install safety guarantees: timestamped backup, atomic write, idempotent re-install, pure-CLI reversible uninstall via `uninstall-statusline --target <path>`.
- **Public contract for the segment surface.** New [`docs/statusline-integration-contract.md`](docs/statusline-integration-contract.md) documents the frozen public-surface behavior of `found-issues status --format=segment`. Snapshot-tested in `tests/contract-segment.bats` (12 tests). User statusline integrations depend on this contract holding across versions; the document specifies the only-allowed evolution path (additive `--format=segment-v2`).
- **AI-mediated fallback paths** in `/found-issues:setup` for the three edge cases where deterministic splice can't proceed: splice point not found (exit 11), multiple existing splices (exit 16), markers stripped from a prior install (exit 17). `Edit` is now in setup.md's allowed-tools — scope-limited to these fallback paths.

### Internal

- New CLI subcommand functions in `bin/found-issues`: `fi_detect_target_language`, `fi_find_bash_splice_point`, `fi_find_node_splice_point`, `fi_find_python_splice_point`, `fi_generate_bash_marker_block`, `fi_generate_node_marker_block`, `fi_generate_python_marker_block`, `cmd_install_statusline_custom_target` (+ per-language handlers), `cmd_uninstall_statusline_custom_target`.
- New test files: `tests/cli-install-statusline-custom-target.bats` (27 tests), `tests/setup-custom-statusline-flow.bats` (6 tests).
- macOS awk compatibility workaround: marker blocks are written to a temp file and read via `getline` inside the per-language awk scripts (the simpler `-v block="$(...)"` form fails on BSD awk with multi-line values). Template-literal and f-string injections use manual `substr`/`index` splicing instead of `sub` with `\1` backreferences (also unsupported on BSD awk).
- `.gitignore` adds `tmp/` to protect against ad-hoc test debugging that bypasses bats's `fi_setup_tmp` isolation.

## [1.3.0] — 2026-05-12

### Added — mid-session statusline freshness

Pre-1.3, the `in PR` counter in the statusline only flipped when sync ran — and sync only ran at SessionStart. Users monitoring their own PRs from a long-running Claude Code session would merge a PR, see the count stay stuck, and assume something was broken. The workaround was to start a new session, which is heavy. v1.3.0 closes the loop with two complementary auto-refresh paths.

- **`hooks/post-pr-state.sh`** — new PostToolUse Bash hook. Fires when Claude (or the user via `!`) runs `gh pr merge`, `gh pr close`, or `gh pr reopen`. The hook spawns `found-issues sync` in a detached subshell; the user's session is never blocked on the gh network calls. Next statusline render — typically within a second of the merge command exiting — shows the new count. Catches the high-frequency case of self-initiated PR state changes inside the session.

- **Segment auto-sync in `found-issues status --format=segment`.** The statusline command itself opportunistically refreshes the on-disk file in the background. Throttled by `~/.cache/found-issues/segment-autosync-ts` (default 10 min — tunable via `FOUND_ISSUES_SEGMENT_AUTOSYNC_INTERVAL`). Catches external state changes that the PostToolUse hook can't see — teammate merges your PR on GitHub web, you merge from another terminal, etc. The timestamp is touched *before* the background sync spawns so concurrent renders in parallel sessions don't double-spawn.

Both paths are fire-and-forget — zero AI latency, no foreground network I/O during a turn. Together they give "feels live" statusline behavior without the cost of an actual long-running daemon or per-turn sync.

### Added — env-var tunables

- `FOUND_ISSUES_POST_PR_STATE=off` — disable the PostToolUse hook entirely
- `FOUND_ISSUES_SEGMENT_AUTOSYNC=off` — disable segment auto-sync entirely
- `FOUND_ISSUES_SEGMENT_AUTOSYNC_INTERVAL=<seconds>` — override the throttle window (default 600)
- `FOUND_ISSUES_AUTOSYNC_CMD` — internal/testing knob: overrides the dispatched sync command. Lets bats tests substitute a marker-writer without invoking real `gh pr view` calls.
- `FOUND_ISSUES_CACHE_DIR` — internal: override the cache root for the autosync timestamp (used by tests for isolation; in production defaults to `~/.cache/found-issues`).

All documented in [`docs/configuration.md`](docs/configuration.md).

### Tests

`tests/post-pr-state.bats` (10 cases): match/no-match logic for `gh pr merge|close|reopen`, command-chain matching (`&& gh pr merge`), false-positive avoidance (`mergeable` substring), opt-out behavior, non-Bash tool ignore.

`tests/cli-status-autosync.bats` (7 cases): trigger on first render, skip within throttle, re-trigger after interval, opt-out, format gating (segment only, not plain/json), output preservation, no-op when issues file is missing.

Full suite: **360/360** passing.

### Reference

- PR: [#86](https://github.com/AltDoug/found-issues/pull/86)
- Background: triggered by the v1.2.1/v1.2.2 release dogfood — counter stayed at "2 in PR" through both PR merges until the operator manually ran `/found-issues:sync`. Confirmed the design hole and motivated this release.

## [1.2.2] — 2026-05-12

### Fixed — annotate-pr / annotate-commit silent path mismatch

`fi_parse_entry` in `lib/parse-entries.sh` used a greedy `sed -E 's/^.*[0-9]{4}-[0-9]{2}-[0-9]{2} //'` to skip past an entry's leading date and isolate the location field. When the symptom text contained *additional* ISO dates — very common in forensic timelines like "regressed on 2026-04-30" / "surfaced 2026-05-10" — `.*` ate past the entry-date and stripped into the symptom. The parsed `path=` field came back empty.

Anything downstream that matched on `path=` silently failed. Most visibly: `found-issues annotate-pr <N>` and `found-issues annotate-commit <sha>` reported `"no [open] entries match"` even when the PR / commit clearly touched the entry's file. Discovered while annotating #83 against the stop-hook entry, whose symptom contained two dates — had to fall back to manual annotation.

Fix anchors the strip to the actual entry-prefix pattern instead of `.*`:

```diff
-sed -E 's/^.*[0-9]{4}-[0-9]{2}-[0-9]{2} //'
+sed -E 's/^- \[(open|deferred|fixed)\]( \[!\])? [0-9]{4}-[0-9]{2}-[0-9]{2} //'
```

Only the leading entry-date can match — extra dates in the symptom are preserved verbatim. Two new bats regressions in `tests/parse-entries.bats` cover the path-only and `path:line` shapes against a multi-date symptom.

### Reference

- PR: [#84](https://github.com/AltDoug/found-issues/pull/84)
- Surfaced by: trying to run `/found-issues:annotate-pr 83` against the stop-hook entry while shipping v1.2.1.

## [1.2.1] — 2026-05-12

### Fixed — Stop hook actually enforces the marker again

The plugin's central discipline-enforcer — the Stop hook that nudges Claude to acknowledge `docs/found-issues.md` at the end of every code-modifying turn — has been a silent no-op since the v0.1.2 smart-fire patch (2026-05-08). Two compounding bugs were masking each other.

- **Smart-fire awk treated tool_result envelopes as user-message boundaries.** Real Claude Code transcripts wrap tool_result content in a top-level `"type":"user"` envelope (role:`user`, content:tool_result). The awk in `hooks/stop-reminder.sh` used `/"type":"user"/` to find the most-recent user boundary, so every tool_result reset the buffer and discarded the earlier assistant tool_use. On a normal tool-use turn (assistant tool_use → tool_result envelope → assistant final text), `last_turn` ended up containing only the closing text — no `"name":"Bash|Edit|…"` match — and smart-fire exited 0 silently. The hook fired but never reached the marker check. Fixed by adding `&& !/"tool_use_id"/` to the awk pattern; tool_result envelopes always carry `tool_use_id` on the same line, real user messages never do.

- **Marker check raced the transcript flush.** Once smart-fire was patched, the hook started blocking turns where the assistant *had* included the marker. Forensics: slicing the transcript to its byte length at the moment Stop fired (immediately after the assistant message was created) and replaying the hook against the slice returned `exit=0` correctly. The live run had returned `exit=2`. Claude Code streams tool results to the transcript as tools run but buffers the closing assistant text until end-of-turn flush; Stop fires in between, so the marker check reads stale content. Fixed by (a) honoring `stop_hook_active` to break the re-prompt loop on retry-fires (matches the convention from `~/.claude/hooks/stop-tests-pass.sh`), and (b) one 300ms retry on the marker grep to absorb the flush race.

### Tests

Four new bats cases in `tests/stop-reminder.bats` cover the realistic transcript shape (tool_result envelope present), the marker-present variant, and both `stop_hook_active` arms. Existing smart-fire and FOUND_ISSUES_STOP_REMINDER tests intact. Full suite: 341/341.

### Reference

- PR: [#83](https://github.com/AltDoug/found-issues/pull/83)
- Regression introduced by: [#18](https://github.com/AltDoug/found-issues/pull/18) (v0.1.2 smart-fire patch)
- Why it survived testing: pre-existing bats fixtures used simplified JSON without the `tool_use_id`-bearing envelope shape that real transcripts emit.

## [1.2.0] — 2026-05-11

### Added — sync self-healing

- **Auto-demote closed-without-merge PR annotations.** `(PR: org/repo#N)` on a CLOSED PR is rewritten to `(PR-closed: org/repo#N)`. Entry becomes eligible for AI verification in `/found-issues:sync` Phase 2, and stops inflating the statusline's `in PR` counter.
- **Auto-demote unresolvable commit annotations.** `(commit: <sha>)` whose SHA no longer resolves on the default branch (squash-merged, force-pushed) is rewritten to `(commit-stale: <sha>)`. Same eligibility + counter treatment as PR-closed.
- **Auto-correct file renames before tombstone closure.** When a missing file is detected, sync now checks `git log --diff-filter=R` for a rename target. If found, the entry's path is updated in-place and a `(renamed-from: ...)` annotation preserves the original path. Replaces the silent false-positive `[fixed]` flip.
- **gh-based default-branch fallback.** When `origin/HEAD` symref is unset, sync falls back to `gh repo view --json defaultBranchRef` (1h session cache) before the last-resort literal `main`. Fixes silent PR-merge misdetection on `master`/`trunk`/`develop` repos.
- **`doctor` extensions.** Now reports `gh auth status` and `origin/HEAD` symref status with remediation hints.
- **Loud warning on gh-empty.** When `gh pr view` returns empty for an annotated PR (typo, deleted, network), sync now emits an aggregated warning at the end of the run instead of silently skipping.

### Changed

- **Counter semantics.** `in PR` now counts only active `(PR: ...)` — demoted forms are excluded. `stale` now absorbs `(PR-closed: ...)` and `(commit-stale: ...)` regardless of date. Existing date-based stale logic unchanged.

### Internal

- Sync's per-PR gh calls consolidated: one `gh pr view` per PR returning `state`, `baseRefName`, `mergedAt`, `isDraft` in one shot.
- New gh-mock PATH shim (`tests/bin-shims/gh`) gives bats tests deterministic coverage of PR-state branches that were previously untested.

### Migration notes

No user action required. All annotation lifecycle work runs passively in `/found-issues:sync` (which fires on SessionStart). Existing `docs/found-issues.md` files are forward- and backward-compatible.

### Known limitations

- **Rename substitution scope.** When sync auto-corrects a renamed file's path, it uses string substitution on the entry line. If the entry's symptom text happens to contain the literal old path as a substring, that occurrence will also be rewritten. Rare in practice (symptom text is free-form English; paths are usually only in the location prefix), but worth flagging. If it bites, edit the entry by hand to restore the symptom text.

### Reference

- Gap analysis: [`docs/superpowers/audits/2026-05-11-annotation-lifecycle-gaps.md`](docs/superpowers/audits/2026-05-11-annotation-lifecycle-gaps.md)
- Design spec: [`docs/superpowers/specs/2026-05-11-sync-self-healing-design.md`](docs/superpowers/specs/2026-05-11-sync-self-healing-design.md)
- Implementation plan: [`docs/superpowers/plans/2026-05-11-sync-self-healing.md`](docs/superpowers/plans/2026-05-11-sync-self-healing.md)

## [Unreleased]

### Planned

- Demo GIF embedded in README
- Submission to official Claude Code marketplace

## [1.1.0] — 2026-05-11

### SemVer recalibration

This release is **v1.1.0 instead of v1.0.7** as a SemVer correction. Two of the four fast-follow items below add new functionality (`defer --mute-until` flag and the new `doctor` subcommand) — under strict [SemVer 2.0.0](https://semver.org/spec/v2.0.0.html) that's a MINOR bump (`1.0.x → 1.1.0`), not PATCH (`1.0.6 → 1.0.7`).

Historical note: v1.0.5 should have been v1.1.0 too — it added new subcommands (`defer`, `promote-deferred`), a new lifecycle state (`[deferred]`), and new flags. The mis-numbering was caught in v1.0.7 planning but the v1.0.5 tag is permanent. Going forward, **the new `scripts/check-version.sh` CI guard** (added in this release) blocks any PR that adds an `### Added` section under a PATCH-only bump.

See [`docs/versioning.md`](docs/versioning.md) for the rules + decision tree.

### Audit-driven fast-follows (4 PRs, all from the 2026-05-10 UX audit's "worth a v1.0.6 if time permits" list)

v1.0.6 shipped the P0 + 3 P1s. v1.1.0 picks up the four "fast-follow" items that the audit flagged as worth shipping but not blocking. Same audit doc, same priority ladder — these were P2-ish polish that the audit explicitly recommended as next-up.

### Added (surfaces 8.2 / 8.6 / 9.2 + cross-cutting #3)

- **`docs/configuration.md`** (PR #64) — canonical env-var reference. Lists every plugin-readable env var (5 hook opt-outs, 3 defer-flow tunables, stale-days, mode override, 4 internal/testing knobs) with defaults, scope, and concrete examples. README's Docs section links to it. Closes the audit's cross-cutting observation #3 ("env-var opt-outs exist but are scattered").

### Added (surface 4.4)

- **`defer --mute-until YYYY-MM-DD`** (PR #66) — new flag on `found-issues defer` that suppresses the recurrence nudge until a target date. Useful when an entry is genuinely blocked for a known period (legal review, third-party fix, post-launch window). Touches still record during the mute (history preservation); only the nudge / auto-promote logic is short-circuited. Critical `[!]` entries are muted too — if the user explicitly muted a critical entry, that's their call. `promote-deferred` strips the annotation on flip to `[open]` since it's a defer-state concept. Strict ISO format; past dates warn but defer succeeds.
- 2 new lib helpers in `lib/parse-entries.sh`: `fi_extract_mute_until`, `fi_is_muted` (lexical ISO comparison — no `date` arithmetic).

### Changed (surface 4.2)

- **Defer overshoot wording** (PR #65) — `fi_handle_deferred_touch` now distinguishes at-threshold from past-threshold cases. Pre-v1.0.7 the wording was identical; users couldn't see at a glance how far past threshold an entry had drifted.
  - At threshold (count == M): `(now Nx, threshold M)` / stdout `(at threshold)` — unchanged.
  - Past threshold (count > M): `(now Nx, K past threshold of M)` / stdout `(past threshold by K)` — new.
  - Below threshold: unchanged.
  - Audit's claim that "nudge doesn't fire on overshoot" was incorrect (the existing `>=` check already fired); this PR is the remaining wording-precision improvement.

### Added (surfaces 5.2 + 6.2)

- **`found-issues doctor`** (PR #67) — general-purpose health diagnostic. Aggregates 7 sections into one screen of output:
  1. Plugin runtime (CLI path, lib dir, onboarding marker)
  2. Statusline state (delegates to `fi_statusline_state` — same 5-state classifier as `doctor-statusline`)
  3. gh CLI auth state
  4. Mode detection + cache state + `FOUND_ISSUES_MODE` override surfacing
  5. Hook opt-outs (which of the 5 env vars are `=off`)
  6. Tunables (non-default) — only shown when any of `FOUND_ISSUES_DEFER_TOUCH_THRESHOLD` / `FOUND_ISSUES_DEFER_ESCALATION_FACTOR` / `FOUND_ISSUES_STALE_DAYS` is set
  7. Issues file (path, per-status counts, suspicious-entry flags — `[open]` with stray `(fixed: ...)`, `[fixed]` without closure-date annotation)
- Ends with a "Recommended next" list of concrete fix commands.
- Read-only; always exits 0. Locale-aware glyph fallback (UTF-8 → ✓/!/✗, ASCII → OK/!!/FAIL).
- Wrapped as `/found-issues:doctor`. README slash-commands table updated.

### Added (versioning discipline)

- **`docs/versioning.md`** — canonical SemVer rules with concrete examples drawn from this project's release history. Decision tree for "is this PATCH or MINOR or MAJOR?"
- **`scripts/check-version.sh`** — CI guard that enforces two invariants:
  1. `FI_VERSION` in `bin/found-issues` matches the top-most `[X.Y.Z]` section header in `CHANGELOG.md`.
  2. If the latest version's bump from the previous is PATCH-only (X.Y unchanged, Z incremented), the latest section must NOT contain `### Added` — additive changes require a MINOR bump.
- Wired into `.github/workflows/test.yml` as a new lint step (runs alongside `shellcheck` / `json validation` / `test name ASCII guard`). Bats tests at `tests/check-version.bats` cover the positive + negative paths.

### Tests

- 261 → 297 (+36 across PRs #65/#66/#67 fast-follows + version-check infra).

## [1.0.6] — 2026-05-11

### Audit-driven fixes (5 PRs, all from the 2026-05-10 UX audit)

The 2026-05-10 end-to-end UX audit ([`docs/superpowers/audits/2026-05-10-ux-audit.md`](docs/superpowers/audits/2026-05-10-ux-audit.md)) walked the 10 surfaces a new user touches in their first 30 minutes and surfaced one P0 + three P1s + a triage of P2/nice-to-have items. v1.0.6 ships the P0 and all three P1s; the P2/nice-to-have items are batched for v1.1+.

### Fixed (P0 — surface 8.1)

- **`hooks/pre-branch-delete.sh` matches by dedup key, not full-line equality** (PR #59). The hook was comparing branch `[open]` entries to main's content via `grep -Fxq`. After a feature branch's entry was annotated with `(PR: ...)` and merged, main's sync flipped it to `[fixed]` and appended `(fixed: YYYY-MM-DD)` — the branch's verbatim `[open]` line no longer matched the new `[fixed]` line, so the hook **hard-blocked deletion of a fully-merged feature branch**. Now compares by dedup key (path:line:symptom) across all statuses on main; promoted entries are correctly recognized regardless of status flip or appended annotations. Hit during the 2026-05-10 `fix/install-statusline-cwd` cleanup. 3 new bats regression tests.

### Fixed (P1 — surfaces 1.1 + 6.1)

- **AGENTS.md install + uninstall sections synced with README** (PR #60). AGENTS.md (the AI-facing source of truth) had drifted from README (the human-facing source of truth) on both install (4-command flow with `/reload-plugins` vs. 2-command + restart) and — more critically — uninstall (claimed `/plugin uninstall` deletes plugin-private state; it does NOT, leaving `~/.claude/found-issues`, the statusline marker block, the mode cache, and the `/fi` alias as orphans). An AI assistant helping a user uninstall would have followed AGENTS.md and created exactly the orphan state PR #50 was meant to mitigate. New `tests/docs-consistency.bats` (6 cases) fails CI on future drift between the two documents.

### Fixed (P1 — surface 3.3)

- **`fi_handle_deferred_touch` emits stdout summary in addition to stderr** (PR #61). Pre-v1.0.6 the deferred-touch path printed only to stderr — wrappers (sidecar tools, CI smoke tests, non-Claude-Code adapters) that swallow stderr saw zero feedback for an action-required event (the nudge, threshold flag, auto-promote). Now emits a single parseable stdout summary line per call (three shapes: below threshold, at threshold "consider promote-deferred", auto-promoted), followed by `cmd_status plain` for symmetry with the open-match and new-entry log paths. Existing stderr output unchanged. 3 new bats cases asserting stdout-only.

### Fixed (P1 — surfaces 2.1 + 9.1)

- **Statusline residual bucket relabels to "other" in mixed counters** (PR #62). The label `2 critical · 5 issues · 1 in PR` was unintuitive: critical is excluded from the residual `issues` count (`issues = total_open - in_pr - critical`), but users naturally tried to add them. Now relabels the residual to `other` whenever critical / in PR / stale is also showing: `2 critical · 5 other · 1 in PR`. The solo plain case (only the residual on display) keeps the natural "1 issue" / "N issues" wording — no regression for the common first-time experience. JSON wire format intentionally unchanged (`"issues": N`) for backwards compat with any external tooling. 5 new bats cases.

### Audit deliverable

- [`docs/superpowers/audits/2026-05-10-ux-audit.md`](docs/superpowers/audits/2026-05-10-ux-audit.md) (PR #58) — 373-line audit walking 10 surfaces with walked-through experience / friction observed / prioritized fixes. Canonical reference for what's coming in v1.1+.

### Tests

- 244 → 261 (+17 across the 4 fix PRs).

## [1.0.5] — 2026-05-10

### Added (defer recurrence flow — full lifecycle for [deferred] status)

- **`found-issues defer <match> [--reason "..."]` subcommand**: flips [open] → [deferred] for an entry matching `<match>`. On re-defer (entry has prior touch history from a previous defer→promote cycle), automatically increments a `(defer-cycle: N)` annotation and appends `;` to the `(touched: ...)` annotation to mark the new cycle boundary. Optional `--reason` captures a short note explaining why the entry is being deferred. Exit codes: 0 success, 1 no match, 2 ambiguous match, 3 already deferred, 4 has active `(PR: ...)` annotation (deferring an in-PR entry would silently drop it from both `issues` and `in PR` counters; blocked with two-option recovery message).
- **`found-issues promote-deferred <match>` subcommand**: inverse of defer. Flips [deferred] → [open] preserving all annotations as evidence of recurrence. Accepts positional or `--match` argument. Exit codes: 0/1/2/3 mirror defer's no-match / ambiguous / wrong-status semantics.
- **Recurrence detection in `found-issues log`**: the dedup loop now scans both [open] AND [deferred] entries. On match against [open], existing "Skipped — already logged" behavior preserved. On match against [deferred], the matched entry's `(touched: ...)` annotation is appended with today's date instead of creating a fresh [open] entry. Threshold checks fire above the per-cycle limit (default `3 * 2^(N-1)`: cycle 1 = 3 touches, cycle 2 = 6, cycle 3 = 12, ...). Non-critical entries print a stderr nudge suggesting `promote-deferred`. Critical (`[!]`) entries auto-promote inline.
- **Two new skills**: `/found-issues:defer` and `/found-issues:promote-deferred` wrap the new subcommands with prose guidance on when to use each.
- **Two env vars**: `FOUND_ISSUES_DEFER_TOUCH_THRESHOLD` (base, default 3) and `FOUND_ISSUES_DEFER_ESCALATION_FACTOR` (factor, default 2) override the threshold formula. Invalid values warn to stderr and fall back to defaults.
- **7 new lib helpers** in `lib/parse-entries.sh`: `fi_extract_touched_segment`, `fi_current_cycle_touch_count`, `fi_extract_defer_cycle`, `fi_extract_reason`, `fi_compute_threshold`, `fi_append_touch`, `fi_increment_defer_cycle`. All atomic (temp+mv pattern) for file mutations.
- **Hook acceptance**: `format-enforcer` and `pre-commit` hook regexes already accept `(touched: ...)`, `(defer-cycle: N)`, `(reason: ...)` annotations (block-on-bad-pattern, not allowlist) — confirmed by regression tests.
- **~60 new bats tests** across 4 phases. Total goes from 184 → 244. Density mirrors `cli-statusline.bats`.

### Architecture notes

- `[deferred]` is now a first-class lifecycle state with explicit transitions (`defer`, `promote-deferred`) and a passive recurrence signal (touch counter via dedup extension).
- Touch annotations use a `;` separator within `(touched: ...)` to demarcate defer-cycle boundaries. Threshold counting is per-cycle (after the last `;`), not cumulative — persistent history serves as evidence for future maintainers, not as a count toward the next nudge.
- Loop prevention: each defer→promote→re-defer cycle bumps `(defer-cycle: N)`. Each cycle's threshold doubles (configurable factor). Self-regulating — operator can keep deferring an entry they genuinely don't want to address; the plugin shuts up faster each cycle.
- Statusline counter unchanged — promotion (auto for critical, manual for non-critical) is the visibility event that bumps the existing `issues` count.

### Spec

[`docs/superpowers/specs/2026-05-10-defer-recurrence-flow-design.md`](docs/superpowers/specs/2026-05-10-defer-recurrence-flow-design.md)

## [1.0.4] — 2026-05-10

### Fixed (legacy-snippet auto-migration is now the default — completes the v1.0.3 self-heal for AI-driven setup)

- **`install-statusline` auto-migrates legacy snippets without `--migrate`.** v1.0.3 added detection + migration for pre-v0.1.7 handwritten snippets but gated it behind an explicit `--migrate` flag for safety. In practice this caused the silent-breakage symptom v1.0.3 was meant to fix: the AI-driven `/found-issues:setup` flow runs the picker without first running `doctor-statusline` (it's a prose-level pre-step), so a user with a legacy snippet picks "statusline segment", the picker invokes bare `install-statusline`, and the CLI bails with `return 1`. Claude doesn't always surface the bail. User uninstalls + reinstalls + re-runs setup — same outcome every cycle, because the legacy lines never get touched.
- **The fix:**
  - `install-statusline` (no flags) now auto-migrates `legacy-handwritten` and `legacy-and-installed` states the same way it already auto-rewrote `installed-broken` blocks. Symmetric with `cmd_uninstall`, which has always auto-stripped legacy snippets without `--migrate`.
  - **Backup safety net**: before stripping legacy lines, the CLI saves a timestamped backup at `~/.claude/statusline.sh.fi-bak-<YYYYMMDD-HHMMSS>`. If the strip heuristic ever mismatches a custom variant, recovery is one `mv` away.
  - **Loud stderr notice**: the CLI now prints a multi-line explanation of what was removed and points at the backup path before the migration runs, so users see exactly what changed.
  - **Opt-out preserved**: pass `--no-migrate` to restore v1.0.3 strict behavior (refuse to touch legacy lines, print manual recovery command). `--migrate` / `--force` stay as backwards-compatible no-ops.
  - **Doctor + SessionStart updated**: both surfaces now recommend plain `found-issues install-statusline` (no flag) as the fix for legacy state, since it's the single canonical entry point.
  - **`commands/setup.md` updated**: the "doctor pass before the picker" prose is now informational rather than required-for-correctness. Picker invokes bare `install-statusline`; AI doesn't need to branch by state or remember to pass `--migrate`.
- **Why flip the default**: the v1.0.3 reasoning was that the strip heuristic could mismatch user-edited variants. In practice, the heuristic only matches the specific 3-line operative pattern (`# ... found-issues ...` comment + `FI_SEG=$(found-issues status --format=segment ...)` line + `$FI_SEG`-using LINE1 follow-up); custom variants that diverged from the template wouldn't match. The cost of false-positive strip is low (one `mv` from the backup); the cost of preserving the opt-in barrier is silent breakage every time AI-driven setup misses the doctor-pass — exactly the failure mode this release fixes.

### Added

- **`fi_save_statusline_backup` helper** — copies `~/.claude/statusline.sh` to a timestamped sibling before destructive edits. Single-shot per migration; doesn't accumulate across repeated installs because subsequent runs hit `installed-fixed` and no-op.
- **2 new bats tests** in `tests/cli-statusline.bats`: `--no-migrate refuses legacy-handwritten` and `--no-migrate refuses legacy-and-installed` assert the strict opt-out still works. The pre-existing default-path tests for both legacy states are renamed and tightened: they now also assert the timestamped backup file exists and contains the pre-migration content. **182 tests total** (was 180).

### How existing users pick up the fix

- **Pre-v0.1.7 handwritten installs** (the cohort blocked by v1.0.3): `found-issues install-statusline` — no flag, just works. A timestamped backup is saved automatically.
- **Auto-discovery**: SessionStart nudge (still once per day) now points at the same plain command.

## [1.0.3] — 2026-05-10

### Fixed (silent-broken-statusline self-heal — completes the v1.0.2 fix for ALL pre-existing users)

- **`install-statusline` is now self-healing.** v1.0.2 fixed the cwd bug for *new* installs but left two cohorts of real users with silently-broken statusline counters: (1) public users who installed via v1.0.0/1.0.1 — they have a marker-bracketed segment that lacks `cd "$__FI_DIR"` handling; (2) early-adopter / dogfood users from pre-v0.1.7 — they have a 3-line handwritten snippet (no markers) embedded in their `~/.claude/statusline.sh` per the old setup.md template. Both cohorts see no counter even though install reported success.
- **The fix:**
  - `install-statusline` now classifies the existing state of `~/.claude/statusline.sh` (`none` / `installed-fixed` / `installed-broken` / `legacy-handwritten` / `legacy-and-installed`).
  - **`installed-broken` (v1.0.0/1.0.1 marker block missing cwd handling)**: auto-rewrites in place — no flag needed, because the markers give us deterministic block boundaries. Users just re-run `found-issues install-statusline` and it self-heals.
  - **`legacy-handwritten` (pre-v0.1.7 handwritten snippet)**: requires explicit `--migrate` flag. The CLI surgically removes the 3-line handwritten block (signature: a comment line containing `found-issues`, the `FI_SEG=$(found-issues status --format=segment ...)` invocation, and the LINE1 assembly follow-up) and inserts the canonical marker-bracketed block. Migration is opt-in because the heuristic could mismatch user-edited variants.
  - **`legacy-and-installed`**: cleans up both with `--migrate`.
- **New subcommand `doctor-statusline`**: dry-run diagnosis of the current state. Reports which of the 5 states the user's statusline is in and the recommended fix command. No file modifications.
- **SessionStart hook self-heal nudge**: detects broken/legacy statusline state at session start. If found, emits a one-time-per-day directive to Claude pointing at `found-issues doctor-statusline` and the migration command. Cost of breakage (silent broken counter) is high; cost of a one-line nudge is low.
- **`status` subcommand now accepts `--cwd PATH`** and falls back to `$CLAUDE_PROJECT_DIR` when no flag is passed. Defensive correctness for any caller that knows the workspace dir explicitly (hooks, scripts, future statusline integrations).
- **`found-issues uninstall` now also strips pre-v0.1.7 handwritten snippets** (in addition to the marker-bracketed block). Previously, dogfood-era users who ran the uninstall flow would still have the broken handwritten lines left behind in `~/.claude/statusline.sh`. Reuses the same `fi_strip_legacy_handwritten` helper that powers `install-statusline --migrate`.

### Added

- **13 new bats tests** covering: `--cwd` flag, `CLAUDE_PROJECT_DIR` fallback, all 5 classifier states via `doctor-statusline`, `--migrate` rewrites for `legacy-handwritten` / `installed-broken` / `legacy-and-installed`, idempotency after migration, true e2e proving pre-migration broken renders empty AND post-migration renders the count, and the new `uninstall` legacy-snippet cleanup. 180 tests total (was 167).

### Changed (release-channel consolidation from prior Unreleased section, no plugin code change)

- **Removed standalone marketplace at `AltDoug/found-issues`.** Deleted `.claude-plugin/marketplace.json` from this repo. The single canonical install path is now the aggregator at `AltDoug/claude-plugins`. Why: dual install paths created confusion (e.g. `/plugin marketplace add AltDoug/found-issues` would register under marketplace name `found-issues` while the aggregator registers as `altdoug-plugins`, leading to mismatches in `/plugin marketplace remove` commands). One marketplace, one install path, one canonical name.
- **README + AGENTS.md install instructions** now use `/plugin marketplace add AltDoug/claude-plugins`.
- **CI `json validation` step** no longer validates the removed marketplace.json.
- **Migration for users who installed via the standalone path**: `/plugin marketplace remove found-issues` then `/plugin marketplace add AltDoug/claude-plugins`. The plugin itself doesn't need reinstalling — same code, just a different marketplace registration.

### How existing users pick up the fix

- **v1.0.0/1.0.1 marker-bracketed installs**: `found-issues install-statusline` (no flag — auto-detects + auto-rewrites).
- **Pre-v0.1.7 handwritten installs**: `found-issues install-statusline --migrate` (explicit opt-in for surgical line removal).
- **Not sure**: `found-issues doctor-statusline` first to inspect, then run the recommended command it prints.
- **Auto-discovery**: SessionStart will nudge once per day until fixed.

## [1.0.2] — 2026-05-09

### Fixed

- **`install-statusline` segment now actually renders the count.** v1.0.1 (and every version before it) generated a segment block that called `found-issues status` from the statusline subprocess's cwd — which is **never the workspace dir**. As a result, the statusline counter silently rendered as empty for every user with a multi-line statusline that uses `git -C "$DIR"` rather than `cd` (i.e. the common pattern). The bug was discovered during a public-release dogfood run when the count didn't appear despite the segment block being correctly installed.
- v1.0.2 segment now extracts `workspace.current_dir` from the conventional `$input` JSON variable (the standard Claude Code statusline convention), and `cd`s into that directory before invoking `found-issues status`. Falls back to no-cd behavior if `$input` isn't defined or `jq` isn't available — same as v1.0.1, no regression.
- Both inline and standalone (append) forms updated. To pick up the fix, existing users must run `found-issues uninstall-statusline` then `found-issues install-statusline` (the marker-based idempotency means a fresh install would otherwise no-op).

### Added

- **2 new bats tests** in `tests/cli-statusline.bats`: (1) a structural test asserting the generated segment block contains the cwd handling (greps for `jq -r`, `.workspace.current_dir`, `cd "$__FI_DIR"`); (2) a true end-to-end test that pipes Claude-Code-style JSON input (`{"workspace":{"current_dir":"..."}}`) into the generated statusline.sh and asserts the count renders. The e2e test would have caught this bug before public release. 167 tests total (was 165).

## [1.0.1] — 2026-05-09

### Added

- **Windows support, verified by CI.** Added `windows-latest` to the bats matrix in `.github/workflows/test.yml` — runs under Git Bash. 165/165 tests pass. README now claims Linux + macOS + Windows in the new "Platform support" section. The plugin remains bash-based (`#!/usr/bin/env bash` shebang on every script); on Windows users need Git for Windows installed (Git Bash provides bash + GNU coreutils — near-universal install on Windows dev boxes). WSL also works.
- **README "How to use it day-to-day" section** surfacing the two usage patterns that weren't documented but are the actual day-to-day value: (1) plain-English queries work because `docs/found-issues.md` is auto-loaded into Claude's context every session — no slash command needed for *"what's open?"* / *"show me the critical ones"*; (2) the log can be treated as a work queue — ask an agent to triage and fix the easy ones in batch, the auto-annotate hooks + auto-flip-on-merge close the loop. Without this section, new readers saw a passive logger and missed the active-queue workflow.

### Fixed

- **`/found-issues:setup` picker now labels the statusline option as `(Recommended)`** and lists it first. Without the recommended marker, users habitually tab through the multi-select picker and skip the highest-signal integration. `commands/setup.md` previously described the install mechanics for each option but didn't specify the picker structure — the LLM was generating it ad-hoc with no recommendation cue. Now setup.md explicitly: (1) requires a single multi-select picker, (2) requires `(Recommended)` suffix on the statusline option, (3) requires statusline listed first, (4) requires omitting already-installed options from the picker, (5) requires skipping the picker entirely when both are installed.
- **Renamed `tests/cli-status.bats:49` test** from `"status: plain format uses '·' separator"` to `"status: plain format uses middle-dot separator"`. The Unicode middle dot in the test *name* (not the body) tripped bats' test-name parser on Git Bash for Windows. The body still asserts the `·` character in output — that's the actual contract being tested.

## [1.0.0] — 2026-05-09

**First stable public release.**

`found-issues` is now publicly available. The plugin spent v0.1.0–v0.1.16 in
private development being dogfooded across the author's own work; v1.0.0 is
the public-debut tag. No functional changes since v0.1.16 — same code,
same behavior, same 165-test suite. Just public-OSS hygiene + repo settings.

### Changed

- README "Status & roadmap" updated from stale `v0.1.0 / 122 tests passing` to current `v1.0.0 / 165 tests passing`.
- README slash-commands table now includes `/found-issues:archive` (was shipping since v0.1.8 but undocumented).
- CHANGELOG: added missing reference links for `[0.1.15]` and `[0.1.16]`; updated `[Unreleased]` compare link to `v1.0.0...HEAD`.
- Aggregator (`AltDoug/claude-plugins`): added a one-line note explaining the manifest-name (`altdoug-plugins`) vs repo-name (`claude-plugins`) asymmetry that confused at least one user during install/uninstall.

### Added

- `SECURITY.md` at repo root — vuln-reporting process surfaced as a GitHub Security tab.
- Aggregator now ships `CONTRIBUTING.md` explaining that plugin code lives in plugin repos; PRs against the aggregator just bump `marketplace.json`.
- GitHub repo metadata: topics (`claude-code`, `claude-code-plugin`, `ai-agents`, `issue-tracker`, `markdown`, `developer-tools`) for discoverability.
- Branch protection on `main`: PR-required + passing CI checks before merge.

### Fixed

- Removed first-name reference (`"like Diogo's"`) from the v0.1.11 CHANGELOG entry — privacy cleanup before public flip.

## [0.1.16] — 2026-05-09

### Fixed

- **`/fi` alias now installs deterministically via `found-issues install-fi-alias`.** v0.1.15 setup told the LLM to handcraft `~/.claude/commands/fi.md` from a markdown code block in `commands/setup.md`. On a real install the agent dropped `$ARGUMENTS` — `/fi log src/foo.py:42` would expand to `Run /found-issues:` with the subcommand and arguments lost. Same failure class statusline had pre-v0.1.11 (LLM editing files by hand). v0.1.16 ships dedicated CLI subcommands `install-fi-alias` / `uninstall-fi-alias` so the LLM just calls them — no more handcrafted content.

### Added

- **New CLI subcommands**: `install-fi-alias` (creates `~/.claude/commands/fi.md` with literal `$ARGUMENTS` baked in, idempotent, refuses to overwrite a user-authored `/fi` command) and `uninstall-fi-alias` (removes only if it's ours; preserves user-authored `/fi`).
- **README**: setup.png screenshot in the Installation section showing the optional-integrations picker.
- 10 new bats tests in `tests/cli-fi-alias.bats` covering install, idempotency, no-clobber, parent-dir creation, uninstall, user-authored preservation, no-op, round-trip — and explicitly: *the file contains literal `$ARGUMENTS`* (regression test for the v0.1.15 bug).

### Changed

- `commands/setup.md` Optional 3 now calls `found-issues install-fi-alias` instead of handing the LLM a markdown code block.
- `cmd_uninstall` now delegates `/fi` removal to `cmd_uninstall_fi_alias` so the "is this ours?" heuristic lives in one place — install and uninstall can't drift apart.

## [0.1.15] — 2026-05-09

### Added

- **`found-issues uninstall` cleanup command** and `/found-issues:uninstall` slash wrapper. Claude Code's `/plugin uninstall` removes the plugin itself but leaves plugin-private state behind under `~/.claude/` and `~/.cache/` (no pre/post-uninstall lifecycle hooks in the spec — see anthropics/claude-code#11240). The new command wipes only what we installed, in one go:
  - Statusline segment block in `~/.claude/statusline.sh` (preserves rest of file + executable bit, reuses `uninstall-statusline`)
  - Onboarding marker dir `~/.claude/found-issues/`
  - Mode-detection cache `~/.cache/found-issues/`
  - `/fi` alias at `~/.claude/commands/fi.md` *only if* it contains `Run /found-issues:` (won't touch a user's own `/fi` command)
  - Per-repo `docs/found-issues.md` and `docs/found-issues-archive.md` are intentionally preserved — that's user project data
- Prints `/plugin uninstall found-issues` and `/plugin marketplace remove altdoug-plugins` as next-steps (those can only run from inside Claude Code).
- 8 new bats tests in `tests/cli-uninstall.bats` covering no-op, each cleanup type individually, user's-own-`fi.md` preservation, statusline-block removal preserving rest of file + executable bit, next-steps reminder, and all-4-at-once.

### Why

User feedback during e2e uninstall+reinstall test: *"shouldnt that all be part of the uninstall? why is there left over"* — manual `rm -rf` cleanup is unacceptable UX. Plugin-side leftovers are our problem to solve.

## [0.1.14] — 2026-05-09

### Fixed

- **`install-statusline` and `uninstall-statusline` now preserve executable permission** on `~/.claude/statusline.sh`. Both commands edit via `awk > tmp; mv tmp file`, but `mktemp` creates files at mode 0600 (no execute bit). Without preservation, after running install-statusline the statusline file lost +x → Claude Code couldn't execute it → **statusline silently disappeared entirely** (not just the segment — the whole multi-line statusline). User caught this during a fresh-install e2e test.
- Both commands now `stat` the original mode before editing (cross-platform: BSD `-f '%Lp'` vs GNU `-c '%a'`) and `chmod` it back after. Falls back to `chmod +x` if stat fails.

### Added

- 2 new bats tests asserting executable permission survives both install and uninstall.

## [0.1.13] — 2026-05-09

### Fixed

- **Statusline fallback uses `sort -V` for semver-correct version selection.** v0.1.12's `for` loop iterated glob results and assigned the alphabetically-last match — which picks `0.1.9` over `0.1.10`/`0.1.11` because byte-wise sort puts `9` after `1`. Affects users who have updated through versions and have multiple cached. Now uses `ls -d ... | sort -V | tail -1`.
- **`|| true` on the cache-glob pipeline.** With `set -o pipefail` (common in statusline scripts), `ls -d` returning non-zero on no glob matches propagates through the pipe and triggers `set -e` exit. The fallback would silently kill the entire statusline whenever the plugin wasn't cached. Adding `|| true` after the pipeline makes it safe.

## [0.1.12] — 2026-05-09

### Fixed

- **Statusline integration is now robust to PATH variability.** Both inline and standalone insertion forms now try `found-issues` on PATH first, then fall back to globbing `~/.claude/plugins/cache/*/found-issues/*/bin/found-issues` for the latest installed binary. The statusline runs in a raw shell exec context where the plugin's auto-PATH may not apply (verified empirically — `command -v found-issues` fails in stripped-env subprocess but the cache glob succeeds). Without this fallback, users had a wired-but-silent statusline segment.

### Added

- New bats test asserting both insertion forms emit the `command -v` + cache-glob fallback pattern.

## [0.1.11] — 2026-05-09

### Fixed

- **`install-statusline` now inserts the segment inline on LINE1 when a LINE1 assembly pattern is detected** in `~/.claude/statusline.sh` (multi-line statuslines that build LINE1 across multiple assignments). Previously always appended at end-of-file, which made the segment render as an awkward standalone 4th line instead of inline next to repo/branch. Falls back to standalone-append for simple printf-style statuslines.
- **`commands/setup.md` "already integrated?" check uses the actual marker grep** (`# === found-issues plugin segment ===`), not a generic "found-issues" string match. Previous check produced false positives when the statusline file had any cleanup comments or other references containing the word "found-issues".

### Added

- New bats test confirming inline insertion when LINE1 pattern detected, distinct from the existing standalone-append test.

## [0.1.10] — 2026-05-09

### Added

- **Light first-run onboarding hint.** SessionStart hook now prepends a single italicized line to the user's first response after install: *"found-issues plugin is now active. Run `/found-issues:setup` for orientation + optional integrations."* Then never fires again (marker at `~/.claude/found-issues/.onboarded`). This closes the discoverability gap from v0.1.5: manual installers via `/plugin install` UI never read the README, so they had no signal that `/found-issues:setup` existed. The v0.1.4 verbose-directive approach was rejected as too "sloppy" (full block hijacked first response). v0.1.10 is the middle ground — visible enough to discover, light enough to not derail.

## [0.1.9] — 2026-05-09

### Changed

- **Archive is now enforced by default.** Sync auto-runs `archive` after the closure pass, surfacing output only when entries actually moved. Without enforcement, users forgot the command existed and active files grew unboundedly. Matches the rest of the plugin's "just works" model (sync auto-flips, format-enforcer auto-blocks, stop-reminder auto-fires).
- Opt-out via `export FOUND_ISSUES_AUTO_ARCHIVE=off`. When disabled, sync prints a hint instead so users still discover the command.

### Added

- 3 new bats tests covering auto-archive behavior (default-on, opt-out, no spurious output).

## [0.1.8] — 2026-05-09

### Added

- **`/found-issues:archive` command + `found-issues archive` CLI subcommand** — moves old `[fixed]` entries to `docs/found-issues-archive.md`. Triggers when EITHER threshold met:
  - Days: `(fixed: YYYY-MM-DD)` older than 30 days (default, `--days=N` to override)
  - Count: total `[fixed]` entries exceed 50 (default, `--count=N` to override) — oldest move first
- `--dry-run` flag previews what would move without modifying files
- Archive file is append-only — the plugin never modifies it after writing
- Open + deferred entries are never touched
- Sync now prints a one-line hint when archive thresholds are exceeded, so users discover the command organically
- 9 new bats tests covering all archive paths

### Why

Real-world entry rate during active development is ~25/day per repo, not "50–200/year" as initially scoped. At that pace, files grow fast and the active file becomes harder to scan. Archive keeps the active file lean while preserving full closure history in a separate append-only file. Single-source-of-truth model preserved (one active + one archive, both readable, no synchronization across multiple status-split files).

## [0.1.7] — 2026-05-09

### Added

- **`found-issues install-statusline`** — deterministic CLI subcommand that appends a marker-bracketed segment block to `~/.claude/statusline.sh`. Replaces the prior approach of asking Claude to read and edit the file in setup.md, which introduced variability across users (some got the `|| true` guard, some didn't). Idempotent (re-runs detect existing install via marker), uses `if/fi` not `&& chains` (so the block's final exit code is always 0), pre-pads the file's trailing newline if missing.
- **`found-issues uninstall-statusline`** — removes the marker block cleanly. Verified byte-identical-to-original via test.
- 8 new bats tests covering install/uninstall edge cases (missing file, idempotency, set -e survival, byte-identical roundtrip).

### Changed

- `commands/setup.md` no longer asks Claude to edit the statusline file. Setup just calls `found-issues install-statusline` after the user opts in. Removes the variability where Claude could miss the `|| true` guard and brick the user's statusline.

## [0.1.6] — 2026-05-08

### Fixed

- **Statusline integration safety**: `setup.md` now enforces `|| true` on the `found-issues status` command substitution. Prevents a `set -e` / `set -euo pipefail` statusline script from dying when the found-issues CLI isn't on PATH (the statusline runs as a raw shell exec outside Claude Code, where the plugin's auto-PATH doesn't apply). Also instructs Claude to insert inline at the LINE1 assembly point rather than appending, so the segment renders in the correct position.

## [0.1.5] — 2026-05-08

### Removed

- **Auto-firing onboarding** in SessionStart hook (added in v0.1.3, made visible in v0.1.4). Forcing every user's first prompt to be hijacked by an orientation block is bad UX. Onboarding belongs in the install ritual, not in a context hijack.

### Changed

- **Install ritual now four commands:** `/plugin marketplace add`, `/plugin install`, `/reload-plugins`, `/found-issues:setup`. Setup is the canonical onboarding moment — run during install, not later. README and AGENTS.md updated to make this explicit.
- AGENTS.md tells installing AIs to run all four steps; if the user already installed the first two themselves, the AI recommends `/found-issues:setup` immediately rather than waiting.

## [0.1.4] — 2026-05-08

### Fixed

- **First-run onboarding now actually visible.** SessionStart hook stdout is injected into Claude's *context*, not displayed to the user. v0.1.3's banner-style output got read by Claude but never spoken to the user. v0.1.4 reframes the output as a directive *to* Claude — telling the assistant to surface the orientation block at the top of its very next response. The user reliably sees the message now.

### Changed

- `commands/setup.md` statusline integration is now an actionable offer instead of just informational. Setup detects whether the user has a `~/.claude/statusline.sh`, asks for consent, then wires the segment append automatically. Detects existing counters to avoid duplicates.

## [0.1.3] — 2026-05-08

### Added

- **First-run onboarding nudge**: SessionStart hook prints a one-time orientation message inviting the user to run `/found-issues:setup`. Marker at `~/.claude/found-issues/.onboarded` blocks repeats. Without this, new users had no signal that `/found-issues:setup` existed.

### Changed

- `AGENTS.md`: install instructions now tell the installing AI to recommend `/found-issues:setup` after install (covers the agentic-install path; the SessionStart nudge covers the manual-install path)
- `commands/setup.md`: setup explicitly writes the onboarding marker on completion

## [0.1.2] — 2026-05-08

### Fixed

- **Stop-hook smart-fire**: only requires the `<!-- found-issues-checked: ... -->` marker on assistant turns that included substantive tool use (Edit/Write/MultiEdit/Bash/NotebookEdit). Pure-conversation turns (greetings, Q&A, brainstorm) no longer get blocked. This was the right behavior all along — a "Hello" reply has no code-change context to notice issues against.
- `bin/found-issues` `FI_VERSION` constant synced to manifest version (was hardcoded `0.1.0` regardless of release)

## [0.1.1] — 2026-05-08

### Fixed

- `marketplace.json` source schema corrected (`source: github, repo: owner/name` per Claude Code spec — previous `type/owner/repo` form failed install)
- `marketplace.json` missing required top-level `name` and `owner` fields
- `plugin.json` removed redundant `"hooks": "./hooks/hooks.json"` field — the standard `hooks/hooks.json` auto-loads via convention; explicit reference caused duplicate-load error on `/reload-plugins`

### Changed

- GitHub owner renamed `DougBTW` → `AltDoug` in all canonical refs (URLs, badges, LICENSE copyright, format-spec examples)

## [0.1.0] — 2026-05-08

Initial release. Built across 7 PRs in a single design + implementation
sprint.

### Added

**Plugin packaging**
- Claude Code plugin manifest (`.claude-plugin/plugin.json`)
- Marketplace listing (`.claude-plugin/marketplace.json`) for `/plugin marketplace add`
- Auto-loading rules skill (`skills/rules/SKILL.md` with `disable-model-invocation: true`)
- Hook event registration (`hooks/hooks.json`) using `${CLAUDE_PLUGIN_ROOT}`

**Slash commands** (all namespaced under `/found-issues:`)
- `/found-issues:log` — append a new `[open]` entry
- `/found-issues:sync` — annotation-driven flip + tombstone close + AI verification of unannotated entries
- `/found-issues:annotate-pr` — append `(PR: org/repo#N)` to matching entries
- `/found-issues:annotate-commit` — append `(commit: <sha>)` to matching entries (defaults to HEAD)
- `/found-issues:promote` — list branch-only entries needing consolidation
- `/found-issues:status` — print counters (critical / issues / in PR / stale)
- `/found-issues:setup` — first-run orientation

**Hooks**
- `format-enforcer.sh` (PreToolUse Write/Edit/MultiEdit) — mode-aware: hard-block in github-pr/github-direct, warn in git, off in local
- `session-start.sh` (SessionStart) — runs sync, injects `[open]` entries into context, prints count
- `stop-reminder.sh` (Stop) — forces `<!-- found-issues-checked: ... -->` marker on every assistant turn
- `post-pr-create.sh` (PostToolUse Bash) — surfaces matching entries after `gh pr create`
- `post-git-commit.sh` (PostToolUse Bash) — surfaces matching entries after `git commit`
- `pre-branch-delete.sh` (PreToolUse Bash) — hard-blocks branch deletion if entries unpromoted
- `pre-commit.sh` — per-repo git pre-commit hook (opt-in via `found-issues install-precommit` — planned)

**CLI** (`bin/found-issues`)
- All subcommands above plus `--version` and `--help`
- Three output formats for `status`: `segment` (ANSI), `plain`, `json`
- Lib resolution priority: `$FOUND_ISSUES_LIB_DIR` → `$CLAUDE_PLUGIN_ROOT/lib` → relative to bin/

**Shared libraries** (`lib/`)
- `canonicalize.sh` — path normalization, symptom canonicalization, dedup keys
- `parse-entries.sh` — file finding, entry parsing, count helpers
- `detect-mode.sh` — auto-detect mode with 1h per-repo cache

**Documentation**
- `README.md` with install, what-it-does, comparison table, format spec, modes
- `docs/format-spec.md` — canonical format with regex patterns
- `docs/architecture.md` — component map and data flow
- `docs/modes.md` — four-mode detection and behavior matrix
- `docs/faq.md` — common questions
- `docs/demo-storyboard.md` — VHS tape file for the demo GIF
- `AGENTS.md` — install instructions for AI agents
- `CONTRIBUTING.md` — contribution process

**CI / quality**
- 122 bats tests covering lib, CLI, hooks
- GitHub Actions matrix on Linux + macOS
- JSON manifest validation
- Advisory shellcheck

### Format spec — v1 lock-in

```
- [STATUS] [!] YYYY-MM-DD path:line — symptom (suggested: fix) [(PR: org/repo#N) | (commit: SHA)] [(fixed: YYYY-MM-DD)] [(verified: ai|review)]
```

- Statuses: `open`, `deferred`, `fixed` (lowercase only)
- `[!]` is the critical flag (separate token from status)
- ` — ` is U+2014 em-dash with spaces (not hyphen)
- Path can be absent for abstract entries
- Multiple `(PR: ...)` and `(commit: ...)` annotations allowed per entry

### Known limitations

- `detect-mode` `github-pr` vs `github-direct` distinction requires `gh` CLI authenticated
- Squash-merge / rebase-merge can break commit-annotation closure (workaround: also annotate with PR)
- Format-enforcer pattern lists in `format-enforcer.sh` and `pre-commit.sh` are duplicated (refactor to `lib/validate.sh` planned)
- No interactive setup wizard; `/found-issues:setup` is informational only

### Untested in CI (smoke-tested only)

- `post-pr-create.sh` end-to-end against a live PR
- `session-start.sh` integration with Claude Code's actual SessionStart event
- Skill auto-loading behavior in a real session
- `gh pr view` JSON output parsing edge cases

These are exercised in dogfood usage rather than CI.

<!-- v0.1.x versions were private-development releases. v1.0.0 is the first
     publicly tagged release on GitHub. The CHANGELOG retains v0.1.x entries
     for transparency about how the plugin was built. -->

[Unreleased]: https://github.com/AltDoug/found-issues/compare/v1.0.2...HEAD
[1.0.2]: https://github.com/AltDoug/found-issues/releases/tag/v1.0.2
[1.0.1]: https://github.com/AltDoug/found-issues/releases/tag/v1.0.1
[1.0.0]: https://github.com/AltDoug/found-issues/releases/tag/v1.0.0
