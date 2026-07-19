# Codex compatibility + usage diet — design

**Date:** 2026-07-19
**Status:** approved direction; spec pending operator review
**Target version:** v1.8.0 (minor — additive surfaces + hook behavior change)

## Problem

1. **Codex compatibility.** found-issues is Claude-Code-only (`AGENTS.md` explicitly
   declares non-Claude agents out of scope). Codex now ships a plugin + hooks +
   skills system that mirrors Claude Code's almost 1:1, so first-class support is
   cheap relative to its reach.
2. **Usage.** Operator's `/usage` (24h): 23% of limit usage from the found-issues
   plugin, 22% from `/found-issues:annotate-pr` alone, in sessions that are 97%
   >150k context. Requirement: cut this hard with **zero efficacy loss** — same
   usefulness, consistency, accuracy.

## Constraint discovered up front (shared-ledger requirement)

A user running both Claude Code and Codex in the same repo must see **one**
ledger. This is already structurally true — the ledger is the committed
`docs/found-issues.md` (or `.found-issues.md` in local mode), and all writes go
through the same `bin/found-issues` CLI. The design must not fork any state:
one ledger, one CLI, one mode cache (`~/.cache/found-issues`). Only the thin
harness adapters (hook wiring, skill/command packaging) differ.

---

## Workstream A — usage diet (no efficacy loss)

### A1. Hook-driven auto-annotation (the 22% killer)

**Today:** after `gh pr create`, `post-pr-create.sh` scans the ledger and injects
a prompt; the model then loads `commands/annotate-pr.md`, runs the CLI, maybe
does a `--pick` round. 2–4 model round-trips at end-of-session (largest context).

**New:** the hook runs `found-issues annotate-pr <N>` itself.

- The CLI's auto path (`fi_annotate_auto`) already annotates **only unambiguous
  matches** (a touched file cited by exactly one `[open]` entry) and refuses
  contested files — that is the exact safety boundary the 2026-07-09
  over-annotation incident produced. Hook-driven execution changes *who invokes
  it*, not *what it annotates*. Zero judgment lost.
- **Unambiguous outcome:** hook emits ONE context line
  (`found-issues: auto-annotated N entries with (PR: org/repo#M)`) so the model
  and operator know the ledger changed. No command load, no extra turns.
- **Ambiguous outcome:** hook surfaces the CLI's candidate list plus a compact
  instruction to run `found-issues annotate-pr <N> --pick …` (direct Bash — not
  the slash command, so the 3KB command file never loads). Model judgment stays
  exactly where it is actually exercised.
- **No matches:** silent (as today).

**CLI change required:** `fi_annotate_auto` currently exits 0 for both outcomes;
only stdout differs. Add **exit code 3 = "candidates need picking"** (additive;
error paths keep 1/2, success keeps 0) so the hook branches on exit code, not
stdout scraping. `commands/annotate-pr.md` (which passes output through) is
unaffected by the new code but gets a doc note.

Same pattern for `post-git-commit.sh` → `found-issues annotate-commit <sha>`
(the CLI has identical `--pick`/`--all` semantics there).

The `/found-issues:annotate-pr` and `:annotate-commit` commands remain as manual
fallbacks (PR opened via web UI, non-Bash tool, hook disabled) — unchanged
behavior, now rarely loaded. New opt-out: `FOUND_ISSUES_AUTO_ANNOTATE=off`
restores the current prompt-only behavior.

### A2. Compress the always-on rules skill

`skills/rules/SKILL.md` is ~8.6KB injected into **every session in every repo**.
Rewrite to ≤3.5KB: identical rule set (core principle, log/don't-log lists,
how-to-log, annotation duties, sync responsibility, branch-deletion guard,
stop-marker, dead-code protocol, format quick-ref, 4 hard rules), terser prose,
and updated annotation section reflecting A1 (hooks auto-annotate unambiguous
matches; the model's job is the `--pick` judgment when the hook surfaces
candidates). The `loc-override` comment and `disable-model-invocation: true`
stay.

### A3. Cap session-start entry injection

`session-start.sh` currently injects **all** `[open]` entries. New: criticals
(`[!]`) always, then newest-first up to `FOUND_ISSUES_SESSION_INJECT_MAX`
(default 15), then one line: `…and M more — run \`found-issues list\` for the
full ledger.` Repos at or under the cap see no change.

### A4. Merge the three per-Bash PostToolUse hooks into one dispatcher

`post-pr-create.sh`, `post-git-commit.sh`, `post-pr-state.sh` each spawn a
process + jq parse after **every** Bash call. Replace with one
`post-bash-dispatch.sh`: single JSON parse, route on command pattern
(`gh pr create` / `git commit` / `gh pr merge|close|reopen`), then run the
respective logic (kept as functions in the dispatcher or sourced files —
implementer's choice, tests decide). `hooks.json` shrinks to one PostToolUse
Bash entry. Not a token saver; a latency/process-overhead cleanup taken because
A1 already rewrites two of the three.

### A5. Stop-hook marker discipline: unchanged

It is the plugin's core efficacy mechanism. Compliant turns cost ~20 output
tokens; the existing smart-fire (substantive-tool-use-only) and terse
post-onboarding verbosity already minimize cost. Explicitly **not** trading
this away. (Existing opt-out `FOUND_ISSUES_STOP_REMINDER=off` remains for users
who disagree.)

### Explicitly rejected

- Dropping the Stop hook (largest token save, direct efficacy loss).
- Running annotation judgment on a cheaper model via command frontmatter
  (accuracy risk on false-`[fixed]` flips; A1 makes it moot for the happy path).

---

## Workstream B — first-class Codex support (dual-manifest, single repo)

Codex facts this design relies on (developers.openai.com/codex → learn.chatgpt.com docs, fetched 2026-07-19):

- Plugins: `.codex-plugin/plugin.json` manifest; default hooks path inside a
  plugin is **`hooks/hooks.json`** — the path this repo already uses. Install
  via `codex plugin marketplace add owner/repo`; repo marketplace file at
  `.agents/plugins/marketplace.json` (legacy compat with
  `.claude-plugin/marketplace.json` is referenced in their docs).
- Hooks: same event names (SessionStart, PreToolUse, PostToolUse, Stop) and
  same payload field names (`tool_name`, `tool_input.command`, `tool_response`,
  `transcript_path`, `cwd`). Plugin hooks receive `PLUGIN_ROOT`/`PLUGIN_DATA`
  **plus legacy `CLAUDE_PLUGIN_ROOT`/`CLAUDE_PLUGIN_DATA`**.
- Output contract differs: SessionStart accepts plain-text stdout as context,
  but **PostToolUse/Stop stdout must be JSON** (`additionalContext`); Stop
  blocking works via exit 2 + stderr (same as Claude Code).
- Skills: `skills/<name>/SKILL.md` with `name`/`description` frontmatter;
  discovered from `~/.agents/skills`, repo `.agents/skills`, or bundled in
  plugins; invoked explicitly (`/skills`, `$` mention) or implicitly by
  description match. Custom prompts are deprecated.

### B1. Dual manifest

Add `.codex-plugin/plugin.json` (name/version/description/author mirrored from
`.claude-plugin/plugin.json`; component pointers: `skills`, `hooks`). CI check
asserts the two manifests' versions stay identical.

### B2. Harness-aware hook output

The three context-emitting hooks (session-start, post-bash dispatcher, stop
reminder) gain a tiny shared emit helper:

- **Claude Code:** plain-text stdout (today's behavior, unchanged).
- **Codex:** JSON `additionalContext` for PostToolUse; plain text for
  SessionStart; Stop keeps exit-2 + stderr (works on both).
- **Detection:** prefer a single JSON shape both harnesses accept if empirical
  testing confirms each ignores the other's fields; otherwise detect harness at
  runtime (`CLAUDE_CODE_ENTRYPOINT` present → Claude; `PLUGIN_DATA` without it →
  Codex; fallback plain text). **Must be verified empirically during
  implementation — the exact Codex JSON nesting is not fully documented.**

### B3. Rules injection on Codex

Codex has no always-loaded-skill mechanism. On Codex, `session-start.sh`
appends the compact rules block (A2 text, same source file — single source of
truth, no drift) to its SessionStart output. On Claude Code it must NOT (the
skill already injects it — double-injection is the exact waste A2 fights).
Claude-specific session-start branches (statusline nudges targeting
`~/.claude/statusline.sh`, `/found-issues:setup` onboarding hint) are skipped
on Codex.

### B4. Codex skills generated from commands

The 13 `commands/*.md` are already thin CLI wrappers. A build script
(`scripts/gen-codex-skills.sh`) generates `codex-skills/<name>/SKILL.md`
from each command: frontmatter `name: fi-<cmd>` + existing `description`;
body = command body with a small rewrite table (`/found-issues:X` → `$fi-X`
skill references, Claude-only phrasing dropped). Generated files are
**checked in**; a CI check regenerates and diffs to prevent drift.

Directory isolation matters: the Codex manifest's `skills` component pointer
targets `./codex-skills`, while Claude Code keeps reading `skills/` (which
holds only the auto-loaded rules skill). If the generated skills lived under
`skills/`, Claude Code would load 13 extra skill descriptions into every
session — the opposite of Workstream A. The Codex manifest must NOT point at
`skills/` and Claude Code never scans `codex-skills/`.

### B5. Stop-hook on Codex: fail-open v1

`stop-reminder.sh`'s smart-fire parses Claude Code's transcript JSONL shapes.
Codex transcripts differ. v1: on Codex, if the transcript is missing or the
turn-boundary parse finds nothing recognizable, **fail open** (no block). The
marker discipline is fully active on Claude Code (unchanged) and
best-effort-then-silent on Codex; documented as a known v1 limitation with a
follow-up ledger entry. No Claude-side behavior change.

### B6. Packaging, docs, marketplace

- `AGENTS.md`: rewrite — install paths for **both** harnesses; delete the
  "do not replicate outside Claude Code" section.
- README: Codex install section.
- `docs/architecture.md` + `docs/modes.md`: harness-adapter note + shared-ledger
  guarantee.
- Marketplace repo (`AltDoug/claude-plugins`): add
  `.agents/plugins/marketplace.json` (Codex-native) alongside the existing
  Claude marketplace file — **separate PR, second repo**, per the established
  release coupling (source PR first, marketplace PR second).
- Statusline counter: no Codex equivalent surface exists in their docs —
  explicitly out of scope v1; documented in FAQ.

### Out of scope

- Codex statusline integration (no surface).
- `agents/openai.yaml` polish (icons, brand color) — nice-to-have, not v1.
- Porting the `/fi` alias (Claude-specific `~/.claude/commands` mechanism);
  Codex users get `$fi-*` skill mentions instead.

---

## Testing & verification

- **bats** coverage for: annotate-pr exit code 3; hook auto-annotation happy /
  ambiguous / opt-out paths; dispatcher routing; session-start cap; Codex JSON
  emit shapes; gen-codex-skills drift check. CI constraints from prior
  incidents: ASCII-only `@test` names, bash-3.2-safe (`set -u` + empty arrays),
  wait for the **full** matrix incl. Windows bats (7–15 min) before declaring
  green.
- **End-to-end (Claude side):** drive a real `gh pr create` in a sandbox repo
  and verify the hook annotates without a model round-trip (the `verify` skill
  recipe).
- **End-to-end (Codex side):** install the plugin into Codex CLI on this
  machine, run a session in a test repo, verify: rules injected, `$fi-log`
  works, PostToolUse JSON accepted, ledger shared with a Claude session in the
  same repo.
- Pre-PR: adversarial `/code-review` workflow (established practice for release
  branches on this repo).

## Definition of done

Tests + build green in-session on the full CI matrix; both end-to-end drives
verified with evidence; ledger shared between harnesses demonstrated in one
repo; usage-diet effect stated honestly (what is now zero-round-trip vs still
model-driven); release PR pair (source → marketplace) opened in order.
