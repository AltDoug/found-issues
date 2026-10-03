# found-issues full audit — 2026-10-03 (post-v2.9.1, origin/main 3844477)

Scope (operator pick): thorough + fix. 6 sonnet finders (Read/Grep/Glob only) → 6 opus adversarial verifiers → orchestrator runtime repros in docker `hookfork`.
Files: `findings-<area>.json` (raw), `verdicts-<area>.json` + `all-verdicts.json` (verified), `runtime-evidence.md` (measurements + verbatim repro output), `repro-scripts/`.

**Totals:** 112 findings → 95 CONFIRMED, 17 PLAUSIBLE, 0 REFUTED by verifiers (ledger-4 disputed: current mawk 20250131 supports `{n}`; verifier says Debian 12/Ubuntu 22.04 mawk 20200120 does not — trivial fix, keep). Unique (non-duplicate): 8 high · 31 medium · 56 low.

## High — all confirmed at runtime (see runtime-evidence.md)
| id | defect |
|---|---|
| prompt-17 | Rules skill (`disable-model-invocation: true`) is NEVER loaded on Claude Code — docs: that flag *prevents* loading; only Codex gets the rules (session-start.sh codex branch). Every Claude user runs without the rules. |
| ledger-1 (=status-4, annot-6) | Unlocked read-all→gh loop→`mv` in sync reverts concurrent writes: `defer` during sync printed success, then vanished. |
| ledger-3 | `archive` with one invalid-UTF-8 byte deleted every [open] entry (`grep ... || true` → mv). |
| prompt-2 | Bare `annotate-pr N` (what SessionStart/rules tell agents to run) writes the CLOSING `(PR:)` on a file-level match with no line check → irreversible false close. |
| cli-4 | `log` symptom ending in `(commit: <sha on main>)` / `(PR: …)` is parsed as an annotation → next sync closes it. |
| hook-2 / hook-4 | pre-branch-delete bypassed by `git -C dir branch -D x` and by a quoted operand `git branch -D "$b"`. (+hook-3 `-df`, low) |
| hook-5 | format-enforcer validates only Edit `new_string` lines starting `- [` → sub-line `[open]`→`[fixed]` edit closes with no token. |
| hook-14 | Without CLAUDE_PLUGIN_ROOT (all Codex hooks), `readlink -f found-issues` resolves against CWD → lib not found → pre-branch-delete AND format-enforcer exit 0 for everything. |

## Resource (measured; Windows Git Bash = process creations leak tokens)
sync ≈ 65 forks/open entry (5,990 at 80 entries); SessionStart 517 forks @6 entries; Stop 22; Edit hook 7 per edit. Root causes: ledger-5 (per-entry parse pipelines, loop-invariant `git rev-parse`), ledger-6 (whole-history rename scan per abstract entry, every sync), ledger-8/cli-11 (`gh auth status` before mode cache; no gh memo), hook-11 (SessionStart sync+status even with 0 open), hook-6/hook-7 (jq before a builtin gate), hook-12, annot-1/2, cli-10/12, status-1/2/14/15.

## Proposed fix batches (each its own PR; AltDoug auto-merge; watch post-merge macOS run)
1. **Data loss / false close (v2.9.2)** — ledger-1 (cmp-skip no-op mv + cksum optimistic check before mv + same-dir tmp = ledger-2/cli-23), ledger-3+15 (archive delete-by-NR in awk), cli-4 (reject annotation-shaped symptom tail), prompt-2 (no-flag annotate writes the -auto suggestion form; only --pick/--all canonical) + SessionStart/rules text, annot-10 (rerun cmd uses resolved sha), ledger-12 (quotepath=off), ledger-11 (no demotion in shallow clones), ledger-17 (skip on conflict markers), hook-8.
2. **Guard bypasses** — hook-2/3/4/5/14, prompt-6 (drop agent-visible bypass hint), hook-18 (warn when jq missing).
3. **Rules reach Claude + prompt accuracy** — prompt-17 (SessionStart emits rules body for Claude too; flip tests/session-start.bats:405; fix architecture.md/AGENTS.md/README), prompt-1/12/13/14/15/16/19, cli-19 (quote Codex description YAML + strict-parse drift test).
4. **Resource** — ledger-5/6/7/8, hook-6/7/11/12/20, annot-1/2/13, cli-10/11/12, status-1/2/3/14/15. Re-measure with repro-scripts/run.sh before/after.
5. **CLI hygiene** — cli-5/6 + the open `*) shift ;;` ledger entry (shared fi_reject_unknown_flag), cli-1/2/3/13(=ledger-10)/14/15/16, status-5/6/7/8/11/17, prompt-7(=cli-8) promote dedup keys.
Remaining lows → log to docs/found-issues.md, don't fix.
Task 3 (opt-in auto-fix/auto-sweep) depends on batch 1 + commands/fix.md gaps (prompt-8/9/10/11) and ships as **v3.0.0** (operator, 2026-10-03).
