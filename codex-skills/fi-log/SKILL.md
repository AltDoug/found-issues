---
name: fi-log
description: Log an out-of-scope issue to docs/found-issues.md
---
<!-- loc-override: generated 1:1 from commands/log.md by scripts/gen-codex-skills.sh; length is owned by the source command file -->

Log an `[open]` issue via the `found-issues` CLI. The CLI handles file
location detection, format validation, dedup against existing entries,
and date stamping — your job is just to pass the user's input through.

## What to do

Run the CLI with the user's arguments:

```bash
found-issues log <the user-provided arguments>
```

Then read the output and report the result to the user concisely:

- If the line starts with `Logged:` — a new entry was added. Show it.
- If the line starts with `Skipped — already logged:` — dedup fired. Show which entry matched.
- The trailing line is the updated count (e.g., `2 issues · 1 in PR`). Pass it through.

## When to use this command vs. proactive logging

The user typically does NOT invoke `$fi-log` directly. You invoke it on their
behalf when you observe an out-of-scope issue per the rules in
`the auto-injected found-issues rules`. They run `$fi-log` only when they want to manually
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
$fi-log src/foo.py:42 — null check missing (suggested: add guard before deref)
$fi-log --critical src/auth.ts:88 — leaks session token in error logger (suggested: redact in formatter)
$fi-log workflow/shutdown — SIGTERM kills detached sessions silently (suggested: pre-shutdown ps check)
```

The third form (no path:line) is for abstract observations that don't
have a single file location.
