# Session-start cut (3.4.0, token-efficiency sub-project 1) — design

Date: 2026-10-07 · Status: approved in brainstorming, awaiting written-spec review
Scope source: memory `context-cut-ships-as-3-4-0` (operator picks 2026-10-06), audit items B0 + B3.

## 1. Why

A user turned auto-fix off over "3k tokens per turn". Measured: the found-issues
resident cost is the SessionStart injection (~2.3k tokens; 7939 B on a 40-entry
ledger, 8254 B on 150; average 6959 B over 418 real sessions) plus skill
descriptions (~0.8k), identical with auto-fix on or off. The injection is
re-sent with every API call of the session (median 59 calls/session), and 21 of
26 resumed transcripts hold it twice.

Goal: cut the session-start injection to ≤1.8 KB on a 150-entry ledger without
making agents log out-of-scope issues less often or less correctly.

## 2. Release model

3.4.0 is the first of four token-efficiency sub-projects; each ships on its own
when ready (operator pick 2026-10-07). This one: session-start cut (B0) + skip
re-injection on resume (B3). Later, separately: slim auto-fix children
(A1-A3, A7), in-session cuts (B1, B2, B4-B6, B8), smarter sync (B7).

## 3. What session start injects (Claude Code and Codex)

In order:

1. **Core rules, fixed text, ~1.2 KB.** The mandate ("Issues found and not
   tracked are issues lost"; never dismiss as pre-existing); one line on the log
   command and its three tags (`--fix small|medium|large`, `--decide "<q>"`,
   `--manual "<why>"`); one line on what to log / not log, naming the
   `dead code:` prefix; one line on annotating after a PR or commit (`--pick`
   only the entries the change fixes); the Stop-marker line; the four hard
   rules (commands only, never delete `[open]`, never mark `[fixed]` unverified,
   never bypass the pre-delete check); one pointer: each `/found-issues:*`
   command carries its own procedure.
2. **Status line** (~60 B), e.g. `68 open · 2 critical · 1 stale · 5 decisions waiting`.
3. **Critical entries:** all `[open] [!]` entries, capped at 5 as today, inside
   the existing untrusted-data fence and wording.
4. **Up to 3 path-less entries** (topic locations, no file path), newest first,
   same fence. 55% of unannotated open entries cite untracked paths, which the
   first-touch hook (section 4) can never surface.
5. **One closing line:** entries for a file appear when you first open or edit
   it; `found-issues list` shows all.

Dropped from the injection: the 15-entry list, the duplicate annotate footer,
the `loc-override` HTML comment, and the long sync / promote / dead-code /
format sections (relocated, section 5).

Budget: ≤1.8 KB on the 150-entry fixture ledger, enforced by a test.

## 4. First-touch hook (new)

- New PostToolUse hook `hooks/first-touch.sh`, matcher `Read|Edit|Write|MultiEdit`
  on Claude Code; on Codex it runs for `apply_patch` and takes the paths from
  the patch. Codex has no Read tool, so Codex sees a file's entries on its
  first edit only.
- Steps: resolve the touched path relative to the repo root; if the path is
  outside the repo, or no ledger exists, exit 0 silently. Cheap pre-check: a
  fixed-string search for the relative path in the ledger; no hit → exit 0
  (the common case). On a hit, parse the `[open]` entries whose path equals the
  relative path and emit them through `fi_emit_post_context`
  (lib/harness.sh) inside the same untrusted-data fence as session start, at
  most 5, then `+N more: found-issues list --path <path>`.
- Once per file per session: seen paths are appended to
  `${FOUND_ISSUES_CACHE_DIR:-~/.cache/found-issues}/sessions/<session_id>`; a
  second touch injects nothing. Session files older than 7 days are pruned
  opportunistically. No session id → inject without recording (fail open
  toward showing).
- Fail open: any error → no output, exit 0. A Read is never blocked.
- Not covered by design: files read through Bash (`cat`, `sed`). The status
  line still says entries exist.
- Speed: ≤50 ms for a no-match touch on the 150-entry fixture (timing test).
- New CLI filter `found-issues list --path <path>` (exact path match), used by
  the "+N more" line.

## 5. Where the removed rule text goes

Nothing is lost; each part moves to where it is used:

| Removed from session start | Lives in |
|---|---|
| Sync procedure | `commands/sync.md` (already complete there) |
| Branch deletion / promote | hard rule 4 stays in the core; the pre-delete hook's block message; `commands/promote.md` |
| Dead-code procedure (do not edit, find the live component) | `commands/log.md`; the core names the `dead code:` prefix |
| Format details | hard rule 1 stays; `docs/format-spec.md`; the log command writes the format |
| Annotation details | the existing post-commit/PR hook output prints the exact `--pick` command |

The rules skill (`skills/rules/SKILL.md`) becomes the core text. The Codex
rules block is generated from it (`fi_codex_rewrite_core`) and `codex-skills/`
is regenerated with `scripts/gen-codex-skills.sh`.

## 6. Resume skip (B3)

Inside `hooks/session-start.sh`, not a hooks.json matcher, so both harnesses
behave the same: when the hook input's `source` is `resume`, skip the context
injection but still run the mechanical work (statusline migration, auto-fix
summary, onboarding hint). `startup`, `clear` and `compact` inject (compaction
can drop earlier context).

## 7. Rollback switch

`FOUND_ISSUES_SESSION_CONTEXT=full` restores the 3.3.1 injection (full rules +
15 entries + footer). Documented in `docs/configuration.md`. Rollback without a
release.

## 8. Tests (bats)

- Byte budget: session-start output ≤1.8 KB on a 150-entry fixture.
- Core content: each hard rule, the three log tags, the annotate `--pick` line
  and the Stop-marker line are present.
- Criticals capped at 5; path-less entries capped at 3, newest first.
- `source=resume`: no injection; mechanical work still runs.
- `FOUND_ISSUES_SESSION_CONTEXT=full` reproduces the old output shape.
- First-touch: injects once per file per session; cap 5 + "+N more"; silent on
  no match, outside the repo, no ledger; fails open on a malformed ledger;
  Codex `apply_patch` payload; ≤50 ms no-match on the 150-entry fixture.
- `list --path`: exact match only.
- Codex rules regenerated; `codex-skills-drift` and `docs-consistency` green.

## 9. Effectiveness eval (gate before shipping)

Script `evals/session-start/run.sh`, repeatable for later sub-projects.

- 3 fixture repos. Each has one real task and 2 planted out-of-scope bugs: one
  in the file the task fixes, one in a neighbouring file the task needs read.
- Arms: old (v3.3.1 hooks) vs new (this branch). Each run loads only that arm's
  plugin (`claude -p --plugin-dir <arm>`). The installed found-issues plugin is
  enabled through user settings (`enabledPlugins` in ~/.claude/settings.json),
  so each run also passes `--setting-sources project,local` to keep it out and
  hooks never double-fire. The plan's first task is a one-run probe that
  confirms exactly one SessionStart injection per arm.
- sonnet, 5 runs per fixture per arm = 30 runs, `--max-budget-usd 0.60` each
  (≤$18 worst case, ~$8-12 expected).
- Measured per run: planted bugs logged (right path, line within ±3), ledger
  format valid, task completed, input tokens.
- Pass: over the 15 runs per arm, new-arm planted bugs logged ≥ old-arm − 1,
  and no drop in task completion. Results to `docs/e2e/`.
- Fail → fall back to approach C (keep the full rules, cut only the entry
  block, footer and comment), re-run the eval, ship that.

## 10. Release

The new hook is `### Added`, so a MINOR bump: **3.4.0**. Usual path:
`/code-review` on the branch, full bare `bats tests/` (0 not ok), ship with
`--pick` (B0/B3 ledger entries if any), merge on green, release Latest,
claude-plugins marketplace bump, sync PR.

## 11. Out of scope

Auto-fix child slimming, Stop-hook block → nudge, annotate-output compaction,
list/fix bounding, log length caps, sync pre-filter (later sub-projects).
