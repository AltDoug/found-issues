---
description: Answer the found-issues decision queue — entries tagged (decide: <question>) that need a human call before they can be fixed. Walks each question with options and a recommendation, then records the answer so the entry becomes fixable.
codex-description: Walk the found-issues decision queue: list [open] entries tagged (decide: <question>), present each with 2-4 options and a recommendation, and record the operator's answer with `found-issues decide <match> --answer`. Use when the operator asks to answer pending decisions or SessionStart reports decisions waiting. Not for fixing entries (that is $fi-fix).
argument-hint: (no arguments)
allowed-tools: Bash(found-issues:*), Read, Grep, AskUserQuestion
---

Walk the decision queue one question at a time.

1. Run `found-issues decide`. If it prints `No decisions waiting.`, say so and stop.
2. For each line `<n>. [!] <loc> — <question>` (critical first):
   - Read the cited code (`<loc>`) enough to frame the choice.
   - Ask the operator the question with 2–4 concrete options. Put your
     recommended option first, labelled "(Recommended)" with a one-line why.
     In Claude Code use the AskUserQuestion picker. In Codex ask in chat as a
     numbered list.
   - Record the answer exactly as chosen (free text is fine):
     `found-issues decide "<loc>" --answer "<answer>"`.
     If the match is ambiguous (exit 2), retry with a longer fragment of the
     entry. Never edit `docs/found-issues.md` by hand.
3. Finish with one line: `Answered N · Skipped M`.
