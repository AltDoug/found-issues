---
description: Print the current open / in-PR / critical / stale counts
argument-hint: (no arguments)
allowed-tools: Bash(found-issues:*)
---

Show the current state of the found-issues file in this repo.

## What to do

```bash
found-issues status --format=plain
```

If the output is empty, the repo has no open entries. Tell the user:
*"No open found-issues entries in this repo."*

If non-empty, pass the output through verbatim. It will look like one of:

- `1 issue` — one open entry, nothing critical or in-PR
- `2 critical · 5 issues · 3 in PR · 1 stale` — full layout

The four counters mean:
- **critical** — `[open]` entries with the `[!]` flag
- **issues** — `[open]` entries without a `(PR: ...)` annotation (your turn to fix)
- **in PR** — `[open]` entries with a `(PR: ...)` annotation (waiting on merge)
- **stale** — `[open]` entries older than 30 days (default; configurable via `FOUND_ISSUES_STALE_DAYS`)

Each counter is hidden when zero.

If the user wants to see the actual entries, run:

```bash
found-issues status --format=json
```

…then inspect `docs/found-issues.md` directly with `Read` for the entry
text.
