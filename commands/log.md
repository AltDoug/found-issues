---
description: Log an out-of-scope issue to docs/found-issues.md
codex-description: Log an out-of-scope issue noticed mid-task to docs/found-issues.md as a dated [open] entry with path:line, symptom, and optional suggested fix. Use whenever a defect, smell, or dead code is noticed that the current task will NOT fix — logging beats dismissing it as pre-existing. Only for NEW observations: to change an existing entry's state use /found-issues:defer (park it), /found-issues:promote-deferred (revive it), or the annotate commands (link a fix). Never edit the ledger file by hand — this is the only supported way to add an entry.
argument-hint: [--critical] [--fix small|medium|large | --decide "<q>" | --manual "<why>"] <path:line> — <symptom> (suggested: <fix>)
allowed-tools: Bash(found-issues:*)
---

Log an `[open]` issue via the `found-issues` CLI. The CLI handles file
location detection, format validation, dedup against existing entries,
and date stamping — your job is just to pass the user's input through.

## What to do

Run the CLI with the user's arguments, as ONE single-quoted argument (the
symptom routinely contains parentheses and apostrophes, which break an
unquoted shell line; escape an apostrophe as `'\''`). `--critical` and the
fix-tag flag, when wanted, go first and outside the quotes:

```bash
found-issues log [--critical] [--fix small|medium|large | --decide "<q>" | --manual "<why>"] '<path:line> — <symptom> (suggested: <fix>)'
```

Tag every entry with exactly one fix tag (v3):

- `--fix small|medium|large` — no human decision needed, and the repo's
  tests can prove a fix. Off-limits paths (CI config, secrets/auth,
  dependency manifests and lockfiles, migrations, untracked or outside the
  repo, or no file at all) are tagged `(manual: off-limits: <category>)`
  instead, and the CLI says so.
- `--decide "<question>"` — needs the operator's call: several valid fixes,
  an interface or UX choice, anything outside the repo, irreversible steps.
- `--manual "<why>"` — no test can prove the fix, or it needs a live payload.

Re-logging an untagged entry with a tag tags it instead of skipping it.

Then read the output and report the result to the user concisely:

- If the line starts with `Logged:` — a new entry was added. Show it.
- If the line starts with `Skipped — already logged:` — dedup fired. Show which entry matched.
- The trailing line is the updated count (e.g., `2 issues · 1 in PR`). Pass it through.

## When to use this command vs. proactive logging

The user typically does NOT invoke `/found-issues:log` directly. You invoke it on their
behalf when you observe an out-of-scope issue per the found-issues rules
(injected at session start). They run `/found-issues:log` only when they want to manually
log something they noticed.

Either way, the command behaves identically — it just appends to the file.

## Format reminder

```
- [open] [!] YYYY-MM-DD path/file.ext:42 — symptom (suggested: fix)
```

The CLI auto-fills the date and `[open]` status. Pass the location, the
em-dash separator (` — `), and the symptom. Use `--critical` for the
`[!]` flag.

## Examples

```
/found-issues:log src/foo.py:42 — null check missing (suggested: add guard before deref)
/found-issues:log --critical src/auth.ts:88 — leaks session token in error logger (suggested: redact in formatter)
/found-issues:log workflow/shutdown — SIGTERM kills detached sessions silently (suggested: pre-shutdown ps check)
```

The third form (no path:line) is for abstract observations that don't
have a single file location.

## Dead code

Zero importers → do not edit, do not delete. Log with prefix `dead code:`, then find the actually-live component via the route/page that triggered the symptom and continue there.
