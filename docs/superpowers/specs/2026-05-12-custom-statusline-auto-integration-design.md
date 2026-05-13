# Custom-Statusline Auto-Integration — Design

**Date:** 2026-05-12
**Status:** Approved; awaiting implementation plan
**Author:** Claude Opus 4.7 (1M context) + Diogo Silva Sena (AltDoug)
**Related:** Public contract — [`docs/statusline-integration-contract.md`](../../statusline-integration-contract.md); contract tests — [`tests/contract-segment.bats`](../../../tests/contract-segment.bats); detection prior art — PR [#78](https://github.com/AltDoug/found-issues/pull/78); brainstorming session 2026-05-12

## Problem statement

`/found-issues:setup` already detects three statusline configurations (`STATUSLINE_AT_CONVENTION`, `STATUSLINE_CUSTOM_ELSEWHERE`, `STATUSLINE_DEFAULT`) via `~/.claude/settings.json` parsing. The first and third paths offer the user a one-click integration via `found-issues install-statusline`. The middle path — user has a custom statusline script at a non-canonical location, e.g. `~/.claude/hooks/gsd-statusline.js` — currently shows manual instructions and skips. The user is left to splice the call themselves.

Empirically this matters: the maintainer's own Windows setup hit this branch during a fresh install of v1.3.0, and any user with a personal statusline script (claude-hud, GSD statusline, dotfiles-managed scripts, custom Node/Python statuslines) hits it too. Every such user gets the SessionStart hook count but no inline statusline counter — a visible feature regression relative to the canonical path.

The fix is an opt-in flow that splices the segment call into the user's existing statusline script automatically, preserving every safety property the canonical install gives users today: idempotency, timestamped backup, atomic write, pure-CLI uninstall, the contract surface untouched.

## Goals

1. **Parity with canonical install for users with custom statuslines.** After auto-integration, the inline counter renders in their statusline exactly as it would on a `~/.claude/statusline.sh` install.
2. **Multi-language support: bash/sh, Node, Python.** Three known languages cover the realistic majority; per-language splice via deterministic CLI heuristics.
3. **Minimal new tool permissions.** Existing `Bash(found-issues:*), Read` covers the primary flow end-to-end. `Edit` is added to `commands/setup.md` allowed-tools to enable AI-mediated fallback paths (splice point not found, multiple existing splices, markers stripped). Usage discipline (spec'd in setup.md prose): `Edit` is invoked ONLY when CLI returns an exit code that routes to an AI fallback, never as part of the happy path.
4. **Idempotent + reversible by default.** Re-running setup never double-installs; `uninstall-statusline --target <path>` reverts to byte-equal pre-install state.
5. **Contract surface untouched.** Every splice still calls `found-issues status --format=segment`. The 12 contract tests in `tests/contract-segment.bats` remain the load-bearing guarantee.
6. **Show diff before write.** User opts in via the setup picker, sees a real unified diff of the proposed edit, then second-confirms before any modification lands.

## Non-goals

- **Languages outside bash/sh/node/python.** Ruby, fish, Crystal, Rust binaries, etc. fall through to the existing manual-instructions branch. Add only if a real user surfaces the need.
- **JSON-output statuslines.** Claude Code's statusline contract allows `{"first_line": "...", "second_line": "..."}` JSON output; splicing into JSON producers is structurally different and deferred. Detected and explicitly rejected (`json_statusline_unsupported`).
- **AI-mediated splice as the primary path.** The AI orchestrates (detects, runs CLI, shows diff, confirms) but does not directly Edit the user's file in the happy path. CLI does the file write. AI Edit is reserved for fallback paths only (CLI exit codes 11, 16, 17).
- **Settings.json modification.** We do not touch `statusLine.command`. The user's custom path stays where they set it; we only modify the script file at that path.
- **Auto-detection without user opt-in.** Even when the picker option is offered, the splice never runs without explicit user yes (picker pick + diff confirm = two yeses).
- **Backwards-incompatible CLI changes.** `found-issues install-statusline` with no flags continues to work exactly as today on the canonical path. `--target` is the new opt-in surface.

## Design decisions

| Decision | Choice | Rationale |
|---|---|---|
| Who writes the file | **CLI** (`install-statusline --target <path> --apply`) | Testable via bats; mirrors canonical install architecture; pure-shell uninstall stays possible |
| AI's role | **Orchestrator** (detect, run CLI `--dry-run`, show diff, get confirm, run CLI `--apply`) | Honors "AI-mediated" direction without sacrificing testability |
| Confirmation UX | **Two yeses**: picker yes → diff shown → second confirm → apply | User sees exactly what's about to change; matches Claude Code Edit-tool expectations |
| Backup before write | **Always** — `<path>.fi-bak-<YYYYMMDD-HHMMSS>` | Matches canonical install pattern; near-zero cost; one-`mv` recovery |
| Atomic write | **tmp + fsync + rename** — `<path>.fi-tmp-<ts>` → `<path>` | No partial-write window; matches canonical pattern |
| Marker syntax | **Per-language**: `# === found-issues plugin segment ===` (bash, python), `// === found-issues plugin segment ===` (node) | Comment syntax must match language; marker text stays consistent for cross-language doctor/grep |
| Reference splice marker | **Inline trailing comment** — `# found-issues:seg` / `// found-issues:seg` on the line containing the variable reference | Lets uninstall identify the modified output line unambiguously without scanning for our variable name |
| Uninstall primary path | **Pure CLI** — `uninstall-statusline --target <path>` finds marker block + reference splice, removes both | No AI required; works from any shell; matches canonical UX |
| Uninstall fallback (markers stripped) | **AI-mediated** — if markers absent but invocation signature present, setup.md offers Edit-based cleanup | Belt-and-suspenders per [[markers-stripped-hybrid]]; rare path, contained to setup.md |
| Tool permission expansion | **Add `Edit` to setup.md allowed-tools** — only invoked in the markers-stripped repair path | One cohesive integration story; documented as scope-limited |
| Version impact | **Minor bump (v1.3.x → v1.4.0)** | New user-facing CLI flag + new setup branch; non-breaking; aligns with prior minor-bump precedent |

## Architecture

### New CLI surface

```
found-issues install-statusline [--target <path> --language=<auto|bash|node|python>] [--dry-run|--apply]
```

- **Flag-less invocation:** unchanged — operates on `~/.claude/statusline.sh` as today
- **`--target <path>`:** opt into custom-path mode; required to be a writable file (or non-existent path that the user wants us to create, though MVP only supports modifying existing scripts — see Non-goals)
- **`--language=auto`:** detect from file extension + shebang. `auto` is the default when `--target` is supplied
- **`--dry-run`:** read the target, identify splice point, generate proposed edit, print unified diff to stdout, exit 0
- **`--apply`:** same as `--dry-run` but also write timestamped backup, perform atomic write of the modified content

```
found-issues uninstall-statusline [--target <path>]
```

- **Flag-less:** unchanged — operates on `~/.claude/statusline.sh`
- **`--target <path>`:** locate marker block + reference splice in the custom file, remove both. Exits 0 if file was never installed (safe to run blindly). Exits 17 (`markers_missing_but_invocation_present`) if the invocation signature is found but markers are absent — signal for setup.md's AI fallback.

### Setup.md flow extension

The existing `STATUSLINE_CUSTOM_ELSEWHERE` branch in `commands/setup.md` (currently lines 130-140) becomes:

```
1. Detect language from $custom_cmd_expanded:
   - .sh, .bash → bash
   - .js, .mjs, .cjs → node
   - .py → python
   - shebang line override if present
   - else → exit 10 unsupported; show existing manual-instructions message

2. Surface picker option (NOT omit it as today):
   "Statusline integration (custom path) (Recommended)"
   "Add the found-issues counter to your custom statusline at <path>"

3. On user yes:
   a. found-issues install-statusline --target <path> --language=<X> --dry-run
   b. Print "Here's what I'd add to <path>:" + the diff
   c. AskUserQuestion: "Apply this edit?" → yes/no
   d. On yes: found-issues install-statusline --target <path> --language=<X> --apply
   e. Report success + "restart your Claude Code session to see it render"

4. On apply error (any non-zero exit code), branch by exit code:
   - 11 splice_point_not_found → offer AI-mediated splice (Edit-based)
   - 13/14 permissions → print actionable error, abort
   - 16 multiple_splices_detected → offer AI repair path
   - others → print error context, abort
```

### Per-language splice mechanics

#### Bash / sh

Detected by: `.sh`, `.bash` extension OR shebang matching `/bin/sh`, `bash`, `zsh`.

**Marker block** inserted after the shebang and any leading `set -*` lines, before the first non-comment statement. Mirrors the canonical install's PATH-resilience and cwd resolution patterns:

```bash
# === found-issues plugin segment ===
# Tries `found-issues` on PATH first; falls back to globbing the plugin cache
# for the latest installed binary (statusline subprocess may not inherit the
# plugin's auto-PATH).
__FI_CLI=""
if command -v found-issues >/dev/null 2>&1; then
  __FI_CLI=found-issues
else
  __FI_CLI=$(ls -d "$HOME"/.claude/plugins/cache/*/found-issues/*/bin/found-issues 2>/dev/null | sort -V | tail -1 || true)
  [[ -x "$__FI_CLI" ]] || __FI_CLI=""
fi
# Cwd resolution: prefer CLAUDE_PROJECT_DIR (env var, when Claude Code sets it);
# fall back to the conventional `$input` JSON variable if user's script populated
# it before this block; otherwise the call runs from $HOME and segment renders
# empty (silent-fail per contract).
__FI_DIR="${CLAUDE_PROJECT_DIR:-}"
if [[ -z "$__FI_DIR" && -n "${input:-}" ]] && command -v jq >/dev/null 2>&1; then
  __FI_DIR=$(echo "$input" | jq -r '.workspace.current_dir // ""' 2>/dev/null || true)
fi
__FI_SEG=""
if [[ -n "$__FI_CLI" ]]; then
  if [[ -n "$__FI_DIR" ]]; then
    __FI_SEG=$( cd "$__FI_DIR" 2>/dev/null && "$__FI_CLI" status --format=segment 2>/dev/null || true )
  else
    __FI_SEG=$("$__FI_CLI" status --format=segment 2>/dev/null || true)
  fi
fi
# === end found-issues plugin segment ===
```

**Reference splice heuristic**, in priority order:
1. First `LINE1=...` assignment → append `${__FI_SEG}` to its rvalue
2. First `printf` or `echo` after the marker block → append `${__FI_SEG}` to last string argument
3. None matched → exit 11 `splice_point_not_found`

#### Node

Detected by: `.js`, `.mjs`, `.cjs` extension OR shebang matching `node`.

**Marker block** inserted after any leading `import` or `const ... = require(...)` lines:

```javascript
// === found-issues plugin segment ===
// PATH-resilience: try `found-issues` on PATH, fall back to plugin cache glob.
// Cwd resolution: prefer CLAUDE_PROJECT_DIR; fall back to $HOME (segment may
// render empty if cwd doesn't contain docs/found-issues.md — silent-fail per contract).
let __fiSeg = '';
try {
  const { execSync } = require('child_process');
  const path = require('path');
  const fs = require('fs');
  let __fiCli = 'found-issues';
  try { execSync('command -v found-issues', { stdio: 'ignore' }); }
  catch (e) {
    // Glob plugin cache for newest installed binary
    const cacheGlob = path.join(process.env.HOME, '.claude/plugins/cache');
    try {
      const candidates = require('child_process')
        .execSync(`ls -d ${cacheGlob}/*/found-issues/*/bin/found-issues 2>/dev/null | sort -V | tail -1`, { encoding: 'utf8' })
        .trim();
      if (candidates && fs.existsSync(candidates)) __fiCli = candidates;
      else throw new Error('no found-issues binary');
    } catch (e2) { throw e2; }
  }
  const cwd = process.env.CLAUDE_PROJECT_DIR || process.env.HOME;
  __fiSeg = execSync(`"${__fiCli}" status --format=segment`, { cwd, encoding: 'utf8', timeout: 5000 }).trim();
} catch (e) {}
// === end found-issues plugin segment ===
```

**Reference splice heuristic**, in priority order:
1. First `console.log(\`...\`)` template literal → inject `${__fiSeg}` before closing backtick
2. First `console.log('...')` or `console.log("...")` with plain string → change to `console.log('...' + __fiSeg)`
3. First `process.stdout.write(...)` → same pattern
4. None matched → exit 11

#### Python

Detected by: `.py` extension OR shebang matching `python`/`python3`.

**Marker block** inserted after any leading `import`/`from ... import` statements:

```python
# === found-issues plugin segment ===
# PATH-resilience: prefer `found-issues` on PATH; fall back to plugin cache glob.
# Cwd resolution: prefer CLAUDE_PROJECT_DIR; fall back to $HOME (segment may
# render empty if cwd doesn't contain docs/found-issues.md — silent-fail per contract).
import subprocess as _fi_subprocess
import shutil as _fi_shutil
import glob as _fi_glob
import os as _fi_os
_fi_seg = ''
try:
    _fi_cli = _fi_shutil.which('found-issues')
    if not _fi_cli:
        _fi_candidates = sorted(_fi_glob.glob(
            _fi_os.path.expanduser('~/.claude/plugins/cache/*/found-issues/*/bin/found-issues')
        ))
        _fi_cli = _fi_candidates[-1] if _fi_candidates else None
    if _fi_cli and _fi_os.access(_fi_cli, _fi_os.X_OK):
        _fi_cwd = _fi_os.environ.get('CLAUDE_PROJECT_DIR') or _fi_os.environ.get('HOME', '.')
        _fi_seg = _fi_subprocess.run(
            [_fi_cli, 'status', '--format=segment'],
            cwd=_fi_cwd, capture_output=True, text=True, timeout=5
        ).stdout.strip()
except Exception:
    _fi_seg = ''
# === end found-issues plugin segment ===
```

**Reference splice heuristic**, in priority order:
1. First `print(f"...")` f-string → inject `{_fi_seg}` before closing quote
2. First `print("...")` or `print('...')` plain string → change to `print("..." + _fi_seg)`
3. First `sys.stdout.write(...)` → same pattern
4. None matched → exit 11

**Note on stdin handling (Node + Python):** Unlike the canonical bash install (which reads `$input` JSON to recover the workspace cwd), the Node and Python snippets do not attempt to consume stdin. Stdin can only be read once and the user's existing statusline likely already reads it. The two-tier cwd fallback (`CLAUDE_PROJECT_DIR` → `$HOME`) degrades to empty-segment silent-fail if the env var is absent — that matches the contract's required failure mode and beats fighting the user's script for stdin.

### Cross-language invariants

- Each marker block produces a `__FI_SEG` / `__fiSeg` / `_fi_seg` variable that holds either the segment string or the empty string. Never raises, never times out beyond 5 seconds.
- Reference splice always appends — never replaces — the user's original output content. If the user has a statusline that emits `"$REPO | $BRANCH"`, post-install it emits `"$REPO | $BRANCH${__FI_SEG}"`.
- Reference splice line gets a `# found-issues:seg` (or `// found-issues:seg`) trailing comment for unambiguous uninstall identification.

### Error model

Exit codes from `install-statusline --target`:

| Code | Name | Meaning | Setup.md response |
|---|---|---|---|
| 0 | `success` (or `already_installed` for no-op) | Splice applied or already present | Report success |
| 10 | `unsupported_language` | Language not in {bash, sh, node, python} | Fall through to existing manual-instructions branch |
| 11 | `splice_point_not_found` | Heuristics tried but no splice point identified | Offer AI-mediated splice via Edit |
| 12 | `target_not_found` | File doesn't exist at path | Actionable error: settings.json points to stale path |
| 13 | `target_unreadable` | Permission denied on read | Actionable error: fix permissions |
| 14 | `target_unwritable` | Permission denied on write | Actionable error: fix permissions |
| 15 | `backup_failed` | Could not write `.fi-bak-<ts>` | Abort before modification |
| 16 | `multiple_splices_detected` (install only) | Multiple marker blocks found in target file | Offer AI repair |
| 17 | `markers_missing_but_invocation_present` (uninstall only) | Invocation signature present but no markers | Offer AI repair |
| 18 | `json_statusline_unsupported` | Script emits JSON output (detected heuristically) | Fall through to manual instructions; future work |

### Symlink behavior

If the target file is a symlink (common with dotfiles/chezmoi managed configs), `--apply` writes through the symlink and emits a stderr warning:

```
note: <path> is a symlink to <realpath>; your sync system may overwrite changes on next render
```

Setup.md relays this warning to the user. This is intentionally a warning, not a refusal — power users with sync systems can re-install after each render via a post-render hook (documented in the existing `[deferred]` found-issue entry about install-statusline render-target awareness).

## Testing strategy

### New test file: `tests/cli-install-statusline-custom-target.bats`

**Group 1 — Language detection (6 tests):** `.sh` → bash, `.bash` → bash, `.js`/`.mjs`/`.cjs` → node, `.py` → python, shebang overrides extension, unknown extension → exit 10.

**Group 2 — Splice point detection (9 tests, 3 per language):** splice found → exit 0 with expected diff; splice missing → exit 11; marker already present → exit 0 `already_installed` no-op.

**Group 3 — Apply path (6 tests):** backup written at expected path, atomic write via tmp+rename, idempotent re-apply, rollback on backup failure, resulting script runs without error, resulting script emits segment value with seeded `docs/found-issues.md`.

**Group 4 — Uninstall path (4 tests):** marker block removed cleanly, reference splice removed via `# found-issues:seg` marker, markers-missing-with-invocation → exit 17 (`markers_missing_but_invocation_present`), uninstall on never-installed file → exit 0 no-op.

### Setup flow integration test: `tests/setup-custom-statusline-flow.bats`

End-to-end: seed fake statusline in tmp dir, point `~/.claude/settings.json` at it, run detection logic, assert `STATUSLINE_CUSTOM_ELSEWHERE: <path>`, run `--dry-run`, assert diff content, run `--apply`, assert file modification + backup.

### Contract tests (no changes)

`tests/contract-segment.bats` (12 tests, already landed) keeps the segment output frozen. This work doesn't touch the segment surface.

### Manual test plan (run before release)

For each of bash/node/python:
1. Create a representative custom statusline script (bash with `LINE1=`, node with `console.log` template literal, python with `print` f-string)
2. Run setup flow end-to-end (picker → dry-run → confirm → apply)
3. Verify counter renders inline in actual Claude Code session
4. Verify `uninstall-statusline --target <path>` cleans up to byte-equal original

## Acceptance criteria

This feature is "done" when:

1. `found-issues install-statusline --target <path> --dry-run` produces a unified diff for any script in {bash, sh, node, python} with a recognized splice pattern, without modifying the file.
2. `found-issues install-statusline --target <path> --apply` writes a timestamped backup, applies the splice atomically, and exits 0.
3. Re-running `--apply` on an already-installed target is a no-op (exit 0, `already_installed`).
4. `found-issues uninstall-statusline --target <path>` reverts the file to byte-equal pre-install state.
5. `/found-issues:setup` surfaces the custom-statusline option in the picker for users on the `STATUSLINE_CUSTOM_ELSEWHERE` branch (when language is supported).
6. All bats tests in the new test files pass; all existing tests (44 in `cli-status.bats` + `cli-statusline.bats`, 12 in `tests/contract-segment.bats`) continue to pass.
7. Manual test plan validated on at least one real custom statusline of each supported language.

## Open questions

None — all design decisions locked in during brainstorming.

## References

- Contract: [`docs/statusline-integration-contract.md`](../../statusline-integration-contract.md)
- Contract tests: [`tests/contract-segment.bats`](../../../tests/contract-segment.bats)
- Custom-statusline detection (prior art): [`commands/setup.md`](../../../commands/setup.md) lines 95-126; PR [#78](https://github.com/AltDoug/found-issues/pull/78)
- Canonical install splice mechanics: [`bin/found-issues`](../../../bin/found-issues) `cmd_install_statusline` (line ~1736), `cmd_uninstall_statusline` (line ~1500), `cmd_doctor_statusline`
- Canonical install tests: [`tests/cli-statusline.bats`](../../../tests/cli-statusline.bats)
- Related future work: `[deferred]` entry in [`docs/found-issues.md`](../../found-issues.md) about install-statusline render-target awareness for sync systems
