# Found issues

Format: `- [status] YYYY-MM-DD path:line — symptom (suggested: fix)`. Statuses: `open`, `deferred`, `fixed`.

- [open] 2026-08-01 src/loader.sh:3 — CONFIG_PATH default is relative to the cwd, breaking when the script is invoked from outside the repo root (suggested: resolve against the script dir) (PR: AltDoug/found-issues#118)
- [open] 2026-08-05 ~/.claude/hooks/example-hook.sh:10 — hook exits 0 on malformed JSON input instead of failing loudly, so a broken payload passes silently (suggested: jq empty guard with exit 2 on parse failure)
- [open] 2026-08-06 src — parser.sh and loader.sh both re-derive the repo root inline instead of sharing a helper (suggested: extract a lib/common.sh)
- [open] 2026-08-07 workflow/release-process — releases are cut by hand with no checklist, so steps get skipped between versions (suggested: write RELEASING.md with a step list)
- [open] 2026-08-08 src/parser.sh:8 — parse_line mangles entries whose symptom text itself contains a path:line token like lib/missing-file.sh:42, treating it as the entry's own path (suggested: anchor the parser to the line prefix, not the first token match)
- [open] 2026-08-09 src/parser.sh:4 — unquoted $1 in the grep call word-splits on spaces, so multi-word patterns silently match only their first word (suggested: quote the expansion)
- [open] 2026-08-10 src/loader.sh:8 — load_config sources CONFIG_PATH with no existence check, crashing on a missing file (suggested: add a [ -f ] guard before sourcing)
