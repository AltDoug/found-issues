# Auto-fix v3 — Phase 1: Fix Tags and Decision Queue — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Entries can carry exactly one fix tag (`fix: small|medium|large`, `decide: …`, `manual: …`). Agents set it at log time or with `found-issues tag`. Off-limits paths are forced to `manual`. A decision queue (`found-issues decide`, `/found-issues:decide`) turns answered questions into `(decided: …)`. Deferred entries can carry `(until: …)` triggers that `sync` wakes mechanically. Nothing auto-launches yet; that is Phase 2.

**Architecture:**
- **One new library, `lib/autofix-tags.sh`,** owns the pure logic: off-limits classification, tag-text sanitizing, and the single string-level tail rewrite (`fi_entry_retag`).
- **New commands:** `lib/tag.sh` (`tag`) and `lib/decide.sh` (`decide`) are thin CLI shells over it. `log`, `defer` and `sync` call the same helpers.
- **Parsing:** the parser learns the new tail groups, so `list --json` exposes them and dedup keys strip them.

**Tech Stack:** bash 3.2+ (macOS system bash), bats, the existing found-issues CLI (`bin/found-issues` + `lib/*.sh`).

**Spec:** `docs/superpowers/specs/2026-10-03-autofix-v3-design.md` (§3 Classification, §6 step 3 wake-ups, §11 phase 1).

**Phase index:** this is plan 1 of 6. Plans for phases 2–6 (§11 of the spec) are written when the previous phase merges into `release/v3`, against the interfaces it actually shipped.

## Global Constraints

- Bash 3.2 compatible: no `declare -A`, no `${var,,}`, no `mapfile`. Guard `"${arr[@]}"` on empty arrays under `set -u`.
- Builtin-only on hot paths (parser, SessionStart gate): no new forks per entry.
- Only `log`, `annotate-*`, `sync`, `defer`, `resolve`, `tag` and `decide` write the ledger, always via `fi_ledger_snapshot` → `fi_ledger_tmp` → `fi_ledger_replace`.
- New tags live in the annotation tail. None of them is a closing token, and `sync` closing behavior is unchanged.
- Tag values contain no `(`, `)` or newline: `(` → `[`, `)` → `]`, whitespace collapsed (spec §3.5, audit cli-7).
- Off-limits categories, spec §3.3 verbatim:
  - CI: `.github/`, `.gitlab-ci*`, `.circleci/`, `Jenkinsfile`.
  - secrets: a path segment or file stem exactly `auth`, `secret`, `secrets`, `credential`, `credentials` (or starting `auth.`/`secret.`), plus `.env*`, `*.pem`, `*.key`.
  - dependencies, exact names: `package.json`, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `bun.lock`, `bun.lockb`, `go.mod`, `go.sum`, `Cargo.toml`, `Cargo.lock`, `pyproject.toml`, `poetry.lock`, `uv.lock`, `requirements*.txt`, `Gemfile`, `Gemfile.lock`.
  - migrations: a `migrations/` or `db/migrate/` segment.
  - outside-repo or untracked.
- Version is `3.0.0` on `release/v3` from Task 1 on. Every phase appends to the one `## [3.0.0]` CHANGELOG section.
- bats test names ASCII only (CI guard).
- Work in worktree `/Users/diogosilvasena/Documents/projects/found-issues/.claude/worktrees/v3`, on a branch `v3/phase1-tags` cut from `release/v3`. PR base is `release/v3`.

## Review Focus

1. **A `--decide` question or `--manual` reason containing parentheses**, e.g. "use fix() or patch()?". It must be stored as `[`/`]` and the entry must still parse: test in Task 3.
2. **A symptom that mentions `(fix: small)` mid-line**, e.g. "docs say (fix: small) but…". It is not a tag, because tags are read from the tail only: test in Task 2.
3. **Off-limits false positives:** `src/author.py`, `lib/clock.py`, `blocklist.py`, `tools/migrate_helpers.py` and `docs/package.json.md` must NOT be off-limits: test in Task 3.
4. **Re-tagging** replaces the previous tag instead of adding a second one, and keeps closing annotations like `(PR: o/r#1)` intact: test in Task 4.
5. **A ledger with no `[open]` entries but a deferred `(until: date:…)` entry that is due** still wakes at SessionStart. The hook-11 skip gate must not skip it: test in Task 7.

---

### Task 1: Integration-branch CI and the 3.0.0 version line

**Files:**
- Modify: `.github/workflows/test.yml:4-7`
- Modify: `bin/found-issues:31`, `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`
- Modify: `CHANGELOG.md` (new top section)

**Interfaces:**
- Produces: CI runs on PRs into and pushes to `release/v3`; `FI_VERSION="3.0.0"`.

- [ ] **Step 1: Branch**

```bash
cd /Users/diogosilvasena/Documents/projects/found-issues/.claude/worktrees/v3
git fetch -q origin && git checkout -q release/v3 && git pull -q
git checkout -b v3/phase1-tags
```

- [ ] **Step 2: Let CI run for the integration branch.** In `.github/workflows/test.yml` change both trigger lists:

```yaml
  push:
    branches: [main, release/v3]
  pull_request:
    branches: [main, release/v3]
```

- [ ] **Step 3: Bump to 3.0.0**

```bash
sed -i '' 's/readonly FI_VERSION="2.10.4"/readonly FI_VERSION="3.0.0"/' bin/found-issues
sed -i '' 's/"version": "2.10.4"/"version": "3.0.0"/' .claude-plugin/plugin.json .codex-plugin/plugin.json
```

Insert directly above `## [2.10.4] - 2026-10-03` in `CHANGELOG.md`:

```markdown
## [3.0.0] - unreleased

Opt-in auto-fix and auto-sweep (spec: `docs/superpowers/specs/2026-10-03-autofix-v3-design.md`).
Built on the `release/v3` branch; this section grows with each phase.

### Added

- Fix tags on entries — `(fix: small|medium|large)`, `(decide: <question>)`,
  `(manual: <why>)` — set with `found-issues log --fix|--decide|--manual` or
  `found-issues tag`. Off-limits paths (CI, secrets/auth, dependency
  manifests and lockfiles, migrations, untracked or outside the repo) are
  always tagged `(manual: off-limits: <category>)`.
- Decision queue: `found-issues decide` lists open questions;
  `found-issues decide <match> --answer "<text>"` records `(decided: <text>)`.
  New `/found-issues:decide` command; SessionStart says how many are waiting.
- `found-issues defer --until pr:<owner/repo#N>|date:<YYYY-MM-DD>|"<text>"`;
  `sync` returns a deferred entry to `[open]` when its PR merged or its date
  passed.
```

- [ ] **Step 4: Verify the version gate**

Run: `bash scripts/check-version.sh`
Expected: exit 0 and a line ending `is MAJOR. Breaking changes documented? Check docs/versioning.md.`

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/test.yml bin/found-issues .claude-plugin/plugin.json .codex-plugin/plugin.json CHANGELOG.md
git commit -m "chore(v3): CI on release/v3, version 3.0.0 (unreleased)"
```

---

### Task 2: Parser reads the new tail groups

**Files:**
- Modify: `lib/parse-entries.sh` (`fi_annotation_tail_v` ~:152, globals ~:199-202, `fi_parse_entry_vars` reset ~:217-220 and tail block ~:278-285, `fi_parse_entry` ~:165-186, `fi_entry_to_json` ~:574-635)
- Test: `tests/autofix-tags.bats` (new)

**Interfaces:**
- Produces:
  - globals `FE_fixtag` (`small|medium|large|""`), `FE_decide`, `FE_decided`, `FE_manual`, `FE_until`, `FE_autofix_failed`, all set by `fi_parse_entry_vars` from the annotation TAIL only;
  - `fi_parse_entry` keys `fixtag=`, `decide=`, `decided=`, `manual=`, `until=`, `autofix_failed=`;
  - `list --json` keys `"fix_tag"`, `"decide"`, `"decided"`, `"manual"`, `"until"`, `"autofix_failed"` (JSON null when empty).

- [ ] **Step 1: Write the failing tests** in `tests/autofix-tags.bats`:

```bash
#!/usr/bin/env bats
# v3.0.0 fix tags (spec docs/superpowers/specs/2026-10-03-autofix-v3-design.md §3).

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
  mkdir -p docs src
  printf 'x\n' > src/a.sh
  git add -A && git commit -q -m init
}
teardown() { fi_teardown_tmp; }

@test "parser: fix tag and decide/manual/until/decided/autofix-failed come from the tail" {
  fi_source_lib canonicalize
  fi_source_lib parse-entries
  fi_parse_entry_vars "- [open] 2026-10-03 src/a.sh:1 — bug (suggested: x) (fix: medium)"
  [ "$FE_fixtag" = "medium" ]
  [ "$FE_symptom" = "bug" ]
  fi_parse_entry_vars "- [open] 2026-10-03 src/a.sh:1 — bug (decide: A or B?)"
  [ "$FE_decide" = "A or B?" ]
  fi_parse_entry_vars "- [open] 2026-10-03 src/a.sh:1 — bug (decided: A) (fix: small)"
  [ "$FE_decided" = "A" ] && [ "$FE_fixtag" = "small" ]
  fi_parse_entry_vars "- [open] 2026-10-03 src/a.sh:1 — bug (manual: needs a live payload)"
  [ "$FE_manual" = "needs a live payload" ]
  fi_parse_entry_vars "- [deferred] 2026-10-03 src/a.sh:1 — bug (reason: later) (until: date:2026-11-01)"
  [ "$FE_until" = "date:2026-11-01" ]
  fi_parse_entry_vars "- [open] 2026-10-03 src/a.sh:1 — bug (fix: small) (autofix-failed: tests stayed red)"
  [ "$FE_autofix_failed" = "tests stayed red" ]
}

@test "parser: a symptom that mentions (fix: small) mid-line is not tagged" {
  fi_source_lib canonicalize
  fi_source_lib parse-entries
  fi_parse_entry_vars "- [open] 2026-10-03 src/a.sh:1 — docs say (fix: small) but the code disagrees"
  [ -z "$FE_fixtag" ]
}

@test "list --json exposes fix_tag, decide, decided, manual, until, autofix_failed" {
  printf -- '- [open] 2026-10-03 src/a.sh:1 — bug (fix: small)\n- [open] 2026-10-03 src/a.sh:2 — q (decide: A or B?)\n' > docs/found-issues.md
  fi_run list --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.[0].fix_tag == "small" and .[0].decide == null and .[1].decide == "A or B?" and .[1].fix_tag == null and (.[0] | has("until") and has("decided") and has("manual") and has("autofix_failed"))'
}

@test "dedup: re-logging the same symptom with a tag is still a duplicate" {
  printf -- '- [open] 2026-10-03 src/a.sh:1 — bug (fix: small)\n' > docs/found-issues.md
  fi_run log "src/a.sh:1 — bug"
  [[ "$output" == *"already logged"* ]]
  [ "$(grep -c 'src/a.sh:1' docs/found-issues.md)" -eq 1 ]
}
```

- [ ] **Step 2: Run them, expect failures**

Run: `bats tests/autofix-tags.bats`
Expected: tests 1, 3 and 4 FAIL (FE_fixtag unset; JSON lacks keys; the tagged entry's key still contains `(fix: small)`, so it is not a duplicate). Test 2 passes already.

- [ ] **Step 3: Teach the tail regex the new keys.** In `fi_annotation_tail_v` replace the `re_tail_group` line with:

```bash
  local re_tail_group='\((PR|PR-auto|PR-closed|commit|commit-auto|commit-stale|verified|fixed|closure|renamed-from|touched|defer-cycle|reason|mute-until|suggested|fix|decide|decided|manual|until|autofix-failed): [^)]*\)[[:space:]]*$'
```

- [ ] **Step 4: Add the globals and their reset.** Append to the global declaration block (after the line `FE_fixed_date="" FE_verified=""` at ~:202):

```bash
FE_fixtag="" FE_decide="" FE_decided="" FE_manual="" FE_until="" FE_autofix_failed=""
```

In `fi_parse_entry_vars`, right after the reset line `FE_fixed_date="" FE_verified=""` (~:220), add:

```bash
  FE_fixtag="" FE_decide="" FE_decided="" FE_manual="" FE_until="" FE_autofix_failed=""
```

- [ ] **Step 5: Read the tags from the tail only.** In `fi_parse_entry_vars`, inside the existing `if [[ -n "$tail" ]]; then … fi` block, after the `FE_commits_stale` line, add:

```bash
    # v3 fix tags — tail only, so a symptom that merely mentions one is not
    # tagged (spec §3.5).
    local re_fixtag='\(fix: (small|medium|large)\)'
    [[ "$tail" =~ $re_fixtag ]] && FE_fixtag="${BASH_REMATCH[1]}"
    local re_decide='\(decide: ([^)]*)\)'
    [[ "$tail" =~ $re_decide ]] && FE_decide="${BASH_REMATCH[1]}"
    local re_decided='\(decided: ([^)]*)\)'
    [[ "$tail" =~ $re_decided ]] && FE_decided="${BASH_REMATCH[1]}"
    local re_manual='\(manual: ([^)]*)\)'
    [[ "$tail" =~ $re_manual ]] && FE_manual="${BASH_REMATCH[1]}"
    local re_until='\(until: ([^)]*)\)'
    [[ "$tail" =~ $re_until ]] && FE_until="${BASH_REMATCH[1]}"
    local re_afail='\(autofix-failed: ([^)]*)\)'
    [[ "$tail" =~ $re_afail ]] && FE_autofix_failed="${BASH_REMATCH[1]}"
```

- [ ] **Step 6: Print them from `fi_parse_entry`.** After `printf 'verified=%s\n' "$FE_verified"`:

```bash
  printf 'fixtag=%s\n' "$FE_fixtag"
  printf 'decide=%s\n' "$FE_decide"
  printf 'decided=%s\n' "$FE_decided"
  printf 'manual=%s\n' "$FE_manual"
  printf 'until=%s\n' "$FE_until"
  printf 'autofix_failed=%s\n' "$FE_autofix_failed"
```

- [ ] **Step 7: Emit them in JSON.** In `fi_entry_to_json`:

Add a local line after `local fixed_date="" verified=""`:

```bash
  local fixtag="" decide="" decided="" manual="" until_="" autofix_failed=""
```

Add these cases to the `case "$key" in` block:

```bash
      fixtag)         fixtag="$val" ;;
      decide)         decide="$val" ;;
      decided)        decided="$val" ;;
      manual)         manual="$val" ;;
      until)          until_="$val" ;;
      autofix_failed) autofix_failed="$val" ;;
```

Replace the final `printf '{"line_no":…,"raw":%s}' \ … "$(fi_json_str "$raw")"` statement with:

```bash
  printf '{"line_no":%s,"status":"%s","critical":%s,"date":%s,"path":%s,"line":%s,"line_end":%s,"symptom":%s,"suggested":%s,"prs":%s,"prs_auto":%s,"prs_closed":%s,"commits":%s,"commits_auto":%s,"commits_stale":%s,"verified":%s,"fixed_date":%s,"renamed_from":%s,"mute_until":%s,"fix_tag":%s,"decide":%s,"decided":%s,"manual":%s,"until":%s,"autofix_failed":%s,"raw":%s}' \
    "$line_no" "$status" "$crit_bool" \
    "$(fi_json_str "$date")" "$(fi_json_str "$path")" "$line_json" "$line_end_json" \
    "$(fi_json_str "$symptom")" "$(fi_json_str "$fix")" \
    "$(fi_json_str "$prs")" "$(fi_json_str "$prs_auto")" "$(fi_json_str "$prs_closed")" \
    "$(fi_json_str "$commits")" "$(fi_json_str "$commits_auto")" "$(fi_json_str "$commits_stale")" \
    "$(fi_json_str "$verified")" "$(fi_json_str "$fixed_date")" \
    "$(fi_json_str "$renamed_from")" "$(fi_json_str "$mute")" \
    "$(fi_json_str "$fixtag")" "$(fi_json_str "$decide")" "$(fi_json_str "$decided")" \
    "$(fi_json_str "$manual")" "$(fi_json_str "$until_")" "$(fi_json_str "$autofix_failed")" \
    "$(fi_json_str "$raw")"
```

(`fi_json_str` already emits `null` for an empty value. Confirm with `rg -n '^fi_json_str' -A8 lib/parse-entries.sh` before relying on it; if it emits `""`, add an empty → `null` branch inside the new calls only.)

- [ ] **Step 8: Run the new tests and the parser suites**

Run: `bats tests/autofix-tags.bats tests/parse-entries*.bats tests/cli-list*.bats tests/canonicalize*.bats`
Expected: all `ok`. The dedup test passes because `fi_dedup_key_v` strips the annotation tail, which now includes `(fix: …)`.

- [ ] **Step 9: Commit**

```bash
git add lib/parse-entries.sh tests/autofix-tags.bats
git commit -m "feat(v3): parse fix/decide/decided/manual/until/autofix-failed tags"
```

---

### Task 3: `lib/autofix-tags.sh`: off-limits, tag text, retag

**Files:**
- Create: `lib/autofix-tags.sh`
- Modify: `bin/found-issues` (source it after `parse-entries.sh`, ~:84)
- Test: `tests/autofix-tags.bats` (append)

**Interfaces:**
- Consumes: `fi_annotation_tail_v` (sets `FI_ANN_TAIL`), `fi_parse_entry_vars`.
- Produces:
  - `fi_offlimits_category <path>` prints a category (`ci|secrets|dependencies|migrations|outside-repo`). Returns 0 when off-limits, 1 otherwise. No git calls.
  - `fi_offlimits_check <path> <repo_root>` is like `fi_offlimits_category`, plus `no-file` for an empty path and `untracked` when `<repo_root>` is non-empty and git does not track the path. Prints the category, returns 0 when off-limits.
  - `fi_tag_text <text>` sets `FI_TAG_TEXT` (parens → brackets, whitespace collapsed, trimmed). Returns 1 if the result is empty or contains a newline.
  - `fi_tag_resolve <kind> <value> <path> <repo_root>` validates and applies the off-limits override, setting `FI_TAG_KIND` and `FI_TAG_VALUE`. Returns 2 on a bad kind or value.
  - `fi_entry_retag <line> <kind> <value>` sets `FI_RETAGGED`:
    - `kind ∈ fix|decide|manual`: removes any `(fix:)`, `(decide:)` and `(manual:)` groups, then appends `(<kind>: <value>)`.
    - `kind = decided`: removes `(decide:)` and `(decided:)`, then appends `(decided: <value>)`.
    - `kind = drop-until`: removes `(until:)` only.
    - All other tail groups are kept in order.

- [ ] **Step 1: Write the failing tests** (append to `tests/autofix-tags.bats`):

```bash
@test "offlimits: categories" {
  fi_source_lib canonicalize; fi_source_lib parse-entries; fi_source_lib autofix-tags
  for p in .github/workflows/ci.yml .gitlab-ci.yml .circleci/config.yml Jenkinsfile; do
    run fi_offlimits_category "$p"; [ "$status" -eq 0 ]; [ "$output" = "ci" ]
  done
  for p in .env .env.local certs/server.pem keys/id.key src/auth/login.py lib/auth.sh config/secrets/x.yml credentials.json; do
    run fi_offlimits_category "$p"; [ "$status" -eq 0 ]; [ "$output" = "secrets" ]
  done
  for p in package.json web/package-lock.json yarn.lock pnpm-lock.yaml go.sum Cargo.lock pyproject.toml uv.lock requirements-dev.txt Gemfile.lock; do
    run fi_offlimits_category "$p"; [ "$status" -eq 0 ]; [ "$output" = "dependencies" ]
  done
  for p in db/migrate/001_init.rb app/migrations/0002.py; do
    run fi_offlimits_category "$p"; [ "$status" -eq 0 ]; [ "$output" = "migrations" ]
  done
  for p in /etc/hosts ../other/x.sh; do
    run fi_offlimits_category "$p"; [ "$status" -eq 0 ]; [ "$output" = "outside-repo" ]
  done
}

@test "offlimits: lookalikes are not off-limits" {
  fi_source_lib canonicalize; fi_source_lib parse-entries; fi_source_lib autofix-tags
  for p in src/author.py lib/clock.py blocklist.py tools/migrate_helpers.py docs/package.json.md src/authority/x.ts README.md; do
    run fi_offlimits_category "$p"; [ "$status" -eq 1 ]
  done
}

@test "offlimits_check: untracked and no-file" {
  fi_source_lib canonicalize; fi_source_lib parse-entries; fi_source_lib autofix-tags
  printf 'y\n' > src/new.sh
  run fi_offlimits_check src/new.sh "$TMP"; [ "$status" -eq 0 ]; [ "$output" = "untracked" ]
  run fi_offlimits_check src/a.sh "$TMP"; [ "$status" -eq 1 ]
  run fi_offlimits_check "" "$TMP"; [ "$status" -eq 0 ]; [ "$output" = "no-file" ]
}

@test "tag text: parentheses become brackets, whitespace collapses, empty is refused" {
  fi_source_lib canonicalize; fi_source_lib parse-entries; fi_source_lib autofix-tags
  fi_tag_text "  use fix() or   patch()?  "
  [ "$FI_TAG_TEXT" = "use fix[] or patch[]?" ]
  run fi_tag_text "   "; [ "$status" -eq 1 ]
  run fi_tag_text $'a\nb'; [ "$status" -eq 1 ]
}

@test "retag: replaces the previous tag, keeps closing annotations, decided clears decide" {
  fi_source_lib canonicalize; fi_source_lib parse-entries; fi_source_lib autofix-tags
  fi_entry_retag "- [open] 2026-10-03 src/a.sh:1 — bug (PR: o/r#1) (fix: small)" decide "A or B?"
  [ "$FI_RETAGGED" = "- [open] 2026-10-03 src/a.sh:1 — bug (PR: o/r#1) (decide: A or B?)" ]
  fi_entry_retag "$FI_RETAGGED" decided "A"
  [ "$FI_RETAGGED" = "- [open] 2026-10-03 src/a.sh:1 — bug (PR: o/r#1) (decided: A)" ]
  fi_entry_retag "- [deferred] 2026-10-03 src/a.sh:1 — bug (reason: x) (until: date:2026-01-01)" drop-until ""
  [ "$FI_RETAGGED" = "- [deferred] 2026-10-03 src/a.sh:1 — bug (reason: x)" ]
}

@test "tag_resolve: --fix on an off-limits path becomes manual off-limits" {
  fi_source_lib canonicalize; fi_source_lib parse-entries; fi_source_lib autofix-tags
  fi_tag_resolve fix small .github/workflows/ci.yml "$TMP"
  [ "$FI_TAG_KIND" = "manual" ] && [ "$FI_TAG_VALUE" = "off-limits: ci" ]
  fi_tag_resolve fix small src/a.sh "$TMP"
  [ "$FI_TAG_KIND" = "fix" ] && [ "$FI_TAG_VALUE" = "small" ]
  run fi_tag_resolve fix tiny src/a.sh "$TMP"; [ "$status" -eq 2 ]
  fi_tag_resolve decide "x (y)" "" ""
  [ "$FI_TAG_KIND" = "decide" ] && [ "$FI_TAG_VALUE" = "x [y]" ]
}
```

- [ ] **Step 2: Run them, expect failures**

Run: `bats tests/autofix-tags.bats -f 'offlimits|tag text|retag|tag_resolve'`
Expected: FAIL. `lib/autofix-tags.sh` does not exist, so `fi_source_lib` errors.

- [ ] **Step 3: Implement `lib/autofix-tags.sh`**

```bash
#!/usr/bin/env bash
# autofix-tags.sh — v3.0.0 fix tags: off-limits classification, tag-text
# sanitizing, and the one string-level writer of an entry's tag groups.
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash). Builtin-only except
# fi_offlimits_check's single `git ls-files`.
#
# Spec: docs/superpowers/specs/2026-10-03-autofix-v3-design.md §3.
#
# Functions:
#   fi_offlimits_category <path>
#   fi_offlimits_check <path> <repo_root>
#   fi_tag_text <text>
#   fi_tag_resolve <kind> <value> <path> <repo_root>
#   fi_entry_retag <line> <kind> <value>

# Off-limits paths are never auto-fixed, whatever the logging agent tagged:
# a wrong guess there costs a broken pipeline, a leaked secret or a bad
# migration (spec §3.3). Matching is by exact name or whole path segment so
# author.py, clock.py and migrate_helpers.py are not caught.
fi_offlimits_category() {
  local p="$1"
  [[ -z "$p" ]] && return 1
  case "$p" in
    /*|../*|*/../*) printf 'outside-repo'; return 0 ;;
  esac
  case "/$p/" in
    */.github/*|*/.circleci/*) printf 'ci'; return 0 ;;
    */migrations/*|*/db/migrate/*) printf 'migrations'; return 0 ;;
  esac
  local base="${p##*/}"
  case "$base" in
    .gitlab-ci*|Jenkinsfile) printf 'ci'; return 0 ;;
    .env|.env.*|*.pem|*.key) printf 'secrets'; return 0 ;;
    package.json|package-lock.json|yarn.lock|pnpm-lock.yaml|bun.lock|bun.lockb|\
    go.mod|go.sum|Cargo.toml|Cargo.lock|pyproject.toml|poetry.lock|uv.lock|\
    requirements*.txt|Gemfile|Gemfile.lock)
      printf 'dependencies'; return 0 ;;
  esac
  local rest="$p" seg stem
  while [[ -n "$rest" ]]; do
    seg="${rest%%/*}"
    if [[ "$rest" == */* ]]; then rest="${rest#*/}"; else rest=""; fi
    stem="${seg%%.*}"
    case "$stem" in
      auth|secret|secrets|credential|credentials) printf 'secrets'; return 0 ;;
    esac
  done
  return 1
}

# Off-limits plus the two checks that need context: an entry with no file
# cannot be fixed by a worker that starts from the cited file, and a path
# git does not track is generated, ignored or outside the repo.
fi_offlimits_check() {
  local p="$1" root="${2:-}"
  if [[ -z "$p" ]]; then printf 'no-file'; return 0; fi
  fi_offlimits_category "$p" && return 0
  if [[ -n "$root" ]] && ! git -C "$root" ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then
    printf 'untracked'; return 0
  fi
  return 1
}

# Tag values live inside "(key: value)"; the parser reads [^)]*, so a ")"
# would truncate the value and a "(" would confuse the tail scan (audit
# cli-7). Brackets keep the meaning readable.
fi_tag_text() {
  local t="$1"
  [[ "$t" == *$'\n'* || "$t" == *$'\r'* ]] && return 1
  t="${t//(/[}"
  t="${t//)/]}"
  t="${t//$'\t'/ }"
  while [[ "$t" == *"  "* ]]; do t="${t//  / }"; done
  t="${t#"${t%%[![:space:]]*}"}"
  t="${t%"${t##*[![:space:]]}"}"
  [[ -z "$t" ]] && return 1
  FI_TAG_TEXT="$t"
}

# Validate a requested tag and apply the off-limits override. kind=fix with
# an off-limits (or file-less, or untracked) path becomes manual.
fi_tag_resolve() {
  local kind="$1" value="$2" path="${3:-}" root="${4:-}" cat
  case "$kind" in
    fix)
      case "$value" in small|medium|large) ;; *)
        fi_err "--fix takes small, medium or large (got: $value)"; return 2 ;;
      esac
      if cat="$(fi_offlimits_check "$path" "$root")"; then
        FI_TAG_KIND="manual"; FI_TAG_VALUE="off-limits: $cat"; return 0
      fi
      FI_TAG_KIND="fix"; FI_TAG_VALUE="$value" ;;
    decide|manual|decided)
      fi_tag_text "$value" || { fi_err "--$kind needs a one-line, non-empty text"; return 2; }
      FI_TAG_KIND="$kind"; FI_TAG_VALUE="$FI_TAG_TEXT" ;;
    *) fi_err "unknown tag kind: $kind"; return 2 ;;
  esac
}

# Rewrite an entry's annotation tail: drop the groups this kind replaces,
# keep every other group in order, append the new one.
fi_entry_retag() {
  local line="$1" kind="$2" value="$3" drop
  case "$kind" in
    fix|decide|manual) drop='fix|decide|manual' ;;
    decided)           drop='decide|decided' ;;
    drop-until)        drop='until' ;;
    *) return 2 ;;
  esac
  fi_annotation_tail_v "$line"
  local tail="$FI_ANN_TAIL" head="${line%"$FI_ANN_TAIL"}"
  head="${head%"${head##*[![:space:]]}"}"
  local re_grp='^[[:space:]]*\(([A-Za-z-]+): [^)]*\)'
  local re_drop="^(${drop})\$" kept="" grp
  while [[ "$tail" =~ $re_grp ]]; do
    grp="${BASH_REMATCH[0]}"
    tail="${tail#"$grp"}"
    if [[ ! "${BASH_REMATCH[1]}" =~ $re_drop ]]; then
      grp="${grp#"${grp%%[![:space:]]*}"}"
      kept+=" $grp"
    fi
  done
  FI_RETAGGED="${head}${kept}"
  [[ "$kind" == "drop-until" ]] || FI_RETAGGED+=" ($kind: $value)"
}
```

In `bin/found-issues`, after `source "$FI_LIB_DIR/parse-entries.sh"`:

```bash
# v3 fix tags: off-limits, tag text, retag (spec 2026-10-03 §3).
# shellcheck source=../lib/autofix-tags.sh
source "$FI_LIB_DIR/autofix-tags.sh"
```

Note: `fi_entry_retag` must evaluate `BASH_REMATCH[1]` before the inner `=~ $re_drop` overwrites `BASH_REMATCH`. The code above reads it in the same `if` test, which runs before the overwrite. Keep it that way.

- [ ] **Step 4: Run them, expect PASS**

Run: `bats tests/autofix-tags.bats`
Expected: all `ok`.

- [ ] **Step 5: Commit**

```bash
git add lib/autofix-tags.sh bin/found-issues tests/autofix-tags.bats
git commit -m "feat(v3): off-limits classification, tag text sanitizing, retag helper"
```

---

### Task 4: `found-issues tag`

**Files:**
- Create: `lib/tag.sh`
- Modify: `bin/found-issues` (source + dispatch `tag) cmd_tag "$@" ;;` next to `resolve)`), `lib/help.sh` (one usage block after `resolve`)
- Test: `tests/autofix-tags.bats` (append)

**Interfaces:**
- Consumes: `fi_tag_resolve`, `fi_entry_retag`, `fi_parse_entry_vars`, `fi_icontains`, `fi_resolve_issues_file`, `fi_entries`, `fi_ledger_snapshot/tmp/replace`, `fi_need_value`, `fi_unknown_arg`, `fi_repo_root_cached` (sets `FI_REPO_ROOT`).
- Produces:
  - `fi_tag_apply <file> <target-line> <kind> <value>`: rewrites the first exact occurrence via the snapshot pattern and prints `Tagged: <new line>`. Returns 0, 1 if the line vanished, or 3 if the ledger changed underneath.
  - `cmd_tag`. Exit codes:

    | Code | Meaning |
    |---|---|
    | 0 | tagged |
    | 1 | no match |
    | 2 | usage error or ambiguous match |
    | 3 | ledger changed during the write; re-run |

- [ ] **Step 1: Write the failing tests** (append):

```bash
@test "tag: sets, replaces, keeps closing annotations; matches open and deferred" {
  printf -- '- [open] 2026-10-03 src/a.sh:1 — bug one (PR: o/r#1)\n- [deferred] 2026-10-03 src/a.sh:2 — bug two (reason: later)\n' > docs/found-issues.md
  fi_run tag "bug one" --fix small
  [ "$status" -eq 0 ]
  grep -qx -- '- \[open\] 2026-10-03 src/a.sh:1 — bug one (PR: o/r#1) (fix: small)' docs/found-issues.md
  fi_run tag "bug one" --decide "A or B?"
  grep -qx -- '- \[open\] 2026-10-03 src/a.sh:1 — bug one (PR: o/r#1) (decide: A or B?)' docs/found-issues.md
  [ "$(grep -c '(fix:' docs/found-issues.md)" -eq 0 ]
  fi_run tag "bug two" --manual "needs a captured payload"
  [ "$status" -eq 0 ]
  grep -q 'bug two (reason: later) (manual: needs a captured payload)' docs/found-issues.md
}

@test "tag: off-limits path is forced to manual and says so" {
  mkdir -p .github/workflows && printf 'x\n' > .github/workflows/ci.yml && git add -A && git commit -q -m ci
  printf -- '- [open] 2026-10-03 .github/workflows/ci.yml:3 — wrong runner\n' > docs/found-issues.md
  fi_run tag "wrong runner" --fix small
  [ "$status" -eq 0 ]
  [[ "$output" == *"off-limits"* ]]
  grep -q '(manual: off-limits: ci)' docs/found-issues.md
}

@test "tag: usage errors, ambiguity and no match" {
  printf -- '- [open] 2026-10-03 src/a.sh:1 — bug one\n- [open] 2026-10-03 src/a.sh:2 — bug two\n' > docs/found-issues.md
  fi_run tag "bug" --fix small;            [ "$status" -eq 2 ]
  fi_run tag "nothing here" --fix small;   [ "$status" -eq 1 ]
  fi_run tag "bug one";                    [ "$status" -eq 2 ]
  fi_run tag "bug one" --fix tiny;         [ "$status" -eq 2 ]
  fi_run tag "bug one" --bogus x;          [ "$status" -eq 2 ]
  fi_run tag --help;                       [ "$status" -eq 0 ]
  ! grep -q '(fix:' docs/found-issues.md
}
```

- [ ] **Step 2: Run, expect FAIL**

Run: `bats tests/autofix-tags.bats -f '^tag:'`
Expected: FAIL (`unknown command: tag` or similar).

- [ ] **Step 3: Implement `lib/tag.sh`**

```bash
#!/usr/bin/env bash
# tag.sh — tag — set an entry's v3 fix tag (spec 2026-10-03 §3.5)
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   fi_tag_apply <file> <target-line> <kind> <value>
#   cmd_tag [...]

# The single file writer of tags (log and decide call it too). Exact-line
# match on the first occurrence, serialized like every other ledger write.
fi_tag_apply() {
  local file="$1" target="$2" kind="$3" value="$4"
  fi_entry_retag "$target" "$kind" "$value" || return 2
  local new_line="$FI_RETAGGED" snapshot tmp line done_one=0
  snapshot="$(fi_ledger_snapshot "$file")"
  tmp="$(fi_ledger_tmp "$file")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( ! done_one )) && [[ "$line" == "$target" ]]; then
      printf '%s\n' "$new_line" >>"$tmp"; done_one=1
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$file"
  if (( ! done_one )); then rm -f "$tmp"; return 1; fi
  fi_ledger_replace "$file" "$tmp" "$snapshot" || return 3
  printf 'Tagged: %s\n' "$new_line"
}

cmd_tag() {
  local match="" kind="" value=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fix|--decide|--manual)
        fi_need_value tag "$1" $# "${2:-}" || return 2
        kind="${1#--}"; value="$2"; shift 2 ;;
      --fix=*|--decide=*|--manual=*)
        kind="${1%%=*}"; kind="${kind#--}"; value="${1#*=}"; shift ;;
      -h|--help)
        printf 'Usage: found-issues tag <match> --fix small|medium|large\n'
        printf '       found-issues tag <match> --decide "<question>"\n'
        printf '       found-issues tag <match> --manual "<why>"\n'
        printf 'Sets the one fix tag of the [open]/[deferred] entry matching <match>.\n'
        return 0 ;;
      -*) fi_unknown_arg tag "$1"; return 2 ;;
      *)
        [[ -z "$match" ]] || { fi_unknown_arg tag "$1"; return 2; }
        match="$1"; shift ;;
    esac
  done
  if [[ -z "$match" || -z "$kind" ]]; then
    fi_err "tag: need <match> and one of --fix / --decide / --manual (see: found-issues tag --help)"
    return 2
  fi

  local file
  file="$(fi_resolve_issues_file)"
  local -a matches=()
  local entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    [[ "$entry" =~ ^-\ \[(open|deferred)\] ]] || continue
    fi_icontains "$entry" "$match" && matches+=("$entry")
  done < <(fi_entries "$file" all 2>/dev/null || true)

  if (( ${#matches[@]} == 0 )); then
    fi_err "tag: no [open] or [deferred] entry matches \"$match\""
    return 1
  fi
  if (( ${#matches[@]} > 1 )); then
    fi_err "tag: ambiguous — ${#matches[@]} entries match \"$match\":"
    local m; for m in "${matches[@]}"; do fi_err "  $m"; done
    return 2
  fi

  local target="${matches[0]}"
  fi_parse_entry_vars "$target" || return 1
  fi_repo_root_cached
  fi_tag_resolve "$kind" "$value" "$FE_path" "$FI_REPO_ROOT" || return 2
  if [[ "$kind" == "fix" && "$FI_TAG_KIND" == "manual" ]]; then
    fi_err "tag: $FE_path is off-limits for auto-fix ($FI_TAG_VALUE) — tagged manual instead"
  fi
  local rc=0
  fi_tag_apply "$file" "$target" "$FI_TAG_KIND" "$FI_TAG_VALUE" || rc=$?
  case $rc in
    0) return 0 ;;
    3) fi_err "tag: the ledger changed while writing — re-run"; return 3 ;;
    *) fi_err "tag: the entry changed before it could be tagged — re-run"; return 1 ;;
  esac
}
```

Wire it up in `bin/found-issues` (source after `resolve.sh`; dispatch line after `resolve)`):

```bash
# shellcheck source=../lib/tag.sh
source "$FI_LIB_DIR/tag.sh"
```

```bash
    tag)              cmd_tag "$@" ;;
```

Before relying on them, confirm with `rg -n '^fi_repo_root_cached\(\)' lib/` and `rg -n '^fi_need_value\(\)' lib/` that both helpers exist with those names. They were added in v2.10.2 and v2.10.4.

In `lib/help.sh`, after the `resolve` block (~:65), add:

```
  tag <match> --fix S|M|L | --decide "<q>" | --manual "<why>"
                                        Set the entry's one fix tag (v3).
                                        Off-limits paths are tagged manual.
```

- [ ] **Step 4: Run, expect PASS**

Run: `bats tests/autofix-tags.bats tests/cli-help*.bats`
Expected: all `ok`. If a help snapshot test pins `cmd_help` output, update its fixture to include the new block.

- [ ] **Step 5: Commit**

```bash
git add lib/tag.sh bin/found-issues lib/help.sh tests/autofix-tags.bats
git commit -m "feat(v3): found-issues tag"
```

---

### Task 5: `log --fix | --decide | --manual`

**Files:**
- Modify: `lib/log.sh` (leading-flag loop ~:24-35; usage strings; open-match branch ~:200; build-entry ~:245-262)
- Test: `tests/autofix-tags.bats` (append)

**Interfaces:**
- Consumes: `fi_tag_resolve`, `fi_entry_retag`, `fi_tag_apply` (Task 4).
- Produces: `found-issues log [--critical] [--fix S|M|L | --decide Q | --manual W] "<loc> — <symptom>"`. Leading flags can come in any order.
  - A new entry is written already tagged.
  - A duplicate of an UNTAGGED open entry gets the tag applied (`Tagged: …`).
  - A duplicate of a tagged entry prints `Skipped — already logged`.

- [ ] **Step 1: Write the failing tests** (append):

```bash
@test "log: --fix writes the tag; off-limits becomes manual" {
  fi_run log --fix small "src/a.sh:1 — off by one"
  [ "$status" -eq 0 ]
  grep -qx -- "- \[open\] $(date +%Y-%m-%d) src/a.sh:1 — off by one (fix: small)" docs/found-issues.md
  printf '{}\n' > package.json && git add -A && git commit -q -m pkg
  fi_run log --critical --fix medium "package.json:1 — wrong engines field"
  [ "$status" -eq 0 ]
  grep -q '^- \[open\] \[!\] .*package.json:1 — wrong engines field (manual: off-limits: dependencies)' docs/found-issues.md
}

@test "log: --decide and --manual; flags in any order before the entry" {
  fi_run log --decide "rename or alias?" --critical "src/a.sh:2 — confusing flag name"
  [ "$status" -eq 0 ]
  grep -q '^- \[open\] \[!\] .*src/a.sh:2 — confusing flag name (decide: rename or alias?)' docs/found-issues.md
  fi_run log --manual "needs prod payload" "src/a.sh:3 — webhook parse"
  grep -q 'src/a.sh:3 — webhook parse (manual: needs prod payload)' docs/found-issues.md
  fi_run log --fix small --manual x "src/a.sh:4 — two tags"
  [ "$status" -eq 2 ]
}

@test "log: re-logging an untagged entry with a tag tags it instead of skipping" {
  fi_run log "src/a.sh:1 — off by one"
  fi_run log --fix small "src/a.sh:1 — off by one"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tagged:"* ]]
  [ "$(grep -c 'src/a.sh:1' docs/found-issues.md)" -eq 1 ]
  grep -q 'off by one (fix: small)' docs/found-issues.md
}
```

- [ ] **Step 2: Run, expect FAIL**

Run: `bats tests/autofix-tags.bats -f '^log:'`
Expected: FAIL (the flags land in the location and are rejected, or are written verbatim).

- [ ] **Step 3: Replace the `--critical`-only prologue** at the top of `cmd_log` (from `local critical="no"` through the missing-arguments check) with:

```bash
  local critical="no" tag_kind="" tag_value=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --critical) critical="yes"; shift ;;
      --fix|--decide|--manual)
        [[ -z "$tag_kind" ]] || { fi_err "found-issues log: one fix tag per entry (got $1 after --$tag_kind)"; return 2; }
        fi_need_value log "$1" $# "${2:-}" || return 2
        tag_kind="${1#--}"; tag_value="$2"; shift 2 ;;
      *) break ;;
    esac
  done

  if [[ $# -eq 0 ]]; then
    fi_err "found-issues log: missing arguments"
    fi_err "Usage: found-issues log [--critical] [--fix small|medium|large | --decide \"<q>\" | --manual \"<why>\"] <location> — <symptom>"
    return 2
  fi
```

Also replace the other `Usage: found-issues log [--critical] <location> — <symptom>` string (the missing-separator error) with the same extended usage line.

- [ ] **Step 4: Resolve the tag once the location is parsed.** Directly after the location-parsing `if/elif` chain (after the block that sets `path`, `line_num`, `line_end`, before the dedup-key comment "Key the NEW entry exactly the way the scan keys existing ones"), add:

```bash
  # v3 fix tag: validated and off-limits-checked up front so a bad value
  # writes nothing (spec §3.3, §3.5).
  if [[ -n "$tag_kind" ]]; then
    fi_repo_root_cached
    fi_tag_resolve "$tag_kind" "$tag_value" "$path" "$FI_REPO_ROOT" || return 2
    if [[ "$tag_kind" == "fix" && "$FI_TAG_KIND" == "manual" ]]; then
      fi_err "found-issues log: ${path:-this entry} is off-limits for auto-fix ($FI_TAG_VALUE) — tagged manual instead"
    fi
  fi
```

- [ ] **Step 5: Tag an untagged duplicate.** In the `if [[ "$matched_status" == "open" ]]; then` branch, immediately before the existing `printf 'Skipped — already logged: %s\n' "$matched_entry"`, add:

```bash
    if [[ -n "$tag_kind" ]]; then
      fi_parse_entry_vars "$matched_entry"
      if [[ -z "$FE_fixtag$FE_decide$FE_manual" ]]; then
        local trc=0
        fi_tag_apply "$file" "$matched_entry" "$FI_TAG_KIND" "$FI_TAG_VALUE" || trc=$?
        (( trc == 0 )) || { fi_err "found-issues log: could not tag the existing entry (rc $trc) — re-run"; return 1; }
        cmd_status plain
        return 0
      fi
    fi
```

- [ ] **Step 6: Write new entries tagged.** Replace the line `local entry="- [open]${crit_flag} $(fi_today)${location_str} — $symptom"` with:

```bash
  local entry="- [open]${crit_flag} $(fi_today)${location_str} — $symptom"
  if [[ -n "$tag_kind" ]]; then
    fi_entry_retag "$entry" "$FI_TAG_KIND" "$FI_TAG_VALUE"
    entry="$FI_RETAGGED"
  fi
```

- [ ] **Step 7: Run, expect PASS, plus the log suites**

Run: `bats tests/autofix-tags.bats tests/cli-log*.bats tests/cli-hygiene.bats`
Expected: all `ok`. The prompt-14 guard, which rejects a `--critical` that appears inside the location, still passes, because flags are consumed only before the entry argument.

- [ ] **Step 8: Commit**

```bash
git add lib/log.sh tests/autofix-tags.bats
git commit -m "feat(v3): log --fix/--decide/--manual"
```

---

### Task 6: Decision queue: `found-issues decide` and `/found-issues:decide`

**Files:**
- Create: `lib/decide.sh`, `commands/decide.md`
- Modify: `bin/found-issues` (source + dispatch `decide)`), `lib/help.sh`, `hooks/session-start.sh` (`fi_render_ledger_context`, ~:501-545)
- Generate: `codex-skills/fi-decide/SKILL.md` via `bash scripts/gen-codex-skills.sh`
- Test: `tests/autofix-tags.bats` (append), `tests/session-start.bats` (append one test)

**Interfaces:**
- Consumes: `fi_tag_apply`, `fi_tag_resolve`, `fi_parse_entry_vars`, `fi_icontains`, `fi_entries`, `fi_entry_loc`.
- Produces:
  - `found-issues decide` prints one open question per line, critical first: `<n>. [!] <loc> — <question>`. When there are none it prints `No decisions waiting.` with exit 0.
  - `found-issues decide --count` prints the integer.
  - `found-issues decide <match> --answer "<text>"` exits 0, 1 (no match), 2 (usage error or ambiguous), or 3 (entry has no open question).

- [ ] **Step 1: Write the failing tests** (append to `tests/autofix-tags.bats`):

```bash
@test "decide: lists questions critical first, counts, records answers" {
  printf -- '- [open] 2026-10-01 src/a.sh:1 — naming (decide: rename or alias?)\n- [open] [!] 2026-10-02 src/a.sh:2 — data shape (decide: keep v1 or migrate?)\n- [open] 2026-10-03 src/a.sh:3 — plain bug (fix: small)\n' > docs/found-issues.md
  fi_run decide
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "1. [!] src/a.sh:2 — keep v1 or migrate?" ]
  [ "${lines[1]}" = "2. src/a.sh:1 — rename or alias?" ]
  fi_run decide --count
  [ "$output" = "2" ]
  fi_run decide "src/a.sh:1" --answer "alias (keep old name)"
  [ "$status" -eq 0 ]
  grep -q 'naming (decided: alias \[keep old name\])' docs/found-issues.md
  ! grep -q 'rename or alias' docs/found-issues.md
  fi_run decide "plain bug" --answer x
  [ "$status" -eq 3 ]
  fi_run decide "src/a.sh" --answer x
  [ "$status" -eq 2 ]
}

@test "decide: empty queue" {
  printf -- '- [open] 2026-10-03 src/a.sh:3 — plain bug\n' > docs/found-issues.md
  fi_run decide
  [ "$status" -eq 0 ]
  [ "$output" = "No decisions waiting." ]
  fi_run decide --count
  [ "$output" = "0" ]
}
```

Append to `tests/session-start.bats`. Copy the `run env … session-start.sh` invocation shape from the nearest existing test in that file:

```bash
@test "session-start: says how many decisions are waiting" {
  mkdir -p docs
  printf -- '- [open] 2026-10-01 a.sh:1 — x (decide: A or B?)\n- [open] 2026-10-01 b.sh:1 — y (decide: C or D?)\n- [open] 2026-10-01 c.sh:1 — z\n' > docs/found-issues.md
  run env CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_ROOT="$TEST_REPO_ROOT" HOME="$TMP" bash "$TEST_REPO_ROOT/hooks/session-start.sh" </dev/null
  [[ "$output" == *"2 decisions waiting"*"/found-issues:decide"* ]]
}
```

- [ ] **Step 2: Run, expect FAIL**

Run: `bats tests/autofix-tags.bats -f '^decide' && bats tests/session-start.bats -f 'decisions waiting'`
Expected: FAIL.

- [ ] **Step 3: Implement `lib/decide.sh`**

```bash
#!/usr/bin/env bash
# decide.sh — decide — the v3 decision queue (spec 2026-10-03 §3.4)
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   cmd_decide [...]

cmd_decide() {
  local match="" answer="" count_only=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --answer) fi_need_value decide --answer $# "${2:-}" || return 2
                answer="$2"; shift 2 ;;
      --answer=*) answer="${1#--answer=}"; shift ;;
      --count) count_only=1; shift ;;
      -h|--help)
        printf 'Usage: found-issues decide                          List open questions (critical first)\n'
        printf '       found-issues decide --count                  Print how many are waiting\n'
        printf '       found-issues decide <match> --answer "<text>"  Record the answer\n'
        return 0 ;;
      -*) fi_unknown_arg decide "$1"; return 2 ;;
      *) [[ -z "$match" ]] || { fi_unknown_arg decide "$1"; return 2; }
         match="$1"; shift ;;
    esac
  done

  local file entry
  file="$(fi_resolve_issues_file)"

  if [[ -z "$match" ]]; then
    [[ -z "$answer" ]] || { fi_err "decide: --answer needs a <match>"; return 2; }
    local crit="" rest="" n=0 loc
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      fi_parse_entry_vars "$entry" || continue
      [[ -n "$FE_decide" ]] || continue
      n=$((n + 1))
      loc="$(fi_entry_loc "$entry" 2>/dev/null || printf '%s' "$FE_path")"
      if [[ "$FE_critical" == "yes" ]]; then
        crit+="[!] $loc — $FE_decide"$'\n'
      else
        rest+="$loc — $FE_decide"$'\n'
      fi
    done < <(fi_entries "$file" open 2>/dev/null || true)
    if (( count_only )); then printf '%s\n' "$n"; return 0; fi
    if (( n == 0 )); then printf 'No decisions waiting.\n'; return 0; fi
    local i=0 l
    while IFS= read -r l; do
      [[ -z "$l" ]] && continue
      i=$((i + 1)); printf '%d. %s\n' "$i" "$l"
    done <<< "${crit}${rest}"
    return 0
  fi

  [[ -n "$answer" ]] || { fi_err "decide: missing --answer \"<text>\""; return 2; }
  local -a matches=()
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    fi_icontains "$entry" "$match" && matches+=("$entry")
  done < <(fi_entries "$file" open 2>/dev/null || true)
  (( ${#matches[@]} > 0 )) || { fi_err "decide: no [open] entry matches \"$match\""; return 1; }
  if (( ${#matches[@]} > 1 )); then
    fi_err "decide: ambiguous — ${#matches[@]} entries match \"$match\":"
    local m; for m in "${matches[@]}"; do fi_err "  $m"; done
    return 2
  fi
  fi_parse_entry_vars "${matches[0]}"
  [[ -n "$FE_decide" ]] || { fi_err "decide: that entry has no open question"; return 3; }
  fi_tag_resolve decided "$answer" "" "" || return 2
  local rc=0
  fi_tag_apply "$file" "${matches[0]}" decided "$FI_TAG_VALUE" || rc=$?
  (( rc == 0 )) || { fi_err "decide: the ledger changed while writing — re-run"; return 1; }
}
```

Wire it into `bin/found-issues` (source after `tag.sh`; dispatch after `tag)`):

```bash
# shellcheck source=../lib/decide.sh
source "$FI_LIB_DIR/decide.sh"
```

```bash
    decide)           cmd_decide "$@" ;;
```

`lib/help.sh`, after the `tag` block:

```
  decide [--count] | decide <match> --answer "<text>"
                                        The decision queue: list open
                                        (decide: ...) questions, or record one.
```

- [ ] **Step 4: Add the SessionStart line.** In `hooks/session-start.sh`, inside `fi_render_ledger_context`, right after the two `if (( … omitted > 0 ))` blocks and before the final `cat <<EOF`, add:

```bash
  # v3 decision queue (spec §3.4). Fixed text + a number only, so it stays
  # outside the untrusted-data fence safely. Builtin count over the ledger
  # text read for the hook-11 gate.
  local fi_decide_ref='/found-issues:decide' __fi_dec=0 __fi_rest="$__fi_ledger_text"
  # shellcheck disable=SC2016  # $fi- is Codex's literal mention sigil
  [[ "$harness" == "codex" ]] && fi_decide_ref='$fi-decide'
  local __fi_re_dec=$'(^|\n)- \\[open\\][^\n]*\\(decide: '
  while [[ "$__fi_rest" =~ $__fi_re_dec ]]; do
    __fi_dec=$((__fi_dec + 1))
    __fi_rest="${__fi_rest#*"${BASH_REMATCH[0]}"}"
  done
  if (( __fi_dec > 0 )); then
    printf '\n%s decision%s waiting — run `%s` to answer them.\n' \
      "$__fi_dec" "$([[ $__fi_dec -eq 1 ]] && printf '' || printf 's')" "$fi_decide_ref"
  fi
```

Check: the `$( … )` plural expression forks once, and only when decisions exist. Replace it with a builtin if a fork-count test in `tests/hook-gates.bats` objects:

```bash
local __fi_s="s"; (( __fi_dec == 1 )) && __fi_s=""
```

- [ ] **Step 5: Create `commands/decide.md`**

```markdown
---
description: Answer the found-issues decision queue — entries tagged (decide: <question>) that need a human call before they can be fixed. Walks each question with options and a recommendation, then records the answer so the entry becomes fixable.
codex-description: Walk the found-issues decision queue: list [open] entries tagged (decide: <question>), present each with 2-4 options and a recommendation, and record the operator's answer with `found-issues decide <match> --answer`. Use when the operator asks to answer pending decisions or SessionStart reports decisions waiting. Not for fixing entries (that is $fi-fix).
argument-hint: (no arguments)
allowed-tools: Bash(found-issues:*), Read, Grep, AskUserQuestion
---

Walk the decision queue one question at a time.

1. Run `found-issues decide`. If it prints `No decisions waiting.`, say so and stop.
2. For each line `<n>. [!] <loc> — <question>` (critical first):
   - Read the cited code (`<loc>`) enough to frame the choice.
   - Ask the operator the question with 2–4 concrete options. Put your
     recommended option first, labelled "(Recommended)" with a one-line why.
     In Claude Code use the AskUserQuestion picker. In Codex ask in chat as a
     numbered list.
   - Record the answer exactly as chosen (free text is fine):
     `found-issues decide "<loc>" --answer "<answer>"`.
     If the match is ambiguous (exit 2), retry with a longer fragment of the
     entry. Never edit `docs/found-issues.md` by hand.
3. Finish with one line: `Answered N · Skipped M`.
```

Then regenerate the Codex skills and run the drift test:

```bash
bash scripts/gen-codex-skills.sh
bats tests/codex-skills-drift.bats
```

Expected: `codex-skills/fi-decide/SKILL.md` created; drift test `ok`.

- [ ] **Step 6: Run, expect PASS**

Run: `bats tests/autofix-tags.bats tests/session-start.bats tests/codex-skills-drift.bats tests/hook-gates.bats`
Expected: all `ok`.

- [ ] **Step 7: Commit**

```bash
git add lib/decide.sh commands/decide.md codex-skills/fi-decide bin/found-issues lib/help.sh hooks/session-start.sh tests/autofix-tags.bats tests/session-start.bats
git commit -m "feat(v3): decision queue — decide command, /found-issues:decide, SessionStart count"
```

---

### Task 7: `defer --until` and `sync` wake-ups

**Files:**
- Modify: `lib/defer.sh` (flag parsing ~:30-45; validation; flip loop ~:140-160), `lib/sync.sh` (main loop `else` at ~:407; summary ~:432-445), `hooks/session-start.sh` (hook-11 gate ~:406-412)
- Test: `tests/autofix-tags.bats` (append), `tests/session-start.bats` (append)

**Interfaces:**
- Consumes: `fi_entry_retag … drop-until`, `fi_tag_text`, `_fi_pr_info` (defined inside `cmd_sync`, sets `_fi_pr_ans` = `state\x1fbase\x1fmergedAt`).
- Produces:
  - `defer <match> --until <spec>` writes `(until: pr:o/r#N | date:YYYY-MM-DD | <text>)`.
  - `fi_until_due <until> <today>` returns 0 when due.
  - `sync` flips a due `[deferred]` entry to `[open]`, drops its `(until:)`, and reports `Woke: N`.

- [ ] **Step 1: Write the failing tests** (append to `tests/autofix-tags.bats`):

```bash
@test "defer --until: validates pr:/date:/text and writes the annotation" {
  printf -- '- [open] 2026-10-03 src/a.sh:1 — one\n- [open] 2026-10-03 src/a.sh:2 — two\n- [open] 2026-10-03 src/a.sh:3 — three\n' > docs/found-issues.md
  fi_run defer "one" --until "pr:foo/bar#12"
  [ "$status" -eq 0 ]
  grep -q 'one (until: pr:foo/bar#12)' docs/found-issues.md
  fi_run defer "two" --until "date:2026-13-45x"
  [ "$status" -eq 2 ]
  fi_run defer "two" --until "after phase 3 (auth rewrite)"
  [ "$status" -eq 0 ]
  grep -q 'two (until: after phase 3 \[auth rewrite\])' docs/found-issues.md
  fi_run defer "three" --until "pr:not-a-ref"
  [ "$status" -eq 2 ]
}

@test "sync: wakes a deferred entry whose date passed, keeps a future one" {
  printf -- '- [deferred] 2026-09-01 src/a.sh:1 — past (reason: wait) (until: date:2026-01-01)\n- [deferred] 2026-09-01 src/a.sh:2 — future (until: date:2999-01-01)\n- [deferred] 2026-09-01 src/a.sh:3 — vague (until: after the redesign)\n' > docs/found-issues.md
  FOUND_ISSUES_AUTO_ARCHIVE=off fi_run sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"Woke: 1"* ]]
  grep -qx -- '- \[open\] 2026-09-01 src/a.sh:1 — past (reason: wait)' docs/found-issues.md
  grep -q '^- \[deferred\].*future (until: date:2999-01-01)' docs/found-issues.md
  grep -q '^- \[deferred\].*vague (until: after the redesign)' docs/found-issues.md
}

@test "sync: wakes on a merged PR trigger; gh missing leaves it deferred" {
  fi_init_github_repo foo/bar main
  mkdir -p "$TMP/stub" && cat > "$TMP/stub/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "auth status"*) exit 0 ;;
  "repo view"*) echo foo/bar ;;
  "pr view 12 "*) printf 'MERGED\037main\0372026-10-01T00:00:00Z\n' ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$TMP/stub/gh"
  printf -- '- [deferred] 2026-09-01 src/a.sh:1 — after pr (until: pr:foo/bar#12)\n' > docs/found-issues.md
  PATH="$TMP/stub:$PATH" FOUND_ISSUES_AUTO_ARCHIVE=off fi_run sync
  grep -q '^- \[open\] 2026-09-01 src/a.sh:1 — after pr$' docs/found-issues.md
}

@test "sync --dry-run reports a wake-up but writes nothing" {
  printf -- '- [deferred] 2026-09-01 src/a.sh:1 — past (until: date:2026-01-01)\n' > docs/found-issues.md
  cp docs/found-issues.md "$TMP/before"
  FOUND_ISSUES_AUTO_ARCHIVE=off fi_run sync --dry-run
  [[ "$output" == *"Woke: 1"* ]]
  cmp "$TMP/before" docs/found-issues.md
}
```

Append to `tests/session-start.bats`:

```bash
@test "session-start: a deferred-only ledger with a due until-trigger still syncs" {
  mkdir -p docs
  printf -- '- [deferred] 2026-09-01 a.sh:1 — past (until: date:2026-01-01)\n' > docs/found-issues.md
  run env CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_PLUGIN_ROOT="$TEST_REPO_ROOT" FOUND_ISSUES_BIN="$TEST_REPO_ROOT/bin/found-issues" PATH="$TEST_REPO_ROOT/bin:$PATH" HOME="$TMP" bash "$TEST_REPO_ROOT/hooks/session-start.sh" </dev/null
  grep -q '^- \[open\] 2026-09-01 a.sh:1 — past$' docs/found-issues.md
}
```

(If session-start resolves its CLI some other way, copy the resolution from the existing test `session-start: no sync when the ledger has nothing [open] (hook-11)` in `tests/resource-guards.bats` and point it at the worktree's `bin/found-issues`.)

- [ ] **Step 2: Run, expect FAIL**

Run: `bats tests/autofix-tags.bats -f 'until|wake' && bats tests/session-start.bats -f 'until-trigger'`
Expected: FAIL (`unknown option '--until'`; no `Woke:`).

- [ ] **Step 3: Parse and validate `--until` in `lib/defer.sh`.** Add to the flag loop:

```bash
      --until)
        fi_need_value defer --until $# "${2:-}" || return 2
        until_spec="$2"; shift 2 ;;
      --until=*) until_spec="${1#--until=}"; shift ;;
```

Declare `local until_spec=""` next to `local mute_until=""`. After the existing mute-until validation, add:

```bash
  # v3 wake-up trigger (spec §6 step 3): pr:<owner/repo#N> and
  # date:<YYYY-MM-DD> are checked by sync; anything else is free text the
  # sweep re-judges.
  if [[ -n "$until_spec" ]]; then
    local re_until_pr='^pr:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+$'
    local re_until_date='^date:[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'
    if [[ "$until_spec" == pr:* ]]; then
      [[ "$until_spec" =~ $re_until_pr ]] || { fi_err "defer: --until pr: needs pr:<owner/repo#N>"; return 2; }
    elif [[ "$until_spec" == date:* ]]; then
      [[ "$until_spec" =~ $re_until_date ]] || { fi_err "defer: --until date: needs date:YYYY-MM-DD"; return 2; }
    else
      fi_tag_text "$until_spec" || { fi_err "defer: --until needs a one-line, non-empty trigger"; return 2; }
      until_spec="$FI_TAG_TEXT"
    fi
  fi
```

In the flip loop, after the `(mute-until: …)` append, add:

```bash
      if [[ -n "$until_spec" ]]; then
        fi_entry_retag "$new_line" drop-until ""
        new_line="$FI_RETAGGED (until: ${until_spec})"
      fi
```

Update the usage strings in `defer` to `[--reason "<text>"] [--mute-until YYYY-MM-DD] [--until pr:<o/r#N>|date:<YYYY-MM-DD>|"<text>"]` (both the help and the missing-match error).

- [ ] **Step 4: Add `fi_until_due` to `lib/autofix-tags.sh`**

```bash
# fi_until_due <until-spec> <today> — 0 when a mechanically checkable
# trigger has fired. pr: needs gh and is answered through sync's memoized
# _fi_pr_info; free text is never "due" here (the sweep re-judges it).
fi_until_due() {
  local spec="$1" today="$2"
  case "$spec" in
    date:*)
      local d="${spec#date:}"
      [[ ! "$d" > "$today" ]] ;;
    pr:*)
      declare -F _fi_pr_info >/dev/null 2>&1 || return 1
      command -v gh >/dev/null 2>&1 || return 1
      _fi_pr_info "${spec#pr:}"
      [[ "${_fi_pr_ans%%$'\x1f'*}" == "MERGED" ]] ;;
    *) return 1 ;;
  esac
}
```

- [ ] **Step 5: Wake in the sync loop.** In `lib/sync.sh`, declare `local woke=0` next to the other counters (where `closed_pr=0` is declared). Replace the loop's final branch:

```bash
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$file"
```

with:

```bash
    elif [[ "$line" == "- [deferred]"* && "$line" == *"(until: "* ]] \
         && fi_parse_entry_vars "$line" && [[ -n "$FE_until" ]] \
         && fi_until_due "$FE_until" "$today"; then
      # v3 wake-up (spec §6 step 3): the blocker is gone, so the entry is
      # actionable again. The trigger is dropped; its fix tag is kept.
      fi_entry_retag "$line" drop-until ""
      printf '%s\n' "- [open]${FI_RETAGGED#- \[deferred\]}" >>"$tmp"
      woke=$((woke + 1))
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$file"
```

In the summary block, extend the condition and append the count. Replace

```bash
  if [[ "$total_closed" -gt 0 || "$total_demoted" -gt 0 || "$renamed_count" -gt 0 ]]; then
```

with

```bash
  if [[ "$total_closed" -gt 0 || "$total_demoted" -gt 0 || "$renamed_count" -gt 0 || "$woke" -gt 0 ]]; then
```

and immediately before the line that prints `"$summary"`, add:

```bash
    (( woke > 0 )) && summary+="$(printf ' Woke: %d.' "$woke")"
```

Read the block first (`sed -n '425,465p' lib/sync.sh`) to put the line where `summary` is final. If no closures happened, the summary's first sentence is just `Synced.`, so the output becomes `Synced. Woke: 1.`

- [ ] **Step 6: Keep SessionStart from skipping a due trigger.** In `hooks/session-start.sh`, replace the hook-11 gate condition

```bash
if [[ ! "$__fi_ledger_text" =~ $__fi_re_open ]]; then
```

with

```bash
__fi_re_until=$'(^|\n)- \\[deferred\\][^\n]*\\(until: '
if [[ ! "$__fi_ledger_text" =~ $__fi_re_open && ! "$__fi_ledger_text" =~ $__fi_re_until ]]; then
```

- [ ] **Step 7: Run, expect PASS**

Run: `bats tests/autofix-tags.bats tests/session-start.bats tests/cli-defer*.bats tests/cli-sync*.bats tests/resource-guards.bats tests/hook-gates.bats`
Expected: all `ok`.

- [ ] **Step 8: Commit**

```bash
git add lib/defer.sh lib/sync.sh lib/autofix-tags.sh hooks/session-start.sh tests/autofix-tags.bats tests/session-start.bats
git commit -m "feat(v3): defer --until triggers; sync wakes due entries"
```

---

### Task 8: Teach agents to tag, docs, full verification, PR into `release/v3`

**Files:**
- Modify: `skills/rules/SKILL.md` (logging section), `docs/format-spec.md` (annotation table), `commands/log.md` (flags), `commands/defer.md` (`--until`), `README.md` (test count), `CHANGELOG.md` (only if wording changed)
- Generate: `codex-skills/*` via `bash scripts/gen-codex-skills.sh`

**Interfaces:**
- Consumes: everything above.
- Produces: agents are told to tag every new entry, and the PR into `release/v3`.

- [ ] **Step 1: Rules text.** In `skills/rules/SKILL.md`, in the section that tells agents how to log, add this block (keep it this short; SessionStart injects this file and the rules budget test guards its size):

```markdown
**Tag every entry you log** with exactly one fix tag, answering: does the fix
need a human decision, can it be done now, can a test prove it, how big is it?

- `--fix small|medium|large` — no decision needed, provable by the repo's tests.
- `--decide "<question>"` — needs the operator's call (several valid fixes,
  an interface or UX choice, anything outside the repo, irreversible steps).
- `--manual "<why>"` — no test can prove it, or it needs a live payload.
- Blocked until something happens → log it, then
  `found-issues defer "<loc>" --until pr:<owner/repo#N>|date:<YYYY-MM-DD>|"<text>"`.

Severity (`--critical`) is separate: it orders work, it never blocks a fix.
```

- [ ] **Step 2: Format spec and command docs.**
  - **`docs/format-spec.md`:** add the six annotations (`fix`, `decide`, `decided`, `manual`, `until`, `autofix-failed`), with value grammar and "not a closing token".
  - **`commands/log.md`:** document the three flags.
  - **`commands/defer.md`:** document `--until`.
  - Then regenerate and re-check:

```bash
bash scripts/gen-codex-skills.sh
bats tests/codex-skills-drift.bats tests/session-start.bats
```

Expected: `ok` (if a rules-size test fails, shorten the block above, not the existing rules).

- [ ] **Step 3: README test count**

```bash
n=$(rg -c '^@test ' tests/*.bats | awk -F: '{s+=$2} END{print s}')
sed -i '' -E "s/ [0-9]+ tests on/ $n tests on/" README.md
rg -n 'tests on' README.md
```

- [ ] **Step 4: Full suite, bash 3.2 subset, lint, version gate**

```bash
bats tests/ > /tmp/v3p1-full.txt 2>&1; echo "exit=$?"; head -1 /tmp/v3p1-full.txt; rg '^not ok' /tmp/v3p1-full.txt
PATH=/private/tmp/claude-501/b32:$PATH bash "$(command -v bats)" tests/autofix-tags.bats tests/session-start.bats tests/cli-sync.bats tests/cli-defer*.bats
shellcheck -S warning lib/autofix-tags.sh lib/tag.sh lib/decide.sh lib/log.sh lib/defer.sh lib/sync.sh hooks/session-start.sh
bash scripts/check-version.sh
```

Expected:
- the full suite exits 0 with no `not ok` lines;
- the bash 3.2 run has no `not ok`;
- shellcheck produces no NEW warnings vs `release/v3` (compare per file as in v2.10.4);
- `check-version.sh` prints MAJOR.

If `/private/tmp/claude-501/b32` is missing, recreate it: `mkdir -p /private/tmp/claude-501/b32 && ln -sf /bin/bash /private/tmp/claude-501/b32/bash`.

- [ ] **Step 5: Drive it for real (verify skill).** In a scratch repo, using the worktree CLI:
  1. `log --fix small` → `tag` → `tag --decide` → `decide` → `decide --answer`.
  2. `log --fix small` on `.github/workflows/x.yml` → shows `manual: off-limits: ci`.
  3. `defer --until date:<yesterday>` → `sync` → `Woke: 1`.
  4. Run SessionStart with two `(decide:)` entries and see the count line.

  Quote the output.

- [ ] **Step 6: Commit, push, PR into `release/v3`, watch**

```bash
git add skills/rules/SKILL.md docs/format-spec.md commands/log.md commands/defer.md codex-skills README.md
git commit -m "docs(v3): agents tag entries; format spec for fix tags"
git push -u origin v3/phase1-tags
gh pr create --base release/v3 --title "feat(v3) phase 1: fix tags and decision queue" --body "<scoreboard, evidence quoted from steps 4-5>"
gh pr merge <N> --auto --squash
```

Watch the PR checks to a terminal state (`gh pr checks <N> --watch`), then confirm the `tests` push run on `release/v3` (ubuntu and macOS) reached `success`. That push run is the only macOS / bash 3.2 CI.
