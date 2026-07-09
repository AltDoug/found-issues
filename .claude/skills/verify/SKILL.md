---
name: verify
description: Drive found-issues CLI changes end-to-end — build/launch/drive recipe for verifying bin/found-issues, hooks, and statusline integrations at their real surfaces.
---

# Verifying found-issues changes

The surface is the CLI (`bin/found-issues <subcommand>`) plus, for statusline
work, the *generated shim executed with synthetic Claude Code stdin*. Tests
passing is CI's job — verification means running the binary against a real
scratch repo and reading its output.

## Scratch-repo harness

```bash
FI=/path/to/repo/bin/found-issues            # co-located lib/ resolves from here
export FOUND_ISSUES_SEGMENT_AUTOSYNC=off      # stop background sync racing rm -rf
W="$(mktemp -d)" && cd "$W" && git init -q -b main
printf -- '- [open] %s a.ts:1 — verify entry\n' "$(date +%Y-%m-%d)" > .found-issues.md
```

- Always use a **dynamic date** in fixture entries — hardcoded dates cross the
  30-day stale threshold and change the rendered label (`1 issue` → `1 other · 1 stale`).
- Never run the binary via `git show <rev>:bin/found-issues > f` — it sources
  `../lib/*.sh` relative to its own path and dies silently. Use a worktree.

## Statusline shims

Install/migrate, then EXECUTE the result with Claude Code's stdin shape:

```bash
"$FI" install-statusline --target "$W/sl.sh" --apply
printf '{"workspace":{"current_dir":"%s"}}' "$W" | bash sl.sh      # bash
... | FOUND_ISSUES_BIN="$FI" node sl.js                             # node
... | FOUND_ISSUES_BIN="$FI" python3 sl.py                          # python
```

Expect ` | <ansi>1 issue<reset>` appended to the host line. Probe with a
hostile `CLAUDE_PROJECT_DIR=/nonexistent` — the `--cwd` flag must win.
Validate rewritten shims with `bash -n` / `node --check` / `ast.parse`.

## Gotchas

- Measure exit codes directly (`cmd; echo $?`), never after a pipe.
- Subagents sometimes leave shims (e.g. `bin/awk`) in `bin/` — a dirty
  `bin/` shadows real tools for any test that prepends it to PATH.
- Hooks read env at fire time: test hook behavior by piping the hook's JSON
  stdin shape to `hooks/<name>.sh` inside the scratch repo.
