# Runtime evidence (orchestrator, 2026-10-03)

All runs: docker `hookfork:latest` (Linux, bash 5.2, strace) with the audit worktree mounted read-only at /src; scripts in `repro-scripts/`. Hooks run with `CLAUDE_PLUGIN_ROOT=/w` (as Claude Code does) unless noted.

## Resource measurements (process creations, Linux strace)
| Event | forks | execs |
|---|---|---|
| SessionStart, real ledger (6 open) | 517 | 277 |
| statusline segment cold (autosync fired) | 485 | 263 |
| Stop (trivial transcript) | 22 | 10 |
| PreToolUse Edit, non-ledger file | 7 | 4 |
| PreToolUse/PostToolUse Bash `ls` | 0 | 1 |
| segment warm | 0 | 1 |
| `sync` (AUTO_ARCHIVE=off), 0 / 10 / 40 / 80 open entries | 57 / 812 / 3033 / 5990 | |
| `status` segment, cache off, any size | ~35 | |
Per open entry in sync: ~65 forks / ~36 execs = 11 grep, 8 sed, 6 paste, 5 head, 5 cut, 1 git (`rev-parse --show-toplevel`, loop-invariant) + ~29 `$()` subshells.

## Confirmed at runtime
| id | result (verbatim) |
|---|---|
| ledger-1 (=status-4, annot-6) | `defer c.sh:3` during a sync printed `Deferred 1 entry.`; `before sync finishes: 1` / `after sync finishes:  0` — update silently lost |
| ledger-3 | archive with one invalid-UTF-8 [open] line: `grep: /t/docs/found-issues.md: binary file matches`, `open entries left: 0` — all [open] entries deleted |
| prompt-2 | bare `annotate-pr 7` on PR touching lib/foo.sh:12 wrote `(PR: o/r#7)` onto the lib/foo.sh:900 entry; `--hook-auto` declined (`1 [open] entry not annotated — each needs judgment`) |
| prompt-17 | docs (code.claude.com/docs/en/skills): `disable-model-invocation: true` = "prevent Claude from automatically loading this skill"; skill body enters context only when invoked. This session: no rules text, no `found-issues:rules` in skill list. Rules never reach Claude sessions; only Codex gets them via session-start.sh |
| hook-2 | `git -C /t branch -D feat/x` rc=0 (control `git branch -D feat/x` rc=2) |
| hook-3 | `git branch -df feat/x` rc=0 |
| hook-4 | `git branch -D "feat/x"` rc=0 |
| hook-5 | Edit old=`[open] 2026-10-01 a.sh:1` new=`[fixed] 2026-10-01 a.sh:1` rc=0 (full-line flip control rc=2) |
| hook-8 | `echo '{"session_id":"x1"}' \| stop-reminder.sh` rc=1 |
| hook-14 | without CLAUDE_PLUGIN_ROOT (Codex): `readlink -f found-issues` resolves against CWD → `lib_dir=/t/../lib` → pre-branch-delete AND format-enforcer `exit 0` for everything (both guards dead on Codex/Linux+Git Bash) |
| cli-2 | `log 'docs/my notes.md:12 — stale'` twice → 2 entries |
| cli-3 | `log 'src/a.py:10 — parse() raises on unicode'` → `Skipped — already logged: ... parse() returns None` |
| cli-4 | `log "a.sh:5 — regression from (commit: <HEAD>)"` then sync → `Synced. Closed: 1 (0 PR + 1 commit + 0 tombstone).` |
| cli-5 | `uninstall --help` deleted ~/.claude/found-issues and ~/.cache/found-issues |
| cli-19 | PyYAML rejects frontmatter of fi-annotate-commit, fi-annotate-pr, fi-fix, fi-log, fi-sync (`mapping values are not allowed here`) |
| status-1 | cache dir unwritable: `spawns over 5 renders: 5` |
| status-3 | autosync ran in `/`; `CLAUDE_PROJECT_DIR=/t found-issues sync` from / → `sync: no found-issues.md found` |
| status-5 | after install+uninstall --target on node `console.log("x");`, `__fiSeg(` call remains, function block gone |
| status-6 | start marker without end marker: install-statusline deleted user lines (`keep-me` count 0), 0 `.fi-bak` backups |
| status-8 | canonical `install-statusline --dry-run` wrote the marker block into ~/.claude/statusline.sh |
| ledger-7 | gh present, jq absent: merged PR → `Synced. Nothing to close.` (with jq: `Closed: 1`) |

## Refuted at runtime
- ledger-4: mawk 1.3.4 20250131 supports `{4}` intervals (`match` → 30, same as gawk). Older 20200120 unverified; low.
