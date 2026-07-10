# /found-issues:fix Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship v1.7.0: a `/found-issues:fix` slash command that verifies, triages, gates, fixes, and ships the repo's `[open]` ledger entries, plus the `found-issues list --json` CLI subcommand it consumes.

**Architecture:** Judgment lives in `commands/fix.md` (a prompt-procedure, like `sync.md`); mechanics live in the bash CLI. One new subcommand (`cmd_list`) built entirely on the existing conflict-aware parse layer (`lib/parse-entries.sh`), extended with JSON emission helpers and an optional numbered mode. No new hooks, no new dependencies.

**Tech Stack:** bash (CLI must run on bash 3.2 — macOS CI), bats (tests), markdown command docs with YAML frontmatter.

**Spec:** `docs/superpowers/specs/2026-07-10-fix-command-design.md` (approved 2026-07-10).

## Global Constraints

- bash 3.2 compatible: no associative arrays, no `${var,,}`; guard empty-array expansion under `set -u` (macOS CI runs /bin/bash 3.2.57).
- ASCII-only `@test` names (CI guard fails the build on non-ASCII; em-dashes in test names break Git Bash).
- No new runtime dependencies in `bin/found-issues` — jq is allowed in `hooks/` only. JSON is emitted via hand-rolled escaping.
- Test fixtures use dynamic dates (`$(date +%Y-%m-%d)`) — hardcoded dates rot past the 30-day stale threshold and break the suite.
- Never widen the parse layer's public behavior: `fi_entries file filter` (2-arg form) must behave byte-identically after this work — statusline contract snapshots depend on it.
- Branch: all work on `feat/fix-command` (already exists, tracks origin). PR to `main`; never push main directly.
- Version: v1.7.0. `.claude-plugin/plugin.json` `"version"` and the newest `CHANGELOG.md` heading must agree (version-check CI job).
- Run tests with `bats tests/` from the repo root; the full suite must be green before the PR (~490 tests).

---

### Task 1: JSON emission helpers in the parse layer

**Files:**
- Modify: `lib/parse-entries.sh` (append after `fi_extract_mute_until`, ~line 430)
- Modify: `lib/parse-entries.sh:202-` (`fi_entries` — add optional numbered mode)
- Test: `tests/parse-entries.bats` (append)

**Interfaces:**
- Produces: `fi_json_escape <string>` → stdout: string with `\` `"` TAB escaped, CR stripped.
- Produces: `fi_json_str <string>` → stdout: `"escaped"` or `null` when empty.
- Produces: `fi_entry_to_json <line_no> <raw_entry_line>` → stdout: one-line JSON object with keys `line_no` (number), `status`, `critical` (bool), `date`, `path`, `line` (number|null), `symptom`, `suggested`, `prs`, `prs_closed`, `commits`, `commits_stale`, `verified`, `fixed_date`, `renamed_from`, `mute_until`, `raw` (strings; `null` when empty). Returns 1 (empty stdout) if the line is not a parseable entry.
- Produces: `fi_entries <file> <filter> numbered` → same lines as the 2-arg form but each prefixed `<file_line_no>:`. 2-arg behavior unchanged.

- [ ] **Step 1: Write the failing tests**

Append to `tests/parse-entries.bats`:

```bash
@test "fi_json_escape escapes backslash quote and tab, strips CR" {
  run fi_json_escape "$(printf 'a\\b "c"\td\r')"
  [ "$status" -eq 0 ]
  [ "$output" = 'a\\b \"c\"\td' ]
}

@test "fi_json_str emits null for empty and quoted string otherwise" {
  run fi_json_str ""
  [ "$output" = "null" ]
  run fi_json_str 'say "hi"'
  [ "$output" = '"say \"hi\""' ]
}

@test "fi_entry_to_json emits full object for a rich entry" {
  TODAY="$(date +%Y-%m-%d)"
  line="- [open] [!] $TODAY src/app.sh:42 — bad thing happens (suggested: do the fix) (PR: org/repo#7)"
  run fi_entry_to_json 5 "$line"
  [ "$status" -eq 0 ]
  [[ "$output" == '{"line_no":5,"status":"open","critical":true,'* ]]
  [[ "$output" == *'"path":"src/app.sh"'* ]]
  [[ "$output" == *'"line":42'* ]]
  [[ "$output" == *'"symptom":"bad thing happens"'* ]]
  [[ "$output" == *'"suggested":"do the fix"'* ]]
  [[ "$output" == *'"prs":"org/repo#7"'* ]]
  [[ "$output" == *'"raw":"- [open] [!]'* ]]
}

@test "fi_entry_to_json emits nulls for absent fields and mute_until when present" {
  TODAY="$(date +%Y-%m-%d)"
  line="- [deferred] $TODAY topic:with:colons — parked thing (mute-until: 2099-01-01)"
  run fi_entry_to_json 9 "$line"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"critical":false'* ]]
  [[ "$output" == *'"path":null'* ]]
  [[ "$output" == *'"line":null'* ]]
  [[ "$output" == *'"suggested":null'* ]]
  [[ "$output" == *'"mute_until":"2099-01-01"'* ]]
}

@test "fi_entry_to_json returns 1 on a non-entry line" {
  run fi_entry_to_json 1 "# found-issues"
  [ "$status" -eq 1 ]
}

@test "fi_entries numbered mode prefixes file line numbers and stays conflict-aware" {
  TODAY="$(date +%Y-%m-%d)"
  cat > issues.md <<EOF
# header

- [open] $TODAY a.sh:1 — first
<<<<<<< HEAD
- [open] $TODAY b.sh:2 — conflicted ours
=======
- [open] $TODAY c.sh:3 — conflicted theirs
>>>>>>> branch
- [open] $TODAY d.sh:4 — last
EOF
  run fi_entries issues.md open numbered
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "3:- [open] $TODAY a.sh:1 — first" ]]
  [[ "${lines[1]}" == "9:- [open] $TODAY d.sh:4 — last" ]]
}

@test "fi_entries two-arg form is unchanged by numbered mode addition" {
  TODAY="$(date +%Y-%m-%d)"
  printf -- '- [open] %s a.sh:1 — thing\n' "$TODAY" > issues.md
  run fi_entries issues.md open
  [ "$output" = "- [open] $TODAY a.sh:1 — thing" ]
}
```

Note: em-dashes are fine INSIDE test bodies/fixtures; only `@test` names must stay ASCII.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/parse-entries.bats`
Expected: the 7 new tests FAIL (`fi_json_escape: command not found`, numbered-mode line-count mismatch); all pre-existing tests PASS.

- [ ] **Step 3: Implement the helpers**

In `lib/parse-entries.sh`, append after `fi_is_muted` (~line 430):

```bash
# --- JSON emission (consumed by `found-issues list --json`) ---------------
# Hand-rolled: bin/found-issues has no jq dependency (hooks may use jq;
# the CLI must run on a bare Git Bash / macOS bash 3.2).

# Escape a string for embedding in a JSON string literal.
fi_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/}"
  printf '%s' "$s"
}

# Emit a JSON string literal, or null for the empty string.
fi_json_str() {
  local s="$1"
  if [[ -z "$s" ]]; then
    printf 'null'
  else
    printf '"%s"' "$(fi_json_escape "$s")"
  fi
}

# Emit one entry as a single-line JSON object.
# $1 = file line number, $2 = raw entry line. Returns 1 if unparseable.
fi_entry_to_json() {
  local line_no="$1" raw="$2"
  local parsed
  parsed="$(fi_parse_entry "$raw")" || return 1

  local status="" critical="" date="" path="" line="" symptom="" fix=""
  local prs="" prs_closed="" commits="" commits_stale="" renamed_from=""
  local fixed_date="" verified=""
  local kv key val
  while IFS= read -r kv; do
    key="${kv%%=*}"
    val="${kv#*=}"
    case "$key" in
      status)        status="$val" ;;
      critical)      critical="$val" ;;
      date)          date="$val" ;;
      path)          path="$val" ;;
      line)          line="$val" ;;
      symptom)       symptom="$val" ;;
      fix)           fix="$val" ;;
      prs)           prs="$val" ;;
      prs_closed)    prs_closed="$val" ;;
      commits)       commits="$val" ;;
      commits_stale) commits_stale="$val" ;;
      renamed_from)  renamed_from="$val" ;;
      fixed_date)    fixed_date="$val" ;;
      verified)      verified="$val" ;;
    esac
  done <<< "$parsed"

  local crit_bool="false"
  [[ "$critical" == "yes" ]] && crit_bool="true"
  local line_json="null"
  [[ -n "$line" ]] && line_json="$line"
  local mute
  mute="$(fi_extract_mute_until "$raw")"

  printf '{"line_no":%s,"status":"%s","critical":%s,"date":%s,"path":%s,"line":%s,"symptom":%s,"suggested":%s,"prs":%s,"prs_closed":%s,"commits":%s,"commits_stale":%s,"verified":%s,"fixed_date":%s,"renamed_from":%s,"mute_until":%s,"raw":%s}' \
    "$line_no" "$status" "$crit_bool" \
    "$(fi_json_str "$date")" "$(fi_json_str "$path")" "$line_json" \
    "$(fi_json_str "$symptom")" "$(fi_json_str "$fix")" \
    "$(fi_json_str "$prs")" "$(fi_json_str "$prs_closed")" \
    "$(fi_json_str "$commits")" "$(fi_json_str "$commits_stale")" \
    "$(fi_json_str "$verified")" "$(fi_json_str "$fixed_date")" \
    "$(fi_json_str "$renamed_from")" "$(fi_json_str "$mute")" \
    "$(fi_json_str "$raw")"
}
```

Then extend `fi_entries` (at `lib/parse-entries.sh:202`): add `local numbered="${3:-}"` beside the existing locals, pass it to the awk program as `-v numbered="$numbered"`, and in the awk print branch change `print` to:

```awk
{ if (numbered == "numbered") print FNR ":" $0; else print $0 }
```

Keep every other awk condition identical — the conflict-marker logic and the `index()`-based status filter must not change. (Check the existing awk block in `fi_entries` before editing; the print site is the only line touched.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/parse-entries.bats`
Expected: ALL PASS (pre-existing + 7 new).

- [ ] **Step 5: Commit**

```bash
git add lib/parse-entries.sh tests/parse-entries.bats
git commit -m "feat(parse): JSON emission helpers + numbered fi_entries mode"
```

---

### Task 2: `cmd_list` subcommand

**Files:**
- Modify: `bin/found-issues` (new `cmd_list` before `cmd_status` at ~line 872; dispatch entry in `main()` case at ~line 4142; help text in `cmd_help` at ~line 217)
- Test: `tests/cli-list.bats` (new file)

**Interfaces:**
- Consumes: `fi_entries <file> <filter> [numbered]`, `fi_entry_to_json <n> <raw>` (Task 1), `fi_detect_mode` (existing).
- Produces: `found-issues list [--status=open|deferred|fixed|all] [--json]`. Default status filter: `open`. Human mode: raw entry lines. JSON mode: a JSON array (possibly `[]`). Missing ledger file: empty output / `[]`, exit 0. Unknown option or bad status: message on stderr, exit 2.

- [ ] **Step 1: Write the failing tests**

Create `tests/cli-list.bats`:

```bash
#!/usr/bin/env bats
# Tests for `found-issues list`

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
  TODAY="$(date +%Y-%m-%d)"
  mkdir -p docs
  cat > docs/found-issues.md <<EOF
# found-issues

- [open] $TODAY src/a.sh:10 — plain open symptom (suggested: fix a)
- [open] [!] $TODAY src/b.sh:20 — critical "quoted" symptom (PR: org/repo#5)
- [deferred] $TODAY src/c.sh — parked symptom (reason: waiting) (mute-until: 2099-01-01)
- [fixed] $TODAY src/d.sh:40 — done symptom (commit: abc1234) (fixed: $TODAY)
EOF
}

teardown() {
  fi_teardown_tmp
}

@test "list defaults to open entries only" {
  fi_run list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == *"src/a.sh:10"* ]]
  [[ "${lines[1]}" == *"src/b.sh:20"* ]]
}

@test "list --status=deferred filters to deferred" {
  fi_run list --status=deferred
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *"src/c.sh"* ]]
}

@test "list --status=all prints every entry" {
  fi_run list --status=all
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "list --json emits an array with typed fields" {
  fi_run list --json
  [ "$status" -eq 0 ]
  [[ "$output" == "["* ]]
  [[ "$output" == *"]" ]]
  [[ "$output" == *'"path":"src/a.sh"'* ]]
  [[ "$output" == *'"line":10'* ]]
  [[ "$output" == *'"critical":true'* ]]
  [[ "$output" == *'"prs":"org/repo#5"'* ]]
}

@test "list --json escapes double quotes inside symptoms" {
  fi_run list --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'critical \"quoted\" symptom'* ]]
}

@test "list --json carries the file line number as line_no" {
  fi_run list --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"line_no":3'* ]]
  [[ "$output" == *'"line_no":4'* ]]
}

@test "list --status=deferred --json includes mute_until" {
  fi_run list --status=deferred --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"mute_until":"2099-01-01"'* ]]
}

@test "list with no ledger file prints nothing and exits 0" {
  rm docs/found-issues.md
  fi_run list
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f docs/found-issues.md ]
}

@test "list --json with no ledger file prints empty array" {
  rm docs/found-issues.md
  fi_run list --json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  [ ! -f docs/found-issues.md ]
}

@test "list rejects an unknown status filter with exit 2" {
  fi_run list --status=bogus
  [ "$status" -eq 2 ]
}

@test "list rejects an unknown option with exit 2" {
  fi_run list --frobnicate
  [ "$status" -eq 2 ]
}

@test "list excludes entries inside merge-conflict blocks" {
  cat > docs/found-issues.md <<EOF
- [open] $TODAY a.sh:1 — outside
<<<<<<< HEAD
- [open] $TODAY b.sh:2 — ours
=======
- [open] $TODAY c.sh:3 — theirs
>>>>>>> other
EOF
  fi_run list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *"a.sh:1"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/cli-list.bats`
Expected: all 12 FAIL (`Unknown command: list` or similar from the dispatch fallthrough).

- [ ] **Step 3: Implement `cmd_list`**

In `bin/found-issues`, insert directly above `cmd_status()` (~line 872):

```bash
# List ledger entries, optionally as JSON. Read-only: never creates the
# ledger file (unlike fi_resolve_issues_file). Default filter: open —
# the actionable set, matching the statusline's mental model.
cmd_list() {
  local status_filter="open" json="no"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status=*) status_filter="${1#--status=}"; shift ;;
      --status)   status_filter="${2:-open}"; shift 2 ;;
      --json)     json="yes"; shift ;;
      *)
        printf 'found-issues list: unknown option: %s\n' "$1" >&2
        return 2
        ;;
    esac
  done

  case "$status_filter" in
    open|deferred|fixed|all) : ;;
    *)
      printf 'found-issues list: invalid --status: %s (use open|deferred|fixed|all)\n' "$status_filter" >&2
      return 2
      ;;
  esac

  # Read-only resolution (mirrors fi_resolve_issues_file minus creation).
  local file
  if [[ "$(fi_detect_mode)" == "local" ]]; then
    file="$PWD/.found-issues.md"
  else
    local repo_root
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    file="$repo_root/docs/found-issues.md"
  fi

  if [[ ! -f "$file" ]]; then
    [[ "$json" == "yes" ]] && printf '[]\n'
    return 0
  fi

  if [[ "$json" == "no" ]]; then
    fi_entries "$file" "$status_filter"
    return 0
  fi

  local out="" numbered_line line_no raw obj
  while IFS= read -r numbered_line; do
    line_no="${numbered_line%%:*}"
    raw="${numbered_line#*:}"
    obj="$(fi_entry_to_json "$line_no" "$raw")" || continue
    if [[ -z "$out" ]]; then
      out="$obj"
    else
      out="$out,$obj"
    fi
  done < <(fi_entries "$file" "$status_filter" numbered)
  printf '[%s]\n' "$out"
}
```

Add the dispatch entry in `main()`'s case (~line 4142), beside `sync`:

```bash
    list)             cmd_list "$@" ;;
```

Add to `cmd_help`'s COMMANDS block, after the `status` entry:

```
  list [--status=open|deferred|fixed|all] [--json]
                                        Print ledger entries (default: open).
                                        --json emits structured entries for tooling
                                        (used by /found-issues:fix).
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/cli-list.bats tests/parse-entries.bats`
Expected: ALL PASS.

- [ ] **Step 5: Run the full suite (regression gate)**

Run: `bats tests/`
Expected: ALL PASS (~490 + 19 new). The statusline contract snapshots must be untouched.

- [ ] **Step 6: Commit**

```bash
git add bin/found-issues tests/cli-list.bats
git commit -m "feat(cli): found-issues list subcommand (--status, --json)"
```

---

### Task 3: `commands/fix.md` — the fix procedure

**Files:**
- Create: `commands/fix.md`
- Test: `tests/docs-consistency.bats` (append)

**Interfaces:**
- Consumes: `found-issues list --json` (Task 2), existing `annotate-pr <N> --pick`, existing sync/defer commands.
- Produces: the `/found-issues:fix` slash command.

- [ ] **Step 1: Write the failing tests**

Append to `tests/docs-consistency.bats`:

```bash
@test "docs-consistency: commands/fix.md exists with frontmatter description" {
  [ -f "$REPO_ROOT/commands/fix.md" ]
  head -6 "$REPO_ROOT/commands/fix.md" | grep -q '^description:'
}

@test "docs-consistency: README documents the fix command" {
  grep -q 'found-issues:fix' "$README"
}

@test "docs-consistency: fix.md forbids annotate-pr --all" {
  grep -q 'never .*--all' "$REPO_ROOT/commands/fix.md"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/docs-consistency.bats`
Expected: the 3 new tests FAIL (file missing); pre-existing PASS.

- [ ] **Step 3: Create `commands/fix.md`**

Full content:

````markdown
---
description: Fix open found-issues entries — verify each against current code, triage into buckets, gate on approval, fix on a branch with tests, ship a PR with precise annotations. Runs when the user asks to "fix the found issues" or work through the open ledger.
argument-hint: [--auto] [--only <path-or-glob>]
allowed-tools: Bash(found-issues:*), Bash(git:*), Bash(gh:*), Bash(bats:*), Read, Edit, Write, Glob, Grep
---

Work through this repo's `[open]` found-issues entries: verify → triage →
gate → fix → ship. You do the judgment; the CLI does the mechanics.

Flags in `$ARGUMENTS`: `--auto` skips the approval gate (and then executes
ONLY the auto-fixable bucket). `--only <path-or-glob>` restricts to entries
whose path matches.

## Phase 1 — Verify (read-only)

1. `found-issues list --json` for `[open]` entries; `found-issues list
   --status=deferred --json` for the deferred surfacing below.
2. **Resume rule:** skip any open entry whose `prs` or `commits` field is
   non-null — a previous run already addressed it; `sync` will close it on
   merge.
3. Re-verify every remaining entry against the CURRENT tree. The cited
   line may have moved — search for the symptom's code pattern, not just
   the line number. When more than ~5 entries need verification, dispatch
   parallel read-only subagents (Agent tool); give each the entry's `raw`
   line and require a fresh `file:line` citation or counter-evidence back.
   Verdicts: `STILL-VALID` | `ALREADY-FIXED` (state what fixed it) |
   `CITATION-MOVED` (carry the corrected location) | `UNVERIFIABLE`.

## Phase 2 — Triage + gate

Bucket every verified entry:

1. **already-fixed** — symptom gone. Do NOT re-fix. Closure edit (on the
   fix branch, Phase 3): append `(verified: ai)` plus a one-line evidence
   note to the entry, or `(commit: <sha>)` when the fixing commit is
   identifiable.
2. **auto-fixable** — code/doc change contained in this repo, verifiable
   by the repo's tests/build, no external dependency.
3. **needs-decision** — the fix requires a design choice. Formulate the
   question with options; do not guess.
4. **not-code-fixable** — external surface (DNS, dashboards, third-party
   config), needs a captured live payload, or the entry says it is
   operator-gated. Propose converting to `[deferred]` with a `(reason:)`.

Also list `[deferred]` entries whose blocker looks resolved (`mute_until`
in the past, or the recorded revisit trigger is now true) under **"worth
un-deferring?"** — never fix them this run.

Present the numbered triage report (verdict, bucket, planned one-line fix,
blast radius per entry) and STOP for approval — approve all or exclude by
number. With `--auto`: print the report and proceed with bucket 2 only.

## Phase 3 — Fix loop

- Branch `fix/found-issues-<YYYYMMDD>` off the default branch. Never fix
  on the current or default branch.
- Order: critical `[!]` first; entries sharing a file are one group;
  then oldest first.
- Per entry/group: write a failing regression test first when the repo
  has a test harness; apply the minimal fix; run the repo's tests +
  build; commit — ONE commit per entry, message referencing the entry
  (`fix: <symptom fragment> (found-issues <path>:<line>)`).
- **Failure rule:** if a fix won't go green within ~2 attempts, revert it
  completely and record `SKIPPED: <reason>`. Never leave a fix
  half-applied.
- Surgical: fix the cited symptom only. New out-of-scope problems you
  notice get logged as NEW entries (`found-issues log` style), not fixed.

## Phase 4 — Ship + close

1. Full test suite + build; quote the summary lines in the PR body.
2. One PR for the run; body lists per-entry outcomes
   (FIXED / CLOSED-ALREADY-FIXED / SKIPPED / DEFER-SUGGESTED).
3. Annotate precisely: `found-issues annotate-pr <N> --pick <path:line>`
   for exactly the entries this PR fixes — never `--all` (file-level
   auto-match over-annotates; the 2026-07-09 incident false-closed 9
   entries).
4. Merged PRs are closed by the existing sync machinery — do not flip
   `[open]` → `[fixed]` by hand for fixed entries.

## Final report (required format)

The last message is a scan target, not an essay:

1. First line scoreboard:
   `Fixed 9 · Closed already-fixed 3 · Skipped 1 · Suggested deferrals 2 · PR #N`
2. Per FIXED entry, one compact block:
   - header line: `path:line — symptom fragment`
   - **Before** / **After** fenced snippets — only the load-bearing lines
     (≤ ~6 lines each)
   - one evidence line: `test: <test name> PASS · commit <short-sha>`
3. SKIPPED / needs-decision / deferral suggestions: one line each with
   the reason. No snippet.
4. No prose paragraphs between blocks — narrative belongs in the PR body.

Example block:

    2. bin/found-issues:880 — status residual double-subtracts overlap

    Before:
    ```bash
    residual=$((total_open - in_pr - critical))
    ```
    After:
    ```bash
    residual=$((total_open - in_pr - critical + overlap))
    ```
    test: "status counts critical in-PR overlap once" PASS · commit ab12cd3
````

- [ ] **Step 4: Run tests to verify the fix.md tests pass**

Run: `bats tests/docs-consistency.bats`
Expected: the fix.md-existence and `--all`-prohibition tests PASS; the README test still FAILS (Task 4 adds the README row — if the suite must stay green per commit, add the README row in this task instead and keep Task 4's step as verification).

- [ ] **Step 5: Add the README + AGENTS.md command rows now (keeps suite green)**

In `README.md`, find the commands table/list (`rg -n 'annotate-pr' README.md`) and add alongside the existing command rows:

```markdown
- `/found-issues:fix [--auto] [--only <path>]` — verify, triage, and fix the open entries: gated batch-fix that ships a PR with precise annotations (`--auto` skips the gate, auto-fixable bucket only).
```

In `AGENTS.md`, same pattern (`rg -n 'annotate-pr' AGENTS.md`), matching its existing row format.

- [ ] **Step 6: Run the docs suite**

Run: `bats tests/docs-consistency.bats`
Expected: ALL PASS.

- [ ] **Step 7: Commit**

```bash
git add commands/fix.md tests/docs-consistency.bats README.md AGENTS.md
git commit -m "feat(commands): /found-issues:fix — gated verify/triage/fix/ship procedure"
```

---

### Task 4: Remaining docs + version bump

**Files:**
- Modify: `docs/architecture.md` (CLI subcommand inventory + command docs list)
- Modify: `CHANGELOG.md` (new 1.7.0 section at top)
- Modify: `.claude-plugin/plugin.json` (`"version"` field)

**Interfaces:**
- Consumes: everything shipped in Tasks 1–3.
- Produces: a version-check-passing release state (plugin.json version == newest CHANGELOG heading).

- [ ] **Step 1: Update `docs/architecture.md`**

Locate the subcommand inventory (`rg -n 'annotate-commit' docs/architecture.md`) and add `list` (with one-line purpose: "structured/filtered entry listing; `--json` feeds `/found-issues:fix`") and `fix` to the command-doc inventory, matching the surrounding format.

- [ ] **Step 2: Add the CHANGELOG entry**

Insert at the top of the version sections in `CHANGELOG.md` (below the intro, above `## [1.6.0]`):

```markdown
## [1.7.0] - 2026-07-10

### Added

- `/found-issues:fix` command: works through `[open]` entries with a
  verify → triage → gate → fix → ship procedure. Re-verifies every entry
  against current code, buckets them (already-fixed / auto-fixable /
  needs-decision / not-code-fixable), gates on approval (`--auto` runs the
  auto-fixable bucket without the gate), fixes on a dedicated branch with
  one commit per entry, and ships a PR annotated via `annotate-pr --pick`.
  Deferred entries are surfaced ("worth un-deferring?") but never fixed.
- `found-issues list [--status=open|deferred|fixed|all] [--json]`
  subcommand: conflict-aware entry listing; `--json` emits structured
  entries (path, line, symptom, annotations, `line_no`, raw) with no new
  dependencies.
```

- [ ] **Step 3: Bump the plugin version**

In `.claude-plugin/plugin.json`, change the `"version"` value from `"1.6.0"` to `"1.7.0"` (verify the current value first: `rg -n '"version"' .claude-plugin/plugin.json`).

- [ ] **Step 4: Full suite + help smoke**

Run: `bats tests/`
Expected: ALL PASS.

Run: `bin/found-issues help | grep -A2 'list \['`
Expected: the new help block prints.

- [ ] **Step 5: Commit**

```bash
git add docs/architecture.md CHANGELOG.md .claude-plugin/plugin.json
git commit -m "chore(release): v1.7.0 — fix command + list subcommand"
```

---

### Task 5: Ship

**Files:** none (git/GitHub operations).

- [ ] **Step 1: Push and open the PR**

```bash
git push -u origin feat/fix-command
gh pr create --title "feat: /found-issues:fix command + list --json subcommand (v1.7.0)" \
  --body "Implements docs/superpowers/specs/2026-07-10-fix-command-design.md (operator-approved).

- commands/fix.md: verify → triage → gate → fix → ship procedure; --auto executes the auto-fixable bucket only; deferred entries surfaced, never fixed; ADHD-proof final-report contract (scoreboard + before/after blocks)
- found-issues list [--status=...] [--json]: conflict-aware, numbered, hand-rolled JSON (no new deps, bash 3.2 safe)
- 22 new bats tests (parse helpers, cli-list, docs-consistency)
- CHANGELOG 1.7.0 + plugin.json bump

Full suite green locally: <paste bats summary line>

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

- [ ] **Step 2: Watch the full CI matrix before declaring done**

Windows bats takes 7–15 minutes (Linux/Mac green is NOT enough — established failure mode). Poll `gh pr checks` until all three platforms pass; fix failures on the branch.

- [ ] **Step 3: Merge (operator-authorized) and complete the release coupling**

After operator merge approval: squash-merge. Then the marketplace half — in `~/Documents/projects/AltDoug/claude-plugins` (clone if absent: `gh repo clone AltDoug/claude-plugins`), replicate the v1.6.0 release PR pattern (see that repo's log: bump the found-issues version reference in the marketplace manifest) with a `found-issues v1.7.0` PR, in this order: source repo first, marketplace second.

---

## Self-Review (completed at write time)

- **Spec coverage:** command surface ✓ (T3), open-only + deferred surfacing ✓ (T3 §1/§2), both modes ✓ (T3 gate/--auto), buckets ✓, fix-loop rules ✓, annotate --pick ✓, resume ✓ (T3 §1.2), final-report contract ✓ (T3), `list --json` ✓ (T1/T2), tests ✓ (T1/T2/T3), docs+version ✓ (T4), release coupling ✓ (T5). Spec's JSON field list amended at plan time to the parse layer's real fields + `mute_until` + `raw` (exotic annotations ride in `raw`).
- **Placeholder scan:** no TBDs; all code complete.
- **Type consistency:** `fi_entry_to_json <line_no> <raw>` signature consistent across T1 (definition), T2 (caller), tests; `numbered` third arg consistent between T1 awk change and T2 caller.
