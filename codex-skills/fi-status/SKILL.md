---
name: fi-status
description: Print the current open / in-PR / critical / stale counts
---
<!-- loc-override: generated 1:1 from commands/status.md by scripts/gen-codex-skills.sh; length is owned by the source command file -->

Show the current state of the found-issues file in this repo.

## What to do

```bash
found-issues status --format=plain
```

If the output is empty, the repo has no open entries. Tell the user:
*"No open found-issues entries in this repo."*

If non-empty, pass the output through verbatim. It will look like one of:

- `1 issue` — one open entry, nothing critical or in-PR (solo plain case keeps the word "issue/issues" for natural reading)
- `2 critical · 5 other · 3 in PR · 1 stale` — full layout (the residual bucket is labeled "other" whenever critical / in PR / stale is also displayed, so the counts add up cleanly to total open)

The four counters mean:
- **critical** — `[open]` entries with the `[!]` flag
- **other / issues** — `[open]` entries without a `(PR: ...)` annotation and without the `[!]` flag (your turn to fix). Labeled "issue/issues" when it's the only counter; relabeled "other" when critical / in PR / stale is also showing, so the residual interpretation is unambiguous.
- **in PR** — `[open]` entries with a `(PR: ...)` annotation (waiting on merge)
- **stale** — `[open]` entries older than 30 days (default; configurable via `FOUND_ISSUES_STALE_DAYS`)

Each counter is hidden when zero. The JSON format still emits the residual as `"issues"` (backwards compat for external tooling).

If the user wants to see the actual entries, run:

```bash
found-issues status --format=json
```

…then inspect `docs/found-issues.md` directly with `Read` for the entry
text.
