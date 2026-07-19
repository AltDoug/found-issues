# Codex Compatibility + Usage Diet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make found-issues a dual-harness (Claude Code + Codex) plugin and cut its per-session token footprint hard, with zero efficacy loss.

**Architecture:** The bash CLI stays the single engine and the committed ledger stays the single store (shared across harnesses). Three per-Bash PostToolUse hooks merge into one dispatcher that auto-annotates line-matched fixes itself (model only sees judgment cases). A new `.codex-plugin` manifest + generated `codex-skills/` + harness-aware hook output make the same repo installable in Codex.

**Tech Stack:** bash (3.2-compatible), jq, bats (tests/), gh CLI, GitHub Actions CI (Linux/macOS/Windows matrix).

**Spec:** `docs/superpowers/specs/2026-07-19-codex-compat-usage-diet-design.md` — read it before starting.

## Global Constraints

- **bash 3.2 compatible** (macOS CI ships bash 3.2): no associative arrays, no `${var,,}`, guard `set -u` against empty-array expansion (`"${arr[@]+"${arr[@]}"}"`).
- **ASCII-only bats `@test` names** (a repo guard fails the PR otherwise; em-dashes in names break Git Bash CI).
- **Windows CI (bats) takes 7–15 min** vs 2 min Linux/Mac — a task is only green when the FULL matrix passes.
- **Never write `docs/found-issues.md` by hand** — use `/found-issues:log` (the format-enforcer hook blocks malformed direct writes anyway).
- All hooks must **fail open** (exit 0, no output) when jq/gh/CLI/ledger are missing — a hook must never break a session.
- `LC_ALL=C` on every awk that processes transcript/statusline/diff content (GNU awk `towc` multibyte failures — precedent in hooks/stop-reminder.sh:110).
- Claude-side behavior of `commands/*.md` manual paths stays byte-identical unless a task says otherwise.
- Branch: `feat/codex-compat-usage-diet` (exists, off origin/main). Commit after every task.
- Version target **2.0.0** (operator's call — dual-harness pivot is a major) — but the bump happens ONLY in Task 10 (both manifests together).
- Run `bats tests/<file>.bats` locally per task; full `bats tests/` before Task 12.

---

### Task 1: `lib/harness.sh` — harness detection + context-emit helper

**Files:**
- Create: `lib/harness.sh`
- Test: `tests/harness.bats`

**Interfaces:**
- Produces: `fi_detect_harness` (stdout: `claude` | `codex`), `fi_emit_post_context <text>` (stdout: plain text on claude, `{"additionalContext": "<text>"}` JSON on codex). Consumed by Task 3 (dispatcher) and Task 8 (session-start).

Detection contract (from Codex docs, verified empirically in Task 11): Claude Code sets `CLAUDE_CODE_ENTRYPOINT` for every hook invocation; Codex plugin hooks receive `PLUGIN_DATA`/`PLUGIN_ROOT` (and legacy `CLAUDE_PLUGIN_ROOT`, which is therefore NOT discriminating). Default to `claude` (legacy behavior) when neither signal is present.

- [ ] **Step 1: Write the failing tests**

```bash
#!/usr/bin/env bats
# Tests for lib/harness.sh - harness detection and context emission

load 'helpers'

setup() {
  fi_setup_tmp
  source "$FI_LIB_DIR/harness.sh"
}

teardown() { fi_teardown_tmp; }

@test "detect: CLAUDE_CODE_ENTRYPOINT set means claude" {
  CLAUDE_CODE_ENTRYPOINT=cli PLUGIN_DATA=/tmp/x run fi_detect_harness
  [ "$output" = "claude" ]
}

@test "detect: PLUGIN_DATA without entrypoint means codex" {
  unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
  PLUGIN_DATA=/tmp/x run fi_detect_harness
  [ "$output" = "codex" ]
}

@test "detect: neither signal defaults to claude" {
  unset CLAUDE_CODE_ENTRYPOINT PLUGIN_DATA 2>/dev/null || true
  run fi_detect_harness
  [ "$output" = "claude" ]
}

@test "emit: plain text on claude" {
  CLAUDE_CODE_ENTRYPOINT=cli run fi_emit_post_context "hello world"
  [ "$output" = "hello world" ]
}

@test "emit: JSON additionalContext on codex" {
  unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
  PLUGIN_DATA=/tmp/x run fi_emit_post_context $'line1\nline "2"'
  # Valid JSON with the text round-tripping through jq
  printf '%s' "$output" | jq -e '.additionalContext' >/dev/null
  [ "$(printf '%s' "$output" | jq -r '.additionalContext')" = $'line1\nline "2"' ]
}

@test "emit: codex without jq emits nothing and exits 0" {
  unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
  # PATH with no jq
  PLUGIN_DATA=/tmp/x PATH="/usr/bin/nonexistent" run fi_emit_post_context "x"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
```

- [ ] **Step 2: Run to verify failure** — `bats tests/harness.bats` → all fail (`harness.sh: No such file`).

- [ ] **Step 3: Implement `lib/harness.sh`**

```bash
#!/usr/bin/env bash
# lib/harness.sh — which agent harness is running this hook, and how to
# emit PostToolUse context for it.
#
# Claude Code sets CLAUDE_CODE_ENTRYPOINT on every hook invocation.
# Codex plugin hooks receive PLUGIN_DATA / PLUGIN_ROOT. Codex ALSO sets
# legacy CLAUDE_PLUGIN_ROOT/CLAUDE_PLUGIN_DATA for compatibility, so those
# must never be used as discriminators. Unknown environments behave as
# claude (plain-text output — the legacy contract).
#
# NOTE: the Codex additionalContext JSON shape is isolated here on purpose;
# if empirical testing (plan Task 11) shows different nesting, this is the
# only place to fix.

fi_detect_harness() {
  if [[ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ]]; then
    printf 'claude'
  elif [[ -n "${PLUGIN_DATA:-}" ]]; then
    printf 'codex'
  else
    printf 'claude'
  fi
}

# Emit PostToolUse context text for the current harness.
# Claude Code injects plain stdout; Codex requires JSON.
fi_emit_post_context() {
  local text="$1"
  [[ -z "$text" ]] && return 0
  if [[ "$(fi_detect_harness)" == "codex" ]]; then
    command -v jq >/dev/null 2>&1 || return 0
    printf '%s' "$text" | jq -Rs '{additionalContext: .}'
  else
    printf '%s\n' "$text"
  fi
}
```

- [ ] **Step 4: Run tests** — `bats tests/harness.bats` → all PASS.
- [ ] **Step 5: Commit** — `git add lib/harness.sh tests/harness.bats && git commit -m "feat(lib): harness detection + post-context emit helper"`

---

### Task 2: CLI — diff hunk parsing, `--hook-auto` gate, exit code 3

**Files:**
- Modify: `bin/found-issues` (`fi_annotate_auto` at :1281, `cmd_annotate_pr` at :1417, `cmd_annotate_commit` — find via `rg -n 'cmd_annotate_commit\(\)' bin/found-issues`)
- Modify: `tests/bin-shims/gh` (add `pr diff` case)
- Test: `tests/cli-annotate.bats` (append), new `tests/cli-annotate-hook-auto.bats`

**Interfaces:**
- Produces: `found-issues annotate-pr <N> --hook-auto` and `found-issues annotate-commit [sha] --hook-auto`; **exit 0** = clean (annotated or no matches), **exit 3** = candidate list printed (model judgment needed), 1/2 unchanged errors. New env knob `FOUND_ISSUES_AUTO_ANNOTATE_MAX` (default 3). New helpers `fi_diff_old_ranges` (stdin: unified diff → stdout rows `path<TAB>oldstart<TAB>oldend`) and `fi_line_matched <path> <line> <ranges>`.
- Consumes: nothing new.

Semantics (spec A1): in `--hook-auto` mode an entry auto-annotates only if it is unambiguous under the EXISTING file-contest rule AND its cited line falls inside an old-side hunk range for its path. Line-less entries never auto-annotate in hook mode. If more than `FOUND_ISSUES_AUTO_ANNOTATE_MAX` entries would auto-annotate, none do (mass-touch guard) and all become candidates. Exit 3 whenever the candidate block is printed (any mode — manual mode also adopts exit 3 for its ambiguous list; `commands/annotate-pr.md` gets a one-line doc note in Task 10).

- [ ] **Step 1: Extend the gh shim with `pr diff`**

Add to the `case "$cmd $sub" in` block of `tests/bin-shims/gh` (before `*)`), and document `GH_MOCK_PR_DIFF` in the header comment:

```bash
  "pr diff")
    # Mocked unified diff for `gh pr diff <N>`. Reads GH_MOCK_PR_DIFF with
    # literal \n expanded (same convention as GH_MOCK_PR_VIEW rows).
    if [[ -n "${GH_MOCK_PR_DIFF:-}" ]]; then
      printf '%s\n' "${GH_MOCK_PR_DIFF//\\n/$'\n'}"
      exit 0
    fi
    exit 1
    ;;
```

- [ ] **Step 2: Write failing tests** — `tests/cli-annotate-hook-auto.bats`:

```bash
#!/usr/bin/env bats
# Tests for annotate-pr/annotate-commit --hook-auto (line-matched gate, cap, exit 3)

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
  fi_init_github_repo "org/repo"
  fi_use_gh_shim
  export GH_MOCK_REPO_VIEW='{"nameWithOwner":"org/repo"}'
}

teardown() { fi_teardown_tmp; }

# Diff fixture helper: one file, old-side hunk covering lines 40-45
mk_pr_mocks() {
  export GH_MOCK_PR_VIEW=$'7\tsrc/foo.py'
  export GH_MOCK_PR_DIFF='--- a/src/foo.py\n+++ b/src/foo.py\n@@ -40,6 +40,7 @@\n context'
}

@test "hook-auto: annotates entry whose cited line is inside a changed hunk" {
  fi_run log "src/foo.py:42 -- null check missing"
  mk_pr_mocks
  fi_run annotate-pr 7 --hook-auto
  [ "$status" -eq 0 ]
  grep -q 'src/foo.py:42.*(PR: org/repo#7)' docs/found-issues.md
}

@test "hook-auto: file-touched but line outside hunks becomes candidate, exit 3" {
  fi_run log "src/foo.py:99 -- wrong cast"
  mk_pr_mocks
  fi_run annotate-pr 7 --hook-auto
  [ "$status" -eq 3 ]
  ! grep -q '(PR: org/repo#7)' docs/found-issues.md
  [[ "$output" == *"src/foo.py:99"* ]]
  [[ "$output" == *"--pick"* ]]
}

@test "hook-auto: line-less abstract entry never auto-annotates" {
  fi_run log "workflow/shutdown -- sigterm kills sessions"
  export GH_MOCK_PR_VIEW=$'7\tworkflow/shutdown'
  export GH_MOCK_PR_DIFF='--- a/workflow/shutdown\n+++ b/workflow/shutdown\n@@ -1,5 +1,5 @@\n x'
  fi_run annotate-pr 7 --hook-auto
  [ "$status" -eq 3 ]
  ! grep -q '(PR:' docs/found-issues.md
}

@test "hook-auto: mass-touch cap sends everything to candidates" {
  export FOUND_ISSUES_AUTO_ANNOTATE_MAX=2
  fi_run log "src/a.py:1 -- bug a"
  fi_run log "src/b.py:1 -- bug b"
  fi_run log "src/c.py:1 -- bug c"
  export GH_MOCK_PR_VIEW=$'7\tsrc/a.py\\nsrc/b.py\\nsrc/c.py'
  export GH_MOCK_PR_DIFF='--- a/src/a.py\n+++ b/src/a.py\n@@ -1,2 +1,2 @@\n x\n--- a/src/b.py\n+++ b/src/b.py\n@@ -1,2 +1,2 @@\n x\n--- a/src/c.py\n+++ b/src/c.py\n@@ -1,2 +1,2 @@\n x'
  fi_run annotate-pr 7 --hook-auto
  [ "$status" -eq 3 ]
  ! grep -q '(PR:' docs/found-issues.md
}

@test "hook-auto: no matches at all stays silent-clean, exit 0" {
  fi_run log "src/other.py:5 -- unrelated"
  mk_pr_mocks
  fi_run annotate-pr 7 --hook-auto
  [ "$status" -eq 0 ]
  [[ "$output" == *"no [open] entries match"* ]]
}

@test "manual ambiguous list now exits 3 (was 0)" {
  fi_run log "src/foo.py:10 -- bug one"
  fi_run log "src/foo.py:20 -- bug two"
  export GH_MOCK_PR_VIEW=$'7\tsrc/foo.py'
  fi_run annotate-pr 7
  [ "$status" -eq 3 ]
  [[ "$output" == *"--pick"* ]]
}

@test "annotate-commit --hook-auto: line-matched entry annotates from git show" {
  mkdir -p src
  printf 'l1\nl2\nl3\nl4\nl5\n' > src/foo.py
  git add -A && git commit -q -m "seed"
  fi_run log "src/foo.py:3 -- bug at line 3"
  printf 'l1\nl2\nFIXED\nl4\nl5\n' > src/foo.py
  git add -A && git commit -q -m "fix"
  short_sha="$(git rev-parse --short=7 HEAD)"
  fi_run annotate-commit HEAD --hook-auto
  [ "$status" -eq 0 ]
  grep -q "src/foo.py:3.*(commit: $short_sha)" docs/found-issues.md
}
```

- [ ] **Step 3: Run to verify failure** — `bats tests/cli-annotate-hook-auto.bats` → failures on unknown flag `--hook-auto`.

- [ ] **Step 4: Implement in `bin/found-issues`**

4a. Add the two helpers directly above `fi_annotate_auto` (:1281):

```bash
# fi_diff_old_ranges — stdin: unified diff; stdout: "path<TAB>start<TAB>end"
# per hunk, OLD-side line ranges. Ledger entries cite pre-fix locations, so
# the old side is the side that corresponds to the cited line numbers.
# Pure-addition hunks (old length 0) produce no range — a fix that only adds
# lines never auto-annotates (conservative by design).
fi_diff_old_ranges() {
  LC_ALL=C awk '
    /^--- / {
      p = $2
      sub(/^a\//, "", p)
      cur = (p == "/dev/null" ? "" : p)
      next
    }
    /^@@ / {
      if (cur == "") next
      split($2, m, ",")
      a = substr(m[1], 2) + 0
      b = (m[2] != "" ? m[2] + 0 : 1)
      if (b > 0) printf "%s\t%d\t%d\n", cur, a, a + b - 1
    }
  '
}

# fi_line_matched <path> <line> <ranges> — 0 iff <path>:<line> falls inside
# any old-side range. Path comparison mirrors the entry/touched-file rule
# used in fi_annotate_auto (exact or suffix match either way).
fi_line_matched() {
  local p="$1" ln="$2" ranges="$3"
  [[ -z "$ln" || -z "$ranges" ]] && return 1
  local rp rs re
  while IFS=$'\t' read -r rp rs re; do
    [[ -z "$rp" ]] && continue
    if [[ "$rp" == "$p" || "$rp" == */"$p" || "$p" == */"$rp" ]]; then
      if (( ln >= rs && ln <= re )); then
        return 0
      fi
    fi
  done <<<"$ranges"
  return 1
}
```

4b. Extend `fi_annotate_auto` — signature gains `$8 = hook_auto` (`yes`/`no`) and `$9 = old_ranges`:

- In **pass 1** (candidate collection), no change.
- In **pass 2** (partition), when `hook_auto == yes`, a candidate goes to `auto_set` only if it passes the existing `shared == 0` test AND `fi_line_matched "$e_path_of_i" "$e_line_of_i" "$old_ranges"`. Store `cand_paths[i]`/`cand_lnums[i]` arrays in pass 1 alongside the existing `cand_locs` to make this available (path = `e_path`, lnum = `e_line`, may be empty). Otherwise it joins `ambig_indices`.
- After pass 2, add the cap guard:

```bash
  if [[ "$hook_auto" == "yes" ]]; then
    local max_auto="${FOUND_ISSUES_AUTO_ANNOTATE_MAX:-3}"
    local auto_count
    auto_count="$(printf '%s' "$auto_set" | grep -c '^-' || true)"
    if (( auto_count > max_auto )); then
      # Mass-touch guard: a sweep PR line-matches everything (2026-07-09
      # incident shape). Annotate nothing; surface all as candidates.
      auto_set=""
      ambig_indices=()
      for (( i = 0; i < ${#cand_lines[@]}; i++ )); do
        ambig_indices+=("$i")
      done
    fi
  fi
```

- At the end, replace `return 0` with:

```bash
  if (( ${#ambig_indices[@]+"${#ambig_indices[@]}"} > 0 )); then
    return 3
  fi
  return 0
```

(Keep the bash-3.2 `set -u` guard pattern shown; verify the file's existing array idioms and match them.)

4c. `cmd_annotate_pr`: parse `--hook-auto` into `hook_auto=yes`; when set, after fetching touched files also run `old_ranges="$(gh pr diff "$pr_num" 2>/dev/null | fi_diff_old_ranges)"` (empty ranges are fine — nothing line-matches, everything surfaces). Thread both new args into the `fi_annotate_auto` call and propagate its return with `|| return $?` (the file runs under `set -e`; an unguarded non-zero return would abort instead of propagating).

4d. `cmd_annotate_commit`: same flag; ranges from `git show --format= "$sha" | fi_diff_old_ranges`.

4e. Update the CLI `--help` text for both subcommands: one line each — `--hook-auto  stricter auto mode used by the PostToolUse hook (line-matched only, capped); exits 3 when candidates need --pick`.

- [ ] **Step 5: Run tests** — `bats tests/cli-annotate-hook-auto.bats tests/cli-annotate.bats` → PASS (the pre-existing annotate tests must still pass unchanged EXCEPT any that asserted exit 0 on the ambiguous list — update those to expect 3).
- [ ] **Step 6: Commit** — `git commit -m "feat(cli): --hook-auto line-matched annotation gate, exit 3 for candidate lists"`

---

### Task 3: One PostToolUse dispatcher replacing three hooks

**Files:**
- Create: `hooks/post-bash-dispatch.sh`
- Modify: `hooks/hooks.json` (one PostToolUse Bash entry instead of three)
- Delete: `hooks/post-pr-create.sh`, `hooks/post-git-commit.sh`, `hooks/post-pr-state.sh`
- Test: create `tests/post-bash-dispatch.bats`; port assertions from `tests/post-pr-state.bats` into it, then delete `tests/post-pr-state.bats`

**Interfaces:**
- Consumes: `found-issues annotate-pr <N> --hook-auto` / `annotate-commit <sha> --hook-auto` (Task 2, exit 3 contract), `lib/harness.sh::fi_emit_post_context` (Task 1).
- Produces: the plugin's only PostToolUse hook. Env knob `FOUND_ISSUES_AUTO_ANNOTATE=off` → legacy prompt-only behavior (old post-pr-create/post-git-commit scan+prompt, moved verbatim into `legacy_pr_prompt()` / `legacy_commit_prompt()` functions). `FOUND_ISSUES_POST_PR_STATE=off` keeps its existing meaning for the merge/close/reopen route.

- [ ] **Step 1: Write failing tests** — `tests/post-bash-dispatch.bats`. Reuse the payload-builder pattern from `tests/post-pr-state.bats` (read it first; keep its `FOUND_ISSUES_AUTOSYNC_CMD` marker technique). Core new tests:

```bash
#!/usr/bin/env bats
# Tests for hooks/post-bash-dispatch.sh routing and auto-annotation

load 'helpers'

HOOK="$TEST_REPO_ROOT/hooks/post-bash-dispatch.sh"

setup() {
  fi_setup_tmp
  fi_init_git
  fi_init_github_repo "org/repo"
  fi_use_gh_shim
  export GH_MOCK_REPO_VIEW='{"nameWithOwner":"org/repo"}'
  export FOUND_ISSUES_BIN="$FI_BIN"
  export CLAUDE_CODE_ENTRYPOINT=cli
}

teardown() { fi_teardown_tmp; }

payload() { # $1=command $2=stdout
  jq -n --arg c "$1" --arg s "$2" \
    '{tool_name:"Bash", tool_input:{command:$c}, tool_response:{stdout:$s, exit_code:"0"}}'
}

@test "pr create: line-matched entry auto-annotates, one-line report" {
  fi_run log "src/foo.py:42 -- null check"
  export GH_MOCK_PR_VIEW=$'7\tsrc/foo.py'
  export GH_MOCK_PR_DIFF='--- a/src/foo.py\n+++ b/src/foo.py\n@@ -40,6 +40,7 @@\n x'
  run bash -c "$(payload 'gh pr create --fill' 'https://github.com/org/repo/pull/7') | '$HOOK'"
  [ "$status" -eq 0 ]
  grep -q '(PR: org/repo#7)' docs/found-issues.md
  [[ "$output" == *"auto-annotated"* ]]
  [[ "$output" != *"--pick"* ]]
}

@test "pr create: unmatched-line candidates surface with pick instruction" {
  fi_run log "src/foo.py:99 -- wrong cast"
  export GH_MOCK_PR_VIEW=$'7\tsrc/foo.py'
  export GH_MOCK_PR_DIFF='--- a/src/foo.py\n+++ b/src/foo.py\n@@ -40,6 +40,7 @@\n x'
  run bash -c "$(payload 'gh pr create' 'https://github.com/org/repo/pull/7') | '$HOOK'"
  [ "$status" -eq 0 ]
  ! grep -q '(PR:' docs/found-issues.md
  [[ "$output" == *"found-issues annotate-pr 7 --pick"* ]]
}

@test "pr create: FOUND_ISSUES_AUTO_ANNOTATE=off falls back to legacy prompt" {
  export FOUND_ISSUES_AUTO_ANNOTATE=off
  fi_run log "src/foo.py:42 -- null check"
  export GH_MOCK_PR_VIEW=$'7\tsrc/foo.py'
  run bash -c "$(payload 'gh pr create' 'https://github.com/org/repo/pull/7') | '$HOOK'"
  [ "$status" -eq 0 ]
  ! grep -q '(PR:' docs/found-issues.md
  [[ "$output" == *"/found-issues:annotate-pr 7"* ]]
}

@test "git commit: line-matched entry auto-annotates" {
  mkdir -p src
  printf 'l1\nl2\nl3\n' > src/foo.py
  git add -A && git commit -q -m seed
  fi_run log "src/foo.py:2 -- bug"
  printf 'l1\nFIX\nl3\n' > src/foo.py
  git add -A && git commit -q -m fix
  run bash -c "$(payload 'git commit -m fix' '') | '$HOOK'"
  [ "$status" -eq 0 ]
  grep -q '(commit:' docs/found-issues.md
}

@test "unrelated bash command: silent exit 0" {
  run bash -c "$(payload 'ls -la' '') | '$HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pr merge: dispatches background sync via FOUND_ISSUES_AUTOSYNC_CMD" {
  marker="$TMP/sync-ran"
  export FOUND_ISSUES_AUTOSYNC_CMD="touch '$marker'"
  run bash -c "$(payload 'gh pr merge 7 --squash' '') | '$HOOK'"
  [ "$status" -eq 0 ]
  for i in 1 2 3 4 5; do [ -f "$marker" ] && break; sleep 1; done
  [ -f "$marker" ]
}

@test "codex harness: candidate surface is additionalContext JSON" {
  unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
  export PLUGIN_DATA="$TMP/plugdata"
  fi_run log "src/foo.py:99 -- wrong cast"
  export GH_MOCK_PR_VIEW=$'7\tsrc/foo.py'
  export GH_MOCK_PR_DIFF='--- a/src/foo.py\n+++ b/src/foo.py\n@@ -40,6 +40,7 @@\n x'
  run bash -c "$(payload 'gh pr create' 'https://github.com/org/repo/pull/7') | '$HOOK'"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.additionalContext' >/dev/null
}
```

Also port every test from `tests/post-pr-state.bats` (merge/close/reopen matching, `time gh pr merge` chaining, opt-out, argv-not-bash-c) against `$HOOK`.

- [ ] **Step 2: Run to verify failure** — `bats tests/post-bash-dispatch.bats` → hook not found.

- [ ] **Step 3: Implement `hooks/post-bash-dispatch.sh`**

```bash
#!/usr/bin/env bash
# post-bash-dispatch.sh — the plugin's single PostToolUse(Bash) hook.
#
# Routes on the executed command:
#   gh pr create            → auto-annotate line-matched entries (--hook-auto);
#                             surface candidates needing model judgment
#   git commit              → same, against HEAD (--hook-auto)
#   gh pr merge|close|reopen→ background `found-issues sync` (statusline
#                             freshness; moved verbatim from post-pr-state.sh)
#
# Replaces post-pr-create.sh, post-git-commit.sh, post-pr-state.sh (v2.0.0):
# one process + one jq parse per Bash call instead of three.
#
# Exit code: 0 always (additive; never blocks).
# Output: via fi_emit_post_context (plain text on Claude, JSON on Codex).
# Opt-outs: FOUND_ISSUES_AUTO_ANNOTATE=off (prompt-only legacy behavior),
#           FOUND_ISSUES_POST_PR_STATE=off (skip merge-route sync).

set -euo pipefail

input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0

get_field() {
  printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null || true
}

tool_name="$(get_field '.tool_name')"
[[ "$tool_name" != "Bash" ]] && exit 0
cmd="$(get_field '.tool_input.command')"
[[ -z "$cmd" ]] && exit 0

# --- shared resolution (same chain as the retired hooks) ---
__fi_hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
FI_BIN="${FOUND_ISSUES_BIN:-found-issues}"
if ! command -v "$FI_BIN" >/dev/null 2>&1; then
  if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -x "$CLAUDE_PLUGIN_ROOT/bin/found-issues" ]]; then
    FI_BIN="$CLAUDE_PLUGIN_ROOT/bin/found-issues"
  elif [[ -x "$__fi_hook_dir/../bin/found-issues" ]]; then
    FI_BIN="$__fi_hook_dir/../bin/found-issues"
  else
    exit 0
  fi
fi
lib_dir="${FOUND_ISSUES_LIB_DIR:-$__fi_hook_dir/../lib}"
[[ -f "$lib_dir/harness.sh" ]] && source "$lib_dir/harness.sh"

# ============ route: gh pr merge/close/reopen → background sync ============
if [[ "$cmd" =~ (^|[[:space:];|&])gh[[:space:]]+pr[[:space:]]+(merge|close|reopen)([[:space:]]|$) ]]; then
  if [[ "${FOUND_ISSUES_POST_PR_STATE:-on}" != "off" ]]; then
    if [[ -n "${FOUND_ISSUES_AUTOSYNC_CMD:-}" ]]; then
      ( bash -c "$FOUND_ISSUES_AUTOSYNC_CMD" >/dev/null 2>&1 & ) >/dev/null 2>&1
    else
      ( "$FI_BIN" sync >/dev/null 2>&1 & ) >/dev/null 2>&1
    fi
  fi
  exit 0
fi

# ============ route: gh pr create → annotate ============
if [[ "$cmd" == *"gh pr create"* ]]; then
  stdout="$(get_field '.tool_response.stdout')"
  pr_num=""
  if [[ "$stdout" =~ /pull/([0-9]+) ]]; then
    pr_num="${BASH_REMATCH[1]}"
  fi
  [[ -z "$pr_num" ]] && exit 0

  if [[ "${FOUND_ISSUES_AUTO_ANNOTATE:-on}" == "off" ]]; then
    legacy_pr_prompt "$pr_num"   # defined below; verbatim old post-pr-create body
    exit 0
  fi

  out="$("$FI_BIN" annotate-pr "$pr_num" --hook-auto 2>/dev/null)" && rc=0 || rc=$?
  if [[ "$rc" -eq 0 && "$out" == *"Annotated"* ]]; then
    fi_emit_post_context "found-issues: ${out%%$'\n'*} (line-matched by the PR diff). Entries updated in the ledger — no action needed unless one looks wrong."
  elif [[ "$rc" -eq 3 ]]; then
    fi_emit_post_context "## found-issues — PR #$pr_num needs annotation judgment

$out

Compare each candidate's symptom against what the PR actually changes, then run:
  found-issues annotate-pr $pr_num --pick <path:line>[,...]
(or --all only if the PR genuinely addresses every candidate). Entries the PR does not fix must NOT be annotated — they would false-flip to [fixed] on merge."
  fi
  exit 0
fi

# ============ route: git commit → annotate ============
if [[ "$cmd" =~ (^|[^A-Za-z_])git[[:space:]]+commit($|[^-A-Za-z_]) ]]; then
  exit_code="$(get_field '.tool_response.exit_code')"
  [[ -n "$exit_code" && "$exit_code" != "0" ]] && exit 0
  git rev-parse --git-dir >/dev/null 2>&1 || exit 0

  if [[ "${FOUND_ISSUES_AUTO_ANNOTATE:-on}" == "off" ]]; then
    legacy_commit_prompt
    exit 0
  fi

  out="$("$FI_BIN" annotate-commit HEAD --hook-auto 2>/dev/null)" && rc=0 || rc=$?
  if [[ "$rc" -eq 0 && "$out" == *"Annotated"* ]]; then
    fi_emit_post_context "found-issues: ${out%%$'\n'*} (line-matched by the commit diff)."
  elif [[ "$rc" -eq 3 ]]; then
    fi_emit_post_context "## found-issues — commit needs annotation judgment

$out

If this commit addresses any candidate, run the printed --pick command; otherwise ignore."
  fi
  exit 0
fi

exit 0
```

Then define `legacy_pr_prompt()` and `legacy_commit_prompt()` ABOVE the routing block, containing the matching-scan + prompt bodies of the deleted `post-pr-create.sh` (lines 55–124) and `post-git-commit.sh` (lines 55–end) **moved verbatim** (they source `lib/parse-entries.sh`; keep their own silent-exit guards). Note bash requires function definitions before use — place them after the shared-resolution block.

- [ ] **Step 4: Update `hooks/hooks.json`** — replace the three PostToolUse Bash entries with one:

```json
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/post-bash-dispatch.sh"
          }
        ]
      }
    ],
```

- [ ] **Step 5: Delete old hooks + old test file** — `git rm hooks/post-pr-create.sh hooks/post-git-commit.sh hooks/post-pr-state.sh tests/post-pr-state.bats`
- [ ] **Step 6: Run** — `bats tests/post-bash-dispatch.bats` → PASS; then `bats tests/` full local run (other suites must not reference deleted hooks — `rg 'post-pr-create|post-git-commit|post-pr-state' tests/ docs/ README.md` and fix references).
- [ ] **Step 7: Commit** — `git commit -m "feat(hooks): single PostToolUse dispatcher with hook-auto annotation"`

---

### Task 4: Compress the always-on rules skill

**Files:**
- Modify: `skills/rules/SKILL.md` (full replacement below)
- Test: `tests/docs-consistency.bats` (add a size-budget test)

- [ ] **Step 1: Add failing size test** to `tests/docs-consistency.bats`:

```bash
@test "rules skill stays under the 3.5KB injection budget" {
  size=$(wc -c < "$TEST_REPO_ROOT/skills/rules/SKILL.md")
  [ "$size" -le 3584 ]
}
```

- [ ] **Step 2: Run to verify failure** — current file is ~8.6KB.

- [ ] **Step 3: Replace `skills/rules/SKILL.md` body** with exactly:

```markdown
---
description: Rules governing how AI agents maintain docs/found-issues.md — what to log, when to annotate after PR/commit, sync responsibility, branch deletion guard, dead code handling. Auto-loaded every session via the found-issues plugin.
disable-model-invocation: true
---

# found-issues — agent rules

<!-- loc-override: single auto-loaded ruleset consumed as ONE context unit by the plugin spec; splitting into multiple skills changes what gets injected per session -->

**Issues found and not tracked are issues lost.** When you notice a defect outside your current task scope, log it — never dismiss it as "pre-existing" or "not my code." The user logs nothing; you maintain `docs/found-issues.md` on their behalf, always via the commands below, never via direct Write/Edit.

## Logging

`/found-issues:log <path:line> — <symptom> (suggested: <fix>)` — `--critical` for drop-everything items; an abstract topic may replace `path:line`.

- **Log:** demonstrable bugs; off-task errors/warnings in test/build/log output; nameable race conditions; security defects; dead code (zero call sites); misleading docs; broken contracts.
- **Don't log:** style nits; "could be cleaner"; known deprecations; existing TODOs; things you fixed in-task; third-party bugs; speculation without a concrete symptom; unmeasured perf hypotheticals; duplicates (the command dedups on path:line).
- When in doubt, log — false positives get cleaned at sync; false negatives are silent.

## Annotation after PR / commit

A hook auto-runs annotation after `gh pr create` and `git commit`: entries whose cited line the diff modifies are annotated automatically and reported in one line. Your job is ONLY the judgment cases the hook surfaces — a candidate list means the CLI could not decide. Compare each candidate's symptom against what the PR/commit actually changes, then run the printed `found-issues annotate-pr <N> --pick <loc>,...` (`--all` only when it genuinely addresses every candidate). Never annotate entries the PR does not fix — they false-flip to `[fixed]` on merge. Do not defer; unannotated entries can never auto-close. Hook didn't fire (web-UI PR)? Run `/found-issues:annotate-pr <N>` manually.

## Sync

On `/found-issues:sync`, for each unannotated `[open]` entry: read the code at `path:line`; decide still-present / fixed / unclear; flip only fixed → `[fixed] (verified: ai) (fixed: <today>)`. Be conservative — a false flip is worse than a stale open. Deleted files auto-close via tombstone; judging rewritten-but-still-present code is YOUR pass.

## Branch deletion

Before deleting any branch, consolidate its `[open]` entries missing from main: `/found-issues:promote`. The pre-delete hook blocks otherwise.

## Stop-hook marker (if enabled)

Every substantive turn includes exactly one HTML comment:
`<!-- found-issues-checked: none-noticed -->` | `logged` | `deferred` (rare; say why).

## Dead code

Zero importers → do not edit, do not delete. Log with prefix `dead code:`, then find the actually-live component via the route/page that triggered the symptom and continue there.

## Format (full spec: docs/format-spec.md)

`- [open] [!] YYYY-MM-DD path/file.ext:42 — symptom (suggested: fix)`
Statuses `[open]`/`[deferred]`/`[fixed]`; `[!]` = critical; ` — ` em-dash with spaces; `(PR: org/repo#N)` / `(commit: <sha>)` added by annotation; `(fixed: YYYY-MM-DD)` added by sync.

## Hard rules (no single-turn override)

1. Never write `docs/found-issues.md` directly — commands only.
2. Never delete `[open]` entries.
3. Never mark `[fixed]` without verification (annotation match, tombstone, or AI-verified sync).
4. Never bypass the pre-branch-delete check — run promote first.
```

- [ ] **Step 4: Run** — size test PASS; `bats tests/docs-consistency.bats` fully green (fix any other doc-consistency assertions that referenced removed phrases).
- [ ] **Step 5: Commit** — `git commit -m "perf(skills): compress always-on rules skill 8.6KB -> ~3.3KB"`

---

### Task 5: Session-start injection cap

**Files:**
- Modify: `hooks/session-start.sh` (the injection block, currently :269–315)
- Test: `tests/session-start.bats` (append)

**Interfaces:**
- Produces: env knob `FOUND_ISSUES_SESSION_INJECT_MAX` (default 15). Criticals (`[!]`) always shown; then the NEWEST non-critical entries (last in ledger order — the file is append-ordered) up to the cap; then `…and M more [open] entries — run \`found-issues list\` for the full ledger.`

- [ ] **Step 1: Failing tests** (append to `tests/session-start.bats`, matching its existing hook-invocation pattern — read the file's setup first):

```bash
@test "session-start: caps injected entries and reports the remainder" {
  export FOUND_ISSUES_SESSION_INJECT_MAX=3
  for i in 1 2 3 4 5 6; do
    fi_run log "src/f$i.py:$i -- bug $i"
  done
  run_session_start_hook   # existing helper in this file; reuse it
  [ "$status" -eq 0 ]
  [[ "$output" == *"src/f6.py:6"* ]]   # newest kept
  [[ "$output" != *"src/f1.py:1"* ]]   # oldest dropped
  [[ "$output" == *"and 3 more [open] entries"* ]]
}

@test "session-start: criticals always injected even over the cap" {
  export FOUND_ISSUES_SESSION_INJECT_MAX=2
  fi_run log --critical "src/sec.py:1 -- token leak"
  for i in 1 2 3 4; do fi_run log "src/f$i.py:$i -- bug $i"; done
  run_session_start_hook
  [[ "$output" == *"src/sec.py:1"* ]]
}

@test "session-start: at-or-under cap output unchanged (no remainder line)" {
  fi_run log "src/a.py:1 -- bug"
  run_session_start_hook
  [[ "$output" != *"more [open] entries"* ]]
}
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement** — in `session-start.sh`, after `open_entries` is built, replace direct injection with:

```bash
# Cap injection: criticals always; then the newest non-critical entries up
# to FOUND_ISSUES_SESSION_INJECT_MAX; a count line covers the remainder.
max_inject="${FOUND_ISSUES_SESSION_INJECT_MAX:-15}"
crit_entries="$(printf '%s\n' "$open_entries" | grep -F '[!]' || true)"
noncrit_entries="$(printf '%s\n' "$open_entries" | grep -Fv '[!]' || true)"
crit_count=0; [[ -n "$crit_entries" ]] && crit_count="$(printf '%s\n' "$crit_entries" | grep -c '^-' || true)"
noncrit_count=0; [[ -n "$noncrit_entries" ]] && noncrit_count="$(printf '%s\n' "$noncrit_entries" | grep -c '^-' || true)"
slots=$(( max_inject - crit_count ))
(( slots < 0 )) && slots=0
shown_noncrit=""
if (( noncrit_count > 0 && slots > 0 )); then
  shown_noncrit="$(printf '%s\n' "$noncrit_entries" | tail -n "$slots")"
fi
omitted=$(( noncrit_count - slots ))
(( omitted < 0 )) && omitted=0
injected_entries="$crit_entries"
if [[ -n "$shown_noncrit" ]]; then
  [[ -n "$injected_entries" ]] && injected_entries+=$'\n'
  injected_entries+="$shown_noncrit"
fi
```

and inject `$injected_entries` inside the existing fenced block, appending after the fence when `omitted > 0`:

```bash
…and $omitted more [open] entries — run \`found-issues list\` for the full ledger.
```

- [ ] **Step 4: Run** — new tests PASS, all pre-existing `session-start.bats` tests still PASS.
- [ ] **Step 5: Commit** — `git commit -m "perf(hooks): cap session-start entry injection (criticals always)"`

---

### Task 6: Codex plugin manifest + version-lockstep check

**Files:**
- Create: `.codex-plugin/plugin.json`
- Test: `tests/check-version.bats` (append)

- [ ] **Step 1: Failing test** (append; mirror the file's existing style):

```bash
@test "codex and claude plugin manifests carry the same version" {
  cv="$(jq -r .version "$TEST_REPO_ROOT/.codex-plugin/plugin.json")"
  av="$(jq -r .version "$TEST_REPO_ROOT/.claude-plugin/plugin.json")"
  [ "$cv" = "$av" ]
}

@test "codex manifest points skills at codex-skills and hooks at hooks.json" {
  [ "$(jq -r .skills "$TEST_REPO_ROOT/.codex-plugin/plugin.json")" = "./codex-skills" ]
  [ "$(jq -r .hooks  "$TEST_REPO_ROOT/.codex-plugin/plugin.json")" = "./hooks/hooks.json" ]
}
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Create `.codex-plugin/plugin.json`** (version matches the CURRENT `.claude-plugin` version — 1.7.1 for now; both bump together in Task 10):

```json
{
  "name": "found-issues",
  "version": "1.7.1",
  "description": "Markdown-based issue tracker for AI agents. The agent logs out-of-scope issues it spots while working; entries auto-flip to fixed on PR merge or commit-fix.",
  "author": {
    "name": "AltDoug",
    "url": "https://github.com/AltDoug"
  },
  "homepage": "https://github.com/AltDoug/found-issues",
  "repository": "https://github.com/AltDoug/found-issues",
  "license": "MIT",
  "keywords": ["issues", "tracking", "todo", "markdown", "agents", "found-issues"],
  "skills": "./codex-skills",
  "hooks": "./hooks/hooks.json"
}
```

- [ ] **Step 4: Run tests** — PASS. **Step 5: Commit** — `git commit -m "feat(codex): plugin manifest + version lockstep test"`

---

### Task 7: Generated Codex skills + drift check

**Files:**
- Create: `scripts/gen-codex-skills.sh`, `codex-skills/` (generated, checked in)
- Test: `tests/codex-skills-drift.bats`

**Interfaces:**
- Produces: `codex-skills/fi-<command>/SKILL.md` for each of the 13 `commands/*.md`, names `fi-log`, `fi-annotate-pr`, etc. Claude Code must never scan `codex-skills/` (it reads `skills/`; the Codex manifest points at `./codex-skills` — Task 6).

- [ ] **Step 1: Failing drift test** — `tests/codex-skills-drift.bats`:

```bash
#!/usr/bin/env bats
# Generated codex-skills/ must exactly match scripts/gen-codex-skills.sh output

load 'helpers'

@test "codex-skills are up to date with commands" {
  tmp="$(mktemp -d -t fi-drift.XXXXXX)"
  cp -R "$TEST_REPO_ROOT/commands" "$tmp/commands"
  cp "$TEST_REPO_ROOT/scripts/gen-codex-skills.sh" "$tmp/"
  mkdir -p "$tmp/scripts" && mv "$tmp/gen-codex-skills.sh" "$tmp/scripts/"
  (cd "$tmp" && bash scripts/gen-codex-skills.sh)
  diff -r "$tmp/codex-skills" "$TEST_REPO_ROOT/codex-skills"
  rm -rf "$tmp"
}

@test "every command has a generated codex skill" {
  for cmd in "$TEST_REPO_ROOT"/commands/*.md; do
    name="$(basename "$cmd" .md)"
    [ -f "$TEST_REPO_ROOT/codex-skills/fi-$name/SKILL.md" ]
  done
}

@test "codex skills contain no claude-only slash references" {
  ! grep -r '/found-issues:' "$TEST_REPO_ROOT/codex-skills"
  ! grep -r '\$ARGUMENTS' "$TEST_REPO_ROOT/codex-skills"
}
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement `scripts/gen-codex-skills.sh`**

```bash
#!/usr/bin/env bash
# gen-codex-skills.sh — regenerate codex-skills/ from commands/*.md.
# Codex discovers skills as <dir>/SKILL.md with name/description frontmatter;
# slash-command syntax and $ARGUMENTS are Claude-only and get rewritten.
# Output is CHECKED IN; tests/codex-skills-drift.bats fails the build when
# commands change without a regeneration.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

rm -rf codex-skills
mkdir -p codex-skills

for cmd in commands/*.md; do
  name="$(basename "$cmd" .md)"
  desc="$(LC_ALL=C awk '/^description:/ { sub(/^description:[ ]*/, ""); print; exit }' "$cmd")"
  mkdir -p "codex-skills/fi-$name"
  {
    printf -- '---\n'
    printf 'name: fi-%s\n' "$name"
    printf 'description: %s\n' "$desc"
    printf -- '---\n\n'
    # Body = everything after the closing frontmatter fence, with Claude-only
    # syntax rewritten for Codex.
    LC_ALL=C awk 'c >= 2 { print } /^---$/ { c++ }' "$cmd" \
      | sed -E \
          -e 's|/found-issues:([a-z-]+)|the fi-\1 skill|g' \
          -e 's|\$ARGUMENTS|the argument the user provided (for example the PR number)|g'
  } > "codex-skills/fi-$name/SKILL.md"
done

printf 'generated %s codex skills\n' "$(ls codex-skills | wc -l | tr -d ' ')"
```

Run it once: `bash scripts/gen-codex-skills.sh && git add codex-skills scripts/gen-codex-skills.sh`.

- [ ] **Step 4: Run tests** — PASS. Manually spot-read `codex-skills/fi-annotate-pr/SKILL.md` and `fi-log/SKILL.md` for rewrite artifacts (broken sentences from the sed); fix the sed table if needed and regenerate.
- [ ] **Step 5: Commit** — `git commit -m "feat(codex): generate codex skills from commands with drift check"`

---

### Task 8: Session-start harness awareness (Codex rules injection, skip Claude-only nudges)

**Files:**
- Modify: `hooks/session-start.sh`
- Test: `tests/session-start.bats` (append)

**Interfaces:**
- Consumes: `lib/harness.sh::fi_detect_harness` (Task 1); `skills/rules/SKILL.md` body (Task 4) as the single rules source.
- Produces: on Codex — compact rules block ALWAYS injected (before any ledger-existence early-exit), Claude-only sections skipped (first-run onboarding hint, statusline self-heal nudge, statusline shim auto-migration — all target `~/.claude/`). On Claude — byte-identical behavior to today.

- [ ] **Step 1: Failing tests:**

```bash
@test "session-start on codex: injects rules block even with no ledger" {
  unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
  export PLUGIN_DATA="$TMP/pd"
  run_session_start_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *"found-issues — agent rules"* ]]
}

@test "session-start on codex: skips statusline nudge and onboarding hint" {
  unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
  export PLUGIN_DATA="$TMP/pd"
  rm -f "$HOME/.claude/found-issues/.onboarded" 2>/dev/null || true
  run_session_start_hook
  [[ "$output" != *"/found-issues:setup"* ]]
  [[ "$output" != *"statusline"* ]]
}

@test "session-start on claude: does NOT inject the rules block (skill owns it)" {
  export CLAUDE_CODE_ENTRYPOINT=cli
  run_session_start_hook
  [[ "$output" != *"found-issues — agent rules"* ]]
}
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement** — near the top of `session-start.sh` (after `set -euo pipefail`):

```bash
__fi_hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
harness=claude
if [[ -f "$__fi_hook_dir/../lib/harness.sh" ]]; then
  source "$__fi_hook_dir/../lib/harness.sh"
  harness="$(fi_detect_harness)"
fi

# Codex has no auto-loaded-skill mechanism: the rules ship here instead.
# (On Claude Code the skills/rules skill injects them — emitting here too
# would double-pay the tokens.) SessionStart stdout is plain-text context
# on both harnesses.
if [[ "$harness" == "codex" ]]; then
  __fi_rules="${PLUGIN_ROOT:-$__fi_hook_dir/..}/skills/rules/SKILL.md"
  if [[ -f "$__fi_rules" ]]; then
    LC_ALL=C awk 'c >= 2 { print } /^---$/ { c++ }' "$__fi_rules"
    printf '\n'
  fi
fi
```

Then wrap the three Claude-only blocks (first-run onboarding hint; broken-statusline nudge; custom-target auto-migration) in `if [[ "$harness" == "claude" ]]; then … fi`. The existing `__fi_hook_dir` assignment further down (:118) becomes redundant — remove the duplicate. Everything from CLI resolution onward (sync + ledger injection) runs on BOTH harnesses unchanged.

- [ ] **Step 4: Run** — new + all existing session-start tests PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(codex): session-start injects rules on codex, skips claude-only nudges"`

---

### Task 9: Stop-reminder — Codex fail-open + ledger note

**Files:**
- Modify: `hooks/stop-reminder.sh`
- Test: `tests/stop-reminder.bats` (append)

- [ ] **Step 1: Failing test:**

```bash
@test "stop-reminder: codex harness exits 0 without reading stdin transcript" {
  unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
  export PLUGIN_DATA="$TMP/pd"
  run bash -c "printf '{}' | '$TEST_REPO_ROOT/hooks/stop-reminder.sh'"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run to verify failure** (currently empty entrypoint = treated as cli = proceeds to transcript logic).
- [ ] **Step 3: Implement** — insert directly after the existing `CLAUDE_CODE_ENTRYPOINT` skip block (:42–44):

```bash
# Codex v1: the marker discipline is Claude-only. Codex transcripts use a
# different rollout format the smart-fire parser below does not understand,
# and a Stop block it can't satisfy burns full-context turns. Fail open.
if [[ -z "${CLAUDE_CODE_ENTRYPOINT:-}" && -n "${PLUGIN_DATA:-}" ]]; then
  exit 0
fi
```

- [ ] **Step 4: Run** — `bats tests/stop-reminder.bats` all PASS.
- [ ] **Step 5: Log the limitation** — run `/found-issues:log codex-stop-marker — stop-hook marker discipline is fail-open on Codex v1 (transcript format unparsed) (suggested: port smart-fire to Codex rollout format)` so the follow-up is tracked.
- [ ] **Step 6: Commit** — `git commit -m "feat(codex): stop-reminder fails open on codex v1"`

---

### Task 10: Docs, AGENTS.md rewrite, CHANGELOG, version bump

**Files:**
- Modify: `AGENTS.md` (replace the "If the user is NOT using Claude Code" section), `README.md` (install section), `docs/architecture.md`, `docs/modes.md`, `docs/faq.md`, `docs/configuration.md` (new env knobs), `commands/annotate-pr.md` + `commands/annotate-commit.md` (exit-3 note + hook-auto mention), `CHANGELOG.md`, `.claude-plugin/plugin.json` + `.codex-plugin/plugin.json` (both → `2.0.0`)
- Test: existing `tests/check-version.bats` + `tests/docs-consistency.bats` keep everything honest; regenerate codex-skills after the command-doc edits (`bash scripts/gen-codex-skills.sh`).

- [ ] **Step 1: `AGENTS.md`** — replace the entire "If the user is NOT using Claude Code" section with:

```markdown
## Installing for Codex

found-issues is dual-harness: the same plugin installs into OpenAI Codex.

```
codex plugin marketplace add AltDoug/claude-plugins
codex plugin install found-issues
```

Then start a new Codex session. The SessionStart hook injects the agent
rules and any open ledger entries; skills are available as `fi-log`,
`fi-sync`, `fi-status`, etc. (explicitly via `$fi-log` mentions or
implicitly by description match).

The ledger is the same committed `docs/found-issues.md` in either harness —
a repo worked on from both Claude Code and Codex shares one ledger with no
migration or sync step. Known v1 limitations on Codex: no statusline
counter (Codex has no statusline surface) and the stop-hook marker
discipline is inactive (documented in the ledger).

## Other agents (Cursor, Aider, plain API)

The markdown format is portable — see
<https://github.com/AltDoug/found-issues/blob/main/docs/format-spec.md> —
but hooks and skills require Claude Code or Codex.
```

Also update the intro line ("This is a Claude Code plugin") to "This is a dual-harness plugin for Claude Code and OpenAI Codex", and mirror the uninstall-order warning for Codex (`fi-uninstall` skill before `codex plugin uninstall`).

- [ ] **Step 2: `README.md`** — add a `### Codex` subsection under install with the same two commands + shared-ledger sentence.
- [ ] **Step 3: `docs/configuration.md`** — document `FOUND_ISSUES_AUTO_ANNOTATE` (`off` = legacy prompt-only), `FOUND_ISSUES_AUTO_ANNOTATE_MAX` (default 3), `FOUND_ISSUES_SESSION_INJECT_MAX` (default 15).
- [ ] **Step 4: `commands/annotate-pr.md` / `annotate-commit.md`** — add under "When to invoke": "The post-bash dispatcher hook normally handles this automatically (`--hook-auto`: line-matched entries annotate silently; exit 3 surfaces candidates). This command is the manual fallback for web-UI PRs or when hooks are disabled." Then `bash scripts/gen-codex-skills.sh`.
- [ ] **Step 5: `docs/architecture.md`** — add a "Harness adapters" paragraph (one engine/CLI + ledger; Claude adapter = commands + auto-loaded skill; Codex adapter = codex-skills + SessionStart rules injection; hook payloads shared; output via lib/harness.sh). `docs/modes.md` + `docs/faq.md`: shared-ledger FAQ entry + no-Codex-statusline note.
- [ ] **Step 6: `CHANGELOG.md`** — add `## 2.0.0` with the two workstreams (Codex support; hook-auto annotation + injection caps + rules compression; new env knobs; exit-3 contract; removed hooks listed by name; BREAKING note: three PostToolUse hooks replaced by one dispatcher, annotate exit-3 contract).
- [ ] **Step 7: Bump both manifests to `2.0.0`.** Run `bats tests/check-version.bats tests/docs-consistency.bats tests/codex-skills-drift.bats` → PASS.
- [ ] **Step 8: Commit** — `git commit -m "docs+release: dual-harness docs, changelog, bump 2.0.0"`

---

### Task 11: Empirical end-to-end verification (both harnesses)

No new files — this task validates and, where reality differs from docs, fixes Tasks 1/3/8 assumptions. Evidence goes in the PR description verbatim.

- [ ] **Step 1: Full local suite** — `bats tests/` → all green (record count).
- [ ] **Step 2: Claude-side E2E** (verify skill recipe): scratch repo under the scratchpad dir, seed a ledger entry citing a line, make a fix touching that line, `git commit` through a simulated PostToolUse payload piped to `hooks/post-bash-dispatch.sh` with `CLAUDE_CODE_ENTRYPOINT=cli`, confirm: annotation applied, one-line plain-text report, no candidate block. Then a NON-matching fix → candidate block with `--pick` instruction.
- [ ] **Step 3: Codex-side E2E** on this machine (Codex CLI is installed — verify with `codex --version`):
  - Add a personal marketplace entry at `~/.agents/plugins/marketplace.json` pointing at this checkout (consult `codex plugin --help` for the exact `source.path` schema; the fetched docs show `"source.path": "./plugins/my-plugin"` relative form — record what actually works).
  - `codex plugin install found-issues`; new Codex session in the scratch repo.
  - Verify: (a) rules text present in context (ask the model to quote a hard rule), (b) `$fi-log` skill invocable, (c) after a scripted `gh pr create` — or a direct PostToolUse simulation if driving gh is impractical — the JSON `additionalContext` is ACCEPTED (not ignored): the model references the injected candidate text. If ignored, capture the correct shape from Codex's hook debug output and fix `fi_emit_post_context` (the shape lives ONLY there), re-run.
  - Verify shared ledger: open the same scratch repo in Claude Code, confirm the entry logged from Codex appears in session-start injection.
- [ ] **Step 4: Fix-forward** any discrepancies found, with tests where representable, and commit each fix atomically.
- [ ] **Step 5: Commit** — `git commit -m "test: e2e verification fixes (claude + codex drives)"` (only if fixes were needed).

---

### Task 12: Adversarial review, ship, marketplace PR

- [ ] **Step 1:** Push branch; run the adversarial review workflow (`/code-review` at high effort on the branch diff) — established practice caught 10 real defects on the last release branch. Fix confirmed findings, commit.
- [ ] **Step 2:** Full `bats tests/` again after fixes.
- [ ] **Step 3:** `gh pr create` — title `feat: dual-harness Codex support + usage diet (v2.0.0)`; body: spec link, usage-diet expectations (what became zero-round-trip vs still model-judged), E2E evidence from Task 11, known Codex v1 limitations. End body with the standard generated-with footer.
- [ ] **Step 4:** The post-bash dispatcher will now fire on our own `gh pr create` — review its output; if it surfaces candidates for the entries this PR addresses, run the printed `--pick` command (dogfood moment).
- [ ] **Step 5:** Watch CI to FULL matrix green (Windows bats 7–15 min; use /loop if the wait spans turns).
- [ ] **Step 6:** After merge: marketplace PR in `AltDoug/claude-plugins` — read that repo's existing `.claude-plugin/marketplace.json` first, add the Codex-native `.agents/plugins/marketplace.json` equivalent entry + bump found-issues to 2.0.0 in the Claude marketplace file. Source-repo PR merges FIRST, marketplace PR second (established release coupling).

---

## Self-review notes (already applied)

- Spec A1 hunk-gate is implemented in Task 2 (old-side ranges — entries cite pre-fix lines; pure additions never match: conservative).
- Exit-3 propagation guarded against `set -e` (`|| return $?` / `&& rc=0 || rc=$?`).
- `codex-skills/` isolation from Claude's `skills/` scan is enforced by the Task 6 manifest test.
- Claude-side manual command semantics untouched except the documented exit-3 change.
- All new env knobs documented in Task 10 Step 3.
