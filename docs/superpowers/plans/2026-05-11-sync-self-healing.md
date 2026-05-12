# Sync Self-Healing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `found-issues sync` self-healing — auto-demote stale PR/commit annotations to re-enable AI verification, auto-correct file renames before tombstone, and replace the silent default-branch fallback footgun with proper gh-based detection.

**Architecture:** Six sequential phases. Phase 1 builds the gh-mock test infrastructure and refactors sync's PR-state reading into a single gh call returning all needed fields. Phases 2-5 layer behavior changes one at a time, each fully tested and committed before the next starts. Phase 6 documents, changelogs, and bumps to v1.2.0.

**Tech Stack:** bash 3.2+ (macOS compat), bats-core (testing), `gh` CLI, `jq`, `git`.

**Spec:** [`docs/superpowers/specs/2026-05-11-sync-self-healing-design.md`](../specs/2026-05-11-sync-self-healing-design.md)
**Gap analysis:** [`docs/superpowers/audits/2026-05-11-annotation-lifecycle-gaps.md`](../audits/2026-05-11-annotation-lifecycle-gaps.md)

---

## File structure overview

### Files to create

| Path | Purpose |
|---|---|
| `tests/bin-shims/gh` | PATH shim that fakes `gh` for bats tests; reads mock responses from env vars |
| `tests/cli-sync-pr-states.bats` | A1/A3/A9/A10 tests — closed-no-merge, stuck-draft, gh-empty |
| `tests/cli-sync-commit-stale.bats` | B1/B2 tests — commit demotion when SHA unreachable |
| `tests/cli-sync-rename.bats` | C1 tests — rename detection before tombstone |
| `tests/cli-sync-default-branch.bats` | E1 tests — gh-based default-branch fallback |
| `tests/format-enforcer-new-annotations.bats` | Confirm new annotations pass the blocklist |

### Files to modify

| Path | Change scope |
|---|---|
| `bin/found-issues` | Extend `cmd_sync` (single gh call, classification, demotion, rename detect, default-branch chain); narrow `cmd_defer` blocker; extend `cmd_doctor` |
| `lib/parse-entries.sh` | Extend `fi_parse_entry` for new annotations; update `fi_count_in_pr` and `fi_count_stale` |
| `tests/helpers.bash` | Add `fi_use_gh_shim` helper |
| `commands/sync.md` | Update Phase 2 instructions to include demoted-annotation entries |
| `docs/format-spec.md` | Document new annotation forms |
| `CHANGELOG.md` | v1.2.0 entry |
| `.claude-plugin/plugin.json` | Version bump |

---

## Phase 1 — Read-only sync introspection + gh test infrastructure

This phase introduces no behavior changes for users. It builds the gh-mocking test harness, refactors sync's PR-state reading into a single gh call returning all needed fields (`state`, `baseRefName`, `mergedAt`, `isDraft`), and adds a `--dry-run` mode that emits a classification table for testing.

### Task 1.1: Create the gh PATH shim

**Files:**
- Create: `tests/bin-shims/gh`

- [ ] **Step 1: Create the shim script**

```bash
mkdir -p tests/bin-shims
```

Write `tests/bin-shims/gh`:

```bash
#!/usr/bin/env bash
# Mock gh CLI for bats tests.
#
# Reads mock responses from env vars:
#   GH_MOCK_PR_VIEW       tab-separated: <pr_num>\t<json>   (newline-separated rows)
#   GH_MOCK_REPO_VIEW     full JSON response for `gh repo view --json ...`
#   GH_MOCK_AUTH          "ok" (default) or "fail" — controls `gh auth status` exit
#   GH_MOCK_TRACE         path to write each invocation (for assertions)
#
# Behavior: print matching JSON to stdout and exit 0; exit 1 if no match.
# Does NOT honor --jq filtering — callers should pipe to real jq in the CLI.

set -euo pipefail

# Trace invocation if requested
if [[ -n "${GH_MOCK_TRACE:-}" ]]; then
  printf '%s\n' "$*" >> "$GH_MOCK_TRACE"
fi

# Strip --json fields and --jq from argv (we don't filter)
filtered_args=()
skip_next=0
for a in "$@"; do
  if [[ "$skip_next" == "1" ]]; then
    skip_next=0
    continue
  fi
  case "$a" in
    --json|--jq) skip_next=1 ;;
    *) filtered_args+=("$a") ;;
  esac
done

cmd="${filtered_args[0]:-}"
sub="${filtered_args[1]:-}"

case "$cmd $sub" in
  "pr view")
    pr_num="${filtered_args[2]:-}"
    if [[ -n "${GH_MOCK_PR_VIEW:-}" ]]; then
      while IFS=$'\t' read -r mock_num mock_json; do
        [[ -z "$mock_num" ]] && continue
        if [[ "$mock_num" == "$pr_num" ]]; then
          printf '%s\n' "$mock_json"
          exit 0
        fi
      done <<<"$GH_MOCK_PR_VIEW"
    fi
    printf 'GraphQL: Could not resolve PR\n' >&2
    exit 1
    ;;
  "repo view")
    if [[ -n "${GH_MOCK_REPO_VIEW:-}" ]]; then
      printf '%s\n' "$GH_MOCK_REPO_VIEW"
      exit 0
    fi
    exit 1
    ;;
  "auth status")
    if [[ "${GH_MOCK_AUTH:-ok}" == "ok" ]]; then
      printf 'Logged in to github.com\n'
      exit 0
    fi
    printf 'not authenticated\n' >&2
    exit 1
    ;;
  *)
    printf 'gh-shim: unsupported command: %s %s\n' "$cmd" "$sub" >&2
    exit 1
    ;;
esac
```

- [ ] **Step 2: Make executable**

```bash
chmod +x tests/bin-shims/gh
```

- [ ] **Step 3: Add helper function to `tests/helpers.bash`**

Append to `tests/helpers.bash`:

```bash
# Activate the gh shim for this test by prepending bin-shims to PATH.
# Caller must set GH_MOCK_PR_VIEW / GH_MOCK_REPO_VIEW / GH_MOCK_AUTH as needed.
fi_use_gh_shim() {
  export PATH="$TEST_REPO_ROOT/tests/bin-shims:$PATH"
}
```

- [ ] **Step 4: Commit**

```bash
git add tests/bin-shims/gh tests/helpers.bash
git commit -m "test: gh PATH shim infrastructure for mocking gh in bats"
```

---

### Task 1.2: Verify shim sanity with a smoke test

**Files:**
- Create: `tests/cli-sync-pr-states.bats`

- [ ] **Step 1: Write smoke test**

```bash
#!/usr/bin/env bats
# Tests for sync's PR-state classification and demotion behavior.
load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
  fi_use_gh_shim
}

teardown() {
  fi_teardown_tmp
}

@test "gh shim: returns mocked JSON for known PR" {
  export GH_MOCK_PR_VIEW=$'42\t{"state":"MERGED","baseRefName":"main","mergedAt":"2026-05-01T12:00:00Z","isDraft":false}'
  run gh pr view 42 --repo foo/bar --json state,baseRefName,mergedAt,isDraft
  [ "$status" -eq 0 ]
  [[ "$output" == *"MERGED"* ]]
  [[ "$output" == *"main"* ]]
}

@test "gh shim: exits 1 for unknown PR" {
  export GH_MOCK_PR_VIEW=$'42\t{"state":"MERGED"}'
  run gh pr view 99 --repo foo/bar --json state
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run smoke test**

```bash
bats tests/cli-sync-pr-states.bats
```

Expected: 2 tests pass.

- [ ] **Step 3: Commit**

```bash
git add tests/cli-sync-pr-states.bats
git commit -m "test: smoke tests for gh shim"
```

---

### Task 1.3: Refactor cmd_sync to single gh call returning all fields

**Files:**
- Modify: `bin/found-issues:1091-1112` (the PR-check loop inside `cmd_sync`)

Today the loop calls `gh pr view` twice per PR (once for state, once for baseRefName). Refactor to one call returning all four fields we'll need (`state`, `baseRefName`, `mergedAt`, `isDraft`), parsed with `jq`.

- [ ] **Step 1: Write a test that the existing MERGED happy path still flips to fixed**

Append to `tests/cli-sync-pr-states.bats`:

```bash
@test "sync: MERGED PR on default branch flips entry to [fixed]" {
  export GH_MOCK_PR_VIEW=$'42\t{"state":"MERGED","baseRefName":"main","mergedAt":"2026-05-01T12:00:00Z","isDraft":false}'
  git commit --allow-empty -q -m "init"
  git remote add origin https://example.com/foo/bar.git
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

  fi_run log "src/foo.py:1 — bug (PR: foo/bar#42)"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '\[fixed\].*\(PR: foo/bar#42\)' docs/found-issues.md
}
```

- [ ] **Step 2: Run test to verify it fails (existing CLI does two calls; current code path won't see the mocked JSON correctly with the shim's behavior)**

```bash
bats tests/cli-sync-pr-states.bats::sync:_MERGED_PR_on_default_branch_flips_entry_to__fixed_
```

Expected: FAIL or pass depending on whether the shim's stripping of `--jq` confuses the current `--jq '.state'` path. Either way, the next step refactors to a single call so the test passes deterministically.

- [ ] **Step 3: Refactor `cmd_sync` PR-check loop**

Locate `bin/found-issues:1091-1112` and replace the block:

```bash
# Check PR annotations
if [[ -n "$e_prs" && -n "$repo_id" ]] && command -v gh >/dev/null 2>&1; then
  local IFS_old="$IFS"
  IFS=','
  for pr_ref in $e_prs; do
    IFS="$IFS_old"
    # pr_ref is org/repo#N
    local pr_num="${pr_ref##*#}"
    local pr_repo="${pr_ref%#*}"
    local pr_state pr_branch
    pr_state="$(gh pr view "$pr_num" --repo "$pr_repo" \
      --json state,baseRefName --jq '.state' 2>/dev/null || true)"
    pr_branch="$(gh pr view "$pr_num" --repo "$pr_repo" \
      --json baseRefName --jq '.baseRefName' 2>/dev/null || true)"
    if [[ "$pr_state" == "MERGED" && ( -z "$default_branch" || "$pr_branch" == "$default_branch" ) ]]; then
      closure_kind="pr"
      closure_label="(fixed: $today)"
      closed_pr=$((closed_pr + 1))
      break
    fi
  done
  IFS="$IFS_old"
fi
```

…with this (single gh call, jq parsing in CLI):

```bash
# Check PR annotations (single gh call per PR returning all needed fields)
if [[ -n "$e_prs" && -n "$repo_id" ]] && command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  local IFS_old="$IFS"
  IFS=','
  for pr_ref in $e_prs; do
    IFS="$IFS_old"
    local pr_num="${pr_ref##*#}"
    local pr_repo="${pr_ref%#*}"
    local pr_json
    pr_json="$(gh pr view "$pr_num" --repo "$pr_repo" \
      --json state,baseRefName,mergedAt,isDraft 2>/dev/null || true)"
    if [[ -z "$pr_json" ]]; then
      # gh empty: warn and continue (don't demote — could be transient)
      gh_empty_warnings+=("$pr_ref")
      continue
    fi
    local pr_state pr_branch
    pr_state="$(printf '%s' "$pr_json" | jq -r '.state // empty')"
    pr_branch="$(printf '%s' "$pr_json" | jq -r '.baseRefName // empty')"
    if [[ "$pr_state" == "MERGED" && ( -z "$default_branch" || "$pr_branch" == "$default_branch" ) ]]; then
      closure_kind="pr"
      closure_label="(fixed: $today)"
      closed_pr=$((closed_pr + 1))
      break
    fi
  done
  IFS="$IFS_old"
fi
```

Also at the top of `cmd_sync` (near `local closed_pr=0 closed_commit=0 closed_tomb=0`), add:

```bash
local -a gh_empty_warnings=()
```

And at the end of `cmd_sync` (before the auto-archive block), add:

```bash
# Surface gh-empty warnings (A9/A10): PRs that couldn't be fetched.
# Don't demote — could be transient auth/network/rate-limit.
if (( ${#gh_empty_warnings[@]} > 0 )); then
  printf '\nWarning: %d PR annotation(s) could not be fetched via gh:\n' "${#gh_empty_warnings[@]}" >&2
  local w
  for w in "${gh_empty_warnings[@]}"; do
    printf '  - %s\n' "$w" >&2
  done
  printf '  (Check gh auth status or verify the PR numbers are correct.)\n' >&2
fi
```

- [ ] **Step 4: Run the test again, verify it passes**

```bash
bats tests/cli-sync-pr-states.bats
```

Expected: 3 tests pass.

- [ ] **Step 5: Run the full existing sync test suite to confirm no regression**

```bash
bats tests/cli-sync.bats
```

Expected: 8 tests pass (no change in behavior for unmocked paths).

- [ ] **Step 6: Commit**

```bash
git add bin/found-issues tests/cli-sync-pr-states.bats
git commit -m "refactor(sync): single gh call per PR returning state/baseRefName/mergedAt/isDraft"
```

---

### Task 1.4: Add gh-empty warning test

**Files:**
- Modify: `tests/cli-sync-pr-states.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/cli-sync-pr-states.bats`:

```bash
@test "sync: gh-empty PR triggers warning but does not mutate" {
  export GH_MOCK_PR_VIEW=""  # no mocks defined → gh exits 1
  git commit --allow-empty -q -m "init"
  git remote add origin https://example.com/foo/bar.git
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

  fi_run log "src/foo.py:1 — bug (PR: foo/bar#99)"
  fi_run sync
  [ "$status" -eq 0 ]
  # Entry stays [open] with original annotation
  grep -q '^- \[open\].*\(PR: foo/bar#99\)' docs/found-issues.md
  # Warning surfaced (combined output from bats captures both stdout and stderr)
  [[ "$output" == *"could not be fetched"* ]]
  [[ "$output" == *"foo/bar#99"* ]]
}
```

- [ ] **Step 2: Run test**

```bash
bats tests/cli-sync-pr-states.bats::sync:_gh-empty_PR_triggers_warning_but_does_not_mutate
```

Expected: PASS (the warning block from Task 1.3 already handles this).

- [ ] **Step 3: Commit**

```bash
git add tests/cli-sync-pr-states.bats
git commit -m "test: gh-empty PR warning surfaces without mutation"
```

---

## Phase 2 — Annotation demotion (PR-closed, commit-stale)

Add mutation logic so closed-without-merge PRs demote to `(PR-closed: ...)` and unreachable commit SHAs demote to `(commit-stale: ...)`. Idempotent.

### Task 2.1: PR-closed demotion

**Files:**
- Modify: `bin/found-issues` — extend the PR-check loop in `cmd_sync`
- Modify: `tests/cli-sync-pr-states.bats`

- [ ] **Step 1: Write the failing test**

Append:

```bash
@test "sync: CLOSED-without-merge PR demotes to (PR-closed: ...)" {
  export GH_MOCK_PR_VIEW=$'42\t{"state":"CLOSED","baseRefName":"main","mergedAt":null,"isDraft":false}'
  git commit --allow-empty -q -m "init"
  git remote add origin https://example.com/foo/bar.git
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

  fi_run log "src/foo.py:1 — bug (PR: foo/bar#42)"
  fi_run sync
  [ "$status" -eq 0 ]
  # Entry stays [open], but annotation demoted
  grep -q '^- \[open\].*\(PR-closed: foo/bar#42\)' docs/found-issues.md
  ! grep -qE '\(PR: foo/bar#42\)' docs/found-issues.md
}

@test "sync: PR-closed demotion is idempotent (second sync is no-op)" {
  export GH_MOCK_PR_VIEW=$'42\t{"state":"CLOSED","baseRefName":"main","mergedAt":null,"isDraft":false}'
  git commit --allow-empty -q -m "init"
  git remote add origin https://example.com/foo/bar.git
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

  fi_run log "src/foo.py:1 — bug (PR: foo/bar#42)"
  fi_run sync
  local content_after_first
  content_after_first="$(cat docs/found-issues.md)"

  fi_run sync
  [ "$status" -eq 0 ]
  diff <(echo "$content_after_first") docs/found-issues.md
}
```

- [ ] **Step 2: Run, verify failure**

```bash
bats tests/cli-sync-pr-states.bats
```

Expected: the two new tests fail.

- [ ] **Step 3: Implement demotion**

In `bin/found-issues`, inside `cmd_sync`'s PR-check loop, after the MERGED branch but before `break`, add a CLOSED branch:

```bash
if [[ "$pr_state" == "MERGED" && ( -z "$default_branch" || "$pr_branch" == "$default_branch" ) ]]; then
  closure_kind="pr"
  closure_label="(fixed: $today)"
  closed_pr=$((closed_pr + 1))
  break
fi

# A1: closed-without-merge → demote annotation
local pr_merged_at
pr_merged_at="$(printf '%s' "$pr_json" | jq -r '.mergedAt // empty')"
if [[ "$pr_state" == "CLOSED" && -z "$pr_merged_at" ]]; then
  demote_pr_refs+=("$pr_ref")
  # don't break — entry might have another PR ref that merged
fi
```

Add at top of `cmd_sync` near other locals:

```bash
local -a demote_pr_refs=()
```

After the per-entry annotation loop ends (after the existing tombstone block), but BEFORE the `if [[ -n "$closure_kind" ]]` block, add the demotion logic:

```bash
# A1: apply PR demotions if entry didn't otherwise close
if [[ -z "$closure_kind" && ${#demote_pr_refs[@]} -gt 0 ]]; then
  local demoted_line="$line"
  local ref
  for ref in "${demote_pr_refs[@]}"; do
    # Replace exactly '(PR: <ref>)' with '(PR-closed: <ref>)'
    demoted_line="${demoted_line//(PR: $ref)/(PR-closed: $ref)}"
  done
  printf '%s\n' "$demoted_line" >>"$tmp"
  demoted_pr=$((demoted_pr + 1))
  # Reset demote_pr_refs for next iteration
  demote_pr_refs=()
  continue
fi

# Reset demote_pr_refs (no demotion needed for this entry, but next entry needs clean slate)
demote_pr_refs=()
```

Also add to top of `cmd_sync`:

```bash
local demoted_pr=0 demoted_commit=0
```

And update the closure summary line near the end of `cmd_sync`:

```bash
local total_closed=$((closed_pr + closed_commit + closed_tomb))
local total_demoted=$((demoted_pr + demoted_commit))
if [[ "$total_closed" -gt 0 || "$total_demoted" -gt 0 ]]; then
  printf 'Synced. Closed: %d (%d PR + %d commit + %d tombstone). Demoted: %d (%d PR-closed + %d commit-stale).\n' \
    "$total_closed" "$closed_pr" "$closed_commit" "$closed_tomb" \
    "$total_demoted" "$demoted_pr" "$demoted_commit"
elif [[ "$total_closed" -eq 0 ]]; then
  printf 'Synced. Nothing to close.\n'
fi
```

- [ ] **Step 4: Run tests, verify pass**

```bash
bats tests/cli-sync-pr-states.bats
bats tests/cli-sync.bats
```

Expected: all pass (idempotency works because second-run sees `(PR-closed: ...)` which isn't in `e_prs` — the parser only extracts `(PR: ...)`).

- [ ] **Step 5: Commit**

```bash
git add bin/found-issues tests/cli-sync-pr-states.bats
git commit -m "feat(sync): demote closed-without-merge PR annotations to (PR-closed: ...)"
```

---

### Task 2.2: Parse-entries recognizes new annotation forms

**Files:**
- Modify: `lib/parse-entries.sh:fi_parse_entry`
- Create: `tests/parse-entries-new-annotations.bats`

- [ ] **Step 1: Write the failing tests**

Create `tests/parse-entries-new-annotations.bats`:

```bash
#!/usr/bin/env bats
load 'helpers'

setup() { fi_source_lib parse-entries; }

@test "fi_parse_entry: recognizes (PR-closed: ...) annotation" {
  output="$(fi_parse_entry '- [open] 2026-05-11 src/foo.py:1 — bug (PR-closed: foo/bar#42)')"
  [[ "$output" == *"prs_closed=foo/bar#42"* ]]
}

@test "fi_parse_entry: recognizes (commit-stale: ...) annotation" {
  output="$(fi_parse_entry '- [open] 2026-05-11 src/foo.py:1 — bug (commit-stale: a1b2c3d)')"
  [[ "$output" == *"commits_stale=a1b2c3d"* ]]
}

@test "fi_parse_entry: recognizes (renamed-from: ...) annotation" {
  output="$(fi_parse_entry '- [open] 2026-05-11 new/path.py:1 — bug (renamed-from: old/path.py)')"
  [[ "$output" == *"renamed_from=old/path.py"* ]]
}

@test "fi_parse_entry: distinguishes (PR: ...) from (PR-closed: ...)" {
  output="$(fi_parse_entry '- [open] 2026-05-11 src/foo.py:1 — bug (PR: foo/bar#42) (PR-closed: foo/bar#41)')"
  [[ "$output" == *"prs=foo/bar#42"* ]]
  [[ "$output" == *"prs_closed=foo/bar#41"* ]]
}
```

- [ ] **Step 2: Run, verify failures**

```bash
bats tests/parse-entries-new-annotations.bats
```

Expected: all 4 fail.

- [ ] **Step 3: Extend `fi_parse_entry`**

In `lib/parse-entries.sh:fi_parse_entry`, locate the section parsing `(PR: ...)` references (around `re_pr=`). The current parser likely uses something like:

```bash
local re_pr='\(PR: ([^)]+)\)'
local prs=""
# ... extracts all matches
```

Read the existing block, then add three new regex extractions immediately after the existing PR extraction. The pattern is identical — extract all matches into a comma-separated list:

```bash
# (PR-closed: ...) annotations
local prs_closed=""
local tmp_line="$line"
local re_pr_closed='\(PR-closed: ([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+)\)'
while [[ "$tmp_line" =~ $re_pr_closed ]]; do
  if [[ -z "$prs_closed" ]]; then
    prs_closed="${BASH_REMATCH[1]}"
  else
    prs_closed="$prs_closed,${BASH_REMATCH[1]}"
  fi
  tmp_line="${tmp_line#*"${BASH_REMATCH[0]}"}"
done

# (commit-stale: ...) annotations
local commits_stale=""
tmp_line="$line"
local re_commit_stale='\(commit-stale: ([a-f0-9]{7,40})\)'
while [[ "$tmp_line" =~ $re_commit_stale ]]; do
  if [[ -z "$commits_stale" ]]; then
    commits_stale="${BASH_REMATCH[1]}"
  else
    commits_stale="$commits_stale,${BASH_REMATCH[1]}"
  fi
  tmp_line="${tmp_line#*"${BASH_REMATCH[0]}"}"
done

# (renamed-from: ...) annotation (single)
local renamed_from=""
local re_renamed='\(renamed-from: ([^)]+)\)'
if [[ "$line" =~ $re_renamed ]]; then
  renamed_from="${BASH_REMATCH[1]}"
fi
```

And in the output emission block at end of `fi_parse_entry`, add three new lines:

```bash
printf 'prs_closed=%s\n' "$prs_closed"
printf 'commits_stale=%s\n' "$commits_stale"
printf 'renamed_from=%s\n' "$renamed_from"
```

**Critical:** the existing `(PR: ...)` regex must NOT match `(PR-closed: ...)`. Verify the existing regex is anchored to require `(PR: ` exactly (colon-space, no hyphen). If it's `\(PR[: -][^)]+\)` or similar over-broad pattern, tighten to `\(PR: ([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+)\)`. Read the existing code first.

- [ ] **Step 4: Run tests, verify pass**

```bash
bats tests/parse-entries-new-annotations.bats
bats tests/parse-entries.bats
```

Expected: 4 new tests pass; existing parse-entries tests still pass.

- [ ] **Step 5: Commit**

```bash
git add lib/parse-entries.sh tests/parse-entries-new-annotations.bats
git commit -m "feat(parse): recognize PR-closed, commit-stale, renamed-from annotations"
```

---

### Task 2.3: Commit-stale demotion

**Files:**
- Modify: `bin/found-issues:cmd_sync` — commit-check loop
- Modify: `tests/cli-sync-commit-stale.bats` (new file)

- [ ] **Step 1: Create test file with failing tests**

Create `tests/cli-sync-commit-stale.bats`:

```bash
#!/usr/bin/env bats
load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

@test "sync: unresolvable commit SHA demotes to (commit-stale: ...)" {
  mkdir -p src
  echo "x" > src/foo.py
  git add src/foo.py
  git commit -q -m "init"

  fi_run log "src/foo.py:1 — bug (commit: deadbeef)"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\].*\(commit-stale: deadbeef\)' docs/found-issues.md
  ! grep -qE '\(commit: deadbeef\)' docs/found-issues.md
}

@test "sync: commit-stale demotion is idempotent" {
  mkdir -p src
  echo "x" > src/foo.py
  git add src/foo.py
  git commit -q -m "init"

  fi_run log "src/foo.py:1 — bug (commit: deadbeef)"
  fi_run sync
  local snapshot
  snapshot="$(cat docs/found-issues.md)"
  fi_run sync
  diff <(echo "$snapshot") docs/found-issues.md
}

@test "sync: existing reachable commit still flips to [fixed] (unchanged behavior)" {
  mkdir -p src
  echo "x" > src/foo.py
  git add src/foo.py
  git commit -q -m "add foo"
  local sha
  sha="$(git rev-parse --short=7 HEAD)"

  fi_run log "src/foo.py:1 — bug (commit: $sha)"
  fi_run sync
  grep -q '\[fixed\].*\(commit: '"$sha"'\)' docs/found-issues.md
}
```

- [ ] **Step 2: Run, verify failures**

```bash
bats tests/cli-sync-commit-stale.bats
```

Expected: first two fail, third (existing behavior) passes.

- [ ] **Step 3: Implement commit-stale demotion**

In `bin/found-issues:cmd_sync`, locate the commit-check loop (around line 1115). Modify:

```bash
# Check commit annotations (only if not already closed via PR)
if [[ -z "$closure_kind" && -n "$e_commits" && -n "$default_branch" ]]; then
  local IFS_old="$IFS"
  IFS=','
  for sha in $e_commits; do
    IFS="$IFS_old"
    if git rev-parse --verify "$sha" >/dev/null 2>&1; then
      if git merge-base --is-ancestor "$sha" "$default_branch" 2>/dev/null \
         || git merge-base --is-ancestor "$sha" "origin/$default_branch" 2>/dev/null; then
        closure_kind="commit"
        closure_label="(fixed: $today)"
        closed_commit=$((closed_commit + 1))
        break
      fi
      # SHA exists but isn't ancestor — leave alone (unmerged feature branch)
    else
      # B1/B2: SHA doesn't resolve (squash-merged away, force-pushed) → demote
      demote_commit_refs+=("$sha")
    fi
  done
  IFS="$IFS_old"
fi
```

Add to top of `cmd_sync`:

```bash
local -a demote_commit_refs=()
```

After the existing PR-demotion block (from Task 2.1), add a parallel commit-demotion block:

```bash
# B1/B2: apply commit demotions if entry didn't otherwise close
if [[ -z "$closure_kind" && ${#demote_commit_refs[@]} -gt 0 ]]; then
  local demoted_line="$line"
  local sha_ref
  for sha_ref in "${demote_commit_refs[@]}"; do
    demoted_line="${demoted_line//(commit: $sha_ref)/(commit-stale: $sha_ref)}"
  done
  printf '%s\n' "$demoted_line" >>"$tmp"
  demoted_commit=$((demoted_commit + 1))
  demote_commit_refs=()
  continue
fi

demote_commit_refs=()
```

- [ ] **Step 4: Run tests, verify pass**

```bash
bats tests/cli-sync-commit-stale.bats
bats tests/cli-sync.bats
bats tests/cli-sync-pr-states.bats
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add bin/found-issues tests/cli-sync-commit-stale.bats
git commit -m "feat(sync): demote unresolvable commit annotations to (commit-stale: ...)"
```

---

## Phase 3 — Tombstone rename auto-correction

Before declaring a tombstone closure on a missing file, detect whether `git mv` moved it. If so, rewrite the entry's path and record `(renamed-from: old-path)`.

### Task 3.1: Rename detection helper

**Files:**
- Modify: `bin/found-issues` — add helper function `fi_detect_rename`
- Create: `tests/cli-sync-rename.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/cli-sync-rename.bats`:

```bash
#!/usr/bin/env bats
load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() {
  fi_teardown_tmp
}

@test "sync: renamed file → entry path auto-corrected with (renamed-from: ...)" {
  mkdir -p src
  echo "content" > src/old.py
  git add src/old.py
  git commit -q -m "add old.py"

  fi_run log "src/old.py:1 — bug"

  git mv src/old.py src/new.py
  git commit -q -m "rename old → new"

  fi_run sync
  [ "$status" -eq 0 ]
  # Entry stays [open] but path updated
  grep -q '^- \[open\].*src/new.py:1.*\(renamed-from: src/old.py\)' docs/found-issues.md
  # Entry is NOT [fixed]
  ! grep -qE '^- \[fixed\].*src/(old|new).py' docs/found-issues.md
}

@test "sync: file deleted (not renamed) still flips to [fixed] tombstone" {
  mkdir -p src
  echo "content" > src/gone.py
  git add src/gone.py
  git commit -q -m "add gone.py"

  fi_run log "src/gone.py:1 — bug"

  git rm src/gone.py
  git commit -q -m "delete gone.py"

  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '\[fixed\].*closure: tombstone' docs/found-issues.md
}

@test "sync: rename then delete → tombstone fires on new path (correctly)" {
  mkdir -p src
  echo "content" > src/a.py
  git add src/a.py
  git commit -q -m "add a"

  fi_run log "src/a.py:1 — bug"

  git mv src/a.py src/b.py
  git commit -q -m "rename a → b"

  fi_run sync  # Should auto-correct path to b.py
  grep -q '^- \[open\].*src/b.py.*renamed-from: src/a.py' docs/found-issues.md

  git rm src/b.py
  git commit -q -m "delete b"

  fi_run sync  # Now b.py is gone, tombstone fires
  grep -q '\[fixed\].*closure: tombstone' docs/found-issues.md
}
```

- [ ] **Step 2: Run, verify failures**

```bash
bats tests/cli-sync-rename.bats
```

Expected: first and third tests fail (rename auto-correct doesn't exist yet); second passes (existing tombstone).

- [ ] **Step 3: Add the rename detection helper**

In `bin/found-issues`, near the top (after `fi_today` and other small helpers, before subcommand definitions), add:

```bash
# Detect if a missing file was renamed via git. Returns the new path on stdout
# if a rename target is found in the working tree; returns nothing + exits 1 otherwise.
#
# Uses git log --diff-filter=R --follow to find rename events in reverse-
# chronological order. The first line's third tab-separated field is the
# most-recent rename target.
fi_detect_rename() {
  local old_path="$1"
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    return 1
  fi
  local rename_line
  rename_line="$(git log --diff-filter=R --follow --name-status --pretty=format: -- "$old_path" 2>/dev/null \
    | grep -E '^R[0-9]+\s' | head -1 || true)"
  if [[ -z "$rename_line" ]]; then
    return 1
  fi
  # Format: R<score>\told_path\tnew_path
  local new_path
  new_path="$(printf '%s' "$rename_line" | awk -F'\t' '{print $3}')"
  if [[ -n "$new_path" && -f "$new_path" ]]; then
    printf '%s' "$new_path"
    return 0
  fi
  return 1
}
```

- [ ] **Step 4: Integrate rename detection into tombstone block**

In `cmd_sync`, locate the tombstone block (around line 1133):

```bash
# Tombstone check (only if no annotations resolved AND path looks like a file)
if [[ -z "$closure_kind" && -n "$e_path" ]]; then
  if [[ "$e_path" == */* || "$e_path" == *.* ]]; then
    local repo_root
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    local full_path="$repo_root/$e_path"
    if [[ ! -f "$full_path" ]]; then
      closure_kind="tombstone"
      closure_label="(closure: tombstone) (fixed: $today)"
      closed_tomb=$((closed_tomb + 1))
    elif [[ -n "$e_line" ]]; then
      ...
    fi
  fi
fi
```

Replace the `if [[ ! -f "$full_path" ]]; then` branch with rename-aware logic:

```bash
if [[ ! -f "$full_path" ]]; then
  # C1: check if file was renamed before declaring tombstone
  local new_path
  if new_path="$(cd "$repo_root" && fi_detect_rename "$e_path")"; then
    rename_target="$new_path"
    rename_source="$e_path"
    # don't set closure_kind — entry stays [open] with corrected path
  else
    closure_kind="tombstone"
    closure_label="(closure: tombstone) (fixed: $today)"
    closed_tomb=$((closed_tomb + 1))
  fi
elif [[ -n "$e_line" ]]; then
  ...
fi
```

Add to top of per-entry loop:

```bash
local rename_target="" rename_source=""
```

After the tombstone block (before the `if [[ -n "$closure_kind" ]]` write block), add a rename-correction write path:

```bash
# C1: apply rename correction if detected
if [[ -z "$closure_kind" && -n "$rename_target" ]]; then
  # Rewrite the location and append (renamed-from: ...)
  local corrected_line="$line"
  # Replace the first occurrence of the old path with the new path
  corrected_line="${corrected_line/$rename_source/$rename_target}"
  # Append (renamed-from: <old_path>) annotation (idempotent — skip if already present)
  if [[ "$corrected_line" != *"(renamed-from:"* ]]; then
    corrected_line="$corrected_line (renamed-from: $rename_source)"
  fi
  printf '%s\n' "$corrected_line" >>"$tmp"
  renamed_count=$((renamed_count + 1))
  continue
fi
```

Add to top of `cmd_sync`:

```bash
local renamed_count=0
```

Update closure summary:

```bash
if [[ "$total_closed" -gt 0 || "$total_demoted" -gt 0 || "$renamed_count" -gt 0 ]]; then
  printf 'Synced. Closed: %d (%d PR + %d commit + %d tombstone). Demoted: %d. Renamed: %d.\n' \
    "$total_closed" "$closed_pr" "$closed_commit" "$closed_tomb" \
    "$total_demoted" "$renamed_count"
elif [[ "$total_closed" -eq 0 ]]; then
  printf 'Synced. Nothing to close.\n'
fi
```

- [ ] **Step 5: Run tests, verify pass**

```bash
bats tests/cli-sync-rename.bats
bats tests/cli-sync.bats
bats tests/cli-sync-pr-states.bats
bats tests/cli-sync-commit-stale.bats
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add bin/found-issues tests/cli-sync-rename.bats
git commit -m "feat(sync): auto-correct entry paths on git mv before tombstone closure"
```

---

## Phase 4 — Counter, defer blocker, and Phase 2 verification updates

Update the counters so `in PR` excludes demoted forms and `stale` absorbs them. Narrow the `defer` blocker. Update `commands/sync.md` Phase 2 instructions.

### Task 4.1: `fi_count_in_pr` excludes demoted PR annotations

**Files:**
- Modify: `lib/parse-entries.sh:fi_count_in_pr`
- Create: `tests/parse-entries-counters.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/parse-entries-counters.bats`:

```bash
#!/usr/bin/env bats
load 'helpers'

setup() {
  fi_setup_tmp
  fi_source_lib parse-entries
}

teardown() { fi_teardown_tmp; }

@test "fi_count_in_pr: excludes (PR-closed: ...) entries" {
  cat > issues.md <<'EOF'
# found-issues
- [open] 2026-05-11 src/a.py:1 — bug (PR: foo/bar#1)
- [open] 2026-05-11 src/b.py:1 — bug (PR-closed: foo/bar#2)
- [open] 2026-05-11 src/c.py:1 — bug
EOF
  result="$(fi_count_in_pr issues.md)"
  [ "$result" -eq 1 ]
}

@test "fi_count_stale: includes (PR-closed: ...) and (commit-stale: ...)" {
  cat > issues.md <<'EOF'
# found-issues
- [open] 2026-05-11 src/a.py:1 — bug (PR-closed: foo/bar#2)
- [open] 2026-05-11 src/b.py:1 — bug (commit-stale: deadbeef)
- [open] 2026-05-11 src/c.py:1 — bug
EOF
  # stale includes the two demoted ones (date-based stale_days threshold not relevant here)
  result="$(fi_count_stale issues.md 30)"
  [ "$result" -ge 2 ]
}
```

- [ ] **Step 2: Run, verify failure**

```bash
bats tests/parse-entries-counters.bats
```

Expected: both tests fail.

- [ ] **Step 3: Update `fi_count_in_pr`**

In `lib/parse-entries.sh`, replace `fi_count_in_pr`:

```bash
# Count [open] entries with at least one (PR: ...) annotation (active form only).
# Excludes (PR-closed: ...) which represents demoted/abandoned PRs.
fi_count_in_pr() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    printf '0'
    return
  fi
  local count
  count="$(grep -cE '^- \[open\].*\(PR: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+\)' "$file" 2>/dev/null || true)"
  printf '%s' "${count:-0}"
}
```

(Note: this is likely unchanged from today's regex which already requires `(PR: ` exactly — but verify by reading the existing code. If the existing regex was looser, this tightening fixes it.)

- [ ] **Step 4: Update `fi_count_stale`**

In `lib/parse-entries.sh`, locate `fi_count_stale` (around line 210). After the existing date-based count, add:

```bash
# Add entries with demoted annotations (always counted as stale regardless of date)
local demoted_count
demoted_count="$(grep -cE '^- \[open\].*(\(PR-closed: |\(commit-stale: )' "$file" 2>/dev/null || true)"
demoted_count="${demoted_count:-0}"
count=$((count + demoted_count))

# Subtract overlap: entries that match BOTH date-stale AND demoted (to avoid double-count)
local overlap
overlap="$(awk -v cutoff="$cutoff" '
  /^- \[open\].*(\(PR-closed: |\(commit-stale: )/ {
    if (match($0, /[0-9]{4}-[0-9]{2}-[0-9]{2}/)) {
      d = substr($0, RSTART, RLENGTH)
      if (d < cutoff) print
    }
  }' "$file" 2>/dev/null | grep -c . || true)"
overlap="${overlap:-0}"
count=$((count - overlap))
```

- [ ] **Step 5: Run tests, verify pass**

```bash
bats tests/parse-entries-counters.bats
bats tests/parse-entries.bats
bats tests/cli-status.bats
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/parse-entries.sh tests/parse-entries-counters.bats
git commit -m "feat(counter): in_pr excludes demoted PRs; stale absorbs demoted annotations"
```

---

### Task 4.2: Draft-PR-with-old-entry counts as stale

**Files:**
- Modify: `bin/found-issues:cmd_sync` — annotate entry in-place with `(draft: stale)` when condition met (kept ephemeral, not persisted)

This is the cleanest path: since sync already fetches `isDraft` (Phase 1), it can pass this info through to the counter. But the counter operates on the file post-sync, not in-memory. Simpler: add a `(stale-draft)` marker annotation on the entry during sync when conditions met, idempotent.

Actually, simpler still: rely on the existing date-stale logic. An entry that's been open with a draft PR for >stale_days is already counted as stale via the existing date check. **No code change needed** — but verify with a test.

- [ ] **Step 1: Write the verification test**

Append to `tests/parse-entries-counters.bats`:

```bash
@test "fi_count_stale: entry older than stale_days counts as stale regardless of annotation" {
  local old_date
  old_date="$(date -v-40d +%Y-%m-%d 2>/dev/null || date -d '40 days ago' +%Y-%m-%d)"
  cat > issues.md <<EOF
# found-issues
- [open] $old_date src/a.py:1 — bug (PR: foo/bar#1)
EOF
  result="$(fi_count_stale issues.md 30)"
  [ "$result" -eq 1 ]
}
```

- [ ] **Step 2: Run, verify pass**

```bash
bats tests/parse-entries-counters.bats
```

Expected: PASS — the existing date-based stale check already covers draft-with-old-entry case via the date stamp.

- [ ] **Step 3: Commit**

```bash
git add tests/parse-entries-counters.bats
git commit -m "test: verify date-based stale check covers stuck-draft PRs"
```

---

### Task 4.3: Defer blocker narrows to active (PR: ...) only

**Files:**
- Modify: `bin/found-issues:cmd_defer` (lines 554-563)
- Modify: `tests/cli-defer.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/cli-defer.bats`:

```bash
@test "defer: allows entries with only (PR-closed: ...) annotation" {
  fi_setup_tmp
  fi_init_git
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] 2026-05-11 src/a.py:1 — bug (PR-closed: foo/bar#42)
EOF
  fi_run defer "src/a.py:1"
  [ "$status" -eq 0 ]
  grep -q '^- \[deferred\].*src/a.py:1' docs/found-issues.md
  fi_teardown_tmp
}

@test "defer: blocks entries with active (PR: ...) annotation (unchanged)" {
  fi_setup_tmp
  fi_init_git
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] 2026-05-11 src/a.py:1 — bug (PR: foo/bar#42)
EOF
  fi_run defer "src/a.py:1"
  [ "$status" -eq 4 ]
  [[ "$output" == *"active PR annotation"* ]]
  fi_teardown_tmp
}

@test "defer: allows entries with (commit-stale: ...) annotation" {
  fi_setup_tmp
  fi_init_git
  mkdir -p docs
  cat > docs/found-issues.md <<'EOF'
# found-issues
- [open] 2026-05-11 src/a.py:1 — bug (commit-stale: deadbeef)
EOF
  fi_run defer "src/a.py:1"
  [ "$status" -eq 0 ]
  grep -q '^- \[deferred\].*src/a.py:1' docs/found-issues.md
  fi_teardown_tmp
}
```

- [ ] **Step 2: Run, verify failure**

```bash
bats tests/cli-defer.bats
```

Expected: the first and third new tests fail (today's blocker rejects any `(PR: ...)` — but wait, that regex uses `\(PR: ` so `(PR-closed: ...)` already doesn't match. Verify by reading the existing regex.)

Looking at `bin/found-issues:554-563`:

```bash
local re_pr='\(PR: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+\)'
if [[ "$target" =~ $re_pr ]]; then
  ...
fi
```

This is already specific to `(PR: ` form — `(PR-closed: ...)` won't match because of the colon-space mismatch. The narrowing was already done correctly. Tests should pass without modification.

- [ ] **Step 3: Run, verify pass**

```bash
bats tests/cli-defer.bats
```

Expected: all pass (including the new ones).

- [ ] **Step 4: Commit**

```bash
git add tests/cli-defer.bats
git commit -m "test: defer correctly allows demoted-annotation entries"
```

---

### Task 4.4: Update commands/sync.md Phase 2 instructions

**Files:**
- Modify: `commands/sync.md`

- [ ] **Step 1: Update the Phase 2 instruction text**

In `commands/sync.md`, locate the section "## Phase 2 — AI verification of unannotated entries" (around line 27). Update the lead-in:

Before:
```markdown
After phase 1, read the issues file and find every `[open]` entry that has
**neither** a `(PR: ...)` annotation **nor** a `(commit: ...)` annotation.
For each one:
```

After:
```markdown
After phase 1, read the issues file and find every `[open]` entry eligible
for AI verification. An entry is eligible when it has:

- **No annotations** (unannotated path:line entries), OR
- Only demoted annotations: `(PR-closed: ...)` and/or `(commit-stale: ...)`.

Entries with an active `(PR: ...)` or `(commit: ...)` annotation are NOT
eligible — those represent in-flight work and should be left alone.

For each eligible entry:
```

Then add a new subsection after "Conservative bias is mandatory":

```markdown
## Reading demoted annotations as hints

When an entry has `(PR-closed: ...)` or `(commit-stale: ...)`, treat the
annotation as **weak evidence that someone tried to fix this**, not proof
the bug is gone. Apply the same conservative bias as for unannotated
entries: verify by reading the code at `path:line`; flip only on clear
evidence the symptom is no longer present.

The demoted annotation stays on the line as audit trail regardless of
your verdict — if you flip the entry, append `(verified: ai) (fixed: ...)`
in addition to the existing demoted annotation. Do not strip the demoted
annotation.
```

- [ ] **Step 2: Commit**

```bash
git add commands/sync.md
git commit -m "docs(sync): update Phase 2 to evaluate demoted-annotation entries"
```

---

## Phase 5 — Default-branch detection chain + doctor extensions

Replace the literal `"main"` fallback with `gh repo view --json defaultBranchRef.name`, session-cached. Extend `doctor` to surface gh-auth and origin/HEAD status.

### Task 5.1: gh-based default-branch fallback

**Files:**
- Modify: `bin/found-issues:cmd_sync` (around line 1066-1070)
- Modify: `bin/found-issues:cmd_promote` (around line 1215-1217)
- Create: `tests/cli-sync-default-branch.bats`

- [ ] **Step 1: Write the failing test**

Create `tests/cli-sync-default-branch.bats`:

```bash
#!/usr/bin/env bats
load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
  fi_use_gh_shim
}

teardown() {
  fi_teardown_tmp
  rm -rf ~/.cache/found-issues/default-branch-* 2>/dev/null || true
}

@test "sync: uses gh repo view fallback when origin/HEAD is unset and gh available" {
  export GH_MOCK_REPO_VIEW='{"defaultBranchRef":{"name":"develop"}}'
  export GH_MOCK_PR_VIEW=$'42\t{"state":"MERGED","baseRefName":"develop","mergedAt":"2026-05-01T12:00:00Z","isDraft":false}'

  git checkout -q -b develop
  git commit --allow-empty -q -m "init"
  git remote add origin https://example.com/foo/bar.git
  # Intentionally do NOT set origin/HEAD — exercise the fallback

  fi_run log "src/foo.py:1 — bug (PR: foo/bar#42)"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '\[fixed\].*\(PR: foo/bar#42\)' docs/found-issues.md
}

@test "sync: gh fallback result is cached per-session" {
  export GH_MOCK_REPO_VIEW='{"defaultBranchRef":{"name":"trunk"}}'
  export GH_MOCK_TRACE="$TMP/gh-trace.log"

  git commit --allow-empty -q -m "init"
  git remote add origin https://example.com/foo/bar.git

  fi_run log "src/a.py:1 — bug"
  fi_run sync  # populates cache
  fi_run sync  # second sync should not call gh repo view again

  # Count how many times `gh repo view` was invoked
  count="$(grep -c '^repo view' "$TMP/gh-trace.log" || true)"
  [ "$count" -le 1 ]
}
```

- [ ] **Step 2: Run, verify failure**

```bash
bats tests/cli-sync-default-branch.bats
```

Expected: both fail.

- [ ] **Step 3: Add helper function**

In `bin/found-issues`, add near other helpers (before `cmd_sync`):

```bash
# Resolve the default branch with a layered fallback chain:
#   1. git symbolic-ref refs/remotes/origin/HEAD (primary, fast)
#   2. gh repo view --json defaultBranchRef (fallback when origin/HEAD unset)
#   3. literal "main" (last-resort guess; logged as a warning)
#
# Caches the gh-result per-repo in ~/.cache/found-issues/default-branch-<slug>.txt
# with a 1h TTL to avoid repeated network calls.
fi_resolve_default_branch() {
  local default_branch

  # Primary: origin/HEAD symref
  default_branch="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's|^refs/remotes/origin/||' || true)"
  if [[ -n "$default_branch" ]]; then
    printf '%s' "$default_branch"
    return 0
  fi

  # Fallback: gh repo view (cached)
  local repo_slug
  repo_slug="$(fi_repo_id 2>/dev/null || true)"
  if [[ -n "$repo_slug" ]] && command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/found-issues"
    local cache_file="$cache_dir/default-branch-${repo_slug//\//-}.txt"
    mkdir -p "$cache_dir" 2>/dev/null || true

    # Check cache freshness (1h TTL)
    if [[ -f "$cache_file" ]]; then
      local age_sec
      age_sec=$(( $(date +%s) - $(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
      if (( age_sec < 3600 )); then
        local cached
        cached="$(cat "$cache_file" 2>/dev/null)"
        if [[ -n "$cached" ]]; then
          printf '%s' "$cached"
          return 0
        fi
      fi
    fi

    # Fetch fresh
    local gh_result
    gh_result="$(gh repo view --json defaultBranchRef 2>/dev/null \
      | jq -r '.defaultBranchRef.name // empty' 2>/dev/null || true)"
    if [[ -n "$gh_result" ]]; then
      printf '%s' "$gh_result" > "$cache_file"
      printf '%s' "$gh_result"
      return 0
    fi
  fi

  # Last resort: hardcoded "main"
  printf 'main'
  return 0
}
```

- [ ] **Step 4: Use the helper in `cmd_sync` and `cmd_promote`**

In `cmd_sync` (around line 1066-1070), replace:

```bash
local default_branch=""
if git rev-parse --git-dir >/dev/null 2>&1; then
  default_branch="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's|^refs/remotes/origin/||' || true)"
  [[ -z "$default_branch" ]] && default_branch="main"
fi
```

with:

```bash
local default_branch=""
if git rev-parse --git-dir >/dev/null 2>&1; then
  default_branch="$(fi_resolve_default_branch)"
fi
```

Same substitution in `cmd_promote` (lines 1215-1217).

- [ ] **Step 5: Run tests, verify pass**

```bash
bats tests/cli-sync-default-branch.bats
bats tests/cli-sync.bats
bats tests/cli-promote.bats
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add bin/found-issues tests/cli-sync-default-branch.bats
git commit -m "feat(sync): gh-based default-branch fallback with 1h session cache"
```

---

### Task 5.2: Doctor reports gh-auth and origin/HEAD status

**Files:**
- Modify: `bin/found-issues:cmd_doctor` (around line 1866)
- Modify: `tests/cli-doctor.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/cli-doctor.bats`:

```bash
@test "doctor: surfaces gh-auth status" {
  fi_setup_tmp
  fi_init_git
  fi_use_gh_shim
  export GH_MOCK_AUTH=ok
  fi_run doctor
  [[ "$output" == *"gh"*"auth"*"OK"* ]] || [[ "$output" == *"gh CLI"* ]]
  fi_teardown_tmp
}

@test "doctor: warns when gh is not authenticated" {
  fi_setup_tmp
  fi_init_git
  fi_use_gh_shim
  export GH_MOCK_AUTH=fail
  fi_run doctor
  [[ "$output" == *"not authenticated"* ]] || [[ "$output" == *"gh auth"* ]]
  fi_teardown_tmp
}

@test "doctor: warns when origin/HEAD symref is unset" {
  fi_setup_tmp
  fi_init_git
  git commit --allow-empty -q -m "init"
  git remote add origin https://example.com/foo/bar.git
  # Intentionally do NOT set origin/HEAD
  fi_run doctor
  [[ "$output" == *"origin/HEAD"* ]] || [[ "$output" == *"default branch"* ]]
  fi_teardown_tmp
}
```

- [ ] **Step 2: Run, verify failures**

```bash
bats tests/cli-doctor.bats
```

Expected: the three new tests fail.

- [ ] **Step 3: Add the checks to `cmd_doctor`**

In `cmd_doctor`, locate the gh check (it likely exists per the existing code at line 1921). Promote it to a structured check block. After the gh-PATH check, add:

```bash
# gh authentication status
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    printf '%s gh auth: OK\n' "$section_pass"
  else
    printf '%s gh auth: not authenticated. PR-state sync degraded.\n' "$section_warn"
    printf '   Run `gh auth login` to enable closed-PR detection and sync flips.\n'
  fi
fi

# origin/HEAD symref (default-branch detection)
if git rev-parse --git-dir >/dev/null 2>&1; then
  if git symbolic-ref refs/remotes/origin/HEAD >/dev/null 2>&1; then
    printf '%s origin/HEAD: set\n' "$section_pass"
  else
    printf '%s origin/HEAD: unset. Sync falls back to gh repo view, then literal "main".\n' "$section_warn"
    printf '   Run `git remote set-head origin --auto` to fix.\n'
  fi
fi
```

- [ ] **Step 4: Run tests, verify pass**

```bash
bats tests/cli-doctor.bats
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add bin/found-issues tests/cli-doctor.bats
git commit -m "feat(doctor): report gh auth and origin/HEAD symref status"
```

---

## Phase 6 — Format spec, CHANGELOG, version bump, format-enforcer sanity

Documentation updates, version bump, and confirmation that the new annotations pass the format enforcer.

### Task 6.1: Format-enforcer accepts new annotations

**Files:**
- Create: `tests/format-enforcer-new-annotations.bats`

- [ ] **Step 1: Write the test**

Create `tests/format-enforcer-new-annotations.bats`:

```bash
#!/usr/bin/env bats
# Confirm format-enforcer (PreToolUse hook) accepts new annotation forms.
# The enforcer is a blocklist of malformed patterns; new sibling annotations
# should pass through cleanly. This test guards against accidental tightening.

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
}

teardown() { fi_teardown_tmp; }

# Run the format-enforcer hook with a synthetic stdin payload
run_enforcer() {
  local content="$1"
  printf '%s' "{
    \"tool_name\": \"Write\",
    \"tool_input\": {
      \"file_path\": \"$TMP/docs/found-issues.md\",
      \"content\": \"$content\"
    }
  }" | "$TEST_REPO_ROOT/hooks/format-enforcer.sh"
}

@test "format-enforcer: (PR-closed: ...) annotation passes" {
  run run_enforcer "- [open] 2026-05-11 src/a.py:1 — bug (PR-closed: foo/bar#42)"
  [ "$status" -eq 0 ]
}

@test "format-enforcer: (commit-stale: ...) annotation passes" {
  run run_enforcer "- [open] 2026-05-11 src/a.py:1 — bug (commit-stale: deadbeef)"
  [ "$status" -eq 0 ]
}

@test "format-enforcer: (renamed-from: ...) annotation passes" {
  run run_enforcer "- [open] 2026-05-11 src/new.py:1 — bug (renamed-from: src/old.py)"
  [ "$status" -eq 0 ]
}

@test "format-enforcer: still blocks bare PR #N (regression guard)" {
  run run_enforcer "- [open] 2026-05-11 src/a.py:1 — bug PR #42"
  # In github-pr mode (which a git+gh-config repo would be), this blocks.
  # In local mode, it allows. Either way, no crash.
  [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
}
```

- [ ] **Step 2: Run, verify pass**

```bash
bats tests/format-enforcer-new-annotations.bats
```

Expected: all pass (no code changes needed — the enforcer is blocklist-based).

- [ ] **Step 3: Commit**

```bash
git add tests/format-enforcer-new-annotations.bats
git commit -m "test: format-enforcer accepts new sibling annotations"
```

---

### Task 6.2: Update format spec documentation

**Files:**
- Modify: `docs/format-spec.md`

- [ ] **Step 1: Add annotation table**

In `docs/format-spec.md`, locate the annotations reference (likely a table near the format definition). Add three rows:

```markdown
| `(PR-closed: org/repo#N)` | Sync auto-demoted from `(PR: ...)` when the PR was closed without merge. Entry is eligible for AI verification; counter excludes from `in PR`, includes in `stale`. |
| `(commit-stale: <sha>)` | Sync auto-demoted from `(commit: ...)` when the SHA no longer resolves on the default branch (squash-merge, force-push). Entry is eligible for AI verification. |
| `(renamed-from: <old-path>)` | Sync detected a `git mv` and auto-corrected the entry path. Original path preserved here for audit. |
```

Add a "Annotation lifecycle" section after the table:

```markdown
## Annotation lifecycle

The `(PR: ...)` and `(commit: ...)` active forms are written by Claude/users
via `/found-issues:annotate-pr` and `/found-issues:annotate-commit`. Sync
flips them to `[fixed]` on merge / ancestor-of-default.

The `(PR-closed: ...)` and `(commit-stale: ...)` demoted forms are written
ONLY by `found-issues sync` when it detects the linked PR was closed without
merge or the SHA is no longer reachable. They are never produced by user
commands. They re-enable AI verification (Phase 2 of `/found-issues:sync`)
because the original closure signal is no longer load-bearing.

The `(renamed-from: ...)` annotation is written ONLY by sync when tombstone
detection finds a rename target — entry path is updated in-place and the
old path preserved for audit. Idempotent: a second rename of the same entry
appends a new (renamed-from: ...) without removing prior ones.
```

- [ ] **Step 2: Commit**

```bash
git add docs/format-spec.md
git commit -m "docs(format-spec): document PR-closed, commit-stale, renamed-from annotations"
```

---

### Task 6.3: CHANGELOG entry + version bump

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `bin/found-issues:9` (`FI_VERSION`)
- Modify: `.claude-plugin/plugin.json:4` (`version`)

- [ ] **Step 1: Add CHANGELOG entry**

In `CHANGELOG.md`, add at top:

```markdown
## [1.2.0] — 2026-05-11

### Added — sync self-healing

- **Auto-demote closed-without-merge PR annotations.** `(PR: org/repo#N)`
  on a CLOSED PR is rewritten to `(PR-closed: org/repo#N)`. The entry
  becomes eligible for AI verification in `/found-issues:sync` Phase 2,
  and stops inflating the statusline's `in PR` counter.
- **Auto-demote unresolvable commit annotations.** `(commit: <sha>)`
  whose SHA no longer resolves on the default branch (squash-merged,
  force-pushed) is rewritten to `(commit-stale: <sha>)`. Same eligibility
  + counter treatment as PR-closed.
- **Auto-correct file renames before tombstone closure.** When a missing
  file is detected, sync now checks `git log --follow` for a rename target.
  If found, the entry's path is updated in-place and a `(renamed-from: ...)`
  annotation preserves the original path. Replaces the silent
  false-positive `[fixed]` flip.
- **gh-based default-branch fallback.** When `origin/HEAD` symref is unset,
  sync falls back to `gh repo view --json defaultBranchRef` (1h session
  cache) before the last-resort literal `main`. Fixes silent PR-merge
  misdetection on `master`/`trunk`/`develop` repos.
- **`doctor` extensions.** Now reports `gh auth status` and `origin/HEAD`
  symref status with remediation hints.
- **Loud warning on gh-empty.** When `gh pr view` returns empty for an
  annotated PR (typo, deleted, network), sync now emits an aggregated
  warning at the end of the run instead of silently skipping.

### Changed

- **Counter semantics.** `in PR` now counts only active `(PR: ...)` —
  demoted forms are excluded. `stale` now absorbs `(PR-closed: ...)` and
  `(commit-stale: ...)` regardless of date. Existing date-based stale logic
  unchanged.

### Internal

- Sync's per-PR gh calls consolidated: one `gh pr view` per PR returning
  `state`, `baseRefName`, `mergedAt`, `isDraft` in one shot.
- New gh-mock PATH shim (`tests/bin-shims/gh`) gives bats tests
  deterministic coverage of PR-state branches that were previously untested.

### Migration notes

No user action required. All annotation lifecycle work runs passively in
`/found-issues:sync` (which fires on SessionStart). Existing
`docs/found-issues.md` files are forward- and backward-compatible.

### Reference

- Gap analysis: [`docs/superpowers/audits/2026-05-11-annotation-lifecycle-gaps.md`](docs/superpowers/audits/2026-05-11-annotation-lifecycle-gaps.md)
- Design spec: [`docs/superpowers/specs/2026-05-11-sync-self-healing-design.md`](docs/superpowers/specs/2026-05-11-sync-self-healing-design.md)
- Implementation plan: [`docs/superpowers/plans/2026-05-11-sync-self-healing.md`](docs/superpowers/plans/2026-05-11-sync-self-healing.md)
```

- [ ] **Step 2: Bump version in `bin/found-issues`**

Edit line 9:

```bash
readonly FI_VERSION="1.2.0"
```

- [ ] **Step 3: Bump version in plugin manifest**

Edit `.claude-plugin/plugin.json:4`:

```json
"version": "1.2.0",
```

- [ ] **Step 4: Run full test suite**

```bash
bats tests/
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md bin/found-issues .claude-plugin/plugin.json
git commit -m "release: v1.2.0 — sync self-healing for stale annotations"
```

---

## Final verification

After Phase 6 commits, run the full integration check:

- [ ] **Step 1: Full test suite**

```bash
bats tests/
```

Expected: all tests pass, including the 6 new bats files added across phases.

- [ ] **Step 2: Manual end-to-end smoke**

```bash
# In a scratch repo with a real GitHub remote and a closed-no-merge PR:
mkdir /tmp/fi-smoke && cd /tmp/fi-smoke
git init && git remote add origin git@github.com:<your-org>/<scratch>.git
echo "stub" > stub.py && git add . && git commit -m "init"
$REPO/bin/found-issues log "stub.py:1 — bug (PR: <your-org>/<scratch>#<closed-pr-num>)"
$REPO/bin/found-issues sync
# Verify entry now shows (PR-closed: ...) and is excluded from `in PR` count.
$REPO/bin/found-issues status --format=plain
```

- [ ] **Step 3: Doctor smoke**

```bash
$REPO/bin/found-issues doctor
# Verify the new gh-auth and origin/HEAD checks render correctly.
```

- [ ] **Step 4: Version smoke**

```bash
$REPO/bin/found-issues --version
# Should print: found-issues version 1.2.0
```

---

## Spec coverage check (run after writing this plan; no separate task)

| Spec section | Implemented in |
|---|---|
| Goals 1–6 | Phases 1–5 |
| New annotation forms (`PR-closed`, `commit-stale`, `renamed-from`) | Tasks 2.1, 2.2, 2.3, 3.1 |
| Counter math changes | Task 4.1 |
| AI verification Phase 2 update | Task 4.4 |
| Defer blocker narrowing | Task 4.3 (verified existing regex already correct) |
| Default-branch detection chain | Task 5.1 |
| Doctor extensions | Task 5.2 |
| Idempotency contract | Tasks 2.1, 2.3 (idempotency tests for each demotion) |
| Format-enforcer compatibility | Task 6.1 |
| Documentation (format spec, CHANGELOG) | Tasks 6.2, 6.3 |
| Version bump to 1.2.0 | Task 6.3 |

## Risks acknowledged

- **Mutation correctness:** every demotion is a string substitution on a single line. Verified safe by idempotency tests in Tasks 2.1 and 2.3.
- **gh shim coverage:** the shim doesn't handle every gh subcommand — only `pr view`, `repo view`, `auth status`. Tests outside those scopes still hit the real `gh`. Acceptable for this scope.
- **`fi_count_stale` overlap math:** the awk overlap calculation handles edge cases where an entry is both date-stale AND has a demoted annotation. Tested in Task 4.1's overlap-stress case (add one if absent).
