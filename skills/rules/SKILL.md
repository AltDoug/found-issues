---
description: Core rules for how AI agents maintain docs/found-issues.md — what to log and how, annotation after PR/commit, the stop marker and the hard rules. The ~1 KB core, injected at session start only when FOUND_ISSUES_SESSION_CONTEXT=lean; the default injects the complete rules from lib/rules-full.md.
disable-model-invocation: true
---

# found-issues — agent rules

**Issues found and not tracked are issues lost.** When you notice a defect outside your task, log it; never dismiss it as "pre-existing". You keep `docs/found-issues.md` for the user.

- **Log:** `/found-issues:log <path:line> — <symptom> (suggested: <fix>)` with one tag: `--fix small|medium|large` (a test proves the fix), `--decide "<question>"` (user's call) or `--manual "<why>"` (no test can prove it). Log bugs, races, security defects, misleading docs, and `dead code:` (zero call sites; never edit it). Skip nits, TODOs, speculation.
- **After a PR or commit:** run the printed `found-issues annotate-pr <N> --pick <loc>,...` (or `annotate-commit <sha> --pick`) naming only entries it fixes; a pick closes on merge.
- **Stop marker:** the first tool-using turn ends with `<!-- found-issues-checked: none-noticed -->`, `logged` or `deferred`.
- Each `/found-issues:*` command carries its own procedure.

**Hard rules:** never write the ledger directly; never delete `[open]` entries; never mark `[fixed]` without verification; never bypass the pre-branch-delete check (run `/found-issues:promote` first).
