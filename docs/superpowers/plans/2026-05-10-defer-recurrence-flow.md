# Defer Recurrence Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a first-class lifecycle for the `[deferred]` status — `defer` and `promote-deferred` subcommands plus passive recurrence detection in `cmd_log` — so deferred entries that keep biting the operator surface naturally without manual review.

**Architecture:** Three new optional parenthetical annotations (`(touched: ...)`, `(defer-cycle: N)`, `(reason: ...)`) extend the existing entry format backwards-compatibly. Touch detection extends the existing dedup loop in `cmd_log` to also scan `[deferred]` entries. Hybrid promotion: critical `[!]` entries auto-promote on Nth touch; non-critical entries nudge the operator. Persistent touch history + geometric threshold escalation (3 → 6 → 12 → 24 per defer-cycle) prevents loop theater.

**Tech Stack:** Bash 3.2+ (macOS system bash), bats for tests, awk/grep/sed for text manipulation, atomic temp+mv pattern for file mutations.

**Spec:** [`docs/superpowers/specs/2026-05-10-defer-recurrence-flow-design.md`](../specs/2026-05-10-defer-recurrence-flow-design.md)

---

## File Structure

**New files:**
- `commands/defer.md` — skill wrapper for `/found-issues:defer`
- `commands/promote-deferred.md` — skill wrapper for `/found-issues:promote-deferred`
- `tests/cli-defer.bats` — defer subcommand tests
- `tests/cli-promote-deferred.bats` — promote-deferred subcommand tests

**Modified files:**
- `lib/parse-entries.sh` — add 7 new helper functions for touch/cycle/reason annotations
- `bin/found-issues` — add `cmd_defer`, `cmd_promote_deferred`, extend `cmd_log` dedup, wire dispatch, add help text, bump `FI_VERSION`
- `hooks/format-enforcer.sh` — extend regex to accept `(touched: ...)`, `(defer-cycle: N)`, `(reason: ...)` annotations
- `hooks/pre-commit.sh` — same extension
- `tests/parse-entries.bats` — tests for the 7 new lib helpers
- `tests/cli-log.bats` — touch-detection cases (count branches, escalation, same-day, env vars)
- `tests/cli-status.bats` — regression tests for promoted-entry counting
- `tests/format-enforcer.bats` — accept new annotation patterns
- `tests/pre-commit.bats` — accept new annotation patterns
- `CHANGELOG.md` — 1.0.5 entry
- `README.md` — new "Deferring recurring issues" subsection
- `.claude-plugin/plugin.json` — version bump to 1.0.5

**Phase boundaries (one PR per phase, reviewable independently):**
- Phase 1 (Tasks 1.1–1.10): Lib helpers + hook extensions. Foundational. No behavior change yet.
- Phase 2 (Tasks 2.1–2.12): `defer` + `promote-deferred` subcommands. Additive. Doesn't touch `cmd_log`.
- Phase 3 (Tasks 3.1–3.7): Extend `cmd_log` dedup to scan `[deferred]`. The recurrence-detection feature.
- Phase 4 (Tasks 4.1–4.3): CHANGELOG, README, version bump.

---

# Phase 1 — Lib helpers + hook extensions

Foundational. All seven helpers extend `lib/parse-entries.sh`. Each helper gets its own task with TDD cycle. No behavior change to existing CLI yet.

---

### Task 1.1: Add `fi_extract_touched_segment` helper

Extracts the value of the `(touched: ...)` annotation from an entry line. Returns empty string if absent. This is the foundation other touch helpers build on.

**Files:**
- Modify: `lib/parse-entries.sh` (append after `fi_count_stale`)
- Test: `tests/parse-entries.bats` (append at end of file)

- [ ] **Step 1: Write the failing test**

Append to `tests/parse-entries.bats`:

```bash
@test "fi_extract_touched_segment: returns empty when annotation absent" {
  fi_source_lib parse-entries
  result="$(fi_extract_touched_segment "- [deferred] 2026-05-10 src/foo.py:42 — bug")"
  [ -z "$result" ]
}

@test "fi_extract_touched_segment: extracts single date" {
  fi_source_lib parse-entries
  result="$(fi_extract_touched_segment "- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21)")"
  [ "$result" = "2026-05-21" ]
}

@test "fi_extract_touched_segment: extracts multiple dates with cycle separator" {
  fi_source_lib parse-entries
  result="$(fi_extract_touched_segment "- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, 2026-05-28; 2026-07-15)")"
  [ "$result" = "2026-05-21, 2026-05-28; 2026-07-15" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/parse-entries.bats -f "fi_extract_touched_segment"`
Expected: 3 failures, "command not found: fi_extract_touched_segment".

- [ ] **Step 3: Implement the helper**

Append to `lib/parse-entries.sh` (after the `fi_count_stale` function ends at line 241):

```bash
# Extract the value of the (touched: ...) annotation from an entry line.
# Echoes the raw value (comma-separated dates, possibly with ';' cycle
# separators). Echoes empty string if the annotation is absent.
fi_extract_touched_segment() {
  local line="$1"
  local re_touched='\(touched: ([^)]+)\)'
  if [[ "$line" =~ $re_touched ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/parse-entries.bats -f "fi_extract_touched_segment"`
Expected: 3 passes.

- [ ] **Step 5: Commit**

```bash
git add lib/parse-entries.sh tests/parse-entries.bats
git commit -m "feat(lib): add fi_extract_touched_segment helper

Extracts (touched: ...) annotation value from an entry line.
Foundation for the defer-recurrence touch counter (Phase 1 of the
defer-recurrence-flow spec).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.2: Add `fi_current_cycle_touch_count` helper

Counts dates in the **current cycle's segment** (after the last `;` in the touched annotation). Returns 0 if annotation absent or current segment is empty.

**Files:**
- Modify: `lib/parse-entries.sh` (append after `fi_extract_touched_segment`)
- Test: `tests/parse-entries.bats` (append)

- [ ] **Step 1: Write the failing test**

Append to `tests/parse-entries.bats`:

```bash
@test "fi_current_cycle_touch_count: returns 0 when annotation absent" {
  fi_source_lib parse-entries
  result="$(fi_current_cycle_touch_count "- [deferred] 2026-05-10 src/foo.py:42 — bug")"
  [ "$result" -eq 0 ]
}

@test "fi_current_cycle_touch_count: counts dates in cycle 1 (no separator)" {
  fi_source_lib parse-entries
  result="$(fi_current_cycle_touch_count "- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, 2026-05-28, 2026-06-04)")"
  [ "$result" -eq 3 ]
}

@test "fi_current_cycle_touch_count: counts only current cycle (after last ';')" {
  fi_source_lib parse-entries
  result="$(fi_current_cycle_touch_count "- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, 2026-05-28, 2026-06-04; 2026-07-15, 2026-07-22)")"
  [ "$result" -eq 2 ]
}

@test "fi_current_cycle_touch_count: returns 0 when current segment is empty (just appended ';')" {
  fi_source_lib parse-entries
  result="$(fi_current_cycle_touch_count "- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, 2026-05-28; )")"
  [ "$result" -eq 0 ]
}

@test "fi_current_cycle_touch_count: ignores malformed (non-date) tokens" {
  fi_source_lib parse-entries
  result="$(fi_current_cycle_touch_count "- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, garbage, 2026-05-28)")"
  [ "$result" -eq 2 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/parse-entries.bats -f "fi_current_cycle_touch_count"`
Expected: 5 failures.

- [ ] **Step 3: Implement the helper**

Append to `lib/parse-entries.sh`:

```bash
# Count the number of well-formed YYYY-MM-DD dates in the CURRENT cycle's
# segment of the (touched: ...) annotation. The current segment is the
# substring after the last ';' separator (or the entire annotation if no
# ';' is present). Echoes 0 if the annotation is absent or the current
# segment contains no well-formed dates.
fi_current_cycle_touch_count() {
  local line="$1"
  local segment
  segment="$(fi_extract_touched_segment "$line")"
  if [[ -z "$segment" ]]; then
    printf '0'
    return
  fi

  # Take everything after the last ';' (if no ';', this is the full segment).
  local current="${segment##*;}"

  # Count well-formed dates (defensive: ignore garbage tokens).
  local count
  count="$(printf '%s' "$current" \
    | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' \
    | grep -c . || true)"
  printf '%s' "${count:-0}"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/parse-entries.bats -f "fi_current_cycle_touch_count"`
Expected: 5 passes.

- [ ] **Step 5: Commit**

```bash
git add lib/parse-entries.sh tests/parse-entries.bats
git commit -m "feat(lib): add fi_current_cycle_touch_count helper

Counts well-formed dates in the current cycle's segment of the
(touched: ...) annotation. Defensive against malformed tokens.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.3: Add `fi_extract_defer_cycle` helper

Reads the `(defer-cycle: N)` annotation. Returns 1 if absent (implicit cycle 1) or non-numeric (defensive).

**Files:**
- Modify: `lib/parse-entries.sh`
- Test: `tests/parse-entries.bats`

- [ ] **Step 1: Write the failing test**

```bash
@test "fi_extract_defer_cycle: returns 1 when annotation absent" {
  fi_source_lib parse-entries
  result="$(fi_extract_defer_cycle "- [deferred] 2026-05-10 src/foo.py:42 — bug")"
  [ "$result" -eq 1 ]
}

@test "fi_extract_defer_cycle: extracts numeric cycle" {
  fi_source_lib parse-entries
  result="$(fi_extract_defer_cycle "- [deferred] 2026-05-10 src/foo.py:42 — bug (defer-cycle: 3)")"
  [ "$result" -eq 3 ]
}

@test "fi_extract_defer_cycle: defaults to 1 on non-numeric value (defensive)" {
  fi_source_lib parse-entries
  result="$(fi_extract_defer_cycle "- [deferred] 2026-05-10 src/foo.py:42 — bug (defer-cycle: garbage)")"
  [ "$result" -eq 1 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/parse-entries.bats -f "fi_extract_defer_cycle"`
Expected: 3 failures.

- [ ] **Step 3: Implement the helper**

Append to `lib/parse-entries.sh`:

```bash
# Extract the integer value of the (defer-cycle: N) annotation.
# Defaults to 1 (implicit cycle 1) if the annotation is absent or
# non-numeric.
fi_extract_defer_cycle() {
  local line="$1"
  local re_cycle='\(defer-cycle: ([0-9]+)\)'
  if [[ "$line" =~ $re_cycle ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '1'
  fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/parse-entries.bats -f "fi_extract_defer_cycle"`
Expected: 3 passes.

- [ ] **Step 5: Commit**

```bash
git add lib/parse-entries.sh tests/parse-entries.bats
git commit -m "feat(lib): add fi_extract_defer_cycle helper

Reads (defer-cycle: N) annotation. Defaults to 1 if absent or non-numeric.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.4: Add `fi_extract_reason` helper

Reads the `(reason: ...)` annotation value. Returns empty string if absent.

**Files:**
- Modify: `lib/parse-entries.sh`
- Test: `tests/parse-entries.bats`

- [ ] **Step 1: Write the failing test**

```bash
@test "fi_extract_reason: returns empty when annotation absent" {
  fi_source_lib parse-entries
  result="$(fi_extract_reason "- [deferred] 2026-05-10 src/foo.py:42 — bug")"
  [ -z "$result" ]
}

@test "fi_extract_reason: extracts reason text" {
  fi_source_lib parse-entries
  result="$(fi_extract_reason "- [deferred] 2026-05-10 src/foo.py:42 — bug (reason: tracked in JIRA-1234)")"
  [ "$result" = "tracked in JIRA-1234" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/parse-entries.bats -f "fi_extract_reason"`
Expected: 2 failures.

- [ ] **Step 3: Implement the helper**

Append to `lib/parse-entries.sh`:

```bash
# Extract the value of the (reason: ...) annotation.
# Echoes empty string if absent.
fi_extract_reason() {
  local line="$1"
  local re_reason='\(reason: ([^)]+)\)'
  if [[ "$line" =~ $re_reason ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/parse-entries.bats -f "fi_extract_reason"`
Expected: 2 passes.

- [ ] **Step 5: Commit**

```bash
git add lib/parse-entries.sh tests/parse-entries.bats
git commit -m "feat(lib): add fi_extract_reason helper

Reads (reason: ...) annotation. Echoes empty string if absent.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.5: Add `fi_compute_threshold` helper

Computes touch threshold for a given defer-cycle. Default formula: `3 * 2^(N-1)`. Env vars `FOUND_ISSUES_DEFER_TOUCH_THRESHOLD` (base, default 3) and `FOUND_ISSUES_DEFER_ESCALATION_FACTOR` (factor, default 2) override. Invalid values warn to stderr and fall back to defaults.

**Files:**
- Modify: `lib/parse-entries.sh`
- Test: `tests/parse-entries.bats`

- [ ] **Step 1: Write the failing test**

```bash
@test "fi_compute_threshold: cycle 1 default (3)" {
  fi_source_lib parse-entries
  unset FOUND_ISSUES_DEFER_TOUCH_THRESHOLD FOUND_ISSUES_DEFER_ESCALATION_FACTOR
  result="$(fi_compute_threshold 1)"
  [ "$result" -eq 3 ]
}

@test "fi_compute_threshold: cycle 2 default (6)" {
  fi_source_lib parse-entries
  unset FOUND_ISSUES_DEFER_TOUCH_THRESHOLD FOUND_ISSUES_DEFER_ESCALATION_FACTOR
  result="$(fi_compute_threshold 2)"
  [ "$result" -eq 6 ]
}

@test "fi_compute_threshold: cycle 4 default (24)" {
  fi_source_lib parse-entries
  unset FOUND_ISSUES_DEFER_TOUCH_THRESHOLD FOUND_ISSUES_DEFER_ESCALATION_FACTOR
  result="$(fi_compute_threshold 4)"
  [ "$result" -eq 24 ]
}

@test "fi_compute_threshold: respects custom base" {
  fi_source_lib parse-entries
  FOUND_ISSUES_DEFER_TOUCH_THRESHOLD=5 \
  FOUND_ISSUES_DEFER_ESCALATION_FACTOR=2 \
    result="$(fi_compute_threshold 2)"
  [ "$result" -eq 10 ]
}

@test "fi_compute_threshold: respects custom factor" {
  fi_source_lib parse-entries
  FOUND_ISSUES_DEFER_TOUCH_THRESHOLD=3 \
  FOUND_ISSUES_DEFER_ESCALATION_FACTOR=3 \
    result="$(fi_compute_threshold 3)"
  [ "$result" -eq 27 ]
}

@test "fi_compute_threshold: invalid base falls back to default with warning" {
  fi_source_lib parse-entries
  FOUND_ISSUES_DEFER_TOUCH_THRESHOLD=garbage \
    result="$(fi_compute_threshold 1 2>&1)"
  [[ "$result" == *"3"* ]]
  [[ "$result" == *"warning"* ]] || [[ "$result" == *"FOUND_ISSUES_DEFER_TOUCH_THRESHOLD"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/parse-entries.bats -f "fi_compute_threshold"`
Expected: 6 failures.

- [ ] **Step 3: Implement the helper**

Append to `lib/parse-entries.sh`:

```bash
# Compute touch threshold for a given defer-cycle.
# Formula: BASE * FACTOR^(cycle-1), defaulting to 3 * 2^(N-1).
# Env vars FOUND_ISSUES_DEFER_TOUCH_THRESHOLD (base) and
# FOUND_ISSUES_DEFER_ESCALATION_FACTOR (factor) override defaults.
# Invalid values (non-numeric, <= 0) warn to stderr and fall back.
fi_compute_threshold() {
  local cycle="${1:-1}"
  local base="${FOUND_ISSUES_DEFER_TOUCH_THRESHOLD:-3}"
  local factor="${FOUND_ISSUES_DEFER_ESCALATION_FACTOR:-2}"

  if ! [[ "$base" =~ ^[0-9]+$ ]] || (( base <= 0 )); then
    printf 'warning: invalid FOUND_ISSUES_DEFER_TOUCH_THRESHOLD=%s (must be positive integer); using default 3\n' "$base" >&2
    base=3
  fi
  if ! [[ "$factor" =~ ^[0-9]+$ ]] || (( factor <= 0 )); then
    printf 'warning: invalid FOUND_ISSUES_DEFER_ESCALATION_FACTOR=%s (must be positive integer); using default 2\n' "$factor" >&2
    factor=2
  fi
  if ! [[ "$cycle" =~ ^[0-9]+$ ]] || (( cycle <= 0 )); then
    cycle=1
  fi

  # Compute base * factor^(cycle-1) using awk (bash has no power operator).
  awk -v b="$base" -v f="$factor" -v c="$cycle" 'BEGIN { printf "%d", b * (f ^ (c - 1)) }'
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/parse-entries.bats -f "fi_compute_threshold"`
Expected: 6 passes.

- [ ] **Step 5: Commit**

```bash
git add lib/parse-entries.sh tests/parse-entries.bats
git commit -m "feat(lib): add fi_compute_threshold helper

Computes touch threshold for a given defer-cycle. Default 3 * 2^(N-1).
Env vars FOUND_ISSUES_DEFER_TOUCH_THRESHOLD and
FOUND_ISSUES_DEFER_ESCALATION_FACTOR override; invalid values warn and
fall back to defaults.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.6: Add `fi_append_touch` helper

Mutates a markdown file: appends a date to the matching entry's `(touched: ...)` annotation. Creates the annotation if absent. Appends after the last `;` (in the current cycle's segment) if present.

**Files:**
- Modify: `lib/parse-entries.sh`
- Test: `tests/parse-entries.bats`

- [ ] **Step 1: Write the failing test**

```bash
@test "fi_append_touch: creates annotation when absent" {
  fi_source_lib parse-entries
  cat > test.md <<'EOF'
- [deferred] 2026-05-10 src/foo.py:42 — bug
EOF
  fi_append_touch test.md "- [deferred] 2026-05-10 src/foo.py:42 — bug" "2026-05-21"
  grep -F "(touched: 2026-05-21)" test.md
}

@test "fi_append_touch: appends to existing single-cycle annotation" {
  fi_source_lib parse-entries
  cat > test.md <<'EOF'
- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21)
EOF
  fi_append_touch test.md "- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21)" "2026-05-28"
  grep -F "(touched: 2026-05-21, 2026-05-28)" test.md
}

@test "fi_append_touch: appends after last ';' (cycle 2)" {
  fi_source_lib parse-entries
  cat > test.md <<'EOF'
- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, 2026-05-28; ) (defer-cycle: 2)
EOF
  fi_append_touch test.md "- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, 2026-05-28; ) (defer-cycle: 2)" "2026-07-15"
  grep -F "(touched: 2026-05-21, 2026-05-28; 2026-07-15)" test.md
}

@test "fi_append_touch: leaves other entries untouched" {
  fi_source_lib parse-entries
  cat > test.md <<'EOF'
- [deferred] 2026-05-10 src/foo.py:42 — bug
- [open] 2026-05-11 src/bar.py:99 — other bug
- [deferred] 2026-05-12 src/baz.py:1 — third bug
EOF
  fi_append_touch test.md "- [deferred] 2026-05-10 src/foo.py:42 — bug" "2026-05-21"
  grep -F "(touched: 2026-05-21)" test.md
  ! grep -F "(touched:" <(grep "src/bar.py" test.md)
  ! grep -F "(touched:" <(grep "src/baz.py" test.md)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/parse-entries.bats -f "fi_append_touch"`
Expected: 4 failures.

- [ ] **Step 3: Implement the helper**

Append to `lib/parse-entries.sh`:

```bash
# Mutate file: append date to the matching entry's (touched: ...) annotation.
# Atomic via temp+mv. Matches entry by exact line equality.
#
# Append rules:
#   - No (touched: ...) annotation: insert " (touched: <date>)" before the
#     first existing parenthetical OR at end of line if no parentheticals.
#     For consistency we always insert at end of line (annotations are
#     order-independent in this format).
#   - Has (touched: ...) and current segment is empty (annotation ends with ';' or '; '):
#     append "<date>" right before the closing ')'.
#   - Has (touched: ...) with content in current segment:
#     append ", <date>" right before the closing ')'.
fi_append_touch() {
  local file="$1"
  local target_entry="$2"
  local date="$3"

  if [[ ! -f "$file" ]]; then
    return 1
  fi

  local tmp
  tmp="$(mktemp -t fi-touch.XXXXXX)"

  local found=0
  while IFS= read -r line; do
    if [[ "$line" == "$target_entry" ]] && (( found == 0 )); then
      found=1
      local new_line
      if [[ "$line" =~ \(touched:\ ([^\)]*)\) ]]; then
        local existing="${BASH_REMATCH[1]}"
        # Determine current cycle segment (after last ';')
        local current="${existing##*;}"
        # Trim leading whitespace from current
        current="${current#"${current%%[![:space:]]*}"}"
        local new_value
        if [[ -z "$current" ]]; then
          # Current segment is empty (just appended ';' / '; ')
          new_value="${existing} ${date}"
          # Normalize: ensure exactly one space after ';'
          new_value="$(printf '%s' "$new_value" | sed -E 's/;[[:space:]]+/; /g')"
        else
          # Current segment has content: append ", date"
          new_value="${existing}, ${date}"
        fi
        # Replace the existing annotation
        new_line="${line//(touched: $existing)/(touched: $new_value)}"
      else
        # No existing annotation: append at end of line
        new_line="${line} (touched: ${date})"
      fi
      printf '%s\n' "$new_line" >> "$tmp"
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"

  if (( found == 0 )); then
    rm -f "$tmp"
    return 2
  fi

  mv "$tmp" "$file"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/parse-entries.bats -f "fi_append_touch"`
Expected: 4 passes.

- [ ] **Step 5: Commit**

```bash
git add lib/parse-entries.sh tests/parse-entries.bats
git commit -m "feat(lib): add fi_append_touch helper

Atomic mutation: appends date to a target entry's (touched: ...)
annotation. Creates annotation if absent; appends to current cycle's
segment if present. Other entries untouched.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.7: Add `fi_increment_defer_cycle` helper

Mutates a markdown file: increments the `(defer-cycle: N)` annotation on a target entry, and appends `;` to the `(touched: ...)` annotation if the current cycle's segment has content.

**Files:**
- Modify: `lib/parse-entries.sh`
- Test: `tests/parse-entries.bats`

- [ ] **Step 1: Write the failing test**

```bash
@test "fi_increment_defer_cycle: adds (defer-cycle: 2) and ';' to touched on first re-defer" {
  fi_source_lib parse-entries
  cat > test.md <<'EOF'
- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, 2026-05-28)
EOF
  fi_increment_defer_cycle test.md "- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, 2026-05-28)"
  grep -F "(defer-cycle: 2)" test.md
  grep -F "(touched: 2026-05-21, 2026-05-28; )" test.md
}

@test "fi_increment_defer_cycle: bumps existing cycle (2 -> 3)" {
  fi_source_lib parse-entries
  cat > test.md <<'EOF'
- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, 2026-05-28; 2026-07-15) (defer-cycle: 2)
EOF
  fi_increment_defer_cycle test.md "- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, 2026-05-28; 2026-07-15) (defer-cycle: 2)"
  grep -F "(defer-cycle: 3)" test.md
  grep -F "(touched: 2026-05-21, 2026-05-28; 2026-07-15; )" test.md
  ! grep -F "(defer-cycle: 2)" test.md
}

@test "fi_increment_defer_cycle: no ';' appended when no touched annotation" {
  fi_source_lib parse-entries
  cat > test.md <<'EOF'
- [deferred] 2026-05-10 src/foo.py:42 — bug
EOF
  fi_increment_defer_cycle test.md "- [deferred] 2026-05-10 src/foo.py:42 — bug"
  grep -F "(defer-cycle: 2)" test.md
  ! grep "touched:" test.md
}

@test "fi_increment_defer_cycle: no ';' appended when current segment is empty" {
  fi_source_lib parse-entries
  cat > test.md <<'EOF'
- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21; ) (defer-cycle: 2)
EOF
  fi_increment_defer_cycle test.md "- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21; ) (defer-cycle: 2)"
  grep -F "(defer-cycle: 3)" test.md
  # No double ';;' — annotation stays "; "
  grep -F "(touched: 2026-05-21; )" test.md
  ! grep -F ";;" test.md
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/parse-entries.bats -f "fi_increment_defer_cycle"`
Expected: 4 failures.

- [ ] **Step 3: Implement the helper**

Append to `lib/parse-entries.sh`:

```bash
# Mutate file: increment the (defer-cycle: N) annotation on a target entry.
# If absent, sets to 2 (since absent means cycle 1 implicitly).
# Also appends ';' separator to (touched: ...) IF that annotation exists
# AND its current segment has content. Skips ';' append when there's
# nothing to separate.
fi_increment_defer_cycle() {
  local file="$1"
  local target_entry="$2"

  if [[ ! -f "$file" ]]; then
    return 1
  fi

  local tmp
  tmp="$(mktemp -t fi-defercycle.XXXXXX)"

  local found=0
  while IFS= read -r line; do
    if [[ "$line" == "$target_entry" ]] && (( found == 0 )); then
      found=1
      local new_line="$line"

      # Bump (or add) defer-cycle annotation
      if [[ "$new_line" =~ \(defer-cycle:\ ([0-9]+)\) ]]; then
        local current_cycle="${BASH_REMATCH[1]}"
        local next_cycle=$((current_cycle + 1))
        new_line="${new_line//(defer-cycle: $current_cycle)/(defer-cycle: $next_cycle)}"
      else
        new_line="${new_line} (defer-cycle: 2)"
      fi

      # Append ';' to touched annotation if it has content in current segment
      if [[ "$new_line" =~ \(touched:\ ([^\)]*)\) ]]; then
        local existing="${BASH_REMATCH[1]}"
        local current="${existing##*;}"
        current="${current#"${current%%[![:space:]]*}"}"
        if [[ -n "$current" ]]; then
          local new_touched="${existing}; "
          new_line="${new_line//(touched: $existing)/(touched: $new_touched)}"
        fi
        # If current is empty (already ends in ';'), do nothing
      fi

      printf '%s\n' "$new_line" >> "$tmp"
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"

  if (( found == 0 )); then
    rm -f "$tmp"
    return 2
  fi

  mv "$tmp" "$file"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/parse-entries.bats -f "fi_increment_defer_cycle"`
Expected: 4 passes.

- [ ] **Step 5: Commit**

```bash
git add lib/parse-entries.sh tests/parse-entries.bats
git commit -m "feat(lib): add fi_increment_defer_cycle helper

Atomic mutation: bumps (defer-cycle: N) annotation. Appends ';' to
(touched: ...) IF current segment has content (skip when nothing to
separate, preventing ';;' artifacts).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.8: Extend `format-enforcer.sh` to accept new annotation patterns

The format-enforcer hook validates entries on edit. Extend its regex to recognize `(touched: ...)`, `(defer-cycle: N)`, `(reason: ...)` as valid annotation patterns so it doesn't flag them as malformed.

**Files:**
- Modify: `hooks/format-enforcer.sh`
- Test: `tests/format-enforcer.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/format-enforcer.bats`:

```bash
@test "format-enforcer: accepts entry with (touched: ...) annotation" {
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, 2026-05-28)
EOF
  fi_run_hook format-enforcer docs/found-issues.md
  [ "$status" -eq 0 ]
}

@test "format-enforcer: accepts entry with (defer-cycle: N) annotation" {
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21; 2026-07-15) (defer-cycle: 2)
EOF
  fi_run_hook format-enforcer docs/found-issues.md
  [ "$status" -eq 0 ]
}

@test "format-enforcer: accepts entry with (reason: ...) annotation" {
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — bug (reason: tracked in JIRA-1234)
EOF
  fi_run_hook format-enforcer docs/found-issues.md
  [ "$status" -eq 0 ]
}
```

(Note: `fi_run_hook` is the existing test helper. If it doesn't exist with that exact signature, check `tests/helpers.bash` and use the same pattern existing format-enforcer tests use to invoke the hook script.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/format-enforcer.bats -f "annotation"`
Expected: failures (or false positives — depends on current strictness).

- [ ] **Step 3: Inspect the existing format-enforcer regex**

Read `hooks/format-enforcer.sh` and locate the regex/check that validates parenthetical annotation patterns. Look for any allowlist of valid annotations like `suggested:`, `PR:`, `commit:`, `fixed:`, `verified:`. Add `touched:`, `defer-cycle:`, `reason:` to that allowlist.

If the format-enforcer doesn't have an explicit allowlist (and just checks structural shape like "entries start with `- [status]`"), then no code change is needed — the new annotations are already structurally valid (parenthetical at end of line). In that case, the tests above would pass without changes; verify by running them.

If the allowlist exists, extend it. Example pattern:

```bash
# Before:
local re_known_annotations='\((suggested|PR|commit|fixed|verified):'
# After:
local re_known_annotations='\((suggested|PR|commit|fixed|verified|touched|defer-cycle|reason):'
```

(Adapt to actual file structure — read it first to see the real pattern.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/format-enforcer.bats`
Expected: all tests pass (no regressions; new tests pass).

- [ ] **Step 5: Commit**

```bash
git add hooks/format-enforcer.sh tests/format-enforcer.bats
git commit -m "feat(hooks): format-enforcer accepts new defer-flow annotations

Adds (touched: ...), (defer-cycle: N), (reason: ...) to the recognized
annotation patterns so deferred entries with touch history don't get
flagged as malformed by the post-edit hook.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.9: Extend `pre-commit.sh` hook to accept new annotation patterns

Same extension as Task 1.8 but for the pre-commit git hook (which validates entries at commit time when `docs/found-issues.md` is staged).

**Files:**
- Modify: `hooks/pre-commit.sh`
- Test: `tests/pre-commit.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/pre-commit.bats`:

```bash
@test "pre-commit: accepts entry with (touched: ...) annotation" {
  fi_init_git
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, 2026-05-28)
EOF
  git add docs/found-issues.md
  fi_run_hook pre-commit
  [ "$status" -eq 0 ]
}

@test "pre-commit: accepts entry with (defer-cycle: N) annotation" {
  fi_init_git
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21; 2026-07-15) (defer-cycle: 2)
EOF
  git add docs/found-issues.md
  fi_run_hook pre-commit
  [ "$status" -eq 0 ]
}

@test "pre-commit: accepts entry with (reason: ...) annotation" {
  fi_init_git
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — bug (reason: tracked in JIRA-1234)
EOF
  git add docs/found-issues.md
  fi_run_hook pre-commit
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/pre-commit.bats -f "annotation"`
Expected: failures (if hook has annotation allowlist) or pass (if structural check only).

- [ ] **Step 3: Inspect and extend `hooks/pre-commit.sh`**

Same pattern as Task 1.8. Read the existing pre-commit hook, locate any annotation allowlist regex, extend with `touched|defer-cycle|reason`. If no allowlist exists (structural check only), the tests should pass without code change.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/pre-commit.bats`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add hooks/pre-commit.sh tests/pre-commit.bats
git commit -m "feat(hooks): pre-commit accepts new defer-flow annotations

Mirrors the format-enforcer extension. Pre-commit validation accepts
(touched: ...), (defer-cycle: N), (reason: ...) annotations on staged
entries.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 1.10: Phase 1 — full suite green + branch + PR

End of Phase 1. Verify nothing regressed, then prepare the PR.

- [ ] **Step 1: Run the full bats suite**

Run: `bats tests/`
Expected: all tests pass; new test count is 184 (current) + 27 (Phase 1: 3+5+3+2+6+4+4+3+3 = 33 new helper + hook tests). Final number depends on whether hook tests required code changes (some may have already passed). If any test fails, return to the relevant task and fix.

- [ ] **Step 2: Verify no helper-function name conflicts**

Run: `grep -nE '^fi_[a-z_]+\(\)' lib/parse-entries.sh`
Expected: All function names unique. Should see new entries: `fi_extract_touched_segment`, `fi_current_cycle_touch_count`, `fi_extract_defer_cycle`, `fi_extract_reason`, `fi_compute_threshold`, `fi_append_touch`, `fi_increment_defer_cycle`.

- [ ] **Step 3: Push the branch**

Run:
```bash
git push -u origin feat/defer-recurrence-flow
```

Expected: push succeeds; branch tracks origin.

- [ ] **Step 4: Open the PR**

Run:
```bash
gh pr create --title "feat(lib+hooks): defer-recurrence flow Phase 1 — helpers + hook acceptance" --body "$(cat <<'EOF'
## Summary

Phase 1 of the defer-recurrence-flow spec. Foundational lib helpers + hook regex extensions. **No behavior change to any existing CLI subcommand yet** — Phase 2 (defer/promote-deferred subcommands) and Phase 3 (cmd_log dedup extension) build on this.

## What's added

7 new helper functions in `lib/parse-entries.sh`:
- `fi_extract_touched_segment` — read `(touched: ...)` annotation value
- `fi_current_cycle_touch_count` — count dates after last `;` in touched annotation
- `fi_extract_defer_cycle` — read `(defer-cycle: N)`, default 1
- `fi_extract_reason` — read `(reason: ...)`
- `fi_compute_threshold` — `BASE * FACTOR^(cycle-1)`, env-var configurable
- `fi_append_touch` — atomic mutation: append date to entry's touched annotation
- `fi_increment_defer_cycle` — atomic mutation: bump defer-cycle, append `;` to touched if current segment has content

Hook extensions:
- `hooks/format-enforcer.sh` and `hooks/pre-commit.sh` accept new annotation patterns

## Test plan

- [x] ~33 new bats tests covering all helpers + hook acceptance
- [x] Full bats suite green (no regressions)
- [ ] CI matrix (Linux/macOS/Windows)

## Spec

[`docs/superpowers/specs/2026-05-10-defer-recurrence-flow-design.md`](docs/superpowers/specs/2026-05-10-defer-recurrence-flow-design.md)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL printed.

- [ ] **Step 5: Queue auto-merge**

Run:
```bash
gh pr merge --squash --delete-branch --auto
```

Expected: auto-merge queued. Phase 1 lands when CI passes. Move to Phase 2.

---

# Phase 2 — `defer` + `promote-deferred` subcommands

Additive. Build on Phase 1 helpers. Doesn't touch `cmd_log` (that's Phase 3). After Phase 2 lands, the operator can defer/promote-deferred via CLI but recurrence detection isn't wired up yet.

**Branch off Phase 1 main** (or off Phase 1 branch if not yet merged):

```bash
git checkout main && git pull --ff-only
git checkout -b feat/defer-recurrence-flow-phase-2
```

---

### Task 2.1: Implement `cmd_defer` skeleton (basic flip, no error paths yet)

Just the happy path: take a match, find one [open] entry, flip status to [deferred].

**Files:**
- Modify: `bin/found-issues` (add `cmd_defer` function)
- Test: `tests/cli-defer.bats` (new file)

- [ ] **Step 1: Write the failing test**

Create `tests/cli-defer.bats`:

```bash
#!/usr/bin/env bats
# Tests for `found-issues defer`

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

@test "defer: flips [open] to [deferred] on basic match" {
  fi_run log "src/foo.py:42 — null check missing"
  [ "$status" -eq 0 ]
  fi_run defer "src/foo.py:42"
  [ "$status" -eq 0 ]
  grep -F "[deferred]" docs/found-issues.md
  ! grep -F "[open]" docs/found-issues.md
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/cli-defer.bats -f "basic"`
Expected: failure ("Unknown subcommand" or similar).

- [ ] **Step 3: Implement `cmd_defer` skeleton**

In `bin/found-issues`, add this function (place after the existing `cmd_log` function, around line ~480):

```bash
# === Subcommand: defer ===
#
# Flips [open] → [deferred] for the entry matching <match>.
# Match is a substring matched case-insensitively against the entry's path
# OR symptom (after canonicalization). Same matching style as annotate-pr.
#
# On re-defer (entry already has touched: history), increments defer-cycle
# annotation and appends ';' to touched to mark the new cycle boundary.
#
# Exits:
#   0 success
#   1 no matching [open] entry
#   2 ambiguous (multiple matches)
#   3 entry already [deferred] (with helpful re-defer-after-promote message)
#   4 entry has active (PR: ...) annotation (would silently drop from in-PR count)
cmd_defer() {
  local match="${1:-}"
  local reason=""

  # Argument parsing
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reason)
        reason="${2:-}"
        shift 2 || break
        ;;
      *)
        shift
        ;;
    esac
  done

  if [[ -z "$match" ]]; then
    fi_err "defer: missing <match> argument"
    fi_err "Usage: found-issues defer <match> [--reason \"<text>\"]"
    return 2
  fi

  local file
  file="$(fi_resolve_issues_file)"

  # Find matching [open] entries
  local matches=()
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    # Case-insensitive substring match on the whole entry line
    local lower_entry lower_match
    lower_entry="$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')"
    lower_match="$(printf '%s' "$match" | tr '[:upper:]' '[:lower:]')"
    if [[ "$lower_entry" == *"$lower_match"* ]]; then
      matches+=("$entry")
    fi
  done < <(fi_entries "$file" open 2>/dev/null || true)

  if (( ${#matches[@]} == 0 )); then
    fi_err "defer: no [open] entries match \"$match\""
    return 1
  fi

  if (( ${#matches[@]} > 1 )); then
    fi_err "defer: ambiguous match — ${#matches[@]} [open] entries match \"$match\":"
    local m
    for m in "${matches[@]}"; do
      fi_err "  $m"
    done
    fi_err "Use a more specific match."
    return 2
  fi

  local target="${matches[0]}"

  # Flip status: replace "- [open]" with "- [deferred]" on this exact line
  local tmp
  tmp="$(mktemp -t fi-defer.XXXXXX)"
  local found=0
  while IFS= read -r line; do
    if [[ "$line" == "$target" ]] && (( found == 0 )); then
      found=1
      local new_line="${line/- \[open\]/- [deferred]}"
      printf '%s\n' "$new_line" >> "$tmp"
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"
  mv "$tmp" "$file"

  printf 'Deferred 1 entry. (cycle 1, threshold for nudge: %s touches)\n' "$(fi_compute_threshold 1)"
}
```

Wire up dispatch — find the `case "$cmd" in` block at the bottom of `bin/found-issues` (around line 1555, before the `uninstall-statusline` line) and add a defer entry:

```bash
    defer)                cmd_defer "$@" ;;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/cli-defer.bats -f "basic"`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add bin/found-issues tests/cli-defer.bats
git commit -m "feat(cli): add defer subcommand skeleton (basic [open] → [deferred] flip)

Happy-path implementation. Error paths (no match, ambiguous, already
deferred, in-PR block) and re-defer cycle-bump come in subsequent tasks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.2: Add `--reason` support to `cmd_defer`

When `--reason "<text>"` is passed, append `(reason: <text>)` to the deferred entry.

**Files:**
- Modify: `bin/found-issues` (extend `cmd_defer`)
- Test: `tests/cli-defer.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/cli-defer.bats`:

```bash
@test "defer: --reason captures (reason: ...) annotation" {
  fi_run log "src/foo.py:42 — null check missing"
  fi_run defer "src/foo.py:42" --reason "tracked in JIRA-1234"
  [ "$status" -eq 0 ]
  grep -F "(reason: tracked in JIRA-1234)" docs/found-issues.md
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/cli-defer.bats -f "reason"`
Expected: failure (annotation not added).

- [ ] **Step 3: Extend `cmd_defer` to handle `--reason`**

In `bin/found-issues`, modify the `cmd_defer` function. Find the line that reads `local new_line="${line/- \[open\]/- [deferred]}"` and replace with:

```bash
      local new_line="${line/- \[open\]/- [deferred]}"
      # Append (reason: ...) annotation if --reason was provided
      if [[ -n "$reason" ]]; then
        new_line="${new_line} (reason: ${reason})"
      fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/cli-defer.bats -f "reason"`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add bin/found-issues tests/cli-defer.bats
git commit -m "feat(cli): defer --reason captures (reason: ...) annotation

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.3: Add no-match and ambiguous-match error paths to `cmd_defer`

The skeleton already has the logic; add explicit tests for both error paths.

**Files:**
- Test: `tests/cli-defer.bats`

- [ ] **Step 1: Write the failing tests**

Append to `tests/cli-defer.bats`:

```bash
@test "defer: no match exits 1 with clear error" {
  fi_run log "src/foo.py:42 — null check"
  fi_run defer "nonexistent"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no [open] entries match"* ]]
  [[ "$output" == *"nonexistent"* ]]
}

@test "defer: ambiguous match exits 2 with listing" {
  fi_run log "src/foo.py:42 — null check"
  fi_run log "src/foo.py:88 — leak"
  fi_run defer "foo.py"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ambiguous match"* ]]
  [[ "$output" == *"src/foo.py:42"* ]]
  [[ "$output" == *"src/foo.py:88"* ]]
  [[ "$output" == *"more specific"* ]]
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `bats tests/cli-defer.bats -f "no match\|ambiguous"`
Expected: pass (logic already in place from Task 2.1).

- [ ] **Step 3: Commit**

```bash
git add tests/cli-defer.bats
git commit -m "test(cli): defer no-match (exit 1) and ambiguous-match (exit 2) coverage

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.4: Add already-deferred error path to `cmd_defer`

If the user runs `defer` against an entry that's already `[deferred]` (without going through promote first), exit 3 with helpful message.

**Files:**
- Modify: `bin/found-issues` (extend `cmd_defer`)
- Test: `tests/cli-defer.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/cli-defer.bats`:

```bash
@test "defer: already-deferred exits 3 with re-defer guidance" {
  fi_run log "src/foo.py:42 — null check"
  fi_run defer "src/foo.py:42"
  [ "$status" -eq 0 ]
  fi_run defer "src/foo.py:42"
  [ "$status" -eq 3 ]
  [[ "$output" == *"already [deferred]"* ]]
  [[ "$output" == *"promote"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/cli-defer.bats -f "already-deferred"`
Expected: failure (no detection logic).

- [ ] **Step 3: Add already-deferred check to `cmd_defer`**

In `bin/found-issues`, in `cmd_defer`, after the `# Find matching [open] entries` block (right before the `if (( ${#matches[@]} == 0 ))` check), add a parallel scan for [deferred] entries that match. If any [open] match exists, proceed normally; if no [open] match but a [deferred] match exists, exit 3 with helpful message.

Update the no-match branch:

```bash
  if (( ${#matches[@]} == 0 )); then
    # Check whether the match hits a [deferred] entry — different error.
    local deferred_matches=()
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      local lower_entry lower_match
      lower_entry="$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')"
      lower_match="$(printf '%s' "$match" | tr '[:upper:]' '[:lower:]')"
      if [[ "$lower_entry" == *"$lower_match"* ]]; then
        deferred_matches+=("$entry")
      fi
    done < <(fi_entries "$file" deferred 2>/dev/null || true)

    if (( ${#deferred_matches[@]} > 0 )); then
      fi_err "defer: already [deferred]. To re-defer (after promote), use \`found-issues defer\` — defer-cycle increments automatically. To promote back to [open], use \`found-issues promote-deferred --match $match\`."
      return 3
    fi

    fi_err "defer: no [open] entries match \"$match\""
    return 1
  fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/cli-defer.bats -f "already-deferred"`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add bin/found-issues tests/cli-defer.bats
git commit -m "feat(cli): defer detects already-deferred (exit 3 with re-defer guidance)

Distinguishes 'no match at all' (exit 1) from 'matches a [deferred] entry'
(exit 3 with promote-deferred suggestion).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.5: Add in-PR entry block (exit 4) to `cmd_defer`

If the [open] entry has a `(PR: org/repo#N)` annotation, deferring would create silent state-loss across both `issues` and `in PR` counters. Block with explanation.

**Files:**
- Modify: `bin/found-issues` (extend `cmd_defer`)
- Test: `tests/cli-defer.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/cli-defer.bats`:

```bash
@test "defer: blocks in-PR entry with exit 4 and recovery message" {
  fi_run log "src/foo.py:42 — null check"
  # Manually add a PR annotation to simulate annotate-pr having run
  sed -i.bak 's/null check/null check (PR: AltDoug\/found-issues#42)/' docs/found-issues.md
  fi_run defer "src/foo.py:42"
  [ "$status" -eq 4 ]
  [[ "$output" == *"active PR annotation"* ]]
  [[ "$output" == *"AltDoug/found-issues#42"* ]] || [[ "$output" == *"(PR:"* ]]
  [[ "$output" == *"sync"* ]] || [[ "$output" == *"merge"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/cli-defer.bats -f "in-PR"`
Expected: failure (no detection logic).

- [ ] **Step 3: Add in-PR check to `cmd_defer`**

In `bin/found-issues`, in `cmd_defer`, after resolving `local target="${matches[0]}"` (and BEFORE the file mutation), add:

```bash
  # Block defer of in-PR entries (would silently drop from both issues + in-PR counts)
  local re_pr='\(PR: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+\)'
  if [[ "$target" =~ $re_pr ]]; then
    local pr_match="${BASH_REMATCH[0]}"
    fi_err "defer: entry has an active PR annotation $pr_match."
    fi_err "Deferring an in-flight PR creates a confusing state. Either:"
    fi_err "  1. Wait for the PR to merge (entry will auto-flip to [fixed] via /found-issues:sync)."
    fi_err "  2. Manually remove the (PR: ...) annotation if the PR was abandoned, then re-run defer."
    return 4
  fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/cli-defer.bats -f "in-PR"`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add bin/found-issues tests/cli-defer.bats
git commit -m "feat(cli): defer blocks in-PR entries (exit 4) to prevent silent state-loss

An in-PR entry deferred would disappear from both 'issues' and 'in PR'
counters silently. Block with two-option recovery message (wait for merge
OR manually clear annotation).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.6: Add re-defer (cycle increment) to `cmd_defer`

When deferring an entry that has prior touch history (which only happens after a previous defer→touch→promote cycle), call `fi_increment_defer_cycle` to bump the counter and append `;` separator. Replace any existing `(reason: ...)` with the new one.

This is the trickier path: defer is currently only called against `[open]` entries, but a re-defer means the entry was previously [deferred] → [open] (via promote-deferred). When [open] again, it may carry `(touched: ...)` and `(defer-cycle: N)` annotations from prior cycles. The `fi_increment_defer_cycle` helper handles both the bump and the `;` append.

**Files:**
- Modify: `bin/found-issues` (extend `cmd_defer`)
- Test: `tests/cli-defer.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/cli-defer.bats`:

```bash
@test "defer: re-defer increments defer-cycle and appends ';' to touched" {
  # Simulate: an entry that was previously deferred + touched + promoted, now [open]
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] 2026-05-10 src/foo.py:42 — null check (touched: 2026-05-21, 2026-05-28, 2026-06-04)
EOF
  fi_run defer "src/foo.py:42" --reason "rescoped, parking for v2"
  [ "$status" -eq 0 ]
  grep -F "[deferred]" docs/found-issues.md
  grep -F "(defer-cycle: 2)" docs/found-issues.md
  grep -F "(touched: 2026-05-21, 2026-05-28, 2026-06-04; )" docs/found-issues.md
  grep -F "(reason: rescoped, parking for v2)" docs/found-issues.md
}

@test "defer: re-defer with new --reason replaces old reason annotation" {
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] 2026-05-10 src/foo.py:42 — null check (reason: original reason) (touched: 2026-05-21, 2026-05-28, 2026-06-04) (defer-cycle: 2)
EOF
  fi_run defer "src/foo.py:42" --reason "new reason"
  [ "$status" -eq 0 ]
  grep -F "(reason: new reason)" docs/found-issues.md
  ! grep -F "(reason: original reason)" docs/found-issues.md
  grep -F "(defer-cycle: 3)" docs/found-issues.md
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/cli-defer.bats -f "re-defer"`
Expected: failures (cycle bump + reason replacement not implemented).

- [ ] **Step 3: Extend `cmd_defer` to handle re-defer**

In `bin/found-issues`, in `cmd_defer`, modify the file mutation block. Replace the current mutation logic (the part that flips `- [open]` to `- [deferred]` and adds the reason annotation) with this richer version:

```bash
  # Detect re-defer: entry has prior touch history OR existing defer-cycle annotation
  local has_prior_touches=0
  if [[ "$target" == *"(touched:"* ]] || [[ "$target" == *"(defer-cycle:"* ]]; then
    has_prior_touches=1
  fi

  # Source lib helpers (in case they aren't already loaded)
  source "$FI_LIB_DIR/parse-entries.sh"

  # First: flip [open] → [deferred] and replace any existing (reason: ...)
  local tmp
  tmp="$(mktemp -t fi-defer.XXXXXX)"
  local found=0
  local flipped_entry=""
  while IFS= read -r line; do
    if [[ "$line" == "$target" ]] && (( found == 0 )); then
      found=1
      local new_line="${line/- \[open\]/- [deferred]}"
      # Strip any existing (reason: ...) annotation
      new_line="$(printf '%s' "$new_line" | sed -E 's/ \(reason: [^)]+\)//g')"
      # Append new (reason: ...) if --reason was provided
      if [[ -n "$reason" ]]; then
        new_line="${new_line} (reason: ${reason})"
      fi
      flipped_entry="$new_line"
      printf '%s\n' "$new_line" >> "$tmp"
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"
  mv "$tmp" "$file"

  # Second: if this is a re-defer, increment cycle + append ';' to touched
  local current_cycle=1
  if (( has_prior_touches == 1 )); then
    fi_increment_defer_cycle "$file" "$flipped_entry"
    current_cycle="$(fi_extract_defer_cycle "$flipped_entry")"
    current_cycle=$((current_cycle + 1))  # because increment hasn't been re-read
  fi

  local next_threshold
  next_threshold="$(fi_compute_threshold "$current_cycle")"
  if (( current_cycle == 1 )); then
    printf 'Deferred 1 entry. (cycle 1, threshold for nudge: %s touches)\n' "$next_threshold"
  else
    printf 'Re-deferred 1 entry. (cycle %s, threshold for next nudge: %s touches)\n' "$current_cycle" "$next_threshold"
  fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/cli-defer.bats -f "re-defer"`
Expected: pass. Also re-run all defer tests to verify no regression: `bats tests/cli-defer.bats`.

- [ ] **Step 5: Commit**

```bash
git add bin/found-issues tests/cli-defer.bats
git commit -m "feat(cli): defer handles re-defer (cycle bump + ';' append + reason replacement)

Re-defer detection: presence of (touched: ...) or (defer-cycle: N)
annotation on the [open] entry. fi_increment_defer_cycle handles the
mutations atomically. Existing (reason: ...) is stripped and replaced
with the new value (or removed if no --reason given).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.7: Implement `cmd_promote_deferred` (basic flip + error paths)

Inverse of defer: flip `[deferred]` → `[open]`, preserving all annotations.

**Files:**
- Modify: `bin/found-issues` (add `cmd_promote_deferred` function)
- Test: `tests/cli-promote-deferred.bats` (new file)

- [ ] **Step 1: Write the failing tests**

Create `tests/cli-promote-deferred.bats`:

```bash
#!/usr/bin/env bats
# Tests for `found-issues promote-deferred`

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

@test "promote-deferred: flips [deferred] to [open], preserves annotations" {
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — null check (reason: tracked) (touched: 2026-05-21, 2026-05-28, 2026-06-04)
EOF
  fi_run promote-deferred "src/foo.py:42"
  [ "$status" -eq 0 ]
  grep -F "[open]" docs/found-issues.md
  ! grep -F "[deferred]" docs/found-issues.md
  # All annotations preserved byte-identical
  grep -F "(reason: tracked)" docs/found-issues.md
  grep -F "(touched: 2026-05-21, 2026-05-28, 2026-06-04)" docs/found-issues.md
}

@test "promote-deferred: no match exits 1" {
  fi_run promote-deferred "nonexistent"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no [deferred] entries match"* ]]
}

@test "promote-deferred: ambiguous match exits 2 with listing" {
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — null check
- [deferred] 2026-05-10 src/foo.py:88 — leak
EOF
  fi_run promote-deferred "foo.py"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ambiguous"* ]]
  [[ "$output" == *"src/foo.py:42"* ]]
  [[ "$output" == *"src/foo.py:88"* ]]
}

@test "promote-deferred: exit 3 with helpful message when match is [open]" {
  fi_run log "src/foo.py:42 — null check"
  fi_run promote-deferred "src/foo.py:42"
  [ "$status" -eq 3 ]
  [[ "$output" == *"not [deferred]"* ]] || [[ "$output" == *"[open]"* ]]
}

@test "promote-deferred: --match flag accepted (alias for positional)" {
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — null check
EOF
  fi_run promote-deferred --match "src/foo.py:42"
  [ "$status" -eq 0 ]
  grep -F "[open]" docs/found-issues.md
}

@test "promote-deferred: preserves (defer-cycle: N) as evidence" {
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — null check (touched: 2026-05-21, 2026-05-28; 2026-07-15) (defer-cycle: 2)
EOF
  fi_run promote-deferred "src/foo.py:42"
  [ "$status" -eq 0 ]
  grep -F "(defer-cycle: 2)" docs/found-issues.md
  grep -F "(touched: 2026-05-21, 2026-05-28; 2026-07-15)" docs/found-issues.md
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/cli-promote-deferred.bats`
Expected: 6 failures.

- [ ] **Step 3: Implement `cmd_promote_deferred`**

In `bin/found-issues`, add (after `cmd_defer`):

```bash
# === Subcommand: promote-deferred ===
#
# Flips [deferred] → [open] for the entry matching <match>.
# All annotations preserved byte-identical (touch history + defer-cycle +
# reason serve as evidence of recurrence and historical context).
#
# Exits:
#   0 success
#   1 no matching [deferred] entry
#   2 ambiguous (multiple matches)
#   3 entry is [open], not [deferred] (helpful message)
cmd_promote_deferred() {
  local match=""

  # Argument parsing — accept positional or --match
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --match)
        match="${2:-}"
        shift 2 || break
        ;;
      *)
        if [[ -z "$match" ]]; then
          match="$1"
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$match" ]]; then
    fi_err "promote-deferred: missing <match> argument"
    fi_err "Usage: found-issues promote-deferred <match>   OR   --match <match>"
    return 2
  fi

  local file
  file="$(fi_resolve_issues_file)"

  # Find matching [deferred] entries
  local matches=()
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local lower_entry lower_match
    lower_entry="$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')"
    lower_match="$(printf '%s' "$match" | tr '[:upper:]' '[:lower:]')"
    if [[ "$lower_entry" == *"$lower_match"* ]]; then
      matches+=("$entry")
    fi
  done < <(fi_entries "$file" deferred 2>/dev/null || true)

  if (( ${#matches[@]} == 0 )); then
    # Check whether the match hits an [open] entry — different error.
    local open_matches=()
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      local lower_entry lower_match
      lower_entry="$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')"
      lower_match="$(printf '%s' "$match" | tr '[:upper:]' '[:lower:]')"
      if [[ "$lower_entry" == *"$lower_match"* ]]; then
        open_matches+=("$entry")
      fi
    done < <(fi_entries "$file" open 2>/dev/null || true)

    if (( ${#open_matches[@]} > 0 )); then
      fi_err "promote-deferred: not [deferred] — match \"$match\" hits an [open] entry already."
      return 3
    fi

    fi_err "promote-deferred: no [deferred] entries match \"$match\""
    return 1
  fi

  if (( ${#matches[@]} > 1 )); then
    fi_err "promote-deferred: ambiguous match — ${#matches[@]} [deferred] entries match \"$match\":"
    local m
    for m in "${matches[@]}"; do
      fi_err "  $m"
    done
    fi_err "Use a more specific match."
    return 2
  fi

  local target="${matches[0]}"

  # Flip status: replace "- [deferred]" with "- [open]" on this exact line.
  # All other content (annotations) preserved.
  local tmp
  tmp="$(mktemp -t fi-promote.XXXXXX)"
  local found=0
  while IFS= read -r line; do
    if [[ "$line" == "$target" ]] && (( found == 0 )); then
      found=1
      local new_line="${line/- \[deferred\]/- [open]}"
      printf '%s\n' "$new_line" >> "$tmp"
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"
  mv "$tmp" "$file"

  printf 'Promoted [deferred] → [open]: %s\n' "$target"
  if [[ "$target" == *"(touched:"* ]]; then
    printf 'Touch history preserved as evidence of recurrence.\n'
  fi
}
```

Wire up dispatch — add to the `case "$cmd" in` block:

```bash
    promote-deferred)     cmd_promote_deferred "$@" ;;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/cli-promote-deferred.bats`
Expected: 6 passes.

- [ ] **Step 5: Commit**

```bash
git add bin/found-issues tests/cli-promote-deferred.bats
git commit -m "feat(cli): add promote-deferred subcommand

Inverse of defer: flips [deferred] → [open], preserving all annotations
(touch history, defer-cycle, reason). Accepts positional or --match
argument. Exit codes mirror defer: 0/1/2/3.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.8: Add help text for `defer` and `promote-deferred`

The `--help` output (printed by `cmd_help` in `bin/found-issues`) lists each subcommand. Add the two new ones in the right order.

**Files:**
- Modify: `bin/found-issues` (`cmd_help`, around line 100-125)

- [ ] **Step 1: Inspect the existing help section**

Run: `sed -n '100,125p' bin/found-issues`
Note where `archive`, `install-statusline`, etc. are listed. New `defer` + `promote-deferred` should logically slot between `log` and the install-* commands.

- [ ] **Step 2: Add the new lines to the help block**

Find the section with subcommands like `log`, `status`, `sync`, `archive`. Insert after `archive` (around line 115):

```
  defer <match> [--reason "..."]        Flip [open] → [deferred]. On re-defer
                                        (entry has prior touch history),
                                        increments defer-cycle and appends ';'
                                        to touched annotation.
  promote-deferred <match>              Flip [deferred] → [open], preserving all
                                        annotations as evidence of recurrence.
```

- [ ] **Step 3: Verify help output**

Run: `bin/found-issues --help | grep -A1 "defer"`
Expected: both new commands listed with descriptions.

- [ ] **Step 4: Commit**

```bash
git add bin/found-issues
git commit -m "docs(cli): add defer and promote-deferred to --help output

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.9: Create `commands/defer.md` skill wrapper

Markdown file that registers as the `/found-issues:defer` slash command. Mirrors the existing `commands/log.md` style.

**Files:**
- Create: `commands/defer.md`

- [ ] **Step 1: Inspect the existing log skill for style**

Run: `cat commands/log.md`
Note the frontmatter format (description, argument-hint, allowed-tools) and the prose conventions.

- [ ] **Step 2: Write `commands/defer.md`**

Create `commands/defer.md`:

```markdown
---
description: Defer a [open] found-issue to [deferred] — suppresses it from the statusline counter and adds optional reason. Re-defers (after promotion) automatically increment the defer-cycle and escalate the touch threshold for the next nudge.
argument-hint: <match> [--reason "<text>"]
allowed-tools: Bash(found-issues:*)
---

The user wants to defer a `[open]` found-issue. Deferring means: keep the entry visible in `docs/found-issues.md` but suppress it from the statusline counter and exempt it from `[open]`-only checks. The entry stays in the file as a parking-lot record.

## Invocation

```bash
found-issues defer <match> [--reason "<text>"]
```

`<match>` is a substring matched case-insensitively against the entry's path or symptom. If the match is ambiguous (matches multiple `[open]` entries), the CLI lists all matches and exits 2 — surface them to the user and ask for a more specific match.

## Exit codes — what to tell the user

- **0**: Deferred successfully. Print the CLI's stdout (it includes cycle + threshold info).
- **1**: No match. The CLI prints the match string; suggest the user check `docs/found-issues.md` or run `/found-issues:status` for the current entry list.
- **2**: Ambiguous match. The CLI lists all matches; ask the user for a more specific substring (e.g., line number, distinctive part of the symptom).
- **3**: Already `[deferred]`. The CLI explains the re-defer-after-promote workflow. If the user actually wanted to promote it back, suggest `/found-issues:promote-deferred`.
- **4**: Entry has an active `(PR: ...)` annotation. Deferring would silently drop the entry from both the `issues` and `in PR` counters. The CLI prints the two-option recovery (wait for merge OR manually clear the annotation); surface it to the user verbatim.

## When to use defer

- **Out-of-scope but real**: a logged issue is genuine but you've decided not to address it in the current cycle (e.g., behind another work stream, blocked on external dep, low-priority cleanup).
- **NOT for "this isn't a real issue"**: those should be removed from the file entirely, not deferred.
- **NOT for in-flight PRs**: the plugin auto-flips entries to `[fixed]` when the referenced PR merges via `/found-issues:sync`. Defer would interfere.

## Re-defer behavior

If you defer an entry that was previously `[deferred]` → promoted → now `[open]` again (the touch history will be visible in the entry's `(touched: ...)` annotation), the CLI auto-increments the `defer-cycle` annotation and the threshold for the next promotion-nudge doubles (3 → 6 → 12 → ...). Each re-defer raises the bar.

## Optional `--reason "<text>"`

Captures a short human note explaining WHY this entry is being deferred. Stored as `(reason: ...)` on the entry. Replaces any existing `(reason: ...)` from a prior cycle. Helpful for future re-review.
```

- [ ] **Step 3: Sanity-check rendering**

The skill is markdown; agent-sync will pick it up next render. No CLI test needed for the file itself, but inspect the frontmatter is well-formed:

Run: `head -5 commands/defer.md`
Expected: frontmatter looks like `commands/log.md`.

- [ ] **Step 4: Commit**

```bash
git add commands/defer.md
git commit -m "feat(skill): add /found-issues:defer slash command

Wraps the new defer subcommand. Documents exit codes (0/1/2/3/4),
when to use defer vs not, and re-defer cycle behavior. Mirrors
commands/log.md style.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.10: Create `commands/promote-deferred.md` skill wrapper

Same pattern, for the inverse subcommand.

**Files:**
- Create: `commands/promote-deferred.md`

- [ ] **Step 1: Write `commands/promote-deferred.md`**

```markdown
---
description: Promote a [deferred] found-issue back to [open] — preserves all annotations (touch history, defer-cycle, reason) as evidence of recurrence and historical context. Inverse of /found-issues:defer.
argument-hint: <match>
allowed-tools: Bash(found-issues:*)
---

The user wants to promote a `[deferred]` found-issue back to `[open]`. This usually happens after the touch counter has triggered a nudge (3 touches in cycle 1; 6 in cycle 2; etc.) — the deferred entry has been bitten enough times that it warrants real attention.

## Invocation

```bash
found-issues promote-deferred <match>
# or
found-issues promote-deferred --match <match>
```

`<match>` is a substring matched case-insensitively against the entry's path or symptom. Same matching rules as `defer`.

## Exit codes — what to tell the user

- **0**: Promoted successfully. Print the CLI's stdout. All annotations (touch history, defer-cycle, reason) are preserved as evidence on the now-`[open]` entry.
- **1**: No `[deferred]` match. The user might have already promoted it, or the substring doesn't hit anything.
- **2**: Ambiguous match. List the matches and ask for a more specific substring.
- **3**: Match hits an `[open]` entry, not `[deferred]`. The user may have meant to promote a different match — suggest `/found-issues:status` to see the current state.

## When to use promote-deferred

- **Threshold nudge fired** in your `found-issues log` output: "Touched deferred entry (now Nx, threshold N)" → promote and address.
- **Manual re-evaluation** during periodic review of the deferred parking lot.
- **Critical [!] auto-promotion is reserved for the plugin** (it happens automatically on Nth touch); you don't need to promote-deferred those — they flip on their own.

## What promotion does

- Flips status `[deferred]` → `[open]`.
- Preserves `(touched: ...)`, `(defer-cycle: N)`, `(reason: ...)` byte-identical.
- The promoted entry appears in the `issues` count of the statusline counter.
- If you re-defer this entry later, the next defer-cycle bump uses the existing `(defer-cycle: N)` value as the starting point (escalating the threshold geometrically).

## What it doesn't do

- Doesn't fix the bug. That's still your job after promotion.
- Doesn't trigger any sync, archive, or annotation flow. Strictly a status flip.
```

- [ ] **Step 2: Commit**

```bash
git add commands/promote-deferred.md
git commit -m "feat(skill): add /found-issues:promote-deferred slash command

Wraps the new promote-deferred subcommand. Mirrors commands/defer.md
style. Documents exit codes, when to use, and what gets preserved.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2.11: Phase 2 — full suite green + branch + PR

- [ ] **Step 1: Run the full bats suite**

Run: `bats tests/`
Expected: all tests pass; new test count from Phase 2 is ~15 (defer ~9 + promote-deferred ~6).

- [ ] **Step 2: Push the branch + open PR**

Run:
```bash
git push -u origin feat/defer-recurrence-flow-phase-2
gh pr create --title "feat(cli): defer-recurrence flow Phase 2 — defer + promote-deferred subcommands" --body "$(cat <<'EOF'
## Summary

Phase 2 of the defer-recurrence-flow spec. Adds the lifecycle subcommands `defer` and `promote-deferred`, plus their skill wrappers. **Touch detection / recurrence signal lives in Phase 3.**

## What's added

- `cmd_defer` with full error-path coverage (no match → 1, ambiguous → 2, already-deferred → 3, in-PR block → 4) + `--reason "..."` support + re-defer cycle bump.
- `cmd_promote_deferred` with mirror error paths.
- Two new skills: `commands/defer.md` and `commands/promote-deferred.md`.
- `--help` output extended.
- ~15 new bats tests across `tests/cli-defer.bats` and `tests/cli-promote-deferred.bats`.

## Test plan

- [x] Full bats suite green (no regressions on existing 184 + Phase 1 tests)
- [ ] CI matrix

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
gh pr merge --squash --delete-branch --auto
```

Expected: PR opened, auto-merge queued.

---

# Phase 3 — Extend `cmd_log` dedup to scan `[deferred]`

This is the actual recurrence-detection feature. Extends the existing dedup loop so `log` invocations matching a deferred entry append a touch annotation instead of creating a fresh `[open]` entry.

**Branch:**
```bash
git checkout main && git pull --ff-only
git checkout -b feat/defer-recurrence-flow-phase-3
```

---

### Task 3.1: Extend `cmd_log` dedup loop to also scan `[deferred]` entries

Currently `cmd_log` calls `fi_entries "$file" open` (`bin/found-issues:249`) for the dedup loop. Extend to scan both `[open]` and `[deferred]`. On `[open]` match, keep existing behavior (silent skip + status print). On `[deferred]` match, dispatch to a new function `fi_handle_deferred_touch` (built in Task 3.2).

**Files:**
- Modify: `bin/found-issues` (`cmd_log`, around line 217-249)
- Test: extends `tests/cli-log.bats` (added in Task 3.2 onwards)

- [ ] **Step 1: Read the current dedup loop**

Run: `sed -n '215,255p' bin/found-issues`
Note the structure: builds `new_key`, iterates `fi_entries "$file" open`, computes `existing_key`, on match prints "Skipped" and returns 0.

- [ ] **Step 2: Refactor the dedup loop to handle two cases**

In `bin/found-issues`, in `cmd_log`, replace the existing dedup loop (the `while IFS= read -r entry; do ... done < <(fi_entries "$file" open ...)` block, around lines 227-249) with:

```bash
  # Dedup against [open] AND [deferred] entries.
  # - [open] match: existing behavior — print "Skipped — already logged" and return.
  # - [deferred] match: new behavior — append touch annotation, possibly nudge or
  #   auto-promote (handled by fi_handle_deferred_touch).
  local matched_status=""  # "open" or "deferred", or empty if no match
  local matched_entry=""
  local entry e_data e_path e_line e_symptom existing_key

  # Scan [open] first (preserve existing precedence)
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    e_data="$(fi_parse_entry "$entry")" || continue
    e_path="$(printf '%s' "$e_data" | grep '^path=' | head -1 | cut -d= -f2-)"
    e_line="$(printf '%s' "$e_data" | grep '^line=' | head -1 | cut -d= -f2-)"
    e_symptom="$(printf '%s' "$e_data" | grep '^symptom=' | head -1 | cut -d= -f2-)"
    if [[ -n "$e_line" ]]; then
      existing_key="$(fi_dedup_key "$e_path" "$e_line" "$e_symptom")"
    elif [[ "$e_path" == */* || "$e_path" == *.* ]]; then
      existing_key="$(fi_dedup_key "$e_path" "" "$e_symptom")"
    else
      existing_key="$(fi_dedup_key_abstract "$e_symptom")"
    fi
    if [[ "$existing_key" == "$new_key" ]]; then
      matched_status="open"
      matched_entry="$entry"
      break
    fi
  done < <(fi_entries "$file" open 2>/dev/null || true)

  # If no [open] match, scan [deferred]
  if [[ -z "$matched_status" ]]; then
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      e_data="$(fi_parse_entry "$entry")" || continue
      e_path="$(printf '%s' "$e_data" | grep '^path=' | head -1 | cut -d= -f2-)"
      e_line="$(printf '%s' "$e_data" | grep '^line=' | head -1 | cut -d= -f2-)"
      e_symptom="$(printf '%s' "$e_data" | grep '^symptom=' | head -1 | cut -d= -f2-)"
      if [[ -n "$e_line" ]]; then
        existing_key="$(fi_dedup_key "$e_path" "$e_line" "$e_symptom")"
      elif [[ "$e_path" == */* || "$e_path" == *.* ]]; then
        existing_key="$(fi_dedup_key "$e_path" "" "$e_symptom")"
      else
        existing_key="$(fi_dedup_key_abstract "$e_symptom")"
      fi
      if [[ "$existing_key" == "$new_key" ]]; then
        matched_status="deferred"
        matched_entry="$entry"
        break
      fi
    done < <(fi_entries "$file" deferred 2>/dev/null || true)
  fi

  # Branch on match
  if [[ "$matched_status" == "open" ]]; then
    printf 'Skipped — already logged: %s\n' "$matched_entry"
    cmd_status plain
    return 0
  fi

  if [[ "$matched_status" == "deferred" ]]; then
    fi_handle_deferred_touch "$file" "$matched_entry"
    return $?
  fi

  # No match — fall through to existing "build new entry" code.
```

- [ ] **Step 3: Verify the existing tests still pass**

Run: `bats tests/cli-log.bats`
Expected: all existing tests pass. The refactored loop preserves [open] dedup behavior exactly.

- [ ] **Step 4: Commit**

```bash
git add bin/found-issues
git commit -m "refactor(cli): cmd_log dedup loop scans [open] then [deferred]

Preparation for touch-detection. [open] match preserves existing
'Skipped — already logged' behavior. [deferred] match dispatches to
fi_handle_deferred_touch (added in next task).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3.2: Implement `fi_handle_deferred_touch` (touch annotation, no nudge yet)

The dispatched function. For now: just append today's date to `(touched: ...)`. Threshold checks come in Task 3.3.

**Files:**
- Modify: `bin/found-issues` (add `fi_handle_deferred_touch` function, place near `cmd_log`)
- Test: `tests/cli-log.bats` (append new test cases)

- [ ] **Step 1: Write the failing tests**

Append to `tests/cli-log.bats`:

```bash
@test "log: matching [deferred] entry appends today's date to (touched: ...)" {
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — null check missing
EOF
  fi_run log "src/foo.py:42 — null check missing"
  [ "$status" -eq 0 ]
  # Today's date appears as a touched annotation
  today="$(date +%Y-%m-%d)"
  grep -F "(touched: $today)" docs/found-issues.md
  # No new [open] entry created
  ! grep -F "[open]" docs/found-issues.md
  # Single [deferred] entry remains
  [ "$(grep -c '^- \[deferred\]' docs/found-issues.md)" -eq 1 ]
}

@test "log: matching [deferred] without prior touched: creates the annotation" {
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — null check missing (reason: scoped out)
EOF
  fi_run log "src/foo.py:42 — null check missing"
  [ "$status" -eq 0 ]
  today="$(date +%Y-%m-%d)"
  grep -F "(touched: $today)" docs/found-issues.md
  # Existing reason annotation preserved
  grep -F "(reason: scoped out)" docs/found-issues.md
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/cli-log.bats -f "deferred"`
Expected: failures (function not defined; refactored loop calls undefined `fi_handle_deferred_touch`).

- [ ] **Step 3: Implement `fi_handle_deferred_touch`**

In `bin/found-issues`, add this function (place above `cmd_log`, around line 155):

```bash
# Handle a `log` invocation that matched a [deferred] entry's dedup key.
# Appends today's date to the (touched: ...) annotation. Subsequent tasks
# extend this with threshold checks and auto-promotion logic.
fi_handle_deferred_touch() {
  local file="$1"
  local matched_entry="$2"
  local today
  today="$(fi_today)"

  # Append today's date to the matched entry's (touched: ...) annotation.
  fi_append_touch "$file" "$matched_entry" "$today"

  # Reload the entry to compute new touch count + threshold (next tasks).
  printf 'Touched deferred entry: %s\n' "$matched_entry" >&2
  return 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/cli-log.bats -f "deferred"`
Expected: 2 passes.

- [ ] **Step 5: Commit**

```bash
git add bin/found-issues tests/cli-log.bats
git commit -m "feat(cli): fi_handle_deferred_touch — appends touch annotation on [deferred] match

Minimal implementation: just appends today's date to (touched: ...).
Threshold checks + nudge/auto-promote behavior come in subsequent tasks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3.3: Add count < threshold branch (silent annotation + brief stderr)

When the touch count after this update is below threshold, print a brief stderr line so the operator sees the touch happen.

**Files:**
- Modify: `bin/found-issues` (extend `fi_handle_deferred_touch`)
- Test: `tests/cli-log.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/cli-log.bats`:

```bash
@test "log: touch below threshold prints brief stderr 'Nx of M for promotion'" {
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — null check missing
EOF
  unset FOUND_ISSUES_DEFER_TOUCH_THRESHOLD FOUND_ISSUES_DEFER_ESCALATION_FACTOR
  # Touch 1 of 3
  fi_run log "src/foo.py:42 — null check missing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1x of 3"* ]] || [[ "$output" == *"1 of 3"* ]]
  [[ "$output" == *"src/foo.py:42"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/cli-log.bats -f "below threshold"`
Expected: failure (output doesn't contain "of 3").

- [ ] **Step 3: Extend `fi_handle_deferred_touch` with threshold check**

Replace the body of `fi_handle_deferred_touch` with:

```bash
fi_handle_deferred_touch() {
  local file="$1"
  local matched_entry="$2"
  local today
  today="$(fi_today)"

  # Append today's date FIRST so the count reflects this touch.
  fi_append_touch "$file" "$matched_entry" "$today"

  # Re-read the updated entry to compute current count + threshold.
  # The entry's path may have changed (annotation appended), so match by
  # the original entry's dedup-stable prefix.
  local updated_entry=""
  local prefix="${matched_entry%% (touched:*}"
  prefix="${prefix%% (defer-cycle:*}"  # be defensive about ordering
  while IFS= read -r line; do
    if [[ "$line" == "$prefix"* ]]; then
      updated_entry="$line"
      break
    fi
  done < <(fi_entries "$file" deferred 2>/dev/null || true)

  if [[ -z "$updated_entry" ]]; then
    # Should not happen if append succeeded; fail soft.
    printf 'Touched deferred entry: %s\n' "$matched_entry" >&2
    return 0
  fi

  local cycle count threshold
  cycle="$(fi_extract_defer_cycle "$updated_entry")"
  count="$(fi_current_cycle_touch_count "$updated_entry")"
  threshold="$(fi_compute_threshold "$cycle")"

  # Compute a hint for the user (path:line if available)
  local hint
  hint="${matched_entry#*— }"
  hint="${hint%% — *}"  # collapse if symptom contains ' — '
  hint="${matched_entry#*\] }"
  hint="${hint#* }"  # strip date
  hint="${hint%% — *}"

  if (( count < threshold )); then
    printf 'Touched deferred entry (%dx of %d for promotion): %s\n' "$count" "$threshold" "$hint" >&2
  fi

  # >= threshold branches added in next tasks
  return 0
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/cli-log.bats -f "below threshold"`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add bin/found-issues tests/cli-log.bats
git commit -m "feat(cli): touch below threshold prints 'Nx of M for promotion' stderr

Operator sees the touch happen. Above-threshold branches (nudge,
auto-promote) come in subsequent tasks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3.4: Add count >= threshold non-critical branch (nudge)

When the touch count meets/exceeds threshold AND the entry is NOT critical, print a stderr nudge with the `promote-deferred --match <hint>` suggestion.

**Files:**
- Modify: `bin/found-issues` (extend `fi_handle_deferred_touch`)
- Test: `tests/cli-log.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/cli-log.bats`:

```bash
@test "log: touch == threshold (non-critical) prints nudge with promote-deferred command" {
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — null check missing (touched: 2026-05-21, 2026-05-28)
EOF
  unset FOUND_ISSUES_DEFER_TOUCH_THRESHOLD FOUND_ISSUES_DEFER_ESCALATION_FACTOR
  # 3rd touch hits threshold
  fi_run log "src/foo.py:42 — null check missing"
  [ "$status" -eq 0 ]
  [[ "$output" == *"now 3x"* ]] || [[ "$output" == *"3x, threshold 3"* ]]
  [[ "$output" == *"promote-deferred"* ]]
  # Entry should still be [deferred] (non-critical doesn't auto-promote)
  grep -F "[deferred]" docs/found-issues.md
  ! grep -F "[open]" docs/found-issues.md
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/cli-log.bats -f "non-critical"`
Expected: failure (no nudge logic yet).

- [ ] **Step 3: Add nudge branch to `fi_handle_deferred_touch`**

In `bin/found-issues`, in `fi_handle_deferred_touch`, after the `if (( count < threshold ))` branch, add:

```bash
  # Determine criticality
  local is_critical=0
  if [[ "$updated_entry" == *"[!]"* ]]; then
    is_critical=1
  fi

  if (( count >= threshold )) && (( is_critical == 0 )); then
    printf 'Touched deferred entry (now %dx, threshold %d): %s\n' "$count" "$threshold" "$hint" >&2
    printf 'Consider: found-issues promote-deferred --match %s\n' "$hint" >&2
  fi
```

(Place this AFTER the `if (( count < threshold ))` block, BEFORE the `return 0`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/cli-log.bats -f "non-critical"`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add bin/found-issues tests/cli-log.bats
git commit -m "feat(cli): touch >= threshold (non-critical) fires nudge

Stderr nudge with the promote-deferred --match command. Entry stays
[deferred] until operator promotes manually. Re-fires every subsequent
touch above threshold (cheap signal; operator can keep deferring).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3.5: Add count >= threshold critical branch (auto-promote)

When the touch count meets/exceeds threshold AND the entry IS critical (`[!]`), auto-promote inline using the same logic `cmd_promote_deferred` uses.

**Files:**
- Modify: `bin/found-issues` (extend `fi_handle_deferred_touch`)
- Test: `tests/cli-log.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/cli-log.bats`:

```bash
@test "log: touch >= threshold (critical [!]) auto-promotes inline" {
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] [!] 2026-05-10 src/foo.py:42 — auth bypass (touched: 2026-05-21, 2026-05-28)
EOF
  unset FOUND_ISSUES_DEFER_TOUCH_THRESHOLD FOUND_ISSUES_DEFER_ESCALATION_FACTOR
  fi_run log "src/foo.py:42 — auth bypass"
  [ "$status" -eq 0 ]
  [[ "$output" == *"auto-promoted"* ]]
  [[ "$output" == *"3x"* ]]
  # Entry now [open] [!]
  grep -F "[open] [!]" docs/found-issues.md
  ! grep -F "[deferred]" docs/found-issues.md
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/cli-log.bats -f "critical"`
Expected: failure.

- [ ] **Step 3: Extract a shared promotion helper, then call it from `fi_handle_deferred_touch`**

In `bin/found-issues`, refactor `cmd_promote_deferred` to extract its core mutation into a helper. Add a new function above `cmd_promote_deferred`:

```bash
# Flip a single matched [deferred] entry to [open] in $file.
# Returns 0 on success. Used by both cmd_promote_deferred (matches by user
# input) and fi_handle_deferred_touch (matches by exact entry).
fi_promote_entry_to_open() {
  local file="$1"
  local target="$2"
  local tmp
  tmp="$(mktemp -t fi-promote.XXXXXX)"
  local found=0
  while IFS= read -r line; do
    if [[ "$line" == "$target" ]] && (( found == 0 )); then
      found=1
      local new_line="${line/- \[deferred\]/- [open]}"
      printf '%s\n' "$new_line" >> "$tmp"
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"
  if (( found == 0 )); then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$file"
  return 0
}
```

Then update `cmd_promote_deferred` to call this helper instead of inlining the mutation. Find the existing mutation block in `cmd_promote_deferred` (the `local tmp; tmp="$(mktemp ...)"` block) and replace it with:

```bash
  if ! fi_promote_entry_to_open "$file" "$target"; then
    fi_err "promote-deferred: internal error mutating file"
    return 5
  fi

  printf 'Promoted [deferred] → [open]: %s\n' "$target"
```

Now extend `fi_handle_deferred_touch` to call `fi_promote_entry_to_open` for the critical branch. After the non-critical nudge branch, add:

```bash
  if (( count >= threshold )) && (( is_critical == 1 )); then
    fi_promote_entry_to_open "$file" "$updated_entry"
    printf 'Touched [!] critical deferred entry — auto-promoted to [open] (%dx in cycle %d): %s\n' "$count" "$cycle" "$hint" >&2
  fi
```

- [ ] **Step 4: Run test to verify it passes (and verify no regressions)**

Run: `bats tests/cli-log.bats -f "critical"`
Expected: pass.

Run: `bats tests/cli-promote-deferred.bats`
Expected: still passing (the refactor preserved behavior).

- [ ] **Step 5: Commit**

```bash
git add bin/found-issues tests/cli-log.bats
git commit -m "feat(cli): touch >= threshold + critical [!] auto-promotes inline

Extracts fi_promote_entry_to_open helper used by both cmd_promote_deferred
and fi_handle_deferred_touch. Critical entries flip [deferred] → [open]
automatically on Nth touch with stderr notice.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3.6: Add escalation cases (cycle 2 threshold = 6, same-day double touch, env-var override)

The escalation logic is already handled by `fi_compute_threshold` from Phase 1, but add explicit tests to confirm end-to-end behavior across cycles + env-var overrides.

**Files:**
- Test: `tests/cli-log.bats`

- [ ] **Step 1: Write the failing tests**

Append to `tests/cli-log.bats`:

```bash
@test "log: cycle 2 threshold = 6 (default base 3, factor 2)" {
  # Entry already in cycle 2 with 5 touches in current segment
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-01, 2026-05-08, 2026-05-15; 2026-07-01, 2026-07-08, 2026-07-15, 2026-07-22, 2026-07-29) (defer-cycle: 2)
EOF
  unset FOUND_ISSUES_DEFER_TOUCH_THRESHOLD FOUND_ISSUES_DEFER_ESCALATION_FACTOR
  # 6th touch in cycle 2 hits threshold (6 = 3 * 2^1)
  fi_run log "src/foo.py:42 — bug"
  [ "$status" -eq 0 ]
  [[ "$output" == *"6x, threshold 6"* ]] || [[ "$output" == *"now 6x"* ]]
  [[ "$output" == *"promote-deferred"* ]]
}

@test "log: cycle 3 threshold = 12 — escalation across multiple cycles" {
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-01, 2026-05-08, 2026-05-15; 2026-07-01, 2026-07-08, 2026-07-15, 2026-07-22, 2026-07-29, 2026-08-05; 2026-09-01, 2026-09-08, 2026-09-15, 2026-09-22, 2026-09-29, 2026-10-06, 2026-10-13, 2026-10-20, 2026-10-27, 2026-11-03, 2026-11-10) (defer-cycle: 3)
EOF
  unset FOUND_ISSUES_DEFER_TOUCH_THRESHOLD FOUND_ISSUES_DEFER_ESCALATION_FACTOR
  # 12th touch in cycle 3 hits threshold (12 = 3 * 2^2)
  fi_run log "src/foo.py:42 — bug"
  [ "$status" -eq 0 ]
  [[ "$output" == *"now 12x"* ]] || [[ "$output" == *"12x, threshold 12"* ]]
}

@test "log: same-day double touch appends date twice" {
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — bug
EOF
  fi_run log "src/foo.py:42 — bug"
  [ "$status" -eq 0 ]
  fi_run log "src/foo.py:42 — bug"
  [ "$status" -eq 0 ]
  today="$(date +%Y-%m-%d)"
  # Date appears twice in the (touched: ...) annotation
  count_in_annotation="$(grep -oE "(touched: [^)]+)" docs/found-issues.md | grep -oE "$today" | wc -l | tr -d ' ')"
  [ "$count_in_annotation" -eq 2 ]
}

@test "log: FOUND_ISSUES_DEFER_TOUCH_THRESHOLD=5 overrides default" {
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, 2026-05-22, 2026-05-23, 2026-05-24)
EOF
  FOUND_ISSUES_DEFER_TOUCH_THRESHOLD=5 fi_run log "src/foo.py:42 — bug"
  [ "$status" -eq 0 ]
  [[ "$output" == *"5x, threshold 5"* ]] || [[ "$output" == *"now 5x"* ]]
}

@test "log: invalid FOUND_ISSUES_DEFER_TOUCH_THRESHOLD warns + falls back to 3" {
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — bug (touched: 2026-05-21, 2026-05-22)
EOF
  FOUND_ISSUES_DEFER_TOUCH_THRESHOLD=garbage fi_run log "src/foo.py:42 — bug"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning"* ]] || [[ "$output" == *"invalid"* ]]
  # Falls back to default 3 → 3rd touch hits threshold
  [[ "$output" == *"now 3x"* ]] || [[ "$output" == *"3x, threshold 3"* ]]
}

@test "log: matching neither [open] nor [deferred] adds new [open] (regression)" {
  fi_run log "src/foo.py:42 — null check"
  [ "$status" -eq 0 ]
  fi_run log "src/bar.py:99 — different bug"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^- \[open\]' docs/found-issues.md)" -eq 2 ]
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `bats tests/cli-log.bats`
Expected: all new escalation tests pass; existing tests still green.

- [ ] **Step 3: Commit**

```bash
git add tests/cli-log.bats
git commit -m "test(cli): defer-recurrence escalation, env-var, same-day, regression coverage

6 new cases covering cycle 2 threshold = 6, cycle 3 threshold = 12,
same-day double touch (raw append), env-var override, invalid env-var
fallback, and regression test that non-matching log still creates [open].

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3.7: Add cli-status regression tests + E2E full-lifecycle test

Verify `cmd_status` doesn't accidentally count `[deferred]` entries (regression check) and that promoted entries correctly bump the right counter (`critical` vs `issues`).

**Files:**
- Test: `tests/cli-status.bats`, `tests/cli-log.bats`

- [ ] **Step 1: Write the failing tests**

Append to `tests/cli-status.bats`:

```bash
@test "status: [deferred] entries do not count toward 'issues'" {
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] 2026-05-10 src/foo.py:42 — null check
- [deferred] 2026-05-10 src/bar.py:99 — kicked down road
EOF
  fi_run status --format=json
  [ "$status" -eq 0 ]
  # total_open should be 1 (only the [open] entry)
  echo "$output" | grep -F '"total_open":1'
}

@test "status: promoted entry counts in [open] (transition correctness)" {
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] 2026-05-10 src/foo.py:42 — null check (touched: 2026-05-21, 2026-05-28, 2026-06-04)
EOF
  # Pre-promote: 0 in 'issues'
  fi_run status --format=json
  echo "$output" | grep -F '"total_open":0'
  # Promote
  fi_run promote-deferred "src/foo.py:42"
  # Post-promote: 1 in 'issues'
  fi_run status --format=json
  echo "$output" | grep -F '"total_open":1'
}

@test "status: critical [!] post-auto-promote bumps 'critical' (not generic 'issues')" {
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [deferred] [!] 2026-05-10 src/foo.py:42 — auth bypass (touched: 2026-05-21, 2026-05-28)
EOF
  unset FOUND_ISSUES_DEFER_TOUCH_THRESHOLD FOUND_ISSUES_DEFER_ESCALATION_FACTOR
  # 3rd touch auto-promotes critical
  fi_run log "src/foo.py:42 — auth bypass"
  [ "$status" -eq 0 ]
  fi_run status --format=json
  # critical: 1, issues: 0 (critical excluded from 'issues' subtraction)
  echo "$output" | grep -F '"critical":1'
}
```

Append the E2E lifecycle test to `tests/cli-log.bats`:

```bash
@test "log: full lifecycle — log, defer, 3x touch, nudge, promote, re-defer, 6x touch, second nudge" {
  unset FOUND_ISSUES_DEFER_TOUCH_THRESHOLD FOUND_ISSUES_DEFER_ESCALATION_FACTOR

  # Step 1: log
  fi_run log "src/auth.py:88 — leaks session token"
  [ "$status" -eq 0 ]

  # Step 2: defer
  fi_run defer "src/auth.py:88" --reason "tracked in JIRA"
  [ "$status" -eq 0 ]
  grep -F "[deferred]" docs/found-issues.md
  grep -F "(reason: tracked in JIRA)" docs/found-issues.md

  # Step 3: 3 touches → nudge fires on 3rd
  fi_run log "src/auth.py:88 — leaks session token"
  [[ "$output" == *"1x of 3"* ]]
  fi_run log "src/auth.py:88 — leaks session token"
  [[ "$output" == *"2x of 3"* ]]
  fi_run log "src/auth.py:88 — leaks session token"
  [[ "$output" == *"now 3x"* ]] || [[ "$output" == *"3x, threshold 3"* ]]
  [[ "$output" == *"promote-deferred"* ]]
  # Still [deferred] (non-critical)
  grep -F "[deferred]" docs/found-issues.md

  # Step 4: promote
  fi_run promote-deferred "src/auth.py:88"
  [ "$status" -eq 0 ]
  grep -F "[open]" docs/found-issues.md

  # Step 5: re-defer (cycle 2)
  fi_run defer "src/auth.py:88" --reason "rescoped"
  [ "$status" -eq 0 ]
  grep -F "(defer-cycle: 2)" docs/found-issues.md
  grep -F "(reason: rescoped)" docs/found-issues.md

  # Step 6: 6 touches in cycle 2 → second nudge at 6th
  fi_run log "src/auth.py:88 — leaks session token"
  [[ "$output" == *"1x of 6"* ]]
  fi_run log "src/auth.py:88 — leaks session token"
  fi_run log "src/auth.py:88 — leaks session token"
  fi_run log "src/auth.py:88 — leaks session token"
  fi_run log "src/auth.py:88 — leaks session token"
  fi_run log "src/auth.py:88 — leaks session token"
  [[ "$output" == *"now 6x"* ]] || [[ "$output" == *"6x, threshold 6"* ]]
}
```

- [ ] **Step 2: Run all tests to verify they pass**

Run: `bats tests/cli-status.bats tests/cli-log.bats`
Expected: all pass.

- [ ] **Step 3: Run the full suite for regression**

Run: `bats tests/`
Expected: 184 (current) + 33 (Phase 1) + 15 (Phase 2) + 14 (Phase 3) = ~246 tests, all green.

- [ ] **Step 4: Commit**

```bash
git add tests/cli-status.bats tests/cli-log.bats
git commit -m "test(e2e): defer-recurrence regression + full lifecycle coverage

- cli-status.bats: [deferred] excluded from 'issues' count, promote
  bumps count, critical [!] auto-promote bumps 'critical' specifically.
- cli-log.bats: end-to-end lifecycle scenario (log → defer → 3x touch →
  nudge → promote → re-defer → 6x touch → cycle-2 nudge).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3.8: Phase 3 — push + PR + auto-merge

- [ ] **Step 1: Push the branch + open PR**

Run:
```bash
git push -u origin feat/defer-recurrence-flow-phase-3
gh pr create --title "feat(cli): defer-recurrence flow Phase 3 — cmd_log dedup extension + touch detection" --body "$(cat <<'EOF'
## Summary

Phase 3 of the defer-recurrence-flow spec. Extends `cmd_log`'s dedup loop to scan `[deferred]` entries and dispatch to `fi_handle_deferred_touch` on match. **This is the actual recurrence-detection feature** — Phase 1 + Phase 2 were the foundation.

## What's added

- `cmd_log` dedup loop refactored to scan [open] then [deferred].
- `fi_handle_deferred_touch`: appends touch annotation, computes count + threshold from cycle, branches on count + criticality.
  - `count < threshold`: silent annotation + brief stderr "Nx of M for promotion".
  - `count >= threshold` non-critical: stderr nudge with `promote-deferred --match` suggestion.
  - `count >= threshold` critical `[!]`: auto-promote inline via extracted `fi_promote_entry_to_open` helper.
- ~14 new bats tests covering all branches, escalation across cycles, env-var overrides, same-day touches, and a full E2E lifecycle scenario.

## Test plan

- [x] All new tests pass
- [x] Existing tests still green (~246 total, was 184)
- [ ] CI matrix

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
gh pr merge --squash --delete-branch --auto
```

Expected: PR opened, auto-merge queued.

---

# Phase 4 — Documentation + version bump

Cosmetic but ships the feature publicly. After this, v1.0.5 is the user-facing release.

**Branch:**
```bash
git checkout main && git pull --ff-only
git checkout -b feat/defer-recurrence-flow-phase-4-docs
```

---

### Task 4.1: Add CHANGELOG 1.0.5 entry

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Inspect the existing CHANGELOG structure**

Run: `head -10 CHANGELOG.md`
Note the version-section pattern (`## [N.N.N] — YYYY-MM-DD` followed by `### Added` / `### Fixed` / etc.).

- [ ] **Step 2: Insert the 1.0.5 entry**

In `CHANGELOG.md`, add a new `## [1.0.5] — 2026-MM-DD` section between the `[Unreleased]` section and `## [1.0.4]`. Content:

```markdown
## [1.0.5] — 2026-MM-DD

### Added (defer recurrence flow — full lifecycle for [deferred] status)

- **`found-issues defer <match> [--reason "..."]` subcommand**: flips [open] → [deferred] for an entry matching `<match>`. On re-defer (entry has prior touch history from a previous defer→promote cycle), automatically increments a `(defer-cycle: N)` annotation and appends `;` to the `(touched: ...)` annotation to mark the new cycle boundary. Optional `--reason` captures a short note explaining why the entry is being deferred. Exit codes: 0 success, 1 no match, 2 ambiguous match, 3 already deferred, 4 has active `(PR: ...)` annotation (deferring an in-PR entry would silently drop it from both `issues` and `in PR` counters; blocked with two-option recovery message).
- **`found-issues promote-deferred <match>` subcommand**: inverse of defer. Flips [deferred] → [open] preserving all annotations as evidence of recurrence. Accepts positional or `--match` argument. Exit codes: 0/1/2/3 mirror defer's no-match / ambiguous / wrong-status semantics.
- **Recurrence detection in `found-issues log`**: the dedup loop now scans both [open] AND [deferred] entries. On match against [open], existing "Skipped — already logged" behavior preserved. On match against [deferred], the matched entry's `(touched: ...)` annotation is appended with today's date instead of creating a fresh [open] entry. Threshold checks fire above the per-cycle limit (default `3 * 2^(N-1)`: cycle 1 = 3 touches, cycle 2 = 6, cycle 3 = 12, ...). Non-critical entries print a stderr nudge suggesting `promote-deferred`. Critical (`[!]`) entries auto-promote inline.
- **Two new skills**: `/found-issues:defer` and `/found-issues:promote-deferred` wrap the new subcommands with prose guidance on when to use each.
- **Two env vars**: `FOUND_ISSUES_DEFER_TOUCH_THRESHOLD` (base, default 3) and `FOUND_ISSUES_DEFER_ESCALATION_FACTOR` (factor, default 2) override the threshold formula. Invalid values warn to stderr and fall back to defaults.
- **7 new lib helpers** in `lib/parse-entries.sh`: `fi_extract_touched_segment`, `fi_current_cycle_touch_count`, `fi_extract_defer_cycle`, `fi_extract_reason`, `fi_compute_threshold`, `fi_append_touch`, `fi_increment_defer_cycle`. All atomic (temp+mv pattern) for file mutations.
- **Hook acceptance**: `format-enforcer` and `pre-commit` hook regexes extended to recognize `(touched: ...)`, `(defer-cycle: N)`, `(reason: ...)` annotations as valid (no false-positive flags).
- **~62 new bats tests** across 4 phases. Total goes from 184 → ~246. Density mirrors `cli-statusline.bats` (28 tests for 5 states + 6 transitions; defer flow has 4 transitions + 3 entry states).

### Architecture notes

- `[deferred]` is now a first-class lifecycle state with explicit transitions (`defer`, `promote-deferred`) and a passive recurrence signal (touch counter via dedup extension).
- Touch annotations use a `;` separator within `(touched: ...)` to demarcate defer-cycle boundaries. Threshold counting is per-cycle (after the last `;`), not cumulative — persistent history serves as evidence for future maintainers, not as a count toward the next nudge.
- Loop prevention: each defer→promote→re-defer cycle bumps `(defer-cycle: N)`. Each cycle's threshold doubles (configurable factor). Self-regulating — operator can keep deferring an entry they genuinely don't want to address; the plugin shuts up faster each cycle.
- Statusline counter unchanged — promotion (auto for critical, manual for non-critical) is the visibility event that bumps the existing `issues` count.

### Spec

[`docs/superpowers/specs/2026-05-10-defer-recurrence-flow-design.md`](docs/superpowers/specs/2026-05-10-defer-recurrence-flow-design.md)
```

(Replace `2026-MM-DD` with the actual ship date when ready to commit.)

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs(changelog): 1.0.5 entry — defer recurrence flow

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4.2: Add README "Deferring recurring issues" subsection

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Inspect README structure**

Run: `grep -nE '^## |^### ' README.md | head -20`
Find the "What it does" section and a logical insertion point — probably after the section that explains the current open/fixed/deferred statuses.

- [ ] **Step 2: Add the new subsection**

In `README.md`, find the "What it does" section. After its existing content (which describes logging + auto-flip on PR merge), add:

```markdown
### Deferring recurring issues

Sometimes a logged issue is real but not addressable now (out-of-scope, blocked, low priority). The plugin treats `[deferred]` as a first-class lifecycle state: tracked in the file, suppressed from the statusline counter, and flagged when it recurs.

```bash
# Defer with optional reason
/found-issues:defer src/auth.py:88 --reason "tracked in JIRA-1234"

# Promote back to [open] when ready to address
/found-issues:promote-deferred src/auth.py:88
```

**Recurrence detection.** When you `log` an issue that matches an existing `[deferred]` entry's dedup key, the plugin appends today's date to a `(touched: ...)` annotation on the deferred entry — no new `[open]` entry is created. After 3 touches (cycle 1 default), it nudges:

```
Touched deferred entry (now 3x, threshold 3): src/auth.py:88
Consider: found-issues promote-deferred --match auth.py
```

**Critical entries auto-promote.** Entries logged with `--critical` (the `[!]` flag) flip back to `[open]` automatically on the Nth touch — no manual step.

**Loop prevention.** If you promote and re-defer the same entry, the threshold for the next nudge doubles (cycle 1: 3 touches → cycle 2: 6 → cycle 3: 12 → ...). The history is preserved as evidence, but the bar to bug you about it again rises geometrically. Configurable via `FOUND_ISSUES_DEFER_TOUCH_THRESHOLD` (base, default 3) and `FOUND_ISSUES_DEFER_ESCALATION_FACTOR` (factor, default 2).
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs(readme): add 'Deferring recurring issues' subsection

Documents the v1.0.5 defer flow: defer/promote-deferred subcommands,
recurrence detection via touch counter, critical auto-promote, and
geometric threshold escalation across defer cycles.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4.3: Bump version to 1.0.5 + open the docs PR + auto-merge

**Files:**
- Modify: `bin/found-issues` (line 9: `readonly FI_VERSION="1.0.4"` → `"1.0.5"`)
- Modify: `.claude-plugin/plugin.json` (line 4: `"version": "1.0.4"` → `"1.0.5"`)

- [ ] **Step 1: Bump version in `bin/found-issues`**

In `bin/found-issues`, change:
```bash
readonly FI_VERSION="1.0.4"
```
to:
```bash
readonly FI_VERSION="1.0.5"
```

- [ ] **Step 2: Bump version in `.claude-plugin/plugin.json`**

In `.claude-plugin/plugin.json`, change:
```json
"version": "1.0.4",
```
to:
```json
"version": "1.0.5",
```

- [ ] **Step 3: Update CHANGELOG date placeholder**

In `CHANGELOG.md`, replace `2026-MM-DD` in the 1.0.5 section header with today's actual date (e.g., `2026-05-10`).

- [ ] **Step 4: Run the full suite for one final regression check**

Run: `bats tests/`
Expected: all ~246 tests pass.

- [ ] **Step 5: Commit + push + PR + auto-merge**

```bash
git add bin/found-issues .claude-plugin/plugin.json CHANGELOG.md
git commit -m "chore(release): bump to v1.0.5 (defer recurrence flow)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"

git push -u origin feat/defer-recurrence-flow-phase-4-docs

gh pr create --title "docs(release): defer-recurrence flow Phase 4 — CHANGELOG, README, v1.0.5 bump" --body "$(cat <<'EOF'
## Summary

Phase 4 of the defer-recurrence-flow spec. Documents the feature publicly + bumps version to 1.0.5.

## What's added

- `CHANGELOG.md` 1.0.5 entry with full feature breakdown + architecture notes + spec link
- `README.md` "Deferring recurring issues" subsection (when-to-use + worked example + threshold env vars)
- Version bump in `bin/found-issues` (FI_VERSION) and `.claude-plugin/plugin.json`

## Test plan

- [x] Full bats suite green (~246 tests across all 4 phases)
- [ ] CI matrix

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"

gh pr merge --squash --delete-branch --auto
```

Expected: PR opened, auto-merge queued. After CI green + merge: v1.0.5 is live.

---

## Self-review summary (post-write)

Verified before handoff:
1. **Spec coverage** — every section of the spec maps to tasks: data model → Tasks 1.1–1.7; CLI subcommands → Tasks 2.1–2.10; cmd_log extension → Tasks 3.1–3.6; error handling matrix → embedded across all defer/promote tasks; testing strategy → embedded per task with the inventory matching ~28 new tests + ~33 helper tests. Phase boundaries match spec's 4-phase implementation guidance.
2. **No placeholders** — every step has actual code, exact file paths, exact commands, exact expected output. The `2026-MM-DD` date placeholder in Task 4.1 is intentionally meta (replaced at ship time in Task 4.3 step 3).
3. **Type consistency** — function names referenced consistently across tasks (e.g., `fi_compute_threshold`, `fi_handle_deferred_touch`, `fi_promote_entry_to_open`). Helper function signatures match between definition and usage.
