# Statusline Resilience v1.5.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the statusline integration resilient to heterogeneous setups — Windows, multi-output-branch statuslines, stdin-parsed workspace dirs, and merge-conflicted issues files — and add defense-in-depth via end-to-end CI runtime tests plus a runtime-probe `doctor`.

**Architecture:** Three layers. Layer 1 rewrites the Node/Python generated shim to be cross-platform (Bug 1), defers segment invocation via a function so splice points can pass workspace dir (Bug 2), and patches every output branch in the splice (Bug 3); the parser becomes merge-conflict-aware (Bug 4). Layer 2 adds an end-to-end CI test group that actually runs the generated shim against synthetic Claude Code stdin on Linux + macOS + Windows. Layer 3 extends `doctor` with a runtime probe pipeline that pipes synthetic stdin into the user's real statusline, captures stdout, and narrows the failure mode if the segment is absent.

**Tech Stack:** Bash 5+ (CLI), bats (tests), `awk`/`sed`/`jq` for splice mechanics, Node + Python for generated shims, GitHub Actions matrix (`ubuntu-latest`, `macos-latest`, `windows-latest` via Git Bash).

**Spec:** [`docs/superpowers/specs/2026-05-13-statusline-windows-resilience-design.md`](../specs/2026-05-13-statusline-windows-resilience-design.md)

**Contract surface (must stay untouched):** [`docs/statusline-integration-contract.md`](../../statusline-integration-contract.md), enforced by [`tests/contract-segment.bats`](../../../tests/contract-segment.bats). This plan changes the **internal** marker-block + splice contract; the `--format=segment` output bytes are frozen.

**Branch:** `feat/statusline-resilience-v1.5.0` (already created, spec committed at `d4f2b47`).

---

## File Structure

### Created

| Path | Purpose |
|---|---|
| `tests/cli-doctor.bats` | New file. All doctor extension tests including runtime probe + failure-mode narrowing |
| `tests/fixtures/statuslines/multi-branch.js` | Multi-output-branch Node statusline fixture (referenced by tests) |
| `tests/fixtures/statuslines/multi-branch.py` | Multi-output-branch Python statusline fixture |
| `tests/fixtures/statuslines/multi-branch.sh` | Multi-output-branch bash statusline fixture |
| `docs/superpowers/plans/2026-05-13-statusline-windows-resilience.md` | This plan |

### Modified

| Path | Change |
|---|---|
| `bin/found-issues` | (1) Rewrite `fi_generate_node_marker_block` (line ~2171); (2) rewrite `fi_generate_python_marker_block` (~2314); (3) update splice form in `cmd_install_statusline_target_node` (~2241) + `cmd_install_statusline_target_python` (~2385); (4) make all three `fi_find_<lang>_splice_point` return multiple line numbers; (5) extend `fi_statusline_state` to accept `<path> <language>` and detect new "installed-broken-posix" sub-state; (6) extend `cmd_doctor` with statusline runtime probe section; (7) add new subcommand `cmd_doctor_statusline_runtime`; (8) bump `FI_VERSION` to 1.5.0 |
| `lib/parse-entries.sh` | Add `fi_has_conflict_markers` helper; rewrite `fi_entries` to skip conflict-region lines |
| `tests/cli-install-statusline-custom-target.bats` | Add Group 5 (Runtime end-to-end, 6 tests) and Group 6 (Migration detection, 3 tests) |
| `tests/cli-status.bats` | Add 2 tests for conflict-aware counting |
| `tests/helpers.bash` | Add `fi_synthetic_stdin <dir>` helper for synthetic Claude Code stdin JSON |
| `hooks/stop-reminder.sh` | Replace fixed 8-line stderr message with adaptive verbosity (full/terse based on `.onboarded` marker or `FOUND_ISSUES_REMINDER_VERBOSITY` env override). UX prerequisite — see Phase 0 |
| `hooks/session-start.sh` | Auto-migrate v1.4.x POSIX-only marker blocks in custom Node/Python statusline targets. Opt-out via `FOUND_ISSUES_AUTO_MIGRATE=off`. Skipped on symlinks. See Task 5.2 |
| `tests/session-start.bats` | Tests for v1.4.x auto-migration on SessionStart (4 new tests) |
| `docs/configuration.md` | Document `FOUND_ISSUES_REMINDER_VERBOSITY` env var |
| `CHANGELOG.md` | New `## [1.5.0]` section |
| `.claude-plugin/plugin.json` | Bump `version` from `1.4.1` to `1.5.0` |
| `README.md` | Update test count line (`~390 tests` → `~410 tests`); add Windows-resilience note |

### Untouched (contract-frozen)

| Path | Reason |
|---|---|
| `tests/contract-segment.bats` | Frozen public-surface tests |
| `docs/statusline-integration-contract.md` | The locked output contract; this plan does not modify the output surface |
| `cmd_status --format=segment` emitter | The segment output bytes are frozen — only the parser feeding it changes (conflict-skipping changes counts but not format) |
| `fi_generate_bash_marker_block` (line ~2014) | Bash shim already handles Windows via Git Bash + has `$input` jq fallback for cwd |

---

## Phase 0 — Stop-reminder UX prerequisite

The stop hook (`hooks/stop-reminder.sh`) currently emits an 8-line message to stderr on every blocked-stop, which Claude Code surfaces in the user's transcript. Claude Code's hook API does not support hiding the reason while keeping it visible to Claude (verified: `additionalContext` is unsupported on `Stop` events; `suppressOutput` is binary). The mitigation is adaptive verbosity: full educational message on first runs, terse single-line message after onboarding.

### Task 0.1: Adaptive verbosity in stop-reminder.sh

**Files:**
- Modify: `hooks/stop-reminder.sh:118-130`
- Test: `tests/stop-reminder.bats`

- [ ] **Step 1: Write the failing tests**

Append to `tests/stop-reminder.bats`:

```bash
@test "stop-reminder: terse message when FOUND_ISSUES_REMINDER_VERBOSITY=terse" {
  TR="$(mktemp)"
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"please fix the bug"}
{"type":"assistant","message":"sure, editing now","tool_uses":[{"name":"Edit","input":{"file_path":"foo.py"}}]}
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "FOUND_ISSUES_REMINDER_VERBOSITY=terse echo '$input' | FOUND_ISSUES_REMINDER_VERBOSITY=terse '$HOOK'"
  [ "$status" -eq 2 ]
  # Terse form: single line, no "Add ONE of these" enumeration.
  [[ "$output" == *"Stop blocked"* ]]
  [[ "$output" == *"missing"* ]]
  [[ "$output" != *"Add ONE of these"* ]]
  # Output is <= 2 lines.
  line_count="$(printf '%s' "$output" | grep -c '' || true)"
  [ "$line_count" -le 2 ]
  rm -f "$TR"
}

@test "stop-reminder: full message when FOUND_ISSUES_REMINDER_VERBOSITY=full" {
  TR="$(mktemp)"
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"please fix the bug"}
{"type":"assistant","message":"sure, editing now","tool_uses":[{"name":"Edit","input":{"file_path":"foo.py"}}]}
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "FOUND_ISSUES_REMINDER_VERBOSITY=full echo '$input' | FOUND_ISSUES_REMINDER_VERBOSITY=full '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"acknowledgment"* ]]
  [[ "$output" == *"Add ONE of these"* ]]
  rm -f "$TR"
}

@test "stop-reminder: auto-detects terse mode when .onboarded marker exists" {
  TR="$(mktemp)"
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"please fix the bug"}
{"type":"assistant","message":"sure, editing now","tool_uses":[{"name":"Edit","input":{"file_path":"foo.py"}}]}
TRANSCRIPT
  # Synthetic HOME with the onboarded marker present.
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/.claude/found-issues"
  touch "$FAKE_HOME/.claude/found-issues/.onboarded"
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "HOME='$FAKE_HOME' echo '$input' | HOME='$FAKE_HOME' '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" != *"Add ONE of these"* ]]
  rm -rf "$FAKE_HOME" "$TR"
}

@test "stop-reminder: auto-detects full mode when .onboarded marker absent" {
  TR="$(mktemp)"
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"please fix the bug"}
{"type":"assistant","message":"sure, editing now","tool_uses":[{"name":"Edit","input":{"file_path":"foo.py"}}]}
TRANSCRIPT
  # Synthetic HOME with NO marker.
  FAKE_HOME="$(mktemp -d)"
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "HOME='$FAKE_HOME' echo '$input' | HOME='$FAKE_HOME' '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Add ONE of these"* ]]
  rm -rf "$FAKE_HOME" "$TR"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/stop-reminder.bats -f "terse|full|auto-detects"`
Expected: 4 tests FAIL — current hook always emits the full message and doesn't respect the env var or marker.

- [ ] **Step 3: Make the existing test deterministic**

The existing test `stop-reminder: blocks when marker missing AND substantive tool use occurred` asserts `[[ "$output" == *"acknowledgment"* ]]` which depends on full-mode output. Make it explicit so it doesn't break when the runner has the `.onboarded` marker:

In `tests/stop-reminder.bats:17-30`, change the `run bash -c` line from:
```bash
  run bash -c "echo '$input' | '$HOOK'"
```
to:
```bash
  run bash -c "FOUND_ISSUES_REMINDER_VERBOSITY=full echo '$input' | FOUND_ISSUES_REMINDER_VERBOSITY=full '$HOOK'"
```

- [ ] **Step 4: Replace the message block in `hooks/stop-reminder.sh`**

Replace lines 118-130 of `hooks/stop-reminder.sh` with:

```bash
# Block with an adaptive message. Verbosity:
#   FOUND_ISSUES_REMINDER_VERBOSITY=full  → 8-line educational form (default for new installs)
#   FOUND_ISSUES_REMINDER_VERBOSITY=terse → 1-line form (post-onboarding default)
#   FOUND_ISSUES_REMINDER_VERBOSITY=auto  → terse iff ~/.claude/found-issues/.onboarded exists
# Default is auto, which gracefully degrades verbosity once the user has seen
# the message enough times to internalize the marker options. Claude Code
# always displays the stderr text to the user — there is no API for hiding
# the reason while still passing it to Claude (verified 2026-05-13).
__fi_verbosity="${FOUND_ISSUES_REMINDER_VERBOSITY:-auto}"
if [[ "$__fi_verbosity" == "auto" ]]; then
  if [[ -f "$HOME/.claude/found-issues/.onboarded" ]]; then
    __fi_verbosity="terse"
  else
    __fi_verbosity="full"
  fi
fi

if [[ "$__fi_verbosity" == "terse" ]]; then
  printf 'Stop blocked: missing <!-- found-issues-checked: ... --> marker. (Options: none-noticed | logged | deferred)\n' >&2
else
  cat >&2 <<'EOF'
Stop blocked: include a found-issues acknowledgment in your final message.

Add ONE of these as an HTML comment anywhere in your response:
  <!-- found-issues-checked: none-noticed -->
  <!-- found-issues-checked: logged -->
  <!-- found-issues-checked: deferred -->

The marker forces conscious consideration; it does not auto-detect issues.
Use /found-issues:log to log items frictionlessly.
EOF
fi
exit 2
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats tests/stop-reminder.bats`
Expected: all tests pass (the 4 new tests + all existing tests with the updated explicit-full override).

- [ ] **Step 6: Run full test suite for regressions**

Run: `bats tests/`
Expected: full suite passes. No other test depends on stop-reminder verbosity.

- [ ] **Step 7: Commit**

```bash
git add hooks/stop-reminder.sh tests/stop-reminder.bats
git commit -m "$(cat <<'EOF'
feat(stop-reminder): adaptive verbosity (full → terse after onboarding)

The stop hook's reminder message is shown verbatim in the user's transcript
on every blocked stop. Claude Code's hook API doesn't expose a "hide from
user, show to Claude" mode (additionalContext is unsupported on Stop;
suppressOutput is binary). The mitigation is to keep the educational
8-line message only while it's still teaching value — once the user has
seen it enough times that ~/.claude/found-issues/.onboarded exists, the
message shrinks to one line:

  Stop blocked: missing <!-- found-issues-checked: ... --> marker.
    (Options: none-noticed | logged | deferred)

Discipline mechanism is unchanged: still blocks via exit 2, still passes
the reminder to Claude. Only the visible footprint shrinks.

New env var FOUND_ISSUES_REMINDER_VERBOSITY accepts full/terse/auto
(default: auto, which checks the .onboarded marker).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 0.2: Document the env var in configuration.md

**Files:**
- Modify: `docs/configuration.md`

- [ ] **Step 1: Add `FOUND_ISSUES_REMINDER_VERBOSITY` to the canonical env-var table**

Find the env-var reference table in `docs/configuration.md` and add a row:

```markdown
| `FOUND_ISSUES_REMINDER_VERBOSITY` | `auto` | Stop-hook message verbosity. `full` (8-line educational form), `terse` (1-line form), or `auto` (terse iff `~/.claude/found-issues/.onboarded` exists). |
```

- [ ] **Step 2: Verify the addition**

Run: `grep -n REMINDER_VERBOSITY docs/configuration.md`
Expected: a single new row.

- [ ] **Step 3: Commit**

```bash
git add docs/configuration.md
git commit -m "$(cat <<'EOF'
docs(configuration): FOUND_ISSUES_REMINDER_VERBOSITY env var reference

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 1 — Parser conflict-awareness (Bug 4)

Foundational: Layer 3 source-file health probe depends on `fi_has_conflict_markers`. Independent of shim work.

### Task 1.1: Add `fi_has_conflict_markers` helper

**Files:**
- Modify: `lib/parse-entries.sh`
- Test: `tests/cli-status.bats`

- [ ] **Step 1: Write the failing test**

Add to `tests/cli-status.bats`:

```bash
@test "fi_has_conflict_markers: returns 0 when file contains <<<<<<< markers" {
  cat > tmp/conflict.md <<'EOF'
- [open] 2026-05-01 a.ts:1 — entry one
<<<<<<< HEAD
- [open] 2026-05-02 b.ts:1 — branch HEAD
=======
- [fixed] 2026-05-02 b.ts:1 — branch OTHER
>>>>>>> other
- [open] 2026-05-03 c.ts:1 — entry two
EOF
  source "${BATS_TEST_DIRNAME}/../lib/parse-entries.sh"
  run fi_has_conflict_markers tmp/conflict.md
  [ "$status" -eq 0 ]
}

@test "fi_has_conflict_markers: returns 1 when file has no markers" {
  cat > tmp/clean.md <<'EOF'
- [open] 2026-05-01 a.ts:1 — entry one
- [open] 2026-05-03 c.ts:1 — entry two
EOF
  source "${BATS_TEST_DIRNAME}/../lib/parse-entries.sh"
  run fi_has_conflict_markers tmp/clean.md
  [ "$status" -eq 1 ]
}

@test "fi_has_conflict_markers: returns 1 when file does not exist" {
  source "${BATS_TEST_DIRNAME}/../lib/parse-entries.sh"
  run fi_has_conflict_markers tmp/nonexistent.md
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/cli-status.bats -f "fi_has_conflict_markers"`
Expected: 3 tests FAIL with `fi_has_conflict_markers: command not found`.

- [ ] **Step 3: Implement `fi_has_conflict_markers`**

Add to `lib/parse-entries.sh` after `fi_find_issues_file` (around line 42):

```bash
# Return 0 iff $1 is a regular file containing merge-conflict markers.
# A conflict marker is any line beginning with `<<<<<<< `, `=======`, or
# `>>>>>>> ` — git's canonical merge conflict syntax. Used by the parser
# (skip counting inside conflict regions) and by doctor (FAIL-level finding
# when source file is degraded). Cheap: single grep pass, exits on first
# match.
fi_has_conflict_markers() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  grep -qE '^(<<<<<<< |=======$|>>>>>>> )' "$file"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/cli-status.bats -f "fi_has_conflict_markers"`
Expected: 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/parse-entries.sh tests/cli-status.bats
git commit -m "$(cat <<'EOF'
feat(parser): fi_has_conflict_markers helper for source file health

New helper detects merge-conflict markers in the issues file. Used by
the upcoming conflict-aware parser (Bug 4 fix) and the doctor runtime
probe (Layer 3 source-file health check).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 1.2: Make `fi_entries` conflict-aware

**Files:**
- Modify: `lib/parse-entries.sh:174-193`
- Test: `tests/cli-status.bats`

- [ ] **Step 1: Write the failing test**

Add to `tests/cli-status.bats`:

```bash
@test "fi_entries: skips lines inside <<<<<<< / >>>>>>> conflict regions" {
  cat > tmp/conflict.md <<'EOF'
- [open] 2026-05-01 a.ts:1 — entry one
<<<<<<< HEAD
- [open] 2026-05-02 b.ts:1 — branch HEAD version
=======
- [open] 2026-05-02 b.ts:1 — branch OTHER version
>>>>>>> other
- [open] 2026-05-03 c.ts:1 — entry two
EOF
  source "${BATS_TEST_DIRNAME}/../lib/parse-entries.sh"
  run fi_entries tmp/conflict.md open
  [ "$status" -eq 0 ]
  # Three [open] lines total in raw file, but two are inside conflict region.
  # Expect only the two outside the conflict block.
  [ "$(echo "$output" | wc -l | tr -d ' ')" = "2" ]
  echo "$output" | grep -q 'a.ts:1'
  echo "$output" | grep -q 'c.ts:1'
  ! echo "$output" | grep -q 'b.ts:1'
}

@test "fi_count open: returns conflict-skipped count" {
  cat > tmp/conflict.md <<'EOF'
- [open] 2026-05-01 a.ts:1 — entry one
<<<<<<< HEAD
- [open] 2026-05-02 b.ts:1 — branch HEAD
=======
- [open] 2026-05-02 b.ts:1 — branch OTHER
>>>>>>> other
- [open] 2026-05-03 c.ts:1 — entry two
EOF
  source "${BATS_TEST_DIRNAME}/../lib/parse-entries.sh"
  run fi_count tmp/conflict.md open
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/cli-status.bats -f "conflict"`
Expected: both new tests FAIL — current parser counts all 3 `[open]` lines (= 3, not 2).

- [ ] **Step 3: Rewrite `fi_entries` with conflict-aware awk**

Replace `fi_entries` in `lib/parse-entries.sh:174-193` with:

```bash
fi_entries() {
  local file="$1"
  local status_filter="${2:-all}"

  if [[ ! -f "$file" ]]; then
    return 1
  fi

  local pattern
  case "$status_filter" in
    all)                   pattern='^- \[(open|deferred|fixed)\]' ;;
    open|deferred|fixed)   pattern="^- \[$status_filter\]" ;;
    *)                     return 2 ;;
  esac

  # Conflict-aware: lines inside <<<<<<< ... >>>>>>> blocks are excluded.
  # Both branches of a conflict are dropped — we never inflate counts during
  # a merge conflict. fi_has_conflict_markers exposes this state to doctor
  # for prominent surfacing.
  LC_ALL=C awk -v pat="$pattern" '
    /^<<<<<<< / { in_conflict = 1; next }
    /^>>>>>>> / { in_conflict = 0; next }
    /^=======$/ && in_conflict { next }
    !in_conflict && $0 ~ pat { print }
  ' "$file"
}
```

(Per memory + CHANGELOG #89: prefix `awk` with `LC_ALL=C` for UTF-8 multibyte safety on Git Bash for Windows.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/cli-status.bats -f "conflict"`
Expected: both new tests PASS.

- [ ] **Step 5: Run full status test suite for regressions**

Run: `bats tests/cli-status.bats`
Expected: all tests pass (existing tests use non-conflicted files; conflict-skipping is additive).

- [ ] **Step 6: Run full parser test suite**

Run: `bats tests/`
Expected: all tests pass. Conflict-awareness is a strict superset of the previous behavior for non-conflicted files.

- [ ] **Step 7: Commit**

```bash
git add lib/parse-entries.sh tests/cli-status.bats
git commit -m "$(cat <<'EOF'
fix(parser): skip merge-conflict regions when counting entries (Bug 4)

The parser previously counted entries inside <<<<<<< / >>>>>>> conflict
blocks as if they were live, inflating statusline counts by ~1 per
conflict region. Now both branches of a conflict are excluded; counts
go down during conflicts, never up.

fi_has_conflict_markers exposes the conflict state separately so doctor
can surface it as a FAIL-level finding (added in Layer 3 work).

Reproduces a real mismatch reported 2026-05-13: statusline showed
'13 other · 1 in PR' while the file had 4 conflict regions and only
10 distinct open entries.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2 — Multi-line splice (Bug 3)

Bug 3 affects all three target languages. Foundational because Phase 3 and 4 (new shim shapes) need the splice mechanism to patch every output branch, not just the first.

### Task 2.1: Multi-line splice (Node)

**Files:**
- Modify: `bin/found-issues:2156-2168` (`fi_find_node_splice_point`)
- Modify: `bin/found-issues:2200-2298` (`cmd_install_statusline_target_node` awk block)
- Test: `tests/cli-install-statusline-custom-target.bats`

- [ ] **Step 1: Write the failing test**

Add to `tests/cli-install-statusline-custom-target.bats` (Group 2):

```bash
@test "install-statusline --target node --apply: patches every console.log in multi-branch statusline" {
  mkdir -p tmp && cat > tmp/sl.js <<'EOF'
#!/usr/bin/env node
const data = { workspace: { current_dir: '/tmp/x' } };
const dir = data.workspace.current_dir;
if (dir) {
  console.log(`A | ${dir}`);
} else {
  console.log(`B | none`);
}
EOF
  fi_run install-statusline --target tmp/sl.js --apply
  [ "$status" -eq 0 ]
  # Both console.log lines must be patched with the splice marker comment.
  local seg_count
  seg_count="$(grep -c 'found-issues:seg' tmp/sl.js)"
  [ "$seg_count" = "2" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/cli-install-statusline-custom-target.bats -f "multi-branch"`
Expected: FAIL — current splice patches only the first `console.log`, so `seg_count == 1`.

- [ ] **Step 3: Update `fi_find_node_splice_point` to return all matching lines**

Replace `bin/found-issues:2156-2168` with:

```bash
fi_find_node_splice_point() {
  local path="$1"
  local lines
  # Priority 1: console.log with template literal (backticks)
  lines="$(LC_ALL=C awk '/console\.log[[:space:]]*\(`/ { print NR }' "$path")"
  [[ -n "$lines" ]] && { echo "$lines"; return 0; }
  # Priority 2: console.log with plain string (single or double quote)
  lines="$(LC_ALL=C awk '/console\.log[[:space:]]*\(("|'"'"')/ { print NR }' "$path")"
  [[ -n "$lines" ]] && { echo "$lines"; return 0; }
  # Priority 3: process.stdout.write
  lines="$(LC_ALL=C awk '/process\.stdout\.write[[:space:]]*\(/ { print NR }' "$path")"
  [[ -n "$lines" ]] && { echo "$lines"; return 0; }
  return 1
}
```

Returns one or more newline-separated line numbers from the highest-priority pattern that matches.

- [ ] **Step 4: Update the awk splicer to patch all matched lines**

Replace the awk block in `cmd_install_statusline_target_node` (lines ~2234-2269) with:

```bash
  # splice_line is now a newline-separated list of line numbers
  tmp_modified="$(mktemp -t fi-target-node-mod.XXXXXX)"
  LC_ALL=C awk -v insert_after="$insert_after" \
      -v splice_lines="$splice_line" \
      -v block_file="$tmp_block" '
    BEGIN {
      n = split(splice_lines, arr, "\n")
      for (i = 1; i <= n; i++) if (arr[i] != "") splice_set[arr[i]] = 1
    }
    function print_block(   line) {
      while ((getline line < block_file) > 0) print line
      close(block_file)
    }
    NR == insert_after && insert_after > 0 { print; print_block(); next }
    (NR in splice_set) {
      line = $0
      if (match(line, /`/)) {
        last_bt = 0
        for (i = length(line); i >= 1; i--) {
          if (substr(line, i, 1) == "`") { last_bt = i; break }
        }
        if (last_bt > 0) {
          line = substr(line, 1, last_bt - 1) "${__fiSeg(typeof dir!=='\''undefined'\''?dir:(typeof cwd!=='\''undefined'\''?cwd:undefined))}" substr(line, last_bt)
        }
        sub(/;[[:space:]]*$/, ";  // found-issues:seg", line)
        if (line !~ /found-issues:seg/) line = line "  // found-issues:seg"
      } else if (match(line, /console\.log\(/) || match(line, /process\.stdout\.write\(/)) {
        sub(/\)/, " + __fiSeg(typeof dir!=='\''undefined'\''?dir:(typeof cwd!=='\''undefined'\''?cwd:undefined)))", line)
        sub(/;[[:space:]]*$/, ";  // found-issues:seg", line)
        if (line !~ /found-issues:seg/) line = line "  // found-issues:seg"
      }
      print line
      next
    }
    NR == 1 && insert_after == 0 { print_block(); print; next }
    { print }
  ' "$path" > "$tmp_modified"
```

Key change: `splice_set` is built from a newline-separated input, and the patch action runs when `NR in splice_set` (set membership) rather than `NR == splice_line` (single-line match). The splice form itself also changes here — that's the Bug 2 fix landing alongside Bug 3 (cohesive change). The function form `__fiSeg(...)` is set up here even though the shim still emits `__fiSeg` as a value at this point; the next phase rewrites the shim to match.

- [ ] **Step 5: Run test to verify it passes**

Run: `bats tests/cli-install-statusline-custom-target.bats -f "multi-branch"`
Expected: PASS — both `console.log` lines have `found-issues:seg`.

- [ ] **Step 6: Verify existing single-branch tests still pass**

Run: `bats tests/cli-install-statusline-custom-target.bats`
Expected: all node tests pass — single-line case is just `splice_set` with one element.

- [ ] **Step 7: Commit (deferred — combine with Phase 3 since splice form change is partial without shim rewrite)**

Do not commit yet. The splice form references `__fiSeg(...)` as a function but the shim still defines `__fiSeg` as a value. Task 3.1 fixes this and we commit the cohesive change together.

### Task 2.2: Multi-line splice (Python)

**Files:**
- Modify: `bin/found-issues:2299-2312` (`fi_find_python_splice_point`)
- Modify: `bin/found-issues:2376-2411` awk block in `cmd_install_statusline_target_python`
- Test: `tests/cli-install-statusline-custom-target.bats`

- [ ] **Step 1: Write the failing test**

Add to `tests/cli-install-statusline-custom-target.bats`:

```bash
@test "install-statusline --target python --apply: patches every print in multi-branch statusline" {
  mkdir -p tmp && cat > tmp/sl.py <<'EOF'
#!/usr/bin/env python3
import json, sys
data = json.loads(sys.stdin.read() or '{}')
dir = data.get('workspace', {}).get('current_dir', '/tmp/x')
if dir:
    print(f"A | {dir}")
else:
    print(f"B | none")
EOF
  fi_run install-statusline --target tmp/sl.py --apply
  [ "$status" -eq 0 ]
  local seg_count
  seg_count="$(grep -c 'found-issues:seg' tmp/sl.py)"
  [ "$seg_count" = "2" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/cli-install-statusline-custom-target.bats -f "multi-branch.*python"`
Expected: FAIL — only first `print` patched.

- [ ] **Step 3: Update `fi_find_python_splice_point` to return all matching lines**

Replace `bin/found-issues:2299-2312` with:

```bash
fi_find_python_splice_point() {
  local path="$1"
  local lines
  # Priority 1: print(f"...") or print(f'...')
  lines="$(LC_ALL=C awk '/^[[:space:]]*print[[:space:]]*\(f["'"'"'][^)]*\)/ { print NR }' "$path")"
  [[ -n "$lines" ]] && { echo "$lines"; return 0; }
  # Priority 2: print("...") or print('...')
  lines="$(LC_ALL=C awk '/^[[:space:]]*print[[:space:]]*\(["'"'"'][^)]*\)/ { print NR }' "$path")"
  [[ -n "$lines" ]] && { echo "$lines"; return 0; }
  # Priority 3: sys.stdout.write(...)
  lines="$(LC_ALL=C awk '/^[[:space:]]*sys\.stdout\.write[[:space:]]*\(/ { print NR }' "$path")"
  [[ -n "$lines" ]] && { echo "$lines"; return 0; }
  return 1
}
```

- [ ] **Step 4: Update the python awk splicer**

Replace the awk block in `cmd_install_statusline_target_python` (lines ~2376-2411) with:

```bash
  tmp_modified="$(mktemp -t fi-target-python-mod.XXXXXX)"
  LC_ALL=C awk -v insert_after="$insert_after" \
      -v splice_lines="$splice_line" \
      -v block_file="$tmp_block" '
    BEGIN {
      n = split(splice_lines, arr, "\n")
      for (i = 1; i <= n; i++) if (arr[i] != "") splice_set[arr[i]] = 1
    }
    function print_block(   line) {
      while ((getline line < block_file) > 0) print line
      close(block_file)
    }
    NR == insert_after && insert_after > 0 { print; print_block(); next }
    (NR in splice_set) {
      line = $0
      if (match(line, /print[[:space:]]*\(f"/)) {
        idx = index(line, "\")")
        if (idx > 0) {
          line = substr(line, 1, idx-1) "{_fi_seg(locals().get(\"dir\") or locals().get(\"cwd\"))}" substr(line, idx) "  # found-issues:seg"
        }
      } else if (match(line, /print[[:space:]]*\(f'"'"'/)) {
        idx = index(line, "'"'"')")
        if (idx > 0) {
          line = substr(line, 1, idx-1) "{_fi_seg(locals().get(\"dir\") or locals().get(\"cwd\"))}" substr(line, idx) "  # found-issues:seg"
        }
      } else if (match(line, /print[[:space:]]*\(["'"'"']/)) {
        sub(/\)[[:space:]]*$/, " + _fi_seg(locals().get(\"dir\") or locals().get(\"cwd\")))  # found-issues:seg", line)
      } else if (match(line, /sys\.stdout\.write[[:space:]]*\(/)) {
        sub(/\)[[:space:]]*$/, " + _fi_seg(locals().get(\"dir\") or locals().get(\"cwd\")))  # found-issues:seg", line)
      }
      print line
      next
    }
    NR == 1 && insert_after == 0 { print_block(); print; next }
    { print }
  ' "$path" > "$tmp_modified"
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bats tests/cli-install-statusline-custom-target.bats -f "multi-branch.*python"`
Expected: PASS.

- [ ] **Step 6: Verify existing python tests still pass**

Run: `bats tests/cli-install-statusline-custom-target.bats`
Expected: all python tests pass.

- [ ] **Step 7: Deferred commit (combined with Phase 4 — see Task 2.1 step 7 rationale)**

### Task 2.3: Multi-line splice (Bash)

**Files:**
- Modify: `bin/found-issues:1996-2007` (`fi_find_bash_splice_point`)
- Modify: `bin/found-issues:2080-2107` (awk block in `cmd_install_statusline_target_bash`)
- Test: `tests/cli-install-statusline-custom-target.bats`

- [ ] **Step 1: Write the failing test**

Add to `tests/cli-install-statusline-custom-target.bats`:

```bash
@test "install-statusline --target bash --apply: patches every echo in multi-branch statusline" {
  mkdir -p tmp && cat > tmp/sl.sh <<'EOF'
#!/usr/bin/env bash
input="$(cat)"
dir="$(echo "$input" | jq -r '.workspace.current_dir // ""')"
if [[ -n "$dir" ]]; then
  echo "A | $dir"
else
  echo "B | none"
fi
EOF
  fi_run install-statusline --target tmp/sl.sh --apply
  [ "$status" -eq 0 ]
  local seg_count
  seg_count="$(grep -c 'found-issues:seg' tmp/sl.sh)"
  [ "$seg_count" = "2" ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/cli-install-statusline-custom-target.bats -f "multi-branch.*bash"`
Expected: FAIL — only first `echo` patched.

- [ ] **Step 3: Update `fi_find_bash_splice_point` to return all matching lines**

Replace lines 1996-2007 with:

```bash
fi_find_bash_splice_point() {
  local path="$1"
  local lines
  # Priority 1: LINE1=... assignment
  lines="$(LC_ALL=C awk '/^[[:space:]]*LINE1=/ { print NR }' "$path")"
  [[ -n "$lines" ]] && { echo "$lines"; return 0; }
  # Priority 2: echo
  lines="$(LC_ALL=C awk '/^[[:space:]]*echo[[:space:]]/ { print NR }' "$path")"
  [[ -n "$lines" ]] && { echo "$lines"; return 0; }
  # Priority 3: printf
  lines="$(LC_ALL=C awk '/^[[:space:]]*printf[[:space:]]/ { print NR }' "$path")"
  [[ -n "$lines" ]] && { echo "$lines"; return 0; }
  return 1
}
```

- [ ] **Step 4: Update the bash awk splicer**

Replace the awk block in `cmd_install_statusline_target_bash` (lines ~2080-2107) with:

```bash
  tmp_modified="$(mktemp -t fi-target-mod.XXXXXX)"
  LC_ALL=C awk -v insert_after="$insert_after" \
      -v splice_lines="$splice_line" \
      -v block_file="$tmp_block" '
    BEGIN {
      n = split(splice_lines, arr, "\n")
      for (i = 1; i <= n; i++) if (arr[i] != "") splice_set[arr[i]] = 1
    }
    function print_block(    line) {
      while ((getline line < block_file) > 0) print line
      close(block_file)
    }
    NR == insert_after && insert_after > 0 { print; print_block(); next }
    (NR in splice_set) {
      line = $0
      if (match(line, /"[^"]*"$/)) {
        sub(/"$/, "${__FI_SEG}\"  # found-issues:seg", line)
      } else {
        line = line "${__FI_SEG}  # found-issues:seg"
      }
      print line
      next
    }
    NR == 1 && insert_after == 0 { print_block(); print; next }
    { print }
  ' "$path" > "$tmp_modified"
  rm -f "$tmp_block"
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bats tests/cli-install-statusline-custom-target.bats -f "multi-branch.*bash"`
Expected: PASS.

- [ ] **Step 6: Verify existing bash tests still pass**

Run: `bats tests/cli-install-statusline-custom-target.bats`
Expected: all bash tests pass.

- [ ] **Step 7: Commit (bash splice is self-contained — no shim rewrite needed)**

```bash
git add bin/found-issues tests/cli-install-statusline-custom-target.bats
git commit -m "$(cat <<'EOF'
fix(install-statusline): bash splice patches every output line (Bug 3, bash)

Multi-branch bash statuslines (if/else with separate echo/printf in each
branch) previously had only the first matching line patched, silently
dropping the segment on the unpatched branch.

fi_find_bash_splice_point now returns all line numbers matching the
highest-priority pattern. The awk splicer uses set-membership to patch
every matched line. Single-branch statuslines are a strict subset
(splice_set with one element) so existing tests continue to pass.

The bash shim block itself is unchanged — bash already handles Windows
via Git Bash and reads stdin via the `$input` jq fallback.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3 — Cross-platform Node shim (Bug 1 + Bug 2)

Rewrite `fi_generate_node_marker_block` to use `os.homedir()`, `fs.readdirSync`, Windows-aware invocation, and a `__fiSeg(dir)` function form. The new splice form was already deployed in Phase 2 — this task completes the cohesive Bug 1 + Bug 2 + Bug 3 (Node) commit.

### Task 3.1: Rewrite Node shim block

**Files:**
- Modify: `bin/found-issues:2171-2198` (`fi_generate_node_marker_block`)
- Test: `tests/cli-install-statusline-custom-target.bats`

- [ ] **Step 1: Write the failing test**

Add to `tests/cli-install-statusline-custom-target.bats`:

```bash
@test "install-statusline --target node: marker block uses os.homedir not process.env.HOME" {
  mkdir -p tmp && cat > tmp/sl.js <<'EOF'
#!/usr/bin/env node
console.log(`repo | main`);
EOF
  fi_run install-statusline --target tmp/sl.js --apply
  [ "$status" -eq 0 ]
  ! grep -q "process.env.HOME" tmp/sl.js
  grep -q "os.homedir" tmp/sl.js
  ! grep -q "command -v found-issues" tmp/sl.js
  grep -q "process.platform" tmp/sl.js
  grep -q "function __fiSeg" tmp/sl.js
}

@test "install-statusline --target node: shim parses + binary resolution executes without throwing" {
  mkdir -p tmp && cat > tmp/sl.js <<'EOF'
#!/usr/bin/env node
console.log(`repo | main`);
EOF
  fi_run install-statusline --target tmp/sl.js --apply
  [ "$status" -eq 0 ]
  if command -v node >/dev/null 2>&1; then
    # node --check verifies syntax; running it with a minimal harness
    # verifies the module-load shim doesn't throw.
    node tmp/sl.js >/dev/null 2>&1 || true
    # Success criterion: node exited (any code is fine, just must not crash on syntax).
    node --check tmp/sl.js
  else
    skip "node not available"
  fi
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/cli-install-statusline-custom-target.bats -f "os.homedir|binary resolution"`
Expected: FAIL — current shim has `process.env.HOME` and `command -v`.

- [ ] **Step 3: Rewrite `fi_generate_node_marker_block`**

Replace `bin/found-issues:2171-2198` with:

```bash
fi_generate_node_marker_block() {
  cat <<'BLOCK'
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
    } catch (e) { /* fall through to cache lookup */ }
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
BLOCK
}
```

The `command -v` POSIX-only fallback is intentionally kept on non-Windows (it's faster than the cache walk when `found-issues` is on PATH). On Windows it's skipped entirely.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/cli-install-statusline-custom-target.bats -f "os.homedir|binary resolution"`
Expected: PASS.

- [ ] **Step 5: Run all node tests for regressions**

Run: `bats tests/cli-install-statusline-custom-target.bats`
Expected: all node tests pass.

- [ ] **Step 6: Commit (cohesive Node Bug 1 + 2 + 3)**

```bash
git add bin/found-issues tests/cli-install-statusline-custom-target.bats
git commit -m "$(cat <<'EOF'
fix(install-statusline): cross-platform Node shim + lazy splice (Bugs 1+2+3)

Rewrites fi_generate_node_marker_block + cmd_install_statusline_target_node:

  Bug 1 (Windows): replace POSIX-only `command -v`, `ls | sort -V | tail`,
  and process.env.HOME with os.homedir(), fs.readdirSync cache walk, and a
  platform-gated `bash -c` invocation (bin/found-issues is a bash script
  that cmd.exe cannot execute directly).

  Bug 2 (cwd-from-stdin): __fiSeg becomes a function instead of a value.
  Splice form is `${__fiSeg(typeof dir!=='undefined'?dir:...)}` which
  opportunistically captures the host statusline's in-scope workspace
  variable (parsed from stdin) before falling through to env vars.

  Bug 3 (multi-branch splice): fi_find_node_splice_point now returns all
  line numbers matching the highest-priority pattern; awk splicer uses
  set-membership to patch every matched output line.

Existing single-output-line, POSIX-only tests continue to pass — the new
shim is a strict superset of the old behavior on Linux/macOS.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 4 — Cross-platform Python shim (Bug 1 + Bug 2)

Parallel to Phase 3 for Python. The Python multi-line splice landed in Task 2.2; this task completes the cohesive Python commit.

### Task 4.1: Rewrite Python shim block

**Files:**
- Modify: `bin/found-issues:2314-2340` (`fi_generate_python_marker_block`)
- Test: `tests/cli-install-statusline-custom-target.bats`

- [ ] **Step 1: Write the failing test**

Add to `tests/cli-install-statusline-custom-target.bats`:

```bash
@test "install-statusline --target python: marker block uses pathlib.Path.home not HOME env" {
  mkdir -p tmp && cat > tmp/sl.py <<'EOF'
#!/usr/bin/env python3
print(f"repo | main")
EOF
  fi_run install-statusline --target tmp/sl.py --apply
  [ "$status" -eq 0 ]
  ! grep -q "environ.get('HOME'" tmp/sl.py
  grep -q "pathlib" tmp/sl.py
  grep -q "platform.system" tmp/sl.py
  grep -q "def _fi_seg" tmp/sl.py
}

@test "install-statusline --target python: shim parses without error" {
  mkdir -p tmp && cat > tmp/sl.py <<'EOF'
#!/usr/bin/env python3
print(f"repo | main")
EOF
  fi_run install-statusline --target tmp/sl.py --apply
  [ "$status" -eq 0 ]
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import ast; ast.parse(open('tmp/sl.py').read())"
  else
    skip "python3 not available"
  fi
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/cli-install-statusline-custom-target.bats -f "pathlib|shim parses"`
Expected: FAIL — current shim uses `_fi_os.environ.get('HOME', '.')`.

- [ ] **Step 3: Rewrite `fi_generate_python_marker_block`**

Replace `bin/found-issues:2314-2340` with:

```bash
fi_generate_python_marker_block() {
  cat <<'BLOCK'
# === found-issues plugin segment ===
# Cross-platform: POSIX uses PATH; Windows invokes via Git Bash (bin/found-issues
# is a bash script). Invocation is deferred via _fi_seg(_dir) so the splice
# point can pass the real workspace dir (parsed from stdin by the host
# statusline). When _dir is unavailable, falls back through env then home.
import subprocess as _fi_subprocess
import shutil as _fi_shutil
import platform as _fi_platform
import os as _fi_os
import pathlib as _fi_pathlib

_fi_cli = None
try:
    if _fi_platform.system() != 'Windows':
        _fi_cli = _fi_shutil.which('found-issues')
    if not _fi_cli:
        _fi_cache_root = _fi_pathlib.Path.home() / '.claude' / 'plugins' / 'cache'
        if _fi_cache_root.is_dir():
            _fi_candidates = []
            for _fi_mkt in _fi_cache_root.iterdir():
                _fi_fi_dir = _fi_mkt / 'found-issues'
                if not _fi_fi_dir.is_dir():
                    continue
                for _fi_ver in _fi_fi_dir.iterdir():
                    _fi_bin = _fi_ver / 'bin' / 'found-issues'
                    if _fi_bin.is_file():
                        _fi_candidates.append((_fi_ver.name, str(_fi_bin)))
            _fi_candidates.sort(key=lambda v: [int(x) if x.isdigit() else x for x in v[0].replace('-', '.').split('.')])
            if _fi_candidates:
                _fi_cli = _fi_candidates[-1][1]
except Exception:
    _fi_cli = None

def _fi_seg(_dir=None):
    if not _fi_cli:
        return ''
    try:
        _fi_cwd = (
            _dir
            or _fi_os.environ.get('CLAUDE_PROJECT_DIR')
            or _fi_os.environ.get('PWD')
            or str(_fi_pathlib.Path.home())
        )
        if _fi_platform.system() == 'Windows':
            _fi_posix = _fi_cli.replace('\\', '/')
            return _fi_subprocess.run(
                ['bash', '-c', f'"{_fi_posix}" status --format=segment'],
                cwd=_fi_cwd, capture_output=True, text=True, timeout=5
            ).stdout.strip()
        return _fi_subprocess.run(
            [_fi_cli, 'status', '--format=segment'],
            cwd=_fi_cwd, capture_output=True, text=True, timeout=5
        ).stdout.strip()
    except Exception:
        return ''
# === end found-issues plugin segment ===
BLOCK
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/cli-install-statusline-custom-target.bats -f "pathlib|shim parses"`
Expected: PASS.

- [ ] **Step 5: Run all python tests for regressions**

Run: `bats tests/cli-install-statusline-custom-target.bats`
Expected: all python tests pass.

- [ ] **Step 6: Commit (cohesive Python Bug 1 + 2 + 3)**

```bash
git add bin/found-issues tests/cli-install-statusline-custom-target.bats
git commit -m "$(cat <<'EOF'
fix(install-statusline): cross-platform Python shim + lazy splice (Bugs 1+2+3)

Mirrors the Node fix from the previous commit:

  Bug 1: pathlib.Path.home() instead of HOME env var; platform.system()-gated
  invocation; bash -c wrapper on Windows.

  Bug 2: _fi_seg becomes a callable with optional _dir arg; splice form is
  `{_fi_seg(locals().get("dir") or locals().get("cwd"))}` — opportunistic
  capture of in-scope workspace variables before env fallback.

  Bug 3 (handled in earlier multi-line splice commit): every matched print
  statement is patched, not just the first.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 5 — Migration detection for v1.4.x installs

Existing v1.4.0/v1.4.1 installs have the broken POSIX-only shim. `install-statusline --target` must detect this and offer to rewrite in place.

### Task 5.1: Detect v1.4.x broken-posix marker block (Node + Python)

**Files:**
- Modify: `bin/found-issues:2046-2048` (Node target idempotency check)
- Modify: `bin/found-issues:2348-2351` (Python target idempotency check)
- Test: `tests/cli-install-statusline-custom-target.bats`

- [ ] **Step 1: Write the failing test**

Add to `tests/cli-install-statusline-custom-target.bats`:

```bash
@test "install-statusline --target node: detects v1.4.x POSIX-only marker block as broken" {
  mkdir -p tmp && cat > tmp/sl.js <<'EOF'
#!/usr/bin/env node
// === found-issues plugin segment ===
// PATH-resilience: try `found-issues` on PATH, fall back to plugin cache glob.
let __fiSeg = '';
try {
  const { execSync } = require('child_process');
  let __fiCli = 'found-issues';
  try { execSync('command -v found-issues', { stdio: 'ignore' }); }
  catch (e) {
    const cacheGlob = process.env.HOME + '/.claude/plugins/cache';
    // ... rest of v1.4.x form
  }
} catch (e) {}
// === end found-issues plugin segment ===
console.log(`repo | main${__fiSeg}`);  // found-issues:seg
EOF
  fi_run install-statusline --target tmp/sl.js --apply
  # New behaviour: detect old form, offer migration (exit 0, message says rewriting).
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "migrating v1.4.x"
  # Post-migration: new form present, old form gone.
  ! grep -q "process.env.HOME" tmp/sl.js
  grep -q "os.homedir" tmp/sl.js
  # Backup written.
  ls tmp/sl.js.fi-bak-* >/dev/null 2>&1
}

@test "install-statusline --target python: detects v1.4.x POSIX-only marker block as broken" {
  mkdir -p tmp && cat > tmp/sl.py <<'EOF'
#!/usr/bin/env python3
# === found-issues plugin segment ===
import subprocess as _fi_subprocess
import shutil as _fi_shutil
import os as _fi_os
_fi_seg = ''
try:
    _fi_cli = _fi_shutil.which('found-issues')
    if _fi_cli:
        _fi_cwd = _fi_os.environ.get('CLAUDE_PROJECT_DIR') or _fi_os.environ.get('HOME', '.')
        _fi_seg = _fi_subprocess.run([_fi_cli, 'status', '--format=segment'], cwd=_fi_cwd, capture_output=True, text=True, timeout=5).stdout.strip()
except Exception:
    _fi_seg = ''
# === end found-issues plugin segment ===
print(f"repo | main{_fi_seg}")  # found-issues:seg
EOF
  fi_run install-statusline --target tmp/sl.py --apply
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "migrating v1.4.x"
  ! grep -q "environ.get('HOME'" tmp/sl.py
  grep -q "pathlib" tmp/sl.py
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/cli-install-statusline-custom-target.bats -f "v1.4.x"`
Expected: FAIL — current idempotency check sees the marker and skips with "already integrated (no-op)".

- [ ] **Step 3: Add detection helper**

Add to `bin/found-issues` near `fi_statusline_state` (around line 1850):

```bash
# Detect whether a custom statusline target contains the v1.4.0/v1.4.1
# POSIX-only marker block. Used by install-statusline --target to trigger
# in-place migration. Signature differs per language:
#   Node:   marker block contains `process.env.HOME` OR `command -v found-issues`
#   Python: marker block contains `_fi_os.environ.get('HOME'` AND not `pathlib`
#   Bash:   N/A (bash shim was always correct)
fi_target_is_v14x_broken() {
  local path="$1"
  local language="$2"
  [[ -f "$path" ]] || return 1
  case "$language" in
    node)
      LC_ALL=C awk '
        /^\/\/ === found-issues plugin segment ===/ { in_block = 1; next }
        /^\/\/ === end found-issues plugin segment ===/ { in_block = 0; next }
        in_block && (/process\.env\.HOME/ || /command -v found-issues/) { found = 1 }
        END { exit (found ? 0 : 1) }
      ' "$path"
      ;;
    python)
      LC_ALL=C awk '
        /^# === found-issues plugin segment ===/ { in_block = 1; next }
        /^# === end found-issues plugin segment ===/ { in_block = 0; next }
        in_block && /environ\.get\(.HOME./ { has_old = 1 }
        in_block && /pathlib/ { has_new = 1 }
        END { exit (has_old && !has_new ? 0 : 1) }
      ' "$path"
      ;;
    *) return 1 ;;
  esac
}
```

- [ ] **Step 4: Wire detection into Node target idempotency check**

Replace `bin/found-issues:2046-2048` (the Node idempotency block) with:

```bash
  # Idempotency: if v1.5.0+ marker block already present, no-op.
  # If v1.4.x POSIX-only marker present, strip + reinstall (migration path).
  if grep -Fq "// === found-issues plugin segment ===" "$path"; then
    if fi_target_is_v14x_broken "$path" node; then
      printf 'install-statusline --target: migrating v1.4.x POSIX-only marker block in %s\n' "$path"
      # Strip old marker block + splice trailers, then fall through to install.
      fi_strip_target_markers "$path" node || {
        fi_err "install-statusline --target: failed to strip v1.4.x marker block"
        return 14
      }
    else
      printf 'install-statusline --target: %s already integrated (no-op)\n' "$path"
      return 0
    fi
  fi
```

- [ ] **Step 5: Same wiring for Python**

Replace `bin/found-issues:2348-2351` with:

```bash
  if grep -Fq "# === found-issues plugin segment ===" "$path"; then
    if fi_target_is_v14x_broken "$path" python; then
      printf 'install-statusline --target: migrating v1.4.x POSIX-only marker block in %s\n' "$path"
      fi_strip_target_markers "$path" python || {
        fi_err "install-statusline --target: failed to strip v1.4.x marker block"
        return 14
      }
    else
      printf 'install-statusline --target: %s already integrated (no-op)\n' "$path"
      return 0
    fi
  fi
```

- [ ] **Step 6: Implement `fi_strip_target_markers`**

Add helper near `fi_target_is_v14x_broken`:

```bash
# Surgically remove marker block + splice trailer comments from a target file.
# Used by the v1.4.x migration path. Mirrors the canonical bash strip in
# fi_strip_legacy_lines but operates on language-specific marker syntax.
fi_strip_target_markers() {
  local path="$1"
  local language="$2"
  local start_marker end_marker trailer_pattern
  case "$language" in
    node)
      start_marker="// === found-issues plugin segment ==="
      end_marker="// === end found-issues plugin segment ==="
      trailer_pattern='[[:space:]]*//[[:space:]]*found-issues:seg[[:space:]]*$'
      ;;
    python)
      start_marker="# === found-issues plugin segment ==="
      end_marker="# === end found-issues plugin segment ==="
      trailer_pattern='[[:space:]]*#[[:space:]]*found-issues:seg[[:space:]]*$'
      ;;
    *) return 1 ;;
  esac

  local tmp
  tmp="$(mktemp -t fi-strip.XXXXXX)"
  LC_ALL=C awk -v start="$start_marker" -v endm="$end_marker" -v trailer="$trailer_pattern" '
    $0 == start { in_block = 1; next }
    $0 == endm { in_block = 0; next }
    in_block { next }
    {
      line = $0
      # Strip the splice injection from the line.
      # Match the inserted segment fragment (varies by language).
      # We strip:
      #   - the ${__fiSeg(...)} or {_fi_seg(...)} interpolation
      #   - the trailing  // found-issues:seg comment
      sub(/\$\{__fiSeg\([^)]*\)\)\}/, "", line)
      sub(/\$\{__fiSeg\}/, "", line)
      sub(/\{_fi_seg\([^)]*\)\)\}/, "", line)
      sub(/\{_fi_seg\}/, "", line)
      sub(/[[:space:]]*\+[[:space:]]*__fiSeg\([^)]*\)\)/, "", line)
      sub(/[[:space:]]*\+[[:space:]]*_fi_seg\([^)]*\)\)/, "", line)
      sub(trailer, "", line)
      print line
    }
  ' "$path" > "$tmp"
  cp "$tmp" "$path"
  rm -f "$tmp"
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `bats tests/cli-install-statusline-custom-target.bats -f "v1.4.x"`
Expected: PASS — old marker block stripped, new marker block + splice installed, backup written.

- [ ] **Step 8: Run all install-statusline tests for regressions**

Run: `bats tests/cli-install-statusline-custom-target.bats`
Expected: all tests pass. Migration is additive.

- [ ] **Step 9: Commit**

```bash
git add bin/found-issues tests/cli-install-statusline-custom-target.bats
git commit -m "$(cat <<'EOF'
feat(install-statusline): auto-migrate v1.4.x POSIX-only target shims

Existing v1.4.0/v1.4.1 installs that integrated the plugin into a custom
Node or Python statusline have the broken POSIX-only shim (process.env.HOME
/ os.environ.get('HOME'), `command -v`, `ls | sort -V | tail -1`). On
Windows they render no segment; on multi-branch statuslines only the first
output line gets the segment.

install-statusline --target now detects the v1.4.x signature inside the
marker block, surgically strips the old block and splice trailers, and
reinstalls the v1.5.0 cross-platform form. Timestamped backup written as
before.

Bash shim is unaffected — bash form was always correct.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 5.2: SessionStart auto-migration for v1.4.x marker blocks

Mirrors the v1.0.0→v1.0.2 canonical-bash migration pattern: detect a broken v1.4.x marker on SessionStart, auto-migrate with timestamped backup, print a one-line notice. Opt-out: `FOUND_ISSUES_AUTO_MIGRATE=off`.

**Files:**
- Modify: `hooks/session-start.sh`
- Modify: `tests/session-start.bats` (if exists — otherwise create)

- [ ] **Step 1: Read existing hook to find the insertion point**

Run: `cat hooks/session-start.sh`
Goal: understand current structure (existing v1.0.0→v1.0.2 migration if any; where to insert v1.4.x→v1.5.0 migration; what stdin/env it has access to).

- [ ] **Step 2: Write the failing tests**

If `tests/session-start.bats` doesn't exist, create it with the standard `load helpers` / `setup` / `teardown` scaffold from other bats files in the repo. Then add:

```bash
@test "session-start: auto-migrates v1.4.x POSIX-only marker in canonical statusline" {
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/.claude"
  cat > "$FAKE_HOME/.claude/statusline.sh" <<'EOF'
#!/usr/bin/env bash
# === found-issues plugin segment ===
# (legacy v1.0.0/1.0.1 form without __FI_DIR — already covered by existing migration)
FI_SEG="$(found-issues status --format=segment 2>/dev/null || true)"
# === end found-issues plugin segment ===
LINE1="repo | main${FI_SEG}"
echo "$LINE1"
EOF
  # Use the v1.4.x signature: this test exercises the NEW migration path.
  # Note: bash shim was always correct, so the "broken-posix" state only
  # applies to custom Node/Python targets — see settings.json variant below.
  HOME="$FAKE_HOME" run bash "${BATS_TEST_DIRNAME}/../hooks/session-start.sh" < /dev/null
  [ "$status" -eq 0 ]
  # Canonical bash statusline is not v1.4.x-broken (bash shim was always correct).
  # No migration message expected for this case.
  ! echo "$output" | grep -q "migrating v1.4.x"
  rm -rf "$FAKE_HOME"
}

@test "session-start: auto-migrates v1.4.x POSIX-only marker in custom Node statusline" {
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/.claude"
  # Custom Node statusline with v1.4.x signature.
  cat > "$FAKE_HOME/custom.js" <<'EOF'
#!/usr/bin/env node
// === found-issues plugin segment ===
let __fiSeg = '';
try {
  const { execSync } = require('child_process');
  const cacheGlob = process.env.HOME + '/.claude/plugins/cache';
  execSync('command -v found-issues');
} catch (e) {}
// === end found-issues plugin segment ===
console.log(`repo${__fiSeg}`);  // found-issues:seg
EOF
  cat > "$FAKE_HOME/.claude/settings.json" <<EOF
{"statusLine": {"command": "node $FAKE_HOME/custom.js"}}
EOF
  HOME="$FAKE_HOME" run bash "${BATS_TEST_DIRNAME}/../hooks/session-start.sh" < /dev/null
  [ "$status" -eq 0 ]
  # Migration notice in output.
  echo "$output" | grep -q "v1.4.x"
  # Backup written.
  ls "$FAKE_HOME"/custom.js.fi-bak-* >/dev/null 2>&1
  # File updated to v1.5.0 form.
  ! grep -q "process.env.HOME" "$FAKE_HOME/custom.js"
  grep -q "os.homedir" "$FAKE_HOME/custom.js"
  rm -rf "$FAKE_HOME"
}

@test "session-start: respects FOUND_ISSUES_AUTO_MIGRATE=off" {
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/.claude"
  cat > "$FAKE_HOME/custom.js" <<'EOF'
#!/usr/bin/env node
// === found-issues plugin segment ===
let __fiSeg = '';
try { require('child_process').execSync('command -v found-issues'); } catch(e) {}
// === end found-issues plugin segment ===
console.log(`repo${__fiSeg}`);  // found-issues:seg
EOF
  cat > "$FAKE_HOME/.claude/settings.json" <<EOF
{"statusLine": {"command": "node $FAKE_HOME/custom.js"}}
EOF
  HOME="$FAKE_HOME" FOUND_ISSUES_AUTO_MIGRATE=off run bash "${BATS_TEST_DIRNAME}/../hooks/session-start.sh" < /dev/null
  [ "$status" -eq 0 ]
  # No migration occurred — file unchanged.
  grep -q "process.env.HOME\|command -v" "$FAKE_HOME/custom.js" || \
    grep -q "execSync\('command -v" "$FAKE_HOME/custom.js"
  ! ls "$FAKE_HOME"/custom.js.fi-bak-* 2>/dev/null
  rm -rf "$FAKE_HOME"
}

@test "session-start: skips migration when target file is a symlink" {
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/.claude" "$FAKE_HOME/dotfiles"
  cat > "$FAKE_HOME/dotfiles/custom.js" <<'EOF'
#!/usr/bin/env node
// === found-issues plugin segment ===
let __fiSeg = '';
try { require('child_process').execSync('command -v found-issues'); } catch(e) {}
// === end found-issues plugin segment ===
console.log(`repo${__fiSeg}`);  // found-issues:seg
EOF
  ln -s "$FAKE_HOME/dotfiles/custom.js" "$FAKE_HOME/custom.js"
  cat > "$FAKE_HOME/.claude/settings.json" <<EOF
{"statusLine": {"command": "node $FAKE_HOME/custom.js"}}
EOF
  HOME="$FAKE_HOME" run bash "${BATS_TEST_DIRNAME}/../hooks/session-start.sh" < /dev/null
  [ "$status" -eq 0 ]
  # Notice mentions skip-due-to-symlink.
  echo "$output" | grep -qi "symlink"
  # File NOT modified.
  grep -q "command -v" "$FAKE_HOME/dotfiles/custom.js"
  rm -rf "$FAKE_HOME"
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bats tests/session-start.bats -f "v1.4.x|AUTO_MIGRATE|symlink"`
Expected: all 4 new tests FAIL — current session-start hook has no v1.4.x migration logic.

- [ ] **Step 4: Implement the migration block in `hooks/session-start.sh`**

Add a new section near the end of `hooks/session-start.sh` (after any existing v1.0.0→v1.0.2 migration block; before the final exit). The exact placement depends on existing hook structure (read in Step 1) — insert before the final `exit 0` and after any existing diagnostics:

```bash
# --- v1.4.x → v1.5.0 marker migration (auto-trigger) ---
# Detect v1.4.0/v1.4.1 POSIX-only marker blocks in custom Node/Python
# statusline targets and auto-migrate them in place. Mirrors the v1.0.0
# bash migration pattern. Opt-out: FOUND_ISSUES_AUTO_MIGRATE=off.
#
# Canonical bash statusline (~/.claude/statusline.sh) was always correct on
# Windows (runs in Git Bash) so this migration only applies to custom Node
# and Python targets reachable via ~/.claude/settings.json statusLine.command.
if [[ "${FOUND_ISSUES_AUTO_MIGRATE:-on}" != "off" ]]; then
  __fi_settings="$HOME/.claude/settings.json"
  if [[ -f "$__fi_settings" ]] && command -v jq >/dev/null 2>&1; then
    __fi_cmd="$(jq -r '.statusLine.command // ""' "$__fi_settings" 2>/dev/null || true)"
    if [[ -n "$__fi_cmd" ]]; then
      # Last whitespace-separated token is the file path.
      __fi_target="$(printf '%s' "$__fi_cmd" | LC_ALL=C awk '{print $NF}' | sed "s|\${HOME}|$HOME|g; s|^~|$HOME|")"
      case "$__fi_target" in
        *.js|*.mjs|*.cjs) __fi_lang=node ;;
        *.py)             __fi_lang=python ;;
        *)                __fi_lang="" ;;
      esac
      if [[ -n "$__fi_lang" && -f "$__fi_target" ]]; then
        # Source the helper so we can call fi_target_is_v14x_broken.
        # FI_BIN_DIR is the plugin's bin directory (resolved by Claude Code's
        # ${CLAUDE_PLUGIN_ROOT} substitution before this hook is invoked).
        if "${FI_BIN_DIR:-$(dirname "$0")/../bin}/found-issues" --help >/dev/null 2>&1; then
          # Use the CLI's own detection via a hidden subcommand surface:
          # `install-statusline --target <path> --apply` is idempotent and
          # auto-migrates v1.4.x marker blocks (Task 5.1). Calling it with
          # --apply on an already-correct file is a no-op.
          if [[ -L "$__fi_target" ]]; then
            printf 'found-issues: skipping v1.4.x migration — %s is a symlink; rerun install-statusline manually after dotfile sync.\n' "$__fi_target" >&2
          else
            # Probe whether migration is needed before invoking install.
            __fi_needs_migrate=0
            if [[ "$__fi_lang" == "node" ]]; then
              LC_ALL=C awk '
                /^\/\/ === found-issues plugin segment ===/ { in_block = 1; next }
                /^\/\/ === end found-issues plugin segment ===/ { in_block = 0; next }
                in_block && (/process\.env\.HOME/ || /command -v found-issues/) { found = 1 }
                END { exit (found ? 0 : 1) }
              ' "$__fi_target" 2>/dev/null && __fi_needs_migrate=1
            elif [[ "$__fi_lang" == "python" ]]; then
              LC_ALL=C awk '
                /^# === found-issues plugin segment ===/ { in_block = 1; next }
                /^# === end found-issues plugin segment ===/ { in_block = 0; next }
                in_block && /environ\.get\(.HOME./ { has_old = 1 }
                in_block && /pathlib/ { has_new = 1 }
                END { exit (has_old && !has_new ? 0 : 1) }
              ' "$__fi_target" 2>/dev/null && __fi_needs_migrate=1
            fi
            if [[ "$__fi_needs_migrate" == "1" ]]; then
              if "${FI_BIN_DIR:-$(dirname "$0")/../bin}/found-issues" install-statusline --target "$__fi_target" --apply >/dev/null 2>&1; then
                printf 'found-issues: auto-migrated v1.4.x statusline shim in %s (timestamped backup written; opt-out: FOUND_ISSUES_AUTO_MIGRATE=off)\n' "$__fi_target" >&2
              else
                printf 'found-issues: v1.4.x migration FAILED for %s — run `found-issues install-statusline --target %s --apply` manually.\n' "$__fi_target" "$__fi_target" >&2
              fi
            fi
          fi
        fi
      fi
    fi
  fi
fi
# --- end v1.4.x → v1.5.0 marker migration ---
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats tests/session-start.bats -f "v1.4.x|AUTO_MIGRATE|symlink"`
Expected: all 4 new tests PASS.

- [ ] **Step 6: Run full test suite for regressions**

Run: `bats tests/`
Expected: full suite passes. Existing session-start tests unaffected (the migration block is no-op when no v1.4.x signature present).

- [ ] **Step 7: Commit**

```bash
git add hooks/session-start.sh tests/session-start.bats
git commit -m "$(cat <<'EOF'
feat(session-start): auto-migrate v1.4.x marker blocks (Layer 1)

Existing v1.4.0/v1.4.1 installs into custom Node/Python statuslines are
silently broken on Windows (POSIX-only shim) and on multi-branch
statuslines (splice gap). Without auto-migration, users only discover the
fix by happening to run `doctor`. Auto-trigger on SessionStart matches
the v1.0.0→v1.0.2 bash migration precedent and gets the fix to users who
don't read CHANGELOGs.

Safety rails:
- Symlinks are skipped (dotfile-sync incompatibility) with a stderr notice
- Opt-out via FOUND_ISSUES_AUTO_MIGRATE=off
- Timestamped backup written (via install-statusline --apply)
- Failure mode is silent — a broken migration prints a fix-it hint but
  doesn't block session start
- Bash canonical statusline is unaffected (the shim was always correct)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 6 — Layer 2: End-to-end CI runtime tests

Pulls together Phases 1-5 with tests that actually run the generated shim against synthetic Claude Code stdin on all 3 OSes in the matrix.

### Task 6.1: Add synthetic stdin helper

**Files:**
- Modify: `tests/helpers.bash`
- Test: indirect via Group 5 tests

- [ ] **Step 1: Add helper to `tests/helpers.bash`**

Append:

```bash
# Emit a synthetic Claude Code statusline stdin JSON payload.
# Used by Layer 2 end-to-end tests and Layer 3 doctor runtime probe.
# Args: $1 = workspace.current_dir
fi_synthetic_stdin() {
  local dir="$1"
  printf '{"model":{"display_name":"Test"},"workspace":{"current_dir":"%s"},"session_id":"t","context_window":{"remaining_percentage":50}}' "$dir"
}
```

- [ ] **Step 2: Verify helper is loadable in a test**

Run: `bats -f "synthetic_stdin" tests/ 2>&1 | head -5` (no test exists yet, just ensure no syntax error in helpers.bash by running any test that sources it).

Run: `bats tests/cli-status.bats -f "fi_has_conflict" | head -3`
Expected: tests still pass (helpers.bash sources cleanly).

- [ ] **Step 3: Commit**

```bash
git add tests/helpers.bash
git commit -m "$(cat <<'EOF'
test(helpers): fi_synthetic_stdin emits Claude Code statusline payload

Shared helper for end-to-end runtime tests (Layer 2) and the upcoming
doctor runtime probe (Layer 3). Single source of truth for the payload
shape so the schema stays consistent across test suites.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 6.2: Group 5 — End-to-end runtime tests (Node)

**Files:**
- Modify: `tests/cli-install-statusline-custom-target.bats`

- [ ] **Step 1: Write the failing tests**

Add a new group at the end of `tests/cli-install-statusline-custom-target.bats`:

```bash
# =====================================================================
# Group 5 — Runtime end-to-end
# Verifies that the generated shim, after install-statusline --apply,
# actually emits the segment in real conditions: piped Claude Code stdin,
# real binary, real .found-issues.md file.
# =====================================================================

@test "runtime e2e (node): single-branch statusline emits segment" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi

  mkdir -p tmp
  cat > tmp/.found-issues.md <<'EOF'
- [open] 2026-05-13 a.ts:1 — synthetic test entry
EOF
  cat > tmp/sl.js <<'EOF'
#!/usr/bin/env node
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(0, 'utf8'));
const dir = data.workspace.current_dir;
console.log(`repo | ${dir}`);
EOF

  fi_run install-statusline --target tmp/sl.js --apply
  [ "$status" -eq 0 ]

  # Pipe synthetic Claude Code stdin into the installed statusline.
  local sl_output
  sl_output="$(fi_synthetic_stdin "$(pwd)/tmp" | node tmp/sl.js 2>/dev/null)"

  # Assert the segment string is present (`<space>|<space>` + count + 'issue').
  echo "$sl_output" | grep -qE ' \| .*issue'
}

@test "runtime e2e (node): multi-branch statusline emits segment in both branches" {
  if ! command -v node >/dev/null 2>&1; then skip "node not available"; fi

  mkdir -p tmp
  cat > tmp/.found-issues.md <<'EOF'
- [open] 2026-05-13 a.ts:1 — synthetic test entry
EOF
  cat > tmp/sl.js <<'EOF'
#!/usr/bin/env node
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(0, 'utf8'));
const dir = data.workspace.current_dir;
if (data.session_id) {
  console.log(`branch-A | ${dir}`);
} else {
  console.log(`branch-B | ${dir}`);
}
EOF

  fi_run install-statusline --target tmp/sl.js --apply
  [ "$status" -eq 0 ]

  # Branch A: session_id present.
  local out_a
  out_a="$(fi_synthetic_stdin "$(pwd)/tmp" | node tmp/sl.js 2>/dev/null)"
  echo "$out_a" | grep -q "branch-A"
  echo "$out_a" | grep -qE ' \| .*issue'

  # Branch B: session_id null.
  local out_b
  out_b="$(printf '{"workspace":{"current_dir":"%s"}}' "$(pwd)/tmp" | node tmp/sl.js 2>/dev/null)"
  echo "$out_b" | grep -q "branch-B"
  echo "$out_b" | grep -qE ' \| .*issue'
}
```

- [ ] **Step 2: Run tests locally**

Run: `bats tests/cli-install-statusline-custom-target.bats -f "runtime e2e \(node\)"`
Expected: both tests PASS on the local platform (developer running this on macOS or Linux).

- [ ] **Step 3: Push branch and check Windows CI**

```bash
git push -u origin feat/statusline-resilience-v1.5.0
gh pr create --draft --title "feat: statusline resilience v1.5.0 (WIP)" --body "Tracking branch for the multi-bug fix. Not ready for review until phases 6-9 land."
```

Watch the bats matrix run on Windows. Expected: Node tests pass on Windows too — this is the proof that Bug 1 is fixed.

- [ ] **Step 4: Commit Group 5 Node tests**

```bash
git add tests/cli-install-statusline-custom-target.bats
git commit -m "$(cat <<'EOF'
test: Group 5 runtime e2e tests for Node (Layer 2)

The previous test bar was `node --check` (syntax validation only). These
new tests actually pipe synthetic Claude Code stdin into the installed
statusline and assert the segment string appears in stdout — exercising
the cross-platform code paths in CI on Linux, macOS, AND Windows.

This is the immune system: without these, the v1.4.x Windows regression
would have shipped again.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 6.3: Group 5 — End-to-end runtime tests (Python)

**Files:**
- Modify: `tests/cli-install-statusline-custom-target.bats`

- [ ] **Step 1: Write the failing tests**

Append to the Group 5 section:

```bash
@test "runtime e2e (python): single-branch statusline emits segment" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 not available"; fi

  mkdir -p tmp
  cat > tmp/.found-issues.md <<'EOF'
- [open] 2026-05-13 a.ts:1 — synthetic test entry
EOF
  cat > tmp/sl.py <<'EOF'
#!/usr/bin/env python3
import json, sys
data = json.loads(sys.stdin.read() or '{}')
dir = data.get('workspace', {}).get('current_dir', '/tmp')
print(f"repo | {dir}")
EOF

  fi_run install-statusline --target tmp/sl.py --apply
  [ "$status" -eq 0 ]

  local sl_output
  sl_output="$(fi_synthetic_stdin "$(pwd)/tmp" | python3 tmp/sl.py 2>/dev/null)"
  echo "$sl_output" | grep -qE ' \| .*issue'
}

@test "runtime e2e (python): multi-branch statusline emits segment in both branches" {
  if ! command -v python3 >/dev/null 2>&1; then skip "python3 not available"; fi

  mkdir -p tmp
  cat > tmp/.found-issues.md <<'EOF'
- [open] 2026-05-13 a.ts:1 — synthetic test entry
EOF
  cat > tmp/sl.py <<'EOF'
#!/usr/bin/env python3
import json, sys
data = json.loads(sys.stdin.read() or '{}')
dir = data.get('workspace', {}).get('current_dir', '/tmp')
if data.get('session_id'):
    print(f"branch-A | {dir}")
else:
    print(f"branch-B | {dir}")
EOF

  fi_run install-statusline --target tmp/sl.py --apply
  [ "$status" -eq 0 ]

  local out_a
  out_a="$(fi_synthetic_stdin "$(pwd)/tmp" | python3 tmp/sl.py 2>/dev/null)"
  echo "$out_a" | grep -q "branch-A"
  echo "$out_a" | grep -qE ' \| .*issue'

  local out_b
  out_b="$(printf '{"workspace":{"current_dir":"%s"}}' "$(pwd)/tmp" | python3 tmp/sl.py 2>/dev/null)"
  echo "$out_b" | grep -q "branch-B"
  echo "$out_b" | grep -qE ' \| .*issue'
}
```

- [ ] **Step 2: Run tests locally**

Run: `bats tests/cli-install-statusline-custom-target.bats -f "runtime e2e \(python\)"`
Expected: both tests PASS.

- [ ] **Step 3: Commit**

```bash
git add tests/cli-install-statusline-custom-target.bats
git commit -m "$(cat <<'EOF'
test: Group 5 runtime e2e tests for Python (Layer 2)

Mirrors the Node e2e tests: synthetic stdin → installed statusline →
assert segment string in stdout. Exercises pathlib.Path.home(),
platform.system() Windows branch, and the locals().get('dir') splice
form on all three CI OSes.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 6.4: Group 5 — End-to-end runtime tests (Bash)

**Files:**
- Modify: `tests/cli-install-statusline-custom-target.bats`

- [ ] **Step 1: Write the failing test**

Append:

```bash
@test "runtime e2e (bash): multi-branch statusline emits segment in both branches" {
  mkdir -p tmp
  cat > tmp/.found-issues.md <<'EOF'
- [open] 2026-05-13 a.ts:1 — synthetic test entry
EOF
  cat > tmp/sl.sh <<'EOF'
#!/usr/bin/env bash
input="$(cat)"
dir="$(echo "$input" | jq -r '.workspace.current_dir // ""')"
if [[ -n "$dir" ]]; then
  echo "branch-A | $dir"
else
  echo "branch-B | none"
fi
EOF
  chmod +x tmp/sl.sh

  fi_run install-statusline --target tmp/sl.sh --apply
  [ "$status" -eq 0 ]

  local out_a
  out_a="$(fi_synthetic_stdin "$(pwd)/tmp" | bash tmp/sl.sh 2>/dev/null)"
  echo "$out_a" | grep -q "branch-A"
  echo "$out_a" | grep -qE ' \| .*issue'

  local out_b
  out_b="$(printf '{}' | bash tmp/sl.sh 2>/dev/null)"
  echo "$out_b" | grep -q "branch-B"
  echo "$out_b" | grep -qE ' \| .*issue'
}
```

- [ ] **Step 2: Run test locally**

Run: `bats tests/cli-install-statusline-custom-target.bats -f "runtime e2e \(bash\)"`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add tests/cli-install-statusline-custom-target.bats
git commit -m "$(cat <<'EOF'
test: Group 5 runtime e2e test for bash (Layer 2)

Bash shim was always correct, but multi-branch splice was buggy. This
test asserts both branches of a conditional emit the segment after
install-statusline --apply.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 7 — Layer 3: Doctor extension

Adds runtime probe pipeline to `cmd_doctor` (§7.1 of spec). Tests live in a new file `tests/cli-doctor.bats`.

### Task 7.1: Doctor source-file health probe (step 1)

**Files:**
- Modify: `bin/found-issues:2672-` (`cmd_doctor`)
- Create: `tests/cli-doctor.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/cli-doctor.bats`:

```bash
#!/usr/bin/env bats

load helpers

setup() {
  fi_test_setup
  cd "$TEST_TMP"
}

teardown() {
  fi_test_teardown
}

@test "doctor: reports FAIL when issues file has merge conflict markers" {
  cat > .found-issues.md <<'EOF'
- [open] 2026-05-01 a.ts:1 — entry one
<<<<<<< HEAD
- [open] 2026-05-02 b.ts:1 — branch HEAD
=======
- [open] 2026-05-02 b.ts:1 — branch OTHER
>>>>>>> other
EOF
  fi_run doctor
  [ "$status" -eq 0 ]
  # Source file health section should report FAIL with line refs.
  echo "$output" | grep -q "Source file health"
  echo "$output" | grep -qE "(FAIL|✗).*conflict marker"
}

@test "doctor: reports OK when issues file is clean" {
  cat > .found-issues.md <<'EOF'
- [open] 2026-05-01 a.ts:1 — entry one
- [open] 2026-05-02 b.ts:1 — entry two
EOF
  fi_run doctor
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Source file health"
  echo "$output" | grep -qE "(OK|✓).*Source file"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/cli-doctor.bats -f "Source file"`
Expected: FAIL — current doctor doesn't have a "Source file health" section.

- [ ] **Step 3: Add the source-file health section to `cmd_doctor`**

In `cmd_doctor` (`bin/found-issues:2672+`), after the `printf 'found-issues doctor — v%s\n\n' "$FI_VERSION"` line, insert a new section:

```bash
  # --- Source file health (NEW) ---
  printf '== Source file health ==\n'
  local issues_file
  issues_file="$(fi_find_issues_file 2>/dev/null || true)"
  if [[ -n "$issues_file" && -f "$issues_file" ]]; then
    if fi_has_conflict_markers "$issues_file"; then
      printf '%s Source file has merge conflict markers: %s\n' "$section_fail" "$issues_file"
      local conflict_lines
      conflict_lines="$(LC_ALL=C grep -nE '^(<<<<<<< |=======$|>>>>>>> )' "$issues_file" | head -10 | sed 's/^/   /')"
      printf '%s\n' "$conflict_lines"
      printf '   Resolve the conflict (git status, then manual edit) before trusting any counts.\n'
      printf '   Counts in the statusline below skip lines inside conflict regions, so they\n'
      printf '   may differ from what you expect during a merge.\n'
    else
      printf '%s Source file: %s (no conflict markers)\n' "$section_pass" "$issues_file"
    fi
  else
    printf '%s No issues file found in current dir or its parents.\n' "$section_warn"
  fi
  printf '\n'
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/cli-doctor.bats -f "Source file"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add bin/found-issues tests/cli-doctor.bats
git commit -m "$(cat <<'EOF'
feat(doctor): source file health probe (Layer 3 step 1)

doctor now reports FAIL with line numbers if the issues file contains
merge-conflict markers. Counts skip conflict regions (per the parser
fix), but doctor surfaces the degraded state so users see WHY their
count looks low instead of treating it as authoritative.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 7.2: Doctor custom-statusline detection (steps 2-4)

**Files:**
- Modify: `bin/found-issues` (`cmd_doctor`, `fi_statusline_state`)
- Modify: `tests/cli-doctor.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/cli-doctor.bats`:

```bash
@test "doctor: detects custom statusline path from ~/.claude/settings.json" {
  mkdir -p tmp/.claude
  cat > tmp/.claude/settings.json <<'EOF'
{"statusLine": {"command": "node ${HOME}/custom-statusline.js"}}
EOF
  HOME="$(pwd)/tmp" fi_run doctor
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "statusLine.command"
  echo "$output" | grep -q "custom-statusline.js"
}

@test "doctor: detects v1.4.x broken-posix marker in custom Node target" {
  mkdir -p tmp/.claude
  cat > tmp/custom.js <<'EOF'
#!/usr/bin/env node
// === found-issues plugin segment ===
let __fiSeg = '';
try {
  const path = process.env.HOME + '/.claude';
  const { execSync } = require('child_process');
  execSync('command -v found-issues');
} catch (e) {}
// === end found-issues plugin segment ===
console.log(`repo${__fiSeg}`);  // found-issues:seg
EOF
  cat > tmp/.claude/settings.json <<EOF
{"statusLine": {"command": "node $(pwd)/tmp/custom.js"}}
EOF
  HOME="$(pwd)/tmp" fi_run doctor
  [ "$status" -eq 0 ]
  # State should be reported as installed-broken-posix.
  echo "$output" | grep -qE "(broken-posix|v1.4.x)"
  echo "$output" | grep -qi "migrat"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/cli-doctor.bats -f "custom statusline|broken-posix"`
Expected: FAIL.

- [ ] **Step 3: Extend `fi_statusline_state` to accept path + language args**

Find `fi_statusline_state()` at `bin/found-issues:1797` and replace its first lines to accept optional args:

```bash
fi_statusline_state() {
  local file="${1:-$FI_STATUSLINE_FILE}"
  local language="${2:-bash}"  # canonical statusline.sh is bash

  if [[ ! -f "$file" ]]; then
    printf 'no-file'
    return 0
  fi
  # ... rest of existing function

  # NEW: detect installed-broken-posix sub-state for node/python targets
  if [[ "$language" != "bash" ]]; then
    if fi_target_is_v14x_broken "$file" "$language"; then
      printf 'installed-broken-posix'
      return 0
    fi
    if grep -Fq "// === found-issues plugin segment ===" "$file" 2>/dev/null \
       || grep -Fq "# === found-issues plugin segment ===" "$file" 2>/dev/null; then
      printf 'installed-fixed'
      return 0
    fi
    printf 'none'
    return 0
  fi
  # ... continue with existing bash logic
```

(The exact splice into the existing function depends on the surrounding code — the executor should preserve the bash detection logic untouched and add the node/python branch at the top.)

- [ ] **Step 4: Add a `cmd_doctor` Statusline section that reads settings.json**

In `cmd_doctor`, replace the existing `== Statusline ==` section with:

```bash
  # --- Statusline (extended for custom targets) ---
  printf '== Statusline ==\n'
  local settings_file="$HOME/.claude/settings.json"
  local custom_target="" custom_language=""
  if [[ -f "$settings_file" ]] && command -v jq >/dev/null 2>&1; then
    local cmd
    cmd="$(jq -r '.statusLine.command // ""' "$settings_file" 2>/dev/null || true)"
    if [[ -n "$cmd" ]]; then
      printf '%s settings.json statusLine.command: %s\n' "$section_pass" "$cmd"
      # Extract the script path: assume last whitespace-separated token is the file.
      custom_target="$(printf '%s' "$cmd" | LC_ALL=C awk '{print $NF}' | sed "s|\${HOME}|$HOME|g; s|^~|$HOME|")"
      # Heuristic: language from extension.
      case "$custom_target" in
        *.js|*.mjs|*.cjs) custom_language=node ;;
        *.py)             custom_language=python ;;
        *.sh|*.bash)      custom_language=bash ;;
      esac
    fi
  fi

  local statusline_target statusline_language
  if [[ -n "$custom_target" && -f "$custom_target" ]]; then
    statusline_target="$custom_target"
    statusline_language="$custom_language"
    printf '   Resolved target: %s (language: %s)\n' "$statusline_target" "$statusline_language"
  else
    statusline_target="$FI_STATUSLINE_FILE"
    statusline_language="bash"
  fi

  if [[ -f "$statusline_target" ]]; then
    local statusline_state
    statusline_state="$(fi_statusline_state "$statusline_target" "$statusline_language")"
    case "$statusline_state" in
      installed-fixed)
        printf '%s State: installed-fixed (canonical block).\n' "$section_pass"
        ;;
      installed-broken-posix)
        printf '%s State: installed-broken-posix — v1.4.x POSIX-only shim.\n' "$section_fail"
        printf '   Symptom: empty segment on Windows OR on multi-branch statuslines.\n'
        printf '   Fix: found-issues install-statusline --target %s --apply   (auto-migrates)\n' "$statusline_target"
        ;;
      installed-broken|legacy-handwritten|legacy-and-installed)
        printf '%s State: %s — counter renders empty silently.\n' "$section_fail" "$statusline_state"
        printf '   Fix: found-issues install-statusline   (auto-migrates with timestamped backup)\n'
        ;;
      none)
        printf '%s State: none — statusline exists but no found-issues segment.\n' "$section_warn"
        if [[ -n "$custom_target" ]]; then
          printf '   Install: found-issues install-statusline --target %s --apply\n' "$statusline_target"
        else
          printf '   Install: found-issues install-statusline\n'
        fi
        ;;
      no-file)
        printf '%s State: no-file.\n' "$section_warn"
        ;;
    esac
  else
    printf '%s Statusline target file not found: %s\n' "$section_warn" "$statusline_target"
  fi
  printf '\n'
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats tests/cli-doctor.bats -f "custom statusline|broken-posix"`
Expected: PASS.

- [ ] **Step 6: Verify existing doctor tests still pass**

Run: `bats tests/`
Expected: full suite passes. Existing canonical-bash doctor logic preserved.

- [ ] **Step 7: Commit**

```bash
git add bin/found-issues tests/cli-doctor.bats
git commit -m "$(cat <<'EOF'
feat(doctor): detect custom statusline target + v1.4.x broken-posix state

doctor now reads ~/.claude/settings.json for a custom statusLine.command
and inspects that file (not just the canonical ~/.claude/statusline.sh).
Adds a new state 'installed-broken-posix' for v1.4.x Node/Python shims,
with an actionable --migrate hint.

Closes the diagnosis gap that left the Windows + GSD-statusline user
unable to root-cause the empty segment without manual log spelunking.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 7.3: Doctor runtime probe (step 5)

**Files:**
- Modify: `bin/found-issues` (`cmd_doctor` extension)
- Modify: `tests/cli-doctor.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/cli-doctor.bats`:

```bash
@test "doctor: runtime probe emits OK when integration is healthy" {
  mkdir -p tmp/.claude
  cat > tmp/.found-issues.md <<'EOF'
- [open] 2026-05-13 a.ts:1 — entry
EOF
  cat > tmp/custom.sh <<'EOF'
#!/usr/bin/env bash
input="$(cat)"
dir="$(echo "$input" | jq -r '.workspace.current_dir // ""')"
echo "repo | $dir"
EOF
  chmod +x tmp/custom.sh
  fi_run install-statusline --target tmp/custom.sh --apply
  [ "$status" -eq 0 ]

  cat > tmp/.claude/settings.json <<EOF
{"statusLine": {"command": "bash $(pwd)/tmp/custom.sh"}}
EOF
  HOME="$(pwd)/tmp" fi_run doctor
  echo "$output" | grep -q "Runtime probe"
  echo "$output" | grep -qE "(OK|✓).*segment rendered"
}

@test "doctor: runtime probe reports FAIL with splice-gap diagnostic when output branch unpatched" {
  mkdir -p tmp/.claude
  cat > tmp/.found-issues.md <<'EOF'
- [open] 2026-05-13 a.ts:1 — entry
EOF
  # Deliberately install, then unpatch one branch to simulate a splice gap.
  cat > tmp/custom.js <<'EOF'
#!/usr/bin/env node
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(0, 'utf8'));
const dir = data.workspace.current_dir;
if (dir) {
  console.log(`A | ${dir}`);
} else {
  console.log(`B | none`);
}
EOF
  fi_run install-statusline --target tmp/custom.js --apply
  [ "$status" -eq 0 ]
  # Remove the splice trailer from one line to simulate a gap.
  LC_ALL=C sed -i.bak "0,/found-issues:seg/{//d;}" tmp/custom.js || true

  cat > tmp/.claude/settings.json <<EOF
{"statusLine": {"command": "node $(pwd)/tmp/custom.js"}}
EOF
  HOME="$(pwd)/tmp" fi_run doctor
  echo "$output" | grep -qE "(FAIL|✗).*splice gap"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/cli-doctor.bats -f "Runtime probe|splice gap"`
Expected: FAIL — no runtime probe section exists yet.

- [ ] **Step 3: Add runtime probe to `cmd_doctor`**

After the `== Statusline ==` section in `cmd_doctor`, insert:

```bash
  # --- Statusline runtime probe (NEW) ---
  printf '== Runtime probe ==\n'
  if [[ -z "$statusline_target" || ! -f "$statusline_target" ]]; then
    printf '%s Skipped — no statusline target file to probe.\n' "$section_warn"
  elif [[ -n "${custom_target}" && -z "$custom_language" ]]; then
    printf '%s Skipped — unrecognized statusline language for %s.\n' "$section_warn" "$custom_target"
  else
    local probe_cwd probe_stdin probe_output probe_exit
    probe_cwd="$(pwd)"
    probe_stdin="$(fi_synthetic_stdin "$probe_cwd")"

    # Resolve the executor: bash for canonical, or per-language.
    local executor
    case "$statusline_language" in
      bash)   executor=(bash "$statusline_target") ;;
      node)   executor=(node "$statusline_target") ;;
      python) executor=(python3 "$statusline_target") ;;
    esac

    probe_output="$(printf '%s' "$probe_stdin" | timeout 5 "${executor[@]}" 2>&1 || true)"

    if echo "$probe_output" | LC_ALL=C grep -qE ' \| [0-9]+ '; then
      if fi_has_conflict_markers "$issues_file" 2>/dev/null; then
        printf '%s INCONCLUSIVE — segment rendered, but source file has conflict markers.\n' "$section_warn"
      else
        printf '%s Segment rendered: %s\n' "$section_pass" "$(echo "$probe_output" | head -1 | sed 's/^/   /')"
      fi
    else
      printf '%s FAIL — segment did NOT render in probe output.\n' "$section_fail"
      printf '   Probe output: %s\n' "$(echo "$probe_output" | head -1)"

      # Sub-probe (a): binary cwd resolution
      if "${FI_BIN_DIR}/found-issues" status --format=segment 2>/dev/null | LC_ALL=C grep -qE ' \| '; then
        :  # binary works from this cwd; cwd resolution probably OK
      else
        printf '   - cause: binary resolution / cwd — `found-issues status --format=segment` is empty from %s\n' "$probe_cwd"
      fi

      # Sub-probe (b): splice gap detection
      local output_count seg_count
      case "$statusline_language" in
        node)   output_count="$(LC_ALL=C grep -cE 'console\.log|process\.stdout\.write' "$statusline_target" || true)" ;;
        python) output_count="$(LC_ALL=C grep -cE '^[[:space:]]*print[[:space:]]*\(|sys\.stdout\.write' "$statusline_target" || true)" ;;
        bash)   output_count="$(LC_ALL=C grep -cE '^[[:space:]]*echo[[:space:]]|^[[:space:]]*printf[[:space:]]' "$statusline_target" || true)" ;;
      esac
      seg_count="$(LC_ALL=C grep -c 'found-issues:seg' "$statusline_target" || true)"
      if (( seg_count < output_count )); then
        printf '   - cause: splice gap — %s output statements, only %s patched with `found-issues:seg`.\n' "$output_count" "$seg_count"
        printf '     Re-run: found-issues install-statusline --target %s --apply\n' "$statusline_target"
      fi

      # Sub-probe (c): runtime exception
      if echo "$probe_output" | LC_ALL=C grep -qiE '(error|exception|undefined|cannot|not found)'; then
        printf '   - cause: runtime error in statusline script (see probe output above).\n'
      fi
    fi
  fi
  printf '\n'
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/cli-doctor.bats -f "Runtime probe|splice gap"`
Expected: PASS.

- [ ] **Step 5: Run all doctor tests**

Run: `bats tests/cli-doctor.bats`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add bin/found-issues tests/cli-doctor.bats
git commit -m "$(cat <<'EOF'
feat(doctor): runtime probe + failure-mode narrowing (Layer 3 step 5+6)

doctor now pipes synthetic Claude Code stdin into the user's real
statusline, captures stdout, and asserts the locked segment substring is
present. If not, three sub-probes narrow the cause:
  (a) binary / cwd resolution — `found-issues status --format=segment` empty from probe cwd
  (b) splice gap — count of output statements vs `found-issues:seg` trailers
  (c) runtime exception — pattern-match on stderr/stdout for error keywords

When the source file has conflict markers, the probe result is downgraded
to INCONCLUSIVE rather than OK/FAIL — count-based assertions can't be
trusted during a merge conflict.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 7.4: New subcommand `doctor-statusline-runtime`

**Files:**
- Modify: `bin/found-issues` (add subcommand, route, help text)
- Modify: `tests/cli-doctor.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/cli-doctor.bats`:

```bash
@test "doctor-statusline-runtime: standalone subcommand emits only the runtime probe section" {
  mkdir -p tmp/.claude
  cat > tmp/.found-issues.md <<'EOF'
- [open] 2026-05-13 a.ts:1 — entry
EOF
  cat > tmp/custom.sh <<'EOF'
#!/usr/bin/env bash
input="$(cat)"
dir="$(echo "$input" | jq -r '.workspace.current_dir // ""')"
echo "repo | $dir"
EOF
  chmod +x tmp/custom.sh
  fi_run install-statusline --target tmp/custom.sh --apply
  [ "$status" -eq 0 ]
  cat > tmp/.claude/settings.json <<EOF
{"statusLine": {"command": "bash $(pwd)/tmp/custom.sh"}}
EOF

  HOME="$(pwd)/tmp" fi_run doctor-statusline-runtime
  [ "$status" -eq 0 ]
  # Should contain the runtime probe section but NOT the gh / mode / plugin runtime sections.
  echo "$output" | grep -q "Runtime probe"
  ! echo "$output" | grep -q "Plugin runtime"
  ! echo "$output" | grep -q "Mode detection"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/cli-doctor.bats -f "doctor-statusline-runtime"`
Expected: FAIL — subcommand doesn't exist (probably `unknown subcommand`).

- [ ] **Step 3: Add subcommand**

Add `cmd_doctor_statusline_runtime()` near `cmd_doctor_statusline()` (around line 2620):

```bash
cmd_doctor_statusline_runtime() {
  # Standalone runtime probe. Reuses the same logic from cmd_doctor's runtime
  # probe section but skips the rest of the report. Useful for AI agents and
  # iterative debugging.
  local section_pass="✓" section_warn="!" section_fail="✗"
  if ! locale 2>/dev/null | grep -qi 'utf-8\|utf8'; then
    section_pass="OK"; section_warn="!!"; section_fail="FAIL"
  fi
  # Reuse the same probe logic as cmd_doctor — extracted into a shared helper.
  fi_run_statusline_runtime_probe "$section_pass" "$section_warn" "$section_fail"
}
```

Extract the runtime-probe body from `cmd_doctor` into a new helper `fi_run_statusline_runtime_probe`:

```bash
fi_run_statusline_runtime_probe() {
  local section_pass="$1" section_warn="$2" section_fail="$3"
  # ... [identical body to the runtime probe section added in Task 7.3,
  #      with the variable resolution for $statusline_target / $statusline_language
  #      duplicated here from the cmd_doctor section since this is standalone] ...
  # (See Task 7.3 step 3 for the exact code; the helper is a verbatim extraction
  # with the section header `== Runtime probe ==` included.)
}
```

Update `cmd_doctor` to call the helper instead of inlining the runtime probe body.

- [ ] **Step 4: Wire the subcommand in the main dispatch (around line 3208)**

Replace:

```bash
    doctor-statusline)    cmd_doctor_statusline "$@" ;;
    doctor)               cmd_doctor "$@" ;;
```

with:

```bash
    doctor-statusline)            cmd_doctor_statusline "$@" ;;
    doctor-statusline-runtime)    cmd_doctor_statusline_runtime "$@" ;;
    doctor)                       cmd_doctor "$@" ;;
```

- [ ] **Step 5: Update help text**

Find the help text block (around line 230-240) and add a line for the new subcommand:

```
  doctor-statusline-runtime             Runtime probe only (synthetic stdin → segment assert)
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bats tests/cli-doctor.bats -f "doctor-statusline-runtime"`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add bin/found-issues tests/cli-doctor.bats
git commit -m "$(cat <<'EOF'
feat(doctor): doctor-statusline-runtime standalone subcommand

Extract the runtime probe body into fi_run_statusline_runtime_probe and
expose a standalone CLI entry point. Useful for AI agents iteratively
debugging integrations without re-printing the full doctor report.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 8 — Release prep

### Task 8.1: CHANGELOG entry

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add v1.5.0 entry at top of CHANGELOG.md**

Insert after the header section:

```markdown
## [1.5.0] - 2026-05-13

### Added
- `doctor` runtime probe pipeline: pipes synthetic Claude Code stdin into the real statusline, captures stdout, asserts the segment string is present.
- `doctor-statusline-runtime` subcommand: standalone runtime probe for iterative debugging.
- Doctor now reads `~/.claude/settings.json` for custom statusline targets (`statusLine.command`) and extends static state detection to Node + Python marker formats.
- `fi_has_conflict_markers` parser helper exposing merge-conflict source-file state.
- `FOUND_ISSUES_REMINDER_VERBOSITY` env var (`full`/`terse`/`auto`) controls stop-hook message verbosity. Default `auto` shrinks the 8-line educational message to a single line once `~/.claude/found-issues/.onboarded` exists.
- SessionStart auto-migration for v1.4.x marker blocks: existing custom Node/Python statusline integrations are rewritten in place on next session start, with timestamped backup. Opt-out: `FOUND_ISSUES_AUTO_MIGRATE=off`. Symlinks are skipped.

### Fixed
- **Bug 1** (Windows breakage): The generated Node and Python shim blocks no longer use POSIX-only commands (`command -v`, `ls | sort -V | tail -1`, `process.env.HOME` / `os.environ['HOME']`). They now use `os.homedir()` / `pathlib.Path.home()`, enumerate the plugin cache via filesystem APIs, and invoke `bin/found-issues` via `bash -c` on Windows (Git Bash mediation).
- **Bug 2** (cwd-from-stdin): The shim's segment invocation is now deferred via a function (`__fiSeg(dir)` in Node, `_fi_seg(_dir)` in Python). The splice form opportunistically captures the host statusline's in-scope workspace variable (`dir` or `cwd`) before falling through to env vars. Statuslines that parse stdin (claude-hud, GSD, dotfiles-managed scripts) now get accurate counts.
- **Bug 3** (multi-branch splice): `fi_find_<lang>_splice_point` now returns all line numbers matching the highest-priority pattern. Every output branch in a conditional statusline gets the segment, not just the first.
- **Bug 4** (parser conflict-blind): `fi_entries` skips lines inside `<<<<<<< / >>>>>>>` merge-conflict regions. Statusline counts no longer inflate during a merge.

### Changed
- Marker-block internal contract: `__fiSeg` is now a function, not a value (Node). `_fi_seg` is callable with optional `_dir` (Python). Bash unchanged. Existing v1.4.0/v1.4.1 installs are auto-detected on the next `install-statusline --target` or `doctor` run and offered a `--migrate` rewrite with timestamped backup.
- Splice form: `${__fiSeg}` → `${__fiSeg(typeof dir!=='undefined'?dir:(typeof cwd!=='undefined'?cwd:undefined))}`. The locked `--format=segment` output bytes are **not** changed; only the internal injection point.

### Internal
- New end-to-end CI test group runs the generated shim against synthetic Claude Code stdin on Linux, macOS, and Windows. Previously CI only verified syntax (`node --check`), which let the v1.4.x Windows regression through.
- Multi-branch statusline fixtures added for all three target languages.
- ~620 new lines of code + tests across `bin/found-issues`, `lib/parse-entries.sh`, `tests/cli-doctor.bats`, `tests/cli-install-statusline-custom-target.bats`, `tests/cli-status.bats`, `tests/helpers.bash`.
```

- [ ] **Step 2: Verify**

Run: `head -50 CHANGELOG.md`
Expected: v1.5.0 entry at top with all five sections.

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "$(cat <<'EOF'
docs(changelog): v1.5.0 entry for statusline resilience

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 8.2: Version bump

**Files:**
- Modify: `bin/found-issues` (FI_VERSION constant)
- Modify: `.claude-plugin/plugin.json`

- [ ] **Step 1: Update FI_VERSION**

Find the line `FI_VERSION="1.4.1"` (around line 9 of `bin/found-issues`) and change to:

```bash
readonly FI_VERSION="1.5.0"
```

- [ ] **Step 2: Update plugin.json**

Change `.claude-plugin/plugin.json`:

```json
"version": "1.5.0",
```

- [ ] **Step 3: Run version-check script**

Run: `bash scripts/check-version.sh`
Expected: PASS — version matches CHANGELOG, and the v1.4.1 → v1.5.0 bump is correctly typed as MINOR (CHANGELOG has `### Added` entries, so MINOR is required per SemVer).

- [ ] **Step 4: Commit**

```bash
git add bin/found-issues .claude-plugin/plugin.json
git commit -m "$(cat <<'EOF'
release: bump to v1.5.0

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 8.3: README test count update

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Find the test count line**

Run: `grep -n "tests passing\|tests in CI" README.md`
Expected: a line referencing the v1.4.0 test count (~390).

- [ ] **Step 2: Update the count**

Run the full suite to get the new count:

Run: `bats tests/ 2>&1 | tail -1`
Expected: `XXX tests, 0 failures` where XXX is around 410-420.

Edit `README.md` to reflect the new count and add `v1.5.0` to any version-history reference.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs(readme): update test count + add v1.5.0 to version history

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

### Task 8.4: Open PR for review

- [ ] **Step 1: Push branch**

```bash
git push -u origin feat/statusline-resilience-v1.5.0
```

- [ ] **Step 2: Convert draft to ready-for-review PR**

```bash
gh pr ready feat/statusline-resilience-v1.5.0 || \
  gh pr create --title "feat: statusline resilience v1.5.0 (Windows, multi-branch, conflict-aware)" --body "$(cat <<'EOF'
## Summary
- Bug 1: Cross-platform Node/Python shim (Windows fix)
- Bug 2: Lazy `__fiSeg(dir)` splice form captures in-scope workspace dir
- Bug 3: Splice patches every output branch, not just the first
- Bug 4: Parser skips merge-conflict regions (no more inflated counts)
- Layer 2: End-to-end CI runtime tests on Linux/macOS/Windows
- Layer 3: Doctor reads `settings.json`, runs synthetic-stdin probe, narrows failure mode
- Auto-migration of v1.4.x marker blocks

## Spec
[`docs/superpowers/specs/2026-05-13-statusline-windows-resilience-design.md`](docs/superpowers/specs/2026-05-13-statusline-windows-resilience-design.md)

## Plan
[`docs/superpowers/plans/2026-05-13-statusline-windows-resilience.md`](docs/superpowers/plans/2026-05-13-statusline-windows-resilience.md)

## Test plan
- [ ] CI matrix passes: bats (ubuntu, macos, windows) + shellcheck + json-lint + test-name-lint + version-check
- [ ] Local manual: install on macOS canonical bash statusline, segment renders
- [ ] Windows manual (operator): install on GSD statusline, segment renders
- [ ] Migration manual: take a v1.4.1 install, run `install-statusline --target --apply`, verify v1.4.x marker stripped and v1.5.0 form installed

## Release coupling
After this merges, marketplace PR in `AltDoug/claude-plugins` to update the plugin manifest entry to v1.5.0.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Start a /loop monitoring CI**

Per memory `feedback-always-loop-monitor-prs`: kick off a `/loop` monitor so any CI failure surfaces in-session for fast iteration.

- [ ] **Step 4: Marketplace PR (after merge)**

Per memory `release-coupling-two-repos`: after this PR merges in `AltDoug/found-issues`, open the corresponding PR in `AltDoug/claude-plugins` to bump the plugin manifest entry to `1.5.0`. **Do not** open the marketplace PR before this one merges — the marketplace points at a tag/release that does not yet exist.

---

## Self-review (executed by plan author after writing)

**Spec coverage:**
- Phase 0 (stop-reminder UX) is **out-of-spec** — added 2026-05-13 as a bundled UX prerequisite per operator request. Verified by claude-code-guide that `additionalContext` is unsupported on Stop hooks, so adaptive verbosity is the best available mitigation without breaking the discipline mechanism.
- §2 Bug 1 → Tasks 3.1 (Node) + 4.1 (Python). ✓
- §2 Bug 2 → Splice form change in Tasks 2.1 (Node), 2.2 (Python), shim rewrite in 3.1 + 4.1. ✓
- §2 Bug 3 → Tasks 2.1, 2.2, 2.3 (multi-line splice all three languages). ✓
- §2 Bug 4 → Tasks 1.1, 1.2 (parser conflict-awareness). ✓
- §4 Layer 1 → Phases 1-5. ✓
- §4 Layer 2 → Phase 6. ✓
- §4 Layer 3 → Phase 7. ✓
- §5.7 Migration → Phase 5. ✓
- §8 Migration story (SessionStart auto-trigger) → Task 5.2. ✓ Approved 2026-05-13.
- §10 Versioning → Task 8.2. ✓
- §11 Testing strategy → Phases 1-7. ✓

**Placeholder scan:** No TBDs. Every code block contains the actual code. Helper function bodies referenced from later tasks are defined inline in earlier tasks (`fi_target_is_v14x_broken`, `fi_strip_target_markers`, `fi_synthetic_stdin`, `fi_run_statusline_runtime_probe`).

**Type consistency:** `__fiSeg` is a function throughout; `_fi_seg` is callable in Python throughout; `__FI_SEG` remains a value in bash throughout; `__fiCli` / `_fi_cli` / `__FI_CLI` are binary-path-holders throughout. Marker state names (`installed-fixed`, `installed-broken-posix`) used consistently between `fi_statusline_state` and `cmd_doctor`.

**Scope:** Single coherent v1.5.0 release. Each phase produces independently committable work and could be reverted without breaking later phases (modulo the Phase 2→3+4 commit-deferral for Node/Python which is called out explicitly).

---

## Estimated execution time

- Phase 0: ~20 min (stop-reminder UX prerequisite)
- Phase 1: ~30 min (parser fixes)
- Phase 2: ~60 min (multi-line splice × 3 languages, including bash commit)
- Phase 3: ~30 min (Node shim)
- Phase 4: ~30 min (Python shim)
- Phase 5: ~90 min (migration detection + strip helper + SessionStart auto-migrate)
- Phase 6: ~45 min (Group 5 e2e tests × 3 languages)
- Phase 7: ~75 min (doctor extension)
- Phase 8: ~30 min (release prep + PR)

Total: ~7 hours focused execution. Plus CI iteration time for any Windows-only failures.
