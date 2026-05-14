# Statusline integration resilience — Windows, multi-branch outputs, conflict-blind parser (v1.5.0)

**Status:** approved 2026-05-13
**Supersedes (where in conflict):** `2026-05-12-custom-statusline-auto-integration-design.md` §"Note on stdin handling (Node + Python)" — the deliberate "env-var-only cwd, silent-fail otherwise" tradeoff is rescinded.

## 1. Context

A maintainer running v1.4.1 on Windows installed the plugin into a custom Node statusline (`~/.claude/hooks/gsd-statusline.js`) and saw no segment render. Manual root-cause analysis surfaced three independent bugs in the generated Node shim and the splice that injects it. A separate session running the segment against a mid-merge-conflict `docs/found-issues.md` showed inflated counts because the parser is conflict-blind. All four bugs are silent-fail: the user sees a wrong number (or no number), not an error.

The original v1.4.0 spec deliberately accepted one of these tradeoffs ("the env-var-only cwd fallback degrades to empty-segment silent-fail if absent — that matches the contract's required failure mode"). Real-world heterogeneous installs make that acceptance untenable.

## 2. Bugs to fix

### Bug 1 — Generated Node/Python shim is POSIX-only

`bin/found-issues:2171-2196` (Node) and `bin/found-issues:2314-2340` (Python). Uses `command -v found-issues`, `ls … | sort -V | tail -1`, and `process.env.HOME` / `os.environ['HOME']` — none of which exist on Windows. The bash shim (`bin/found-issues:2014-2040`) is unaffected because it runs in Git Bash on Windows, where POSIX semantics hold.

### Bug 2 — Eager cwd resolution at module load misses stdin-parsed workspace dir

Same blocks. The shim invokes `found-issues status --format=segment` at module load using `CLAUDE_PROJECT_DIR || HOME` as cwd. Claude Code does not set `CLAUDE_PROJECT_DIR` for the statusline command — the workspace dir arrives via stdin JSON (`data.workspace.current_dir`), parsed after the shim has already run. Result: cwd resolves to home, segment runs against an empty/wrong issues file, segment string is empty.

### Bug 3 — Splice patches only the first output line

`cmd_install_statusline_target_node` (line 2241), `cmd_install_statusline_target_bash` (line 2088), `cmd_install_statusline_target_python` (line 2385). Each calls `fi_find_<lang>_splice_point` which returns one line number, then `awk` patches only `NR == splice_line`. Statuslines with multiple output branches (`if (middle) console.log(A) else console.log(B)`) get the segment on one branch only — the alternate branch silently drops it.

### Bug 4 — Parser is merge-conflict-blind

`lib/parse-entries.sh:174-208`. Uses raw `grep -E '^- \[(open|deferred|fixed)\]'` against the entire file. When the issues file is mid-merge-conflict (markers `<<<<<<<`, `=======`, `>>>>>>>` present), entries inside conflict regions are counted from both branches, inflating the displayed count. Observed: statusline `13 other · 1 in PR` (= 14) vs human-deduped count of 10 — 4 phantoms from 4 conflict regions.

## 3. Root cause of "why didn't we catch this"

- **CI runs Windows but never executes the generated shim.** `tests/cli-install-statusline-custom-target.bats:234-247` uses `node --check` (syntax-only). The Windows-incompatible runtime paths parse fine and only fail when actually executed.
- **Test fixtures are 2-line single-output statuslines.** A 2-line statusline has one output line — first-match-wins splice succeeds trivially. Multi-branch statuslines have never been a fixture.
- **`doctor` is blind to custom statuslines.** `fi_statusline_state` only inspects `~/.claude/statusline.sh`. Custom-statusline integration was added in v1.4.0 without extending diagnosis to those targets.
- **No runtime health check exists.** All state detection is static text-matching against marker blocks. There is no test that asserts "the installed integration actually emits the segment in real Claude Code conditions."
- **Parser was never tested against degraded source-file states.** `tests/cli-status.bats` exercises a clean issues file; no fixture tests behavior when the file is mid-merge or otherwise broken.

## 4. Architecture: defense in depth

Three layers, each independently load-bearing. Removing any one re-opens the class of bug:

```
                ┌────────────────────────────────────────────────┐
   Layer 1 ────▶│  Robust shim + conflict-aware parser           │
   (runtime)    │  Tolerates heterogeneous setups at execution   │
                └────────────────────────────────────────────────┘
                ┌────────────────────────────────────────────────┐
   Layer 2 ────▶│  End-to-end CI on Linux + macOS + Windows      │
   (prevention) │  Generated shim actually runs; segment asserted │
                └────────────────────────────────────────────────┘
                ┌────────────────────────────────────────────────┐
   Layer 3 ────▶│  doctor with runtime probe + failure-mode      │
   (diagnosis)  │  narrowing for users when Layers 1+2 missed    │
                └────────────────────────────────────────────────┘
```

## 5. Layer 1 — Shim & parser fixes

### 5.1 Node shim block (new shape)

`fi_generate_node_marker_block` emits:

```js
// === found-issues plugin segment ===
// Cross-platform: POSIX uses PATH; Windows enumerates the plugin cache via fs.
// Invocation is deferred via __fiSeg(dir) so the splice point can pass the
// real workspace dir (parsed from stdin by the host statusline). When dir is
// unavailable, falls back through env (CLAUDE_PROJECT_DIR, PWD) then home.
let __fiCli = null;
function __fiSeg(dir) {
  if (!__fiCli) return '';
  try {
    const { execFileSync } = require('child_process');
    const cwd = dir
      || process.env.CLAUDE_PROJECT_DIR
      || process.env.PWD
      || require('os').homedir();
    if (process.platform === 'win32') {
      const posixPath = __fiCli.replace(/\\/g, '/');
      return execFileSync('bash', ['-c', `"${posixPath}" status --format=segment`],
        { cwd, encoding: 'utf8', timeout: 5000 }).trim();
    }
    return execFileSync(__fiCli, ['status', '--format=segment'],
      { cwd, encoding: 'utf8', timeout: 5000 }).trim();
  } catch (e) { return ''; }
}
try {
  const _path = require('path');
  const _fs = require('fs');
  const _os = require('os');
  if (process.platform !== 'win32') {
    try {
      require('child_process').execSync('command -v found-issues', { stdio: 'ignore' });
      __fiCli = 'found-issues';
    } catch (e) { /* fall through */ }
  }
  if (!__fiCli) {
    const cacheRoot = _path.join(_os.homedir(), '.claude', 'plugins', 'cache');
    if (_fs.existsSync(cacheRoot)) {
      const candidates = [];
      for (const mkt of _fs.readdirSync(cacheRoot)) {
        const fiDir = _path.join(cacheRoot, mkt, 'found-issues');
        if (!_fs.existsSync(fiDir)) continue;
        for (const ver of _fs.readdirSync(fiDir)) {
          const bin = _path.join(fiDir, ver, 'bin', 'found-issues');
          if (_fs.existsSync(bin)) candidates.push({ ver, bin });
        }
      }
      candidates.sort((a, b) => a.ver.localeCompare(b.ver, undefined, { numeric: true }));
      if (candidates.length) __fiCli = candidates[candidates.length - 1].bin;
    }
  }
} catch (e) { /* silent: never break the statusline */ }
// === end found-issues plugin segment ===
```

Key changes from the v1.4.0/v1.4.1 form:

- Uses `os.homedir()` instead of `process.env.HOME` (Windows-safe).
- Enumerates plugin cache via `fs.readdirSync` instead of `ls | sort -V | tail -1` (no shell required).
- On Windows, invokes `bin/found-issues` via `bash -c "<posixpath>" ...` (the script needs Git Bash; cmd.exe can't run it).
- `__fiSeg` is now a **function**, not a value. Splice points must call it with parens.
- Cwd fallback chain extends to `PWD` (often set by shells) and `os.homedir()` last.

### 5.2 Splice form change

The splice injects, instead of `${__fiSeg}`:

```js
${__fiSeg(typeof dir !== 'undefined' ? dir : (typeof cwd !== 'undefined' ? cwd : undefined))}
```

This opportunistically captures whichever workspace-dir variable the host statusline has in scope. `dir` and `cwd` are by far the most common names (the GSD statusline, claude-hud, and most dotfiles-managed statuslines use one of them). Falls through to env-only resolution if neither is in scope.

Splice point detection (`fi_find_node_splice_point`) is also updated to return **all line numbers** matching the highest-priority pattern, not just the first. The awk splicer iterates the set, patching every output line.

### 5.3 Python shim block (new shape)

Parallel change to `fi_generate_python_marker_block`. Specifically:

- Replace `_fi_os.environ.get('HOME', '.')` with `pathlib.Path.home()`.
- Replace `_fi_glob.glob('~/.claude/plugins/cache/*/found-issues/*/bin/found-issues')` with a direct directory walk using `pathlib`, sorted by version.
- Add a `platform.system() == 'Windows'` branch that invokes `bin/found-issues` via `subprocess.run(['bash', '-c', f'"{posix_path}" status --format=segment'], ...)` — same Git Bash invocation pattern as Node.
- Convert `_fi_seg` from a module-scope string into a module-scope function `_fi_seg(_dir=None)`. The function holds the resolved `_fi_cli` binary path in a module-level variable and is callable lazily.

**Python splice form** (auto-applied by `install-statusline --target`):

```python
{_fi_seg(locals().get('dir') or locals().get('cwd'))}
```

`locals()` introspection inside an f-string is supported in CPython 3.6+ and works because the f-string is interpolated in the scope of the print call. `locals().get('dir')` returns `None` if `dir` isn't defined, which then short-circuits to `cwd`, which then short-circuits to `None`, which the function treats as "no dir given — use env fallback." Identical semantics to the Node form, mechanically different because Python f-strings don't have `typeof`.

The function signature `_fi_seg(_dir=None)` uses a leading-underscore parameter to avoid colliding with Python's built-in `dir()`.

### 5.4 Bash shim block

The bash form already reads `$input` (statusline stdin convention) via jq. It is **left unchanged** — the existing two-tier cwd resolution (`CLAUDE_PROJECT_DIR` → `$input` JSON) is correct for bash. The multi-line splice fix (5.5) still applies.

### 5.5 Multi-line splice (Bug 3 fix, all three languages)

`fi_find_<lang>_splice_point` returns a newline-separated list of line numbers matching the highest-priority pattern in the file. The awk splicer is rewritten to use an `in splice_lines` set membership test instead of `NR == splice_line`. Each matched line gets the same transform applied independently.

Priority order is preserved — if pattern 1 matches at lines 50 and 100, both are patched. If pattern 1 matches nowhere but pattern 2 matches at lines 30 and 80, both pattern-2 lines are patched. We do not mix priorities within a file.

### 5.6 Parser conflict-awareness (Bug 4 fix)

`fi_entries` (and downstream counters in `lib/parse-entries.sh`) gain conflict-marker skipping:

```bash
awk -v pat="$pattern" '
  /^<<<<<<< / { in_conflict = 1; next }
  /^>>>>>>> / { in_conflict = 0; next }
  /^=======$/ && in_conflict { next }
  !in_conflict && $0 ~ pat { print }
' "$file"
```

Lines inside `<<<<<<< … >>>>>>>` regions are excluded from the count. The deduplication is conservative — if both branches of a conflict region contain different valid entries, both are dropped. This matches the principle "during a conflict, show fewer entries than reality rather than more."

New helper `fi_has_conflict_markers` returns 0 iff the file contains any conflict marker line. This is exposed to:

- `cmd_status --format=segment`: when conflict detected, return the (skipping-applied) count as normal. **No stderr output** — the segment contract forbids stderr in normal operation, and the segment command should not assume a TTY.
- `cmd_doctor`: the source-file health check (§7.1 step 1) calls this and reports prominently if conflicts are present.

### 5.7 Idempotent re-install / migration

`install-statusline` (and `install-statusline --target`) detects v1.4.0/v1.4.1 marker blocks and auto-migrates:

- **Node detection signature:** marker block contains `process.env.HOME` OR `command -v found-issues` (the new form has neither, replaced by `os.homedir()` and a platform check).
- **Python detection signature:** marker block contains `_fi_os.environ.get('HOME'` or `_fi_shutil.which` without the `platform.system()` Windows check.
- **Bash:** no migration needed (existing shim is correct).

The migration path mirrors the existing v1.0.0/1.0.1→v1.0.2+ migration in `fi_statusline_state`: detect a "broken" sub-state, surface it in `doctor`, and offer automatic rewrite-in-place with timestamped backup.

## 6. Layer 2 — End-to-end CI

### 6.1 New test group: `Group 5 — Runtime end-to-end`

Added to `tests/cli-install-statusline-custom-target.bats`. For each language × OS combination, the test:

1. Seeds a tmp `.found-issues.md` with one `[open]` entry.
2. Generates a synthetic statusline fixture with **multiple output branches** (see 6.2).
3. Runs `install-statusline --target tmp/sl.<ext> --apply`.
4. Pipes a synthetic Claude Code stdin payload into the installed statusline:
   ```json
   {"model":{"display_name":"Test"},"workspace":{"current_dir":"<tmp>"},"session_id":"t","context_window":{"remaining_percentage":50}}
   ```
5. Triggers each output branch (by varying the stdin payload).
6. Asserts the segment string ` | 1 issue` appears in stdout **for every triggered branch**.

This runs on Linux, macOS, and Windows in the existing matrix. Windows runs through Git Bash for the test harness, but `node tmp/sl.js` runs the Node binary directly with no bash mediation — exercising the real cross-platform code path.

### 6.2 Multi-branch fixture (Node example)

```js
#!/usr/bin/env node
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(0, 'utf8'));
const dir = data.workspace?.current_dir || process.cwd();
const branch = data.session_id ? 'A' : 'B';
console.log(`branch-${branch} | ${dir}`);
```

Two paths through, gated on `data.session_id`. Both should emit the segment post-install.

### 6.3 Conflict-blind parser regression test

Added to `tests/cli-status.bats`. Seeds a `.found-issues.md` with:

```markdown
- [open] 2026-05-01 a.ts:1 — real entry 1
<<<<<<< HEAD
- [open] 2026-05-02 b.ts:1 — branch HEAD version
=======
- [fixed] 2026-05-02 b.ts:1 — branch OTHER version
>>>>>>> other
- [open] 2026-05-03 c.ts:1 — real entry 2
```

Asserts `found-issues status --format=segment` reports 2 open issues (entries inside the conflict block are skipped), not 4 (entries from both branches counted). Asserts `fi_has_conflict_markers` returns 0.

### 6.4 What we are NOT adding

- No fuzz testing of arbitrary statusline shapes — the splice contract requires specific patterns and we cannot reasonably defend against unbounded user creativity. Manual install via the AI fallback covers the long tail.
- No "user statusline emits JSON" handling — explicit `exit 18` remains; this is out of scope.

## 7. Layer 3 — `doctor` extension

### 7.1 New diagnostic pipeline

`cmd_doctor` extends with a `== Statusline runtime probe ==` section that runs **after** the existing static checks. The probe pipeline:

1. **Source file health.** Locate `docs/found-issues.md` or `.found-issues.md` per `fi_find_issues_file`. Check for merge conflict markers via `fi_has_conflict_markers`. If found, emit a `FAIL`-level finding with the line numbers of the markers. Continue probing — binary resolution and static state checks remain useful — but mark the final runtime probe (step 5) as `INCONCLUSIVE` rather than `OK`/`FAIL`, since count-based assertions cannot be trusted while the source file is degraded.

2. **Binary resolution.** Verify `found-issues` is reachable: PATH lookup AND plugin-cache enumeration. Report which path resolved.

3. **Statusline file location.** Read `~/.claude/settings.json` for `statusLine.command`. Determine the target file (canonical `~/.claude/statusline.sh`, or custom path). If JSON statusline (no command file), surface as `WARN` — runtime probe is skipped.

4. **Static marker state.** Extended `fi_statusline_state` accepts an optional target-path and language argument. Reports `installed-fixed` / `installed-broken-posix` (new v1.4.x marker) / `installed-broken-cwd` / `installed-broken-no-cwd` / `none`. Mirrors the existing canonical-bash logic for Node and Python target files.

5. **Runtime probe.** Build a synthetic Claude Code stdin payload (workspace.current_dir = the user's repo cwd). Pipe into the user's statusline command with a 5-second timeout. Capture stdout. Search for the locked segment substring (` | ` followed by a digit, per the contract).

6. **Failure-mode narrowing.** If the runtime probe shows an empty segment despite step 4 reporting `installed-fixed`:
   - Sub-probe (a): does `found-issues status --format=segment` from the same cwd produce a non-empty result? → if no, cwd resolution is the cause.
   - Sub-probe (b): grep the statusline file for the splice trailer comment (`// found-issues:seg` for Node, `# found-issues:seg` for bash/python) and count occurrences. Compare against the count of output statements (`console.log` / `print` / `echo`) using the existing splice-point heuristics. If the splice marker count is less than the output statement count, report **splice gap** and list which output lines are unpatched.
   - Sub-probe (c): force-run the statusline with `node --inspect` or `bash -x` and capture stderr — surface unexpected runtime errors.

Each finding gets one of three severities: `OK` (probe passes), `WARN` (degraded but functioning, e.g. JSON statusline), `FAIL` (segment not rendering).

### 7.2 New subcommand: `doctor-statusline-runtime`

A standalone form that runs just §7.1 without the rest of `doctor`. Useful for iterative debugging by the user or by AI agents helping them. Implementation reuses the same probe pipeline. Read-only; never modifies files.

### 7.3 What we are NOT adding to doctor

- No interactive repair — `doctor` remains read-only. Repair goes through `install-statusline --migrate` or AI-mediated edit per the existing flow.
- No telemetry / phone-home. Doctor output is local-only.

## 8. Migration story (for existing v1.4.0 / v1.4.1 installs)

When a user upgrades the plugin to v1.5.0:

- **SessionStart hook** (no change) — issues file is loaded.
- **First time** the user runs any of `/found-issues:setup`, `found-issues install-statusline`, or `found-issues doctor`, the v1.4.x marker block is detected (signatures in §5.7) and a clear message is emitted:
  > "Your statusline integration was installed with v1.4.x and uses the pre-Windows-fix shim. Run `found-issues install-statusline --migrate` (or `--target <path> --migrate` for custom statuslines) to update in place. A timestamped backup will be saved."

- The auto-migrate path runs the new install-statusline flow, which replaces the marker block AND the splice form atomically. The contract change (`${__fiSeg}` → `${__fiSeg(...)}`) is handled by the splice rewriter.

For users with file-shape changes (chezmoi etc.), the existing symlink warning fires; a follow-up note in CHANGELOG advises re-running `--migrate` after each dotfiles sync until v1.5.0+ is propagated everywhere.

## 9. Contract changes

| Contract | Before | After v1.5.0 |
|---|---|---|
| `--format=segment` output shape | Locked (frozen surface) | Unchanged. Locked. |
| Marker block exposed identifier | `__fiSeg` as a value | `__fiSeg` as a function. **Breaking inside the marker contract**, but the marker contract is internal — users do not write code that references `__fiSeg` directly. |
| Splice form (Node) | `${__fiSeg}` | `${__fiSeg(typeof dir!=='undefined'?dir:(typeof cwd!=='undefined'?cwd:undefined))}` |
| Splice form (Python) | `{_fi_seg}` | `{_fi_seg(locals().get('dir') or locals().get('cwd'))}` |
| Splice form (Bash) | `${__FI_SEG}` (value) | `${__FI_SEG}` (value, unchanged — bash already deferred via `$input` jq read) |
| Parser counting | Counts every grep match | Skips lines inside conflict-marker regions |
| `doctor` output | Static state only | Static state + runtime probe |

The `--format=segment` *output* contract from `docs/statusline-integration-contract.md` is **not** modified. Only the internal marker-block and splice contract changes. No `segment-v2` format is introduced; the segment surface stays frozen.

## 10. Versioning

This is a **MINOR** bump (v1.4.1 → v1.5.0) per `docs/versioning.md` rules:

- Additions: `doctor` runtime probe, `doctor-statusline-runtime` subcommand, `fi_has_conflict_markers` helper, conflict-blind parser fixed (behaviour change but additive: existing users get *more accurate* counts, no API change).
- No breaking changes to public CLI surface.
- Marker-block contract change is internal and migration-mediated.

## 11. Testing strategy summary

| Test group | Location | Coverage |
|---|---|---|
| Cross-platform shim runtime | `tests/cli-install-statusline-custom-target.bats` (new Group 5) | Generated shim runs end-to-end on Linux + macOS + Windows for bash / node / python. |
| Multi-branch splice | Same file, extended Group 2 | Splice patches every output branch, not just the first. |
| Parser conflict-skip | `tests/cli-status.bats` (new tests) | Counts exclude conflict-region entries. |
| Migration detection | `tests/cli-install-statusline-custom-target.bats` (new) | Old v1.4.x marker block detected as broken; `--migrate` rewrites successfully with backup. |
| Doctor runtime probe | `tests/cli-doctor.bats` (new file) | Each failure mode (binary, cwd, splice gap, conflict) produces the documented narrowing diagnostic. |
| Segment contract | `tests/contract-segment.bats` (unchanged) | Output bytes remain frozen. |

## 12. Out of scope / future work

- **`--format=segment-v2` with explicit cwd arg.** Discussed and deferred — see brainstorming session. Revisit if a third cwd-failure mode emerges in the next year.
- **JSON statusline support.** Still exits 18 with manual instructions. Separate spec when prioritized.
- **Statuslines in deno / bun / TypeScript / fish.** Manual install via AI fallback. Add language detection only if user demand emerges.
- **Telemetry on segment failures.** Out of scope; no phone-home in this plugin by design.

## 13. Estimated work

| Task | Files | Rough size |
|---|---|---|
| Layer 1 — Node shim rewrite | `bin/found-issues:2171-2196` | ~50 lines |
| Layer 1 — Python shim rewrite | `bin/found-issues:2314-2340` | ~50 lines |
| Layer 1 — Multi-line splice (3 langs) | `bin/found-issues` find/awk blocks | ~80 lines |
| Layer 1 — Parser conflict-awareness | `lib/parse-entries.sh` | ~30 lines |
| Layer 1 — Migration detection | `bin/found-issues` (`fi_statusline_state` extension) | ~40 lines |
| Layer 2 — CI tests | `tests/cli-install-statusline-custom-target.bats`, `tests/cli-status.bats` | ~150 lines |
| Layer 3 — Doctor runtime probe | `bin/found-issues` (`cmd_doctor` extension + `cmd_doctor_statusline_runtime`) | ~120 lines |
| Layer 3 — Doctor tests | `tests/cli-doctor.bats` (new) | ~80 lines |
| CHANGELOG + version bump | `CHANGELOG.md`, `bin/found-issues:FI_VERSION`, `.claude-plugin/plugin.json` | trivial |
| Release coupling | Marketplace PR in `AltDoug/claude-plugins` after merge here | trivial |

Total: ~600 lines of code + tests. Single working session is realistic.

## 14. References

- `docs/statusline-integration-contract.md` — segment output surface (unchanged).
- `docs/superpowers/specs/2026-05-12-custom-statusline-auto-integration-design.md` — v1.4.0 design that introduced the now-superseded "env-var-only cwd, silent-fail otherwise" tradeoff.
- `docs/found-issues.md` — running tracker; this work folds in the parser conflict-blindness issue surfaced 2026-05-13.
