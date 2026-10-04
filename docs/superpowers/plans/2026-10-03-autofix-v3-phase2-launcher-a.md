# Auto-fix v3 — Phase 2: Queue, Claim, Ship and Launcher A — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** With `found-issues.autofix=true`, `found-issues log --fix small '<loc> — <symptom>'` queues the entry, and `found-issues autofix run <id>` produces a merged-when-green fix PR: claim, worktree, a headless fixer child (Claude or Codex), bash test run, a read-only verifier child, then commit, push, PR, ledger annotation and auto-merge. Every unhappy path leaves the ledger in a defined state. No hook launches anything yet; that is Phase 3.

**Architecture:**
- **Five new libraries:**
  - `lib/autofix-config.sh`: settings, kill switch, state paths, test-command detection, engine choice.
  - `lib/autofix-queue.sh`: queue items, lock, caps, crash reaping, claim, and release/finish (the only ledger writer here).
  - `lib/autofix-engine.sh`: the child runner with its wall-clock watchdog, allowlist, prompts, result/verdict/cost parsing.
  - `lib/autofix-ship.sh`: diff, ledger reset, test runner, ship, merge arming, merge-when-green.
  - `lib/autofix.sh`: `cmd_autofix` dispatcher, the `run` orchestrator, `status`.
- **The bash CLI owns every git, gh and ledger write.** Engine children only edit files in the worktree and end with an `FI-RESULT:` line. This is a deliberate deviation from spec §4.5/§5, where the child calls `autofix release`: the Codex `workspace-write` sandbox cannot write the state dir or the source checkout's ledger, so one contract for both engines keeps lifecycle in bash. Phase 3's launcher B still calls `autofix claim/diff/ship/release` from its agent, and this phase exposes those subcommands.
- **Tests run end to end at zero cost:**
  - stand-in `claude`/`codex` binaries in `tests/standins/`;
  - the `gh` shim, extended with `pr create` and `pr merge`;
  - a local bare remote reached through `url.<bare>.insteadOf`.

**Tech Stack:** bash 3.2+ (macOS system bash), bats, git worktrees, jq, `gh`, `claude -p` (Claude Code 2.1.289), `codex exec` (codex-cli 0.159.0).

**Spec:** `docs/superpowers/specs/2026-10-03-autofix-v3-design.md`. This plan implements §4.1 (`AUTOFIX-QUEUED` only; `AUTOFIX-SWEEP-DUE` is Phase 4), §4.5, §5, §7 (spot-fix cap, run budget, turn cap), §8 (kill switch, settings resolution, run logs), §9 (Codex engine), §10 (the Phase 2 test rows), and §11 phase 2.

**Phase index:** plan 2 of 6. Phase 1 shipped tags, `tag`, `decide` and `until:` (PR #186, squash 54a4214 on `release/v3`).

## Live facts this plan pins (measured 2026-10-03, this Mac)

**Allowlist syntax** (Claude Code 2.1.289, `claude -p --permission-mode dontAsk --permission-prompts none`, haiku probes at $0.08 and $0.10):
- `Bash(pa:*)` and `Bash(pb *)` both allow `pa x` / `pb x`.
- `Bash(pc)` allows `pc` and **denies** `pc x`.
- A multi-word prefix works: `Bash(pe sub:*)` allows `pe sub y` and denies `pe other`.
- Compound commands are denied even when every part is allowed: `pa x && pd y`, `pa x; pd z`, `cd /tmp && pa q`.
- Denials come back in `.permission_denials[].tool_input.command`, with no prompt.
- The spike's "`Bash(cat:*)` did not apply" is not a syntax problem. A plain custom binary behaves as above.

**CLI surfaces:**
- `--allowedTools <tools...>` is **variadic**: a positional prompt placed right after it would be swallowed as a tool name. The prompt must follow another flag (`--output-format json`).
- `--max-turns` is accepted but not listed in `--help`.
- `--effort <level>` exists.
- macOS has no `timeout` binary, so the watchdog is bash.
- `git remote get-url origin` expands `url.*.insteadOf`. `git config --get remote.origin.url` returns the configured URL.
- `codex exec` takes `--sandbox read-only|workspace-write`, `-C`, `--ephemeral`, `--json` (JSONL events), `-o <last-message-file>` and `--output-schema <file>`. It has no budget or turn flag.

## Global Constraints

- **Bash 3.2 compatible:**
  - no `declare -A`, `${var,,}`, `mapfile` or `$EPOCHSECONDS`-only code;
  - guard `"${arr[@]}"` on empty arrays under `set -u`;
  - `printf -v` is allowed.
- **Every file-fed read loop** is `while IFS= read -r line || [[ -n "$line" ]]; do … done <"$file"`. `tests/source-guards.bats` scans `lib/*.sh`. The only process-substitution producer exempt from the guard is `fi_entries`.
- **Ledger writes** go only through `fi_ledger_snapshot` → `fi_ledger_tmp` → `fi_ledger_replace`, or through `fi_tag_apply`. Autofix writes only the ledger the entry lives in: the item's `root` (source checkout), plus the worktree's own ledger in `ship`.
- **State lives in `${FOUND_ISSUES_STATE_DIR:-$HOME/.claude/found-issues}/autofix/<owner>__<repo>/`:**
  - `queue/<id>`, `running/<id>`, `done/<id>` (`key=value` item files);
  - `lock/` (an atomic `mkdir`);
  - `day/<YYYY-MM-DD>.spot` (one line per claim);
  - `disabled`, a kill-switch file at the `autofix/` root.
- **Run logs** live in `${FOUND_ISSUES_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/found-issues}/autofix/<owner>__<repo>/runs/` (spec §8).
- **Settings come from git config.** Local overrides global (git does this natively). Phase 2 reads:
  - `found-issues.autofix` (bool);
  - `found-issues.autofix.engine` (`auto|claude|codex`, default `auto`);
  - `.testCommand`;
  - `.dailyFixes` (default `5`);
  - `.runBudget` (default `2`, USD);
  - `.runTimeoutMin` (default `20`, a Phase 2 addition: Codex has no budget flag).
- **Kill switches:** `FOUND_ISSUES_AUTOFIX=off` and `found-issues autofix off`.
- **Off-limits and tag rules** are Phase 1's. Never bypass `fi_tag_resolve`.
- **Fixer and verifier invocation:**
  - Claude fixer: `--model sonnet`, `--max-turns 40`.
  - Claude verifier: `--model opus --effort high`, `--max-turns 15`, `--allowedTools Read Grep Glob`.
  - Both: `--permission-mode dontAsk --permission-prompts none --no-session-persistence --output-format json`, with the prompt as the last argument.
  - Codex fixer: `--sandbox workspace-write`. Codex verifier: `--sandbox read-only -c model_reasoning_effort=high`.
- **Fixer branches** are `fi/autofix/<loc-slug>-<id>`. Worktrees live at `<root>/.claude/worktrees/fi-autofix-<id>`, cut from `origin/<default>` after `git fetch`.
- **At most 2 attempts per item.** The worktree is reset to `origin/<default>` between attempts. A failure tags `(autofix-failed: <reason>)`, which is never claimed again.
- **Fix PRs always arm auto-merge** (`gh pr merge <N> --auto --squash`), falling back to a detached `autofix merge-when-green <N>`.
- **Source the CLI at most once per test shell.** `source "$FI_BIN"` a second time fails on `readonly FI_VERSION` (verified 2026-10-03). `fi_af_queue_fixture` sources it, so tests whose setup calls it never source again.
- bats test names are ASCII only. Version stays `3.0.0`. Changes append to the `## [3.0.0] - unreleased` CHANGELOG section.
- **Work location:** worktree `/Users/diogosilvasena/Documents/projects/found-issues/.claude/worktrees/v3-docs`, branch `v3/phase2-launcher-a`, cut from `release/v3` at ebfbbab. The PR base is `release/v3`.

## Review Focus

1. **The variadic `--allowedTools` swallowing the prompt.** A reordering of the argv that puts the prompt directly after the tool list makes the child run with no prompt. The argv-pinning test in Task 5 asserts that the prompt is the last argument and that `--output-format json` sits between the tools and the prompt.
2. **An entry logged in the working tree but never committed to `origin/<default>`.** This is the common case. The worktree ledger lacks the entry, and `fi_find_issues_file` called from inside the worktree walks UP into the source checkout's ledger. `ship` must not annotate or `git add` a path outside the worktree. It annotates the source ledger instead and succeeds: test in Task 6.
3. **The headless child edits the worktree ledger.** The user's found-issues SessionStart sync runs in the child, and the fixer may touch the ledger. Those edits must never reach the fix commit or the verifier's diff: test in Task 6, where the stand-in edits the ledger too.
4. **Two `autofix run` processes for the same repo** (Phase 3's hook plus its Stop fallback). Exactly one claims. The other exits 4 with the item still queued, and nothing is orphaned: test in Task 3.
5. **A run killed mid-flight** leaves `running/<id>` and `lock/` behind. The next claim reaps it: requeue once, then `(autofix-failed: crashed)`. A lock older than 60 minutes is broken: test in Task 3.


## Deferred to later phases (spec items this plan does not build)

- **Phase 3:**
  - the PostToolUse hook that reads `AUTOFIX-QUEUED` and picks a launcher;
  - launcher B and the plugin agents;
  - the Stop-hook claim fallback;
  - the `agent_id` half of the recursion guard;
  - `claim` recording the claimer's pid for in-session fixers.
- **Phase 4:**
  - the sweep, `AUTOFIX-SWEEP-DUE` and the sweep cap;
  - `/found-issues:fix` on this plumbing;
  - `--cwd` consistency (prompt-8);
  - the headless SessionStart guard (prompt-11).
- **Phase 5:**
  - `autofix cancel` (process-group kill);
  - the statusline `🔧N`/`❓N`;
  - the full `autofix status` with PR links;
  - the SessionStart summary, setup disclosure, `doctor` section and `found-issues config`;
  - live E2E against real GitHub.

---

### Task 1: Settings, kill switch, state paths, test command, engine

**Files:**
- Create: `lib/autofix-config.sh`
- Create: `lib/autofix.sh` (dispatcher skeleton: `on`, `off`, `--help`)
- Modify: `bin/found-issues` (source the two libs, dispatch `autofix`, `fi_repo_id` insteadOf fallback)
- Test: `tests/autofix-config.bats`

**Interfaces:**
- Consumes: `fi_repo_id`, `fi_err`, `fi_unknown_arg` (existing).
- Produces:
  - `fi_af_cfg <key> <default>` → stdout.
  - `fi_af_int <key> <default>` → stdout, a positive int.
  - `fi_af_budget` → stdout, a USD decimal.
  - `fi_af_root` → sets `FI_AF_ROOT`.
  - `fi_af_enabled` → 0/1, sets `FI_AF_WHY`.
  - `fi_af_dirs <owner/repo>` → sets `FI_AF_ST`, `FI_AF_RUNS` and creates the dirs.
  - `fi_af_context` → sets `FI_AF_SLUG` + dirs, returns 1 outside GitHub.
  - `fi_af_test_command <dir>` → stdout, or returns 1.
  - `fi_af_engine [<explicit>]` → stdout `claude|codex`, or returns 1.
  - `cmd_autofix <sub> …`.

- [ ] **Step 1: Branch** (already cut during planning; verify)

```bash
cd /Users/diogosilvasena/Documents/projects/found-issues/.claude/worktrees/v3-docs
git branch --show-current   # v3/phase2-launcher-a
git log --oneline -1 release/v3   # ebfbbab
```

- [ ] **Step 2: Write the failing tests** in `tests/autofix-config.bats`:

```bash
#!/usr/bin/env bats
# v3 auto-fix settings, kill switch, test command and engine (spec §5.3, §8, §9).

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
  export FOUND_ISSUES_STATE_DIR="$TMP/state"
  export HOME="$TMP/home"; mkdir -p "$HOME"
  unset FOUND_ISSUES_AUTOFIX CLAUDECODE
}
teardown() { fi_teardown_tmp; }

src() {
  source "$FI_BIN"
}

@test "autofix config: disabled until found-issues.autofix is true" {
  git remote add origin https://github.com/foo/bar.git
  src
  run fi_af_enabled
  [ "$status" -eq 1 ]
  git config found-issues.autofix true
  run fi_af_enabled
  [ "$status" -eq 0 ]
}

@test "autofix config: a local false overrides a global true" {
  git remote add origin https://github.com/foo/bar.git
  git config --global found-issues.autofix true
  git config found-issues.autofix false
  src
  run fi_af_enabled
  [ "$status" -eq 1 ]
}

@test "autofix config: FOUND_ISSUES_AUTOFIX=off and the kill switch both win over true" {
  git remote add origin https://github.com/foo/bar.git
  git config found-issues.autofix true
  src
  FOUND_ISSUES_AUTOFIX=off run fi_af_enabled
  [ "$status" -eq 1 ]
  run "$FI_BIN" autofix off
  [ "$status" -eq 0 ]
  [ -e "$TMP/state/autofix/disabled" ]
  run fi_af_enabled
  [ "$status" -eq 1 ]
  run "$FI_BIN" autofix on
  [ ! -e "$TMP/state/autofix/disabled" ]
  run fi_af_enabled
  [ "$status" -eq 0 ]
}

@test "autofix config: no GitHub origin means disabled" {
  git config found-issues.autofix true
  src
  run fi_af_enabled
  [ "$status" -eq 1 ]
}

@test "autofix config: fi_repo_id survives an insteadOf rewrite to a local path" {
  git remote add origin https://github.com/foo/bar.git
  git config url."$TMP/bare.git".insteadOf https://github.com/foo/bar.git
  src
  run fi_repo_id
  [ "$status" -eq 0 ]
  [ "$output" = "foo/bar" ]
}

@test "autofix config: integer settings fall back on garbage" {
  src
  [ "$(fi_af_int dailyFixes 5)" = 5 ]
  git config found-issues.autofix.dailyFixes 3
  [ "$(fi_af_int dailyFixes 5)" = 3 ]
  git config found-issues.autofix.dailyFixes lots
  run fi_af_int dailyFixes 5
  [ "${lines[${#lines[@]}-1]}" = 5 ]
  git config found-issues.autofix.runBudget 1.5
  [ "$(fi_af_budget)" = 1.5 ]
  git config found-issues.autofix.runBudget '$2'
  run fi_af_budget
  [ "${lines[${#lines[@]}-1]}" = 2 ]
}

@test "autofix config: dirs are per repo under the state and cache roots" {
  src
  fi_af_dirs foo/bar
  [ "$FI_AF_ST" = "$TMP/state/autofix/foo__bar" ]
  [ -d "$FI_AF_ST/queue" ] && [ -d "$FI_AF_ST/running" ] && [ -d "$FI_AF_ST/done" ] && [ -d "$FI_AF_ST/day" ]
  [[ "$FI_AF_RUNS" == */autofix/foo__bar/runs ]]
  [ -d "$FI_AF_RUNS" ]
}

@test "autofix config: test command - explicit setting wins" {
  mkdir -p tests && touch tests/a.bats
  git config found-issues.autofix.testCommand 'make check'
  src
  [ "$(fi_af_test_command "$TMP")" = "make check" ]
}

@test "autofix config: test command detection order bats npm pytest go cargo make" {
  src
  run fi_af_test_command "$TMP"
  [ "$status" -eq 1 ]
  printf 'test:\n\techo ok\n' > Makefile
  [ "$(fi_af_test_command "$TMP")" = "make test" ]
  touch Cargo.toml
  [ "$(fi_af_test_command "$TMP")" = "cargo test" ]
  touch go.mod
  [ "$(fi_af_test_command "$TMP")" = "go test ./..." ]
  touch pytest.ini
  [ "$(fi_af_test_command "$TMP")" = "pytest" ]
  printf '{\n  "scripts": {\n    "test": "vitest run"\n  }\n}\n' > package.json
  [ "$(fi_af_test_command "$TMP")" = "npm test" ]
  mkdir -p tests && touch tests/x.bats
  [ "$(fi_af_test_command "$TMP")" = "bats tests/" ]
}

@test "autofix config: npm's placeholder test script is not a test command" {
  printf '{ "scripts": { "test": "echo \\"Error: no test specified\\" && exit 1" } }\n' > package.json
  src
  run fi_af_test_command "$TMP"
  [ "$status" -eq 1 ]
}

@test "autofix config: a Makefile without a test target is not a test command" {
  printf 'build:\n\techo hi\n' > Makefile
  src
  run fi_af_test_command "$TMP"
  [ "$status" -eq 1 ]
}

@test "autofix config: engine - explicit, setting, then the calling harness" {
  src
  [ "$(fi_af_engine codex)" = codex ]
  git config found-issues.autofix.engine claude
  [ "$(fi_af_engine)" = claude ]
  git config found-issues.autofix.engine auto
  CLAUDECODE=1 run fi_af_engine
  [ "$output" = claude ]
  CODEX_THREAD_ID=x PATH="/usr/bin:/bin" run fi_af_engine
  [ "$output" = codex ]
}
```

- [ ] **Step 3: Run to confirm failure**

Run: `bats tests/autofix-config.bats`
Expected: FAIL — `fi_af_enabled: command not found` / `Unknown command: autofix`.

- [ ] **Step 4: Fix `fi_repo_id` for insteadOf remotes.** In `bin/found-issues`, replace the first four lines of `fi_repo_id`'s body:

```bash
fi_repo_id() {
  local remote_url
  remote_url="$(git remote get-url origin 2>/dev/null || true)"
  if [[ "$remote_url" != *"github.com"* ]]; then
    # get-url expands url.<x>.insteadOf; the configured URL still names the
    # GitHub repo (a mirror or a local bare remote in tests).
    remote_url="$(git config --get remote.origin.url 2>/dev/null || true)"
    [[ "$remote_url" == *"github.com"* ]] || return 1
  fi
```

(The rest of the function is unchanged.)

- [ ] **Step 5: Create `lib/autofix-config.sh`**

```bash
#!/usr/bin/env bash
# autofix-config.sh — v3 auto-fix settings, kill switch, state paths, test
# command and engine (spec 2026-10-03 §5 step 3, §7, §8, §9).
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   fi_af_cfg <key> <default>
#   fi_af_int <key> <default>
#   fi_af_budget
#   fi_af_root
#   fi_af_enabled
#   fi_af_dirs <owner/repo>
#   fi_af_context
#   fi_af_test_command <dir>
#   fi_af_engine [<explicit>]

FI_AF_ROOT="" FI_AF_WHY="" FI_AF_ST="" FI_AF_RUNS="" FI_AF_SLUG=""

# git config reads global then local, so a per-repo value overrides.
fi_af_cfg() {
  local v
  v="$(git config --get "found-issues.autofix.$1" 2>/dev/null || true)"
  printf '%s' "${v:-$2}"
}

fi_af_int() {
  local v
  v="$(fi_af_cfg "$1" "$2")"
  if [[ ! "$v" =~ ^[0-9]+$ ]] || (( 10#$v < 1 )); then
    fi_err "found-issues: found-issues.autofix.$1=$v is not a positive integer — using $2"
    v="$2"
  fi
  printf '%s' "$((10#$v))"
}

fi_af_budget() {
  local v
  v="$(fi_af_cfg runBudget 2)"
  if [[ ! "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    fi_err "found-issues: found-issues.autofix.runBudget=$v is not a USD amount — using 2"
    v=2
  fi
  printf '%s' "$v"
}

fi_af_root() {
  FI_AF_ROOT="${FOUND_ISSUES_STATE_DIR:-$HOME/.claude/found-issues}/autofix"
}

# On: the toggle is true here, nothing switched it off, and origin is on
# GitHub (v3.0.0 is GitHub-PR-mode only, spec §2).
fi_af_enabled() {
  FI_AF_WHY=""
  case "${FOUND_ISSUES_AUTOFIX:-}" in
    off|0|false|no) FI_AF_WHY="FOUND_ISSUES_AUTOFIX=off"; return 1 ;;
  esac
  fi_af_root
  if [[ -e "$FI_AF_ROOT/disabled" ]]; then
    FI_AF_WHY="switched off (found-issues autofix on)"; return 1
  fi
  local v
  v="$(git config --type=bool --get found-issues.autofix 2>/dev/null || true)"
  [[ "$v" == "true" ]] || { FI_AF_WHY="found-issues.autofix is not true"; return 1; }
  fi_repo_id >/dev/null 2>&1 || { FI_AF_WHY="origin is not a GitHub repo"; return 1; }
}

fi_af_dirs() {
  local key="${1//\//__}"
  fi_af_root
  FI_AF_ST="$FI_AF_ROOT/$key"
  FI_AF_RUNS="${FOUND_ISSUES_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/found-issues}/autofix/$key/runs"
  mkdir -p "$FI_AF_ST/queue" "$FI_AF_ST/running" "$FI_AF_ST/done" "$FI_AF_ST/day" "$FI_AF_RUNS"
}

fi_af_context() {
  FI_AF_SLUG="$(fi_repo_id 2>/dev/null)" || { fi_err "autofix: not in a GitHub repo"; return 1; }
  fi_af_dirs "$FI_AF_SLUG"
}

# _fi_af_has <file> <literal> — 0 if any line contains the literal.
_fi_af_has() {
  local line
  [[ -f "$1" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *"$2"* ]] && return 0
  done <"$1"
  return 1
}

# npm's generated placeholder ("no test specified") is not a test command.
_fi_af_npm_test() {
  local line re='"test"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
  [[ -f "$1" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $re ]]; then
      [[ "${BASH_REMATCH[1]}" != *"no test specified"* ]]
      return
    fi
  done <"$1"
  return 1
}

_fi_af_make_test() {
  local line
  [[ -f "$1" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == test:* ]] && return 0
  done <"$1"
  return 1
}

# Spec §5 step 3: the setting, else the first marker that matches.
fi_af_test_command() {
  local d="$1" cmd f
  cmd="$(git -C "$d" config --get found-issues.autofix.testCommand 2>/dev/null || true)"
  if [[ -n "$cmd" ]]; then printf '%s' "$cmd"; return 0; fi
  for f in "$d"/tests/*.bats; do
    [[ -f "$f" ]] && { printf 'bats tests/'; return 0; }
  done
  _fi_af_npm_test "$d/package.json" && { printf 'npm test'; return 0; }
  if [[ -f "$d/pytest.ini" || -f "$d/conftest.py" ]] \
     || _fi_af_has "$d/pyproject.toml" '[tool.pytest' \
     || _fi_af_has "$d/setup.cfg" '[tool:pytest]'; then
    printf 'pytest'; return 0
  fi
  [[ -f "$d/go.mod" ]] && { printf 'go test ./...'; return 0; }
  [[ -f "$d/Cargo.toml" ]] && { printf 'cargo test'; return 0; }
  _fi_af_make_test "$d/Makefile" && { printf 'make test'; return 0; }
  return 1
}

# Spec §9: engine=auto follows the calling harness. Phase 3's hook passes
# the harness explicitly; this fallback serves log-time queueing and a
# hand-run `autofix run`.
fi_af_engine() {
  local e="${1:-}"
  [[ -n "$e" ]] || e="$(fi_af_cfg engine auto)"
  case "$e" in
    claude|codex) printf '%s' "$e"; return 0 ;;
    auto) ;;
    *) fi_err "found-issues: found-issues.autofix.engine=$e (want auto, claude or codex) — using auto" ;;
  esac
  if [[ -n "${CLAUDECODE:-}" ]]; then printf 'claude'; return 0; fi
  if [[ -n "$(compgen -v CODEX_ 2>/dev/null || true)" ]]; then printf 'codex'; return 0; fi
  command -v claude >/dev/null 2>&1 && { printf 'claude'; return 0; }
  command -v codex >/dev/null 2>&1 && { printf 'codex'; return 0; }
  return 1
}
```

- [ ] **Step 6: Create `lib/autofix.sh`** (later tasks add subcommands to the `case`)

```bash
#!/usr/bin/env bash
# autofix.sh — the `autofix` subcommand family (spec 2026-10-03 §4-§8).
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   cmd_autofix <sub> [...]

_fi_af_usage() {
  cat <<'EOF'
Usage: found-issues autofix <command>
  on | off                    Clear or set the kill switch (all repos)
  status                      Queue, running, today's count, recent results
  run <id> [--engine claude|codex]
                              Fix a queued item headlessly, then the rest of the queue
  claim <id>                  Take a queued item: lock, cap, worktree (prints its path)
  diff <id>                   The claimed item's change against origin/<default>
  ship <id>                   Test, commit, push, open the PR, annotate, arm auto-merge
  release <id> --already-fixed|--decide|--manual|--failed "<text>"
                              Give a claimed item back with an outcome
  merge-when-green <N>        Wait for PR <N>'s checks, then squash-merge it
Settings: git config found-issues.autofix true|false (local overrides --global),
found-issues.autofix.{engine,testCommand,dailyFixes,runBudget,runTimeoutMin}.
EOF
}

cmd_autofix() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    on)
      fi_af_root
      rm -f "$FI_AF_ROOT/disabled"
      printf 'Auto-fix kill switch cleared. Auto-fix runs in repos where found-issues.autofix=true.\n' ;;
    off)
      fi_af_root
      mkdir -p "$FI_AF_ROOT"
      : >"$FI_AF_ROOT/disabled"
      printf 'Auto-fix switched off in every repo (undo: found-issues autofix on).\n' ;;
    ""|-h|--help|help) _fi_af_usage ;;
    *) fi_unknown_arg autofix "$sub"; return 2 ;;
  esac
}
```

- [ ] **Step 7: Wire the libs into `bin/found-issues`.**
  1. Source `autofix-config.sh` after the `autofix-tags.sh` source line, and `autofix.sh` after `decide.sh`. Use the same `# shellcheck source=../lib/<name>.sh` comment style.
  2. In `main()`, add `autofix)          cmd_autofix "$@" ;;` after the `decide)` line.

- [ ] **Step 8: Run to confirm pass**

Run: `bats tests/autofix-config.bats`
Expected: `12 tests, 0 failures`.

- [ ] **Step 9: Commit**

```bash
git add lib/autofix-config.sh lib/autofix.sh bin/found-issues tests/autofix-config.bats
git commit -m "feat(v3) autofix settings, kill switch, test command and engine resolution"
```

---

### Task 2: Queue items and the `log` trigger

**Files:**
- Create: `lib/autofix-queue.sh` (item I/O + `fi_af_queue_spot`)
- Modify: `bin/found-issues` (source it after `autofix-config.sh`)
- Modify: `lib/log.sh` (call `fi_af_queue_spot` after a `(fix: small)` write)
- Test: `tests/autofix-queue.bats`

**Interfaces:**
- Consumes:
  - `fi_af_enabled`, `fi_af_dirs`, `fi_af_engine` (Task 1);
  - `fi_entry_dedup_key_v <entry> <root>` → `FI_KEY`;
  - `fi_entry_loc_v` → `FE_loc`;
  - `fi_repo_root_cached` → `FI_REPO_ROOT`.
- Produces:
  - `fi_af_item_write <path> key=value…` writes atomically.
  - `fi_af_item_read <path>` sets `AFI_id AFI_kind AFI_root AFI_slug AFI_loc AFI_key AFI_entry AFI_engine AFI_queued AFI_crashes AFI_pid AFI_wt AFI_branch AFI_base AFI_result AFI_pr AFI_cost`, and returns 1 if the file is missing.
  - `fi_af_item_set <path> <key> <value>`.
  - `fi_af_new_id` → `FI_AF_ID`.
  - `fi_af_queue_spot <entry-line>` prints `AUTOFIX-QUEUED <id>`, or the child-safe line.
  - `fi_af_log <id> <text>` appends to `runs/<id>.log`.

- [ ] **Step 1: Write the failing tests** in `tests/autofix-queue.bats`:

```bash
#!/usr/bin/env bats
# v3 auto-fix queue items and the log trigger (spec §4.1, §4.4).

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
  export FOUND_ISSUES_STATE_DIR="$TMP/state"
  export HOME="$TMP/home"; mkdir -p "$HOME"
  unset FOUND_ISSUES_AUTOFIX FOUND_ISSUES_AUTOFIX_CHILD
  git remote add origin https://github.com/foo/bar.git
  mkdir -p src docs
  printf 'a\nb\nc\n' > src/a.py
  git add -A && git commit -q -m init
  QDIR="$TMP/state/autofix/foo__bar/queue"
}
teardown() { fi_teardown_tmp; }

@test "autofix queue: log --fix small queues one item when enabled" {
  git config found-issues.autofix true
  run "$FI_BIN" log --fix small 'src/a.py:2 — off by one'
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUTOFIX-QUEUED "* ]]
  [ "$(ls "$QDIR" | wc -l | tr -d ' ')" = 1 ]
  f="$QDIR/$(ls "$QDIR")"
  grep -q '^kind=spot$' "$f"
  grep -q '^slug=foo/bar$' "$f"
  grep -q '^loc=src/a.py:2$' "$f"
  [ "$(sed -n 's/^root=//p' "$f")" = "$(git rev-parse --show-toplevel)" ]
  grep -q '^entry=- \[open\] .*src/a.py:2 — off by one (fix: small)$' "$f"
}

@test "autofix queue: nothing is queued when auto-fix is off" {
  run "$FI_BIN" log --fix small 'src/a.py:2 — off by one'
  [ "$status" -eq 0 ]
  [[ "$output" != *"AUTOFIX-QUEUED"* ]]
  [ ! -d "$QDIR" ] || [ -z "$(ls "$QDIR")" ]
}

@test "autofix queue: medium, large, decide and untagged entries are not spot-queued" {
  git config found-issues.autofix true
  "$FI_BIN" log --fix medium 'src/a.py:1 — medium thing'
  "$FI_BIN" log --fix large 'src/a.py:3 — large thing'
  "$FI_BIN" log --decide 'which way?' 'src/a.py:2 — needs a call'
  "$FI_BIN" log 'src/a.py — untagged'
  [ ! -d "$QDIR" ] || [ -z "$(ls "$QDIR")" ]
}

@test "autofix queue: re-logging the same entry does not queue it twice" {
  git config found-issues.autofix true
  "$FI_BIN" log --fix small 'src/a.py:2 — off by one'
  run "$FI_BIN" log --fix small 'src/a.py:2 — off by one'
  [ "$(ls "$QDIR" | wc -l | tr -d ' ')" = 1 ]
}

@test "autofix queue: log --fix small on an entry already tagged medium does not queue it" {
  "$FI_BIN" log --fix medium 'src/a.py:2 — off by one'
  git config found-issues.autofix true
  run "$FI_BIN" log --fix small 'src/a.py:2 — off by one'
  [[ "$output" != *"AUTOFIX-QUEUED"* ]]
  [ ! -d "$QDIR" ] || [ -z "$(ls "$QDIR")" ]
}

@test "autofix queue: tagging an existing open entry small through log queues it" {
  "$FI_BIN" log 'src/a.py:2 — off by one'
  git config found-issues.autofix true
  run "$FI_BIN" log --fix small 'src/a.py:2 — off by one'
  [[ "$output" == *"AUTOFIX-QUEUED "* ]]
  [ "$(ls "$QDIR" | wc -l | tr -d ' ')" = 1 ]
}

@test "autofix queue: inside a fixer the item is queued without the launch marker" {
  git config found-issues.autofix true
  FOUND_ISSUES_AUTOFIX_CHILD=1 run "$FI_BIN" log --fix small 'src/a.py:2 — off by one'
  [ "$status" -eq 0 ]
  [[ "$output" != *"AUTOFIX-QUEUED"* ]]
  [[ "$output" == *"inside a fixer"* ]]
  [ "$(ls "$QDIR" | wc -l | tr -d ' ')" = 1 ]
}

@test "autofix queue: an off-limits path is tagged manual and never queued" {
  git config found-issues.autofix true
  mkdir -p .github/workflows && echo x > .github/workflows/ci.yml && git add -A && git commit -q -m ci
  run "$FI_BIN" log --fix small '.github/workflows/ci.yml:1 — bad step'
  [[ "$output" != *"AUTOFIX-QUEUED"* ]]
  grep -q '(manual: off-limits: ci)' docs/found-issues.md
}

@test "autofix queue: no GitHub origin logs normally and queues nothing" {
  git remote remove origin
  git config found-issues.autofix true
  run "$FI_BIN" log --fix small 'src/a.py:2 — off by one'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Logged:"* ]]
  [[ "$output" != *"AUTOFIX"* ]]
}

@test "autofix queue: item read and set round-trip values with = and spaces" {
  source "$FI_BIN"
  fi_af_item_write "$TMP/item" "id=x1" "entry=- [open] a = b (fix: small)" "crashes=0"
  fi_af_item_read "$TMP/item"
  [ "$AFI_id" = x1 ]
  [ "$AFI_entry" = "- [open] a = b (fix: small)" ]
  fi_af_item_set "$TMP/item" crashes 1
  fi_af_item_set "$TMP/item" pid 4242
  fi_af_item_read "$TMP/item"
  [ "$AFI_crashes" = 1 ]
  [ "$AFI_pid" = 4242 ]
  [ "$AFI_entry" = "- [open] a = b (fix: small)" ]
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `bats tests/autofix-queue.bats`
Expected: FAIL — no `AUTOFIX-QUEUED` in output; `fi_af_item_write: command not found`.

- [ ] **Step 3: Create `lib/autofix-queue.sh`**

```bash
#!/usr/bin/env bash
# autofix-queue.sh — v3 auto-fix queue: items, lock, caps, crash reaping,
# claim and release (spec 2026-10-03 §4.1, §4.3-§4.4, §5 steps 1-2, §7, §8).
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Items are key=value files under $FI_AF_ST/{queue,running,done}/<id>. A
# directory move is the state change, so a crashed process can never leave
# an item in two states.
#
# Functions:
#   fi_af_item_write <path> key=value...
#   fi_af_item_read <path>
#   fi_af_item_set <path> <key> <value>
#   fi_af_new_id
#   fi_af_log <id> <text>
#   fi_af_queue_spot <entry-line>

# shellcheck disable=SC2034  # AFI_* are read by the other autofix libs

AFI_id="" AFI_kind="" AFI_root="" AFI_slug="" AFI_loc="" AFI_key="" AFI_entry=""
AFI_engine="" AFI_queued="" AFI_crashes="0" AFI_pid="" AFI_wt="" AFI_branch=""
AFI_base="" AFI_result="" AFI_pr="" AFI_cost="" FI_AF_ID=""

fi_af_item_write() {
  local path="$1" tmp
  shift
  tmp="$path.tmp.$$"
  printf '%s\n' "$@" >"$tmp" && mv "$tmp" "$path"
}

fi_af_item_read() {
  AFI_id="" AFI_kind="" AFI_root="" AFI_slug="" AFI_loc="" AFI_key="" AFI_entry=""
  AFI_engine="" AFI_queued="" AFI_crashes="0" AFI_pid="" AFI_wt="" AFI_branch=""
  AFI_base="" AFI_result="" AFI_pr="" AFI_cost=""
  [[ -f "$1" ]] || return 1
  local line k
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}"
    case "$k" in
      id|kind|root|slug|loc|key|entry|engine|queued|crashes|pid|wt|branch|base|result|pr|cost)
        printf -v "AFI_$k" '%s' "${line#*=}" ;;
    esac
  done <"$1"
}

fi_af_item_set() {
  local path="$1" key="$2" val="$3" line tmp found=0
  tmp="$path.tmp.$$"
  : >"$tmp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "${line%%=*}" == "$key" ]]; then
      printf '%s=%s\n' "$key" "$val" >>"$tmp"; found=1
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$path"
  (( found )) || printf '%s=%s\n' "$key" "$val" >>"$tmp"
  mv "$tmp" "$path"
}

# Sortable by queue time: the drain loop takes the oldest first.
fi_af_new_id() {
  printf -v FI_AF_ID '%s-%05d' "$(date +%Y%m%d-%H%M%S)" "$RANDOM"
}

fi_af_log() {
  printf '%s %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$2" >>"$FI_AF_RUNS/$1.log" 2>/dev/null || true
}

# Spec §4.1: called by log after it wrote or tagged a (fix: small) entry.
# Never fails the log call: every problem here just means "not queued".
fi_af_queue_spot() {
  local entry="$1" slug root key engine f
  fi_af_enabled || return 0
  slug="$(fi_repo_id 2>/dev/null)" || return 0
  fi_repo_root_cached
  root="$FI_REPO_ROOT"
  [[ -n "$root" ]] || return 0
  fi_entry_dedup_key_v "$entry" "$root" || return 0
  key="$FI_KEY"
  fi_entry_loc_v "$entry" || return 0
  fi_af_dirs "$slug" || return 0
  for f in "$FI_AF_ST"/queue/* "$FI_AF_ST"/running/*; do
    [[ -f "$f" ]] || continue
    fi_af_item_read "$f"
    if [[ "$AFI_key" == "$key" && "$AFI_root" == "$root" ]]; then
      printf 'Auto-fix: already queued (%s)\n' "$AFI_id"
      return 0
    fi
  done
  engine="$(fi_af_engine 2>/dev/null || true)"
  fi_af_new_id
  fi_af_item_write "$FI_AF_ST/queue/$FI_AF_ID" "id=$FI_AF_ID" "kind=spot" \
    "root=$root" "slug=$slug" "loc=$FE_loc" "key=$key" "entry=$entry" \
    "engine=$engine" "queued=$(date +%Y-%m-%dT%H:%M:%S)" "crashes=0"
  if [[ "${FOUND_ISSUES_AUTOFIX_CHILD:-}" == "1" ]]; then
    printf 'Auto-fix: queued %s (inside a fixer; the main session launches it)\n' "$FI_AF_ID"
  else
    printf 'AUTOFIX-QUEUED %s\n' "$FI_AF_ID"
  fi
}
```

Note: `fi_entry_loc_v` (lib/annotate.sh) re-parses the entry, which sets `FE_loc`. `fi_af_item_read` in the loop overwrites the `AFI_*` variables but not `FE_loc`.

- [ ] **Step 4: Source it.** In `bin/found-issues`, add the line below directly after the `autofix-config.sh` source, with a `# shellcheck source=../lib/autofix-queue.sh` comment above it:

```bash
source "$FI_LIB_DIR/autofix-queue.sh"
```

- [ ] **Step 5: Hook `log`.** In `lib/log.sh`, `cmd_log`, the trigger goes in three places. Each spot is exactly where a `(fix: small)` line now exists in the ledger.

  1. **Escalation branch.** After `_fi_log_tag_existing "$file" "$esc_line" || return 1`, before `cmd_status plain`:

```bash
      _fi_log_autofix "$_fi_log_line"
```

  2. **Open-match tag branch.** Inside `if [[ "$_fi_log_line" != "$matched_entry" ]]; then`, before `cmd_status plain`:

```bash
        _fi_log_autofix "$_fi_log_line"
```

  3. **New-entry path.** After `printf 'Logged: %s\n' "$entry"`, before the final `cmd_status plain`:

```bash
  _fi_log_autofix "$entry"
```

Then add this helper above `cmd_log`. It reads `cmd_log`'s `tag_kind`, like `_fi_log_tag_existing`:

```bash
# v3 spec §4.1: a (fix: small) entry this call wrote or tagged is queued for
# auto-fix. Reads the line as written: an entry log left "already tagged"
# (say medium) is not small, whatever this call asked for, and off-limits
# paths were already turned into manual by fi_tag_resolve.
_fi_log_autofix() {
  [[ -n "$tag_kind" ]] || return 0
  fi_parse_entry_vars "$1" || return 0
  [[ "$FE_status" == "open" && "$FE_fixtag" == "small" ]] || return 0
  fi_af_queue_spot "$1" || true
}
```

The deferred-match branch deliberately does not queue: the entry stays `[deferred]`, and claim requires `[open]`.

- [ ] **Step 6: Run to confirm pass**

Run: `bats tests/autofix-queue.bats tests/cli-log.bats`
Expected: all pass (10 new tests; `cli-log.bats` unchanged).

- [ ] **Step 7: Commit**

```bash
git add lib/autofix-queue.sh lib/log.sh bin/found-issues tests/autofix-queue.bats
git commit -m "feat(v3) autofix queue items; log --fix small queues a spot fix"
```

---

### Task 3: Lock, caps, crash reaping and `autofix claim`

**Files:**
- Modify: `lib/autofix-queue.sh` (append lock/cap/reap/eligibility/worktree/claim)
- Modify: `lib/autofix.sh` (add `claim` to the dispatcher)
- Create: `tests/autofix-helpers.bash` (the GitHub-shaped fixture, used by Tasks 3-8)
- Test: `tests/autofix-claim.bats`

**Interfaces:**
- Consumes: Task 2 item I/O; `fi_find_issues_file <dir>`; `fi_entries <file> open`; `fi_parse_entry_vars` (`FE_prs FE_prs_auto FE_commits FE_commits_auto FE_autofix_failed FE_fixtag FE_decided FE_decide`); `fi_resolve_default_branch`; `fi_file_mtime`; `fi_today`.
- Produces:
  - `fi_af_lock <id>` / `fi_af_unlock <id>`.
  - `fi_af_cap_ok <kind> <limit>` / `fi_af_cap_take <kind> <id>`.
  - `fi_af_reap`.
  - `fi_af_find_entry [<ledger>]` → `FI_AF_ENTRY`, `FI_AF_LEDGER`. It matches by dedup key; the default ledger is the source checkout's, from `AFI_root`.
  - `fi_af_eligible` → 0/1 + `FI_AF_WHY`.
  - `fi_af_worktree_add` → sets `AFI_wt AFI_branch AFI_base`.
  - `fi_af_claim <id>` → 0 claimed, 1 unknown, 3 capped, 4 locked, 5 retired (stale), 6 worktree failed. On 0, `running/<id>` holds `pid wt branch base`.
  - `fi_af_retire <id> <outcome> <text>` moves an item to `done/` without a ledger write. Task 4 extends this into `fi_af_finish`.

- [ ] **Step 1: Create the fixture helper** `tests/autofix-helpers.bash`:

```bash
#!/usr/bin/env bash
# tests/autofix-helpers.bash — GitHub-shaped fixtures for the v3 auto-fix tests.
# Load after helpers: `load 'helpers'; load 'autofix-helpers'`.

# A repo whose origin is https://github.com/foo/bar.git, served by a local
# bare repo through url.insteadOf (fi_repo_id still reads foo/bar). It has
# one bug (add subtracts), a test command that sees it, a committed ledger
# entry tagged (fix: small), and auto-fix enabled locally. cwd = the repo.
fi_af_fixture() {
  export FOUND_ISSUES_STATE_DIR="$TMP/state"
  export HOME="$TMP/home"; mkdir -p "$HOME"
  export FOUND_ISSUES_MODE=github-pr
  unset FOUND_ISSUES_AUTOFIX FOUND_ISSUES_AUTOFIX_CHILD CLAUDECODE
  git init -q --bare -b main "$TMP/remote.git"
  mkdir -p "$TMP/repo" && cd "$TMP/repo"
  fi_init_git
  git remote add origin https://github.com/foo/bar.git
  git config url."$TMP/remote.git".insteadOf https://github.com/foo/bar.git
  mkdir -p src docs
  printf 'add() { echo $(( $1 - $2 )); }\n' > src/calc.sh
  printf '. ./src/calc.sh\n[ "$(add 2 3)" = 5 ]\n' > test.sh
  printf '# found-issues\n\n- [open] 2026-10-01 src/calc.sh:1 — add subtracts (fix: small)\n' > docs/found-issues.md
  git add -A && git commit -q -m init
  git push -q -u origin main
  git fetch -q origin && git remote set-head origin main >/dev/null
  git config found-issues.autofix true
  git config found-issues.autofix.testCommand 'sh test.sh'
  REPO="$(pwd -P)"
}

# Queue the fixture's entry as a spot item; sets ID and QITEM.
fi_af_queue_fixture() {
  source "$FI_BIN"
  fi_af_context
  fi_af_queue_spot "$(grep -m1 '^- \[open\]' docs/found-issues.md)" >/dev/null
  ID="$(ls "$FI_AF_ST/queue" | head -1)"
  QITEM="$FI_AF_ST/queue/$ID"
}
```

- [ ] **Step 2: Write the failing tests** in `tests/autofix-claim.bats`:

```bash
#!/usr/bin/env bats
# v3 auto-fix claim: lock, caps, eligibility, reaping, worktree (spec §5.1, §7, §8).

load 'helpers'
load 'autofix-helpers'

setup() { fi_setup_tmp; fi_af_fixture; fi_af_queue_fixture; ST="$FI_AF_ST"; }
teardown() { fi_teardown_tmp; }

@test "autofix claim: claims, cuts a worktree from origin, records it" {
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 0 ]
  wt="$REPO/.claude/worktrees/fi-autofix-$ID"
  [ "${lines[${#lines[@]}-1]}" = "$wt" ]
  [ -f "$wt/src/calc.sh" ]
  [ "$(git -C "$wt" branch --show-current)" = "fi/autofix/src-calc-sh-1-$ID" ]
  [ ! -e "$ST/queue/$ID" ]
  grep -q "^wt=$wt$" "$ST/running/$ID"
  grep -q '^base=main$' "$ST/running/$ID"
  [ -d "$ST/lock" ]
  [ "$(wc -l < "$ST/day/$(date +%Y-%m-%d).spot" | tr -d ' ')" = 1 ]
}

@test "autofix claim: a second claimer for the same repo gets exit 4 and the item stays queued" {
  fi_af_context   # setup already sourced the CLI (a second source hits its readonly vars)
  fi_af_lock other-run
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 4 ]
  [ -f "$ST/queue/$ID" ]
  [ "$(cat "$ST/lock/owner")" = other-run ]
}

@test "autofix claim: a lock older than 60 minutes is broken" {
  fi_af_context   # setup already sourced the CLI (a second source hits its readonly vars)
  fi_af_lock other-run
  touch -t 202001010000 "$ST/lock"
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 0 ]
  [ "$(cat "$ST/lock/owner")" = "$ID" ]
}

@test "autofix claim: the daily cap holds the item in the queue" {
  git config found-issues.autofix.dailyFixes 1
  printf 'earlier\n' > "$ST/day/$(date +%Y-%m-%d).spot"
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 3 ]
  [ -f "$ST/queue/$ID" ]
  [ ! -d "$ST/lock" ]
}

@test "autofix claim: an entry that gained a PR annotation is retired, not claimed" {
  sed -i.bak 's/(fix: small)/(fix: small) (PR: foo\/bar#9)/' docs/found-issues.md
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 5 ]
  [ -f "$ST/done/$ID" ]
  grep -q '^result=stale: entry already has a fix reference$' "$ST/done/$ID"
  [ ! -d "$ST/lock" ]
}

@test "autofix claim: autofix-failed and retagged entries are not claimed" {
  sed -i.bak 's/(fix: small)/(fix: small) (autofix-failed: tests fail)/' docs/found-issues.md
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 5 ]
  grep -q 'auto-fix failed before' "$ST/done/$ID"
}

@test "autofix claim: a decided entry is fixable now" {
  sed -i.bak 's/(fix: small)/(decided: use plus)/' docs/found-issues.md
  run "$FI_BIN" autofix claim "$ID"
  [ "$status" -eq 0 ]
}

@test "autofix claim: a dead running item is requeued once, then failed as crashed" {
  "$FI_BIN" autofix claim "$ID" >/dev/null
  fi_af_context   # setup already sourced the CLI (a second source hits its readonly vars)
  fi_af_item_set "$ST/running/$ID" pid 999999
  fi_af_reap
  [ -f "$ST/queue/$ID" ]
  grep -q '^crashes=1$' "$ST/queue/$ID"
  [ ! -d "$ST/lock" ]
  [ ! -d "$REPO/.claude/worktrees/fi-autofix-$ID" ]
  "$FI_BIN" autofix claim "$ID" >/dev/null
  fi_af_item_set "$ST/running/$ID" pid 999999
  fi_af_reap
  [ -f "$ST/done/$ID" ]
  grep -q '^result=failed: crashed$' "$ST/done/$ID"
}

@test "autofix claim: unknown id exits 1" {
  run "$FI_BIN" autofix claim nope
  [ "$status" -eq 1 ]
}
```

(The `crashed` ledger tag is asserted in Task 4, after `fi_af_finish` exists. Here `fi_af_reap` calls `fi_af_retire`, which writes no tag yet.)

- [ ] **Step 3: Run to confirm failure**

Run: `bats tests/autofix-claim.bats`
Expected: FAIL — `autofix: unknown option 'claim'` / `fi_af_lock: command not found`.

- [ ] **Step 4: Append to `lib/autofix-queue.sh`.** Also add the new names to the header's `Functions:` list.

```bash
FI_AF_ENTRY="" FI_AF_LEDGER=""

# Spec §5.1: one fixer per repo at a time. mkdir is the atomic test-and-set;
# a lock older than 60 min (FOUND_ISSUES_AUTOFIX_LOCK_STALE seconds) belonged
# to a dead run and is broken by rename, so only one breaker wins.
fi_af_lock() {
  local id="$1" lock="$FI_AF_ST/lock" now age
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$id" >"$lock/owner"; return 0
  fi
  now="$(date +%s)"
  age=$(( now - $(fi_file_mtime "$lock") ))
  (( age >= ${FOUND_ISSUES_AUTOFIX_LOCK_STALE:-3600} )) || return 1
  mv "$lock" "$lock.stale.$$" 2>/dev/null || return 1
  rm -rf "$lock.stale.$$"
  mkdir "$lock" 2>/dev/null || return 1
  printf '%s\n' "$id" >"$lock/owner"
}

fi_af_unlock() {
  local lock="$FI_AF_ST/lock" owner=""
  [[ -f "$lock/owner" ]] && IFS= read -r owner <"$lock/owner"
  [[ "$owner" == "$1" ]] && rm -rf "$lock"
  return 0
}

# Spec §7: claims per repo per day, one line per claim.
fi_af_cap_ok() {
  local f="$FI_AF_ST/day/$(fi_today).$1" n=0 line
  if [[ -f "$f" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do n=$((n + 1)); done <"$f"
  fi
  (( n < $2 ))
}

fi_af_cap_take() {
  printf '%s\n' "$2" >>"$FI_AF_ST/day/$(fi_today).$1"
}

# The entry this item is about, re-found by dedup key (relative path, line,
# symptom — annotations and tags may have changed since it was queued) in
# the source checkout's ledger, or in <ledger> when given (ship uses the
# worktree's own ledger).
fi_af_find_entry() {
  local file="${1:-}" entry
  FI_AF_ENTRY=""
  [[ -n "$file" ]] || file="$(fi_find_issues_file "$AFI_root")" || return 1
  [[ -f "$file" ]] || return 1
  FI_AF_LEDGER="$file"
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    fi_entry_dedup_key_v "$entry" "$AFI_root" || continue
    if [[ "$FI_KEY" == "$AFI_key" ]]; then FI_AF_ENTRY="$entry"; return 0; fi
  done < <(fi_entries "$file" open 2>/dev/null || true)
  return 1
}

# Spec §5.1: still [open], fixable now, no fix reference, never failed.
fi_af_eligible() {
  FI_AF_WHY=""
  fi_af_find_entry || { FI_AF_WHY="entry is no longer [open]"; return 1; }
  fi_parse_entry_vars "$FI_AF_ENTRY"
  if [[ -n "$FE_prs$FE_prs_auto$FE_commits$FE_commits_auto" ]]; then
    FI_AF_WHY="entry already has a fix reference"; return 1
  fi
  if [[ -n "$FE_autofix_failed" ]]; then
    FI_AF_WHY="auto-fix failed before: $FE_autofix_failed"; return 1
  fi
  case "$FE_fixtag" in small|medium) return 0 ;; esac
  [[ -n "$FE_decided" && -z "$FE_decide" ]] && return 0
  FI_AF_WHY="entry is not fixable now (fix: ${FE_fixtag:-none})"
  return 1
}

fi_af_worktree_add() {
  local s base
  base="$(cd "$AFI_root" && fi_resolve_default_branch)"
  git -C "$AFI_root" fetch -q origin "$base" 2>/dev/null || { FI_AF_WHY="git fetch failed"; return 1; }
  s="${AFI_loc//[^A-Za-z0-9]/-}"
  s="${s:0:40}"
  AFI_base="$base"
  AFI_branch="fi/autofix/$s-$AFI_id"
  AFI_wt="$AFI_root/.claude/worktrees/fi-autofix-$AFI_id"
  mkdir -p "$AFI_root/.claude/worktrees"
  git -C "$AFI_root" worktree add -q -b "$AFI_branch" "$AFI_wt" "origin/$base" >/dev/null 2>&1 \
    || { FI_AF_WHY="git worktree add failed"; return 1; }
}

fi_af_worktree_remove() {
  [[ -n "$AFI_wt" && -n "$AFI_root" ]] || return 0
  git -C "$AFI_root" worktree remove --force "$AFI_wt" >/dev/null 2>&1 || rm -rf "$AFI_wt"
  git -C "$AFI_root" worktree prune >/dev/null 2>&1 || true
  if [[ -n "$AFI_branch" ]]; then
    git -C "$AFI_root" branch -D "$AFI_branch" >/dev/null 2>&1 || true
  fi
}

# Move an item (queued or running) to done/ with a result, no ledger write.
fi_af_retire() {
  local id="$1" outcome="$2" text="$3" f="$FI_AF_ST/running/$1"
  [[ -f "$f" ]] || f="$FI_AF_ST/queue/$id"
  [[ -f "$f" ]] || return 1
  fi_af_item_set "$f" result "$outcome: $text"
  mv "$f" "$FI_AF_ST/done/$id"
  fi_af_unlock "$id"
  fi_af_log "$id" "$outcome: $text"
}

# Spec §8: a running item whose process is gone crashed. Requeue it once;
# the second crash fails it.
fi_af_reap() {
  local f
  for f in "$FI_AF_ST"/running/*; do
    [[ -f "$f" ]] || continue
    fi_af_item_read "$f"
    if [[ -n "$AFI_pid" ]] && kill -0 "$AFI_pid" 2>/dev/null; then continue; fi
    fi_af_worktree_remove
    if (( ${AFI_crashes:-0} < 1 )); then
      fi_af_item_set "$f" crashes 1
      fi_af_item_set "$f" pid ""
      fi_af_unlock "$AFI_id"
      mv "$f" "$FI_AF_ST/queue/$AFI_id"
      fi_af_log "$AFI_id" "requeued after a crash"
    else
      fi_af_finish "$AFI_id" failed "crashed"
    fi
  done
}

# Spec §5.1. Lock first, so of two claimers exactly one sees the queue file.
fi_af_claim() {
  local id="$1" q="$FI_AF_ST/queue/$1" r="$FI_AF_ST/running/$1"
  fi_af_lock "$id" || { [[ -f "$q" ]] || return 1; return 4; }
  if ! fi_af_item_read "$q"; then fi_af_unlock "$id"; return 1; fi
  if ! fi_af_eligible; then fi_af_retire "$id" stale "$FI_AF_WHY"; return 5; fi
  if ! fi_af_cap_ok spot "$(fi_af_int dailyFixes 5)"; then fi_af_unlock "$id"; return 3; fi
  mv "$q" "$r" || { fi_af_unlock "$id"; return 1; }
  fi_af_cap_take spot "$id"
  fi_af_item_set "$r" pid "${FI_AF_PID:-$$}"
  if ! fi_af_worktree_add; then
    fi_af_finish "$id" failed "$FI_AF_WHY"
    return 6
  fi
  fi_af_item_set "$r" wt "$AFI_wt"
  fi_af_item_set "$r" branch "$AFI_branch"
  fi_af_item_set "$r" base "$AFI_base"
  fi_af_log "$id" "claimed: $AFI_wt ($AFI_branch from origin/$AFI_base)"
}
```

Until Task 4 lands, add this temporary stub so `fi_af_reap` and `fi_af_claim` work:

```bash
fi_af_finish() { fi_af_retire "$1" "$2" "$3"; }
```

Task 4 deletes the stub. The second-crash test asserts only `result=failed: crashed`.

Note on the lock wait: `fi_af_lock` returns 1 when held and not stale. `fi_af_claim` maps that to 4. An unknown id under a held lock is still 1.

Note on `FI_AF_PID`: the `run` orchestrator (Task 7) exports `FI_AF_PID=$$` so the reaper sees the long-lived run process. A standalone `autofix claim` (launcher B, Phase 3) records its own short-lived pid, and Phase 3 replaces it.

- [ ] **Step 5: Dispatch `claim`.** In `cmd_autofix`, add this before `""|-h|--help|help)`:

```bash
    claim)
      [[ $# -eq 1 ]] || { fi_err "Usage: found-issues autofix claim <id>"; return 2; }
      fi_af_context || return 1
      fi_af_reap
      local rc=0
      fi_af_claim "$1" || rc=$?
      case $rc in
        0) printf '%s\n' "$AFI_wt" ;;
        1) fi_err "autofix: no queued item $1" ;;
        3) fi_err "autofix: today's spot-fix cap is reached; $1 waits for tomorrow" ;;
        4) fi_err "autofix: another auto-fix run holds this repo; $1 stays queued" ;;
        5) fi_err "autofix: $1 retired — $FI_AF_WHY" ;;
        6) fi_err "autofix: $1 failed — $FI_AF_WHY" ;;
      esac
      return $rc ;;
```

- [ ] **Step 6: Run to confirm pass**

Run: `bats tests/autofix-claim.bats`
Expected: `9 tests, 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add lib/autofix-queue.sh lib/autofix.sh tests/autofix-helpers.bash tests/autofix-claim.bats
git commit -m "feat(v3) autofix claim: repo lock, daily cap, eligibility, crash reaping, worktree"
```

---

### Task 4: Release outcomes and the `(autofix-failed: …)` tag

**Files:**
- Modify: `lib/autofix-tags.sh` (`fi_tag_resolve` and `fi_entry_retag` learn `autofix-failed`)
- Modify: `lib/autofix-queue.sh` (replace the stub with `fi_af_finish`, plus ledger helpers)
- Modify: `lib/autofix.sh` (add `release`)
- Test: `tests/autofix-release.bats`; add one case to `tests/autofix-tags.bats`

**Interfaces:**
- Consumes: `fi_tag_resolve`, `fi_tag_apply`, `fi_ledger_*`, `fi_af_find_entry`, `fi_af_retire`, `fi_af_worktree_remove`.
- Produces:
  - `fi_af_finish <id> <outcome> <text>`. Outcomes:
    - `already-fixed` → the entry becomes `[fixed] … (verified: ai) (fixed: <today>)`;
    - `decide` / `manual` → retag;
    - `failed` → `(autofix-failed: <text>)` (the fix tag is kept);
    - `shipped` / `stale` → no ledger write.

    It removes the worktree and branch, moves the item to `done/`, unlocks and logs. It returns 0 even when the ledger entry has vanished (the outcome is logged).
  - `fi_af_ledger_tag <kind> <text>`.
  - `fi_af_ledger_resolve`.
  - CLI `autofix release <id> --already-fixed|--decide|--manual|--failed "<text>"`.

- [ ] **Step 1: Write the failing tests.** Add to `tests/autofix-tags.bats`:

```bash
@test "autofix-tags: autofix-failed replaces only its own group and keeps the fix tag" {
  source "$FI_BIN"
  fi_entry_retag '- [open] 2026-10-01 a.sh:1 — x (fix: small) (autofix-failed: old)' autofix-failed 'tests fail'
  [ "$FI_RETAGGED" = '- [open] 2026-10-01 a.sh:1 — x (fix: small) (autofix-failed: tests fail)' ]
  fi_tag_resolve autofix-failed 'verifier said (no)' '' ''
  [ "$FI_TAG_KIND" = autofix-failed ]
  [ "$FI_TAG_VALUE" = 'verifier said [no]' ]
}
```

Then create `tests/autofix-release.bats`:

```bash
#!/usr/bin/env bats
# v3 auto-fix release outcomes (spec §5 steps 2 and 4).

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_fixture; fi_af_queue_fixture; ST="$FI_AF_ST"
  "$FI_BIN" autofix claim "$ID" >/dev/null
  WT="$REPO/.claude/worktrees/fi-autofix-$ID"
}
teardown() { fi_teardown_tmp; }

assert_released() {
  [ -f "$ST/done/$ID" ]
  [ ! -e "$ST/running/$ID" ]
  [ ! -d "$ST/lock" ]
  [ ! -d "$WT" ]
  ! git -C "$REPO" rev-parse --verify -q "refs/heads/fi/autofix/src-calc-sh-1-$ID"
}

@test "autofix release: --failed tags the entry and keeps the fix tag" {
  run "$FI_BIN" autofix release "$ID" --failed "tests fail after 2 attempts"
  [ "$status" -eq 0 ]
  grep -q '(fix: small) (autofix-failed: tests fail after 2 attempts)$' docs/found-issues.md
  grep -q '^result=failed: tests fail after 2 attempts$' "$ST/done/$ID"
  assert_released
}

@test "autofix release: --decide swaps the fix tag for the question" {
  run "$FI_BIN" autofix release "$ID" --decide "plus or a lookup table?"
  [ "$status" -eq 0 ]
  grep -q 'add subtracts (decide: plus or a lookup table?)$' docs/found-issues.md
  ! grep -q '(fix: small)' docs/found-issues.md
  assert_released
}

@test "autofix release: --manual records why" {
  run "$FI_BIN" autofix release "$ID" --manual "needs a real device"
  grep -q '(manual: needs a real device)$' docs/found-issues.md
  assert_released
}

@test "autofix release: --already-fixed closes the entry as verified by ai" {
  run "$FI_BIN" autofix release "$ID" --already-fixed "add already uses plus at origin/main"
  [ "$status" -eq 0 ]
  grep -q "^- \[fixed\] 2026-10-01 src/calc.sh:1 — add subtracts (fix: small) (verified: ai) (fixed: $(date +%Y-%m-%d))$" docs/found-issues.md
  grep -q 'already-fixed: add already uses plus' "$ST/done/$ID"
  assert_released
}

@test "autofix release: an entry removed from the ledger still releases the item" {
  printf '# found-issues\n\n' > docs/found-issues.md
  run "$FI_BIN" autofix release "$ID" --failed "boom"
  [ "$status" -eq 0 ]
  assert_released
}

@test "autofix release: needs exactly one outcome and a text" {
  run "$FI_BIN" autofix release "$ID"
  [ "$status" -eq 2 ]
  run "$FI_BIN" autofix release "$ID" --failed
  [ "$status" -eq 2 ]
  run "$FI_BIN" autofix release nope --failed x
  [ "$status" -eq 1 ]
}

@test "autofix release: the second crash tags the entry crashed" {
  fi_af_context   # setup already sourced the CLI (a second source hits its readonly vars)
  fi_af_item_set "$ST/running/$ID" pid 999999
  fi_af_item_set "$ST/running/$ID" crashes 1
  fi_af_reap
  grep -q '(autofix-failed: crashed)$' docs/found-issues.md
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `bats tests/autofix-release.bats tests/autofix-tags.bats`
Expected: FAIL — `unknown tag kind: autofix-failed`; `autofix: unknown option 'release'`.

- [ ] **Step 3: Teach the tag helpers `autofix-failed`.** In `lib/autofix-tags.sh`:
  - in `fi_tag_resolve`, change the case label `decide|manual|decided)` to `decide|manual|decided|autofix-failed)`;
  - in `fi_entry_retag`'s kind `case`, add the line `autofix-failed)    drop='autofix-failed' ;;` after `decided)`.

- [ ] **Step 4: Replace the stub in `lib/autofix-queue.sh`.** Delete `fi_af_finish() { fi_af_retire "$1" "$2" "$3"; }` and add:

```bash
# Retag the entry in the source checkout's ledger.
fi_af_ledger_tag() {
  fi_af_find_entry || return 1
  fi_tag_resolve "$1" "$2" "" "" || return 2
  fi_tag_apply "$FI_AF_LEDGER" "$FI_AF_ENTRY" "$FI_TAG_KIND" "$FI_TAG_VALUE" >/dev/null
}

# Already fixed at origin: close it the way `resolve` does.
fi_af_ledger_resolve() {
  fi_af_find_entry || return 1
  local new="- [fixed]${FI_AF_ENTRY#- \[open\]} (verified: ai) (fixed: $(fi_today))"
  local snapshot tmp line done_one=0
  snapshot="$(fi_ledger_snapshot "$FI_AF_LEDGER")"
  tmp="$(fi_ledger_tmp "$FI_AF_LEDGER")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( ! done_one )) && [[ "$line" == "$FI_AF_ENTRY" ]]; then
      printf '%s\n' "$new" >>"$tmp"; done_one=1
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$FI_AF_LEDGER"
  fi_ledger_replace "$FI_AF_LEDGER" "$tmp" "$snapshot"
}

# Spec §5 steps 2, 4 and 7: end an item with an outcome. The ledger write is
# best effort — the item always leaves running/, so it never wedges the lock.
fi_af_finish() {
  local id="$1" outcome="$2" text="$3" f="$FI_AF_ST/running/$1" rc=0
  [[ -f "$f" ]] || f="$FI_AF_ST/queue/$id"
  fi_af_item_read "$f" || { fi_err "autofix: no queued or running item $id"; return 1; }
  text="${text//$'\n'/ }"
  text="${text:0:160}"
  case "$outcome" in
    already-fixed) fi_af_ledger_resolve || rc=$? ;;
    decide|manual) fi_af_ledger_tag "$outcome" "$text" || rc=$? ;;
    failed)        fi_af_ledger_tag autofix-failed "$text" || rc=$? ;;
    shipped|stale) ;;
    *) fi_err "autofix: unknown outcome $outcome"; return 2 ;;
  esac
  (( rc == 0 )) || fi_af_log "$id" "ledger not updated for $outcome (rc $rc)"
  fi_af_worktree_remove
  fi_af_retire "$id" "$outcome" "$text"
}
```

- [ ] **Step 5: Dispatch `release`.** In `cmd_autofix`:

```bash
    release)
      local rid="${1:-}" outcome="" text=""
      [[ $# -gt 0 ]] && shift
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --already-fixed|--decide|--manual|--failed)
            [[ -z "$outcome" ]] || { fi_err "autofix release: one outcome only"; return 2; }
            fi_need_value "autofix release" "$1" $# "${2:-}" || return 2
            outcome="${1#--}"; text="$2"; shift 2 ;;
          *) fi_unknown_arg "autofix release" "$1"; return 2 ;;
        esac
      done
      if [[ -z "$rid" || -z "$outcome" ]]; then
        fi_err "Usage: found-issues autofix release <id> --already-fixed|--decide|--manual|--failed \"<text>\""
        return 2
      fi
      fi_af_context || return 1
      [[ -f "$FI_AF_ST/running/$rid" || -f "$FI_AF_ST/queue/$rid" ]] || { fi_err "autofix: no queued or running item $rid"; return 1; }
      fi_af_finish "$rid" "$outcome" "$text" ;;
```

- [ ] **Step 6: Run to confirm pass**

Run: `bats tests/autofix-release.bats tests/autofix-tags.bats tests/autofix-claim.bats`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add lib/autofix-tags.sh lib/autofix-queue.sh lib/autofix.sh tests/autofix-release.bats tests/autofix-tags.bats
git commit -m "feat(v3) autofix release outcomes and the (autofix-failed:) tag"
```

---

### Task 5: Engine layer — watchdog, allowlist, prompts, parsing, stand-ins

**Files:**
- Create: `lib/autofix-engine.sh`
- Create: `tests/standins/claude`, `tests/standins/codex` (executable)
- Modify: `bin/found-issues` (source `autofix-engine.sh` after `autofix-queue.sh`)
- Modify: `tests/autofix-helpers.bash` (`fi_use_standins`)
- Test: `tests/autofix-engine.bats`

**Interfaces:**
- Consumes: `AFI_*` (a claimed item), `fi_af_budget`, `fi_af_int`, `FI_AF_RUNS`.
- Produces:
  - `fi_af_child <out> <err> <cwd> cmd…` → the child's rc, or 124 on timeout. It sets `FOUND_ISSUES_AUTOFIX_CHILD=1` for the child.
  - `fi_af_allowlist <testcmd>` → `FI_AF_TOOLS` array.
  - `fi_af_fixer_cmd <engine> <prompt> <last>` and `fi_af_verifier_cmd <engine> <prompt> <last> <schema>` → `FI_AF_CMD` array.
  - `fi_af_fixer_prompt <testcmd> <feedback>` and `fi_af_verifier_prompt <diff>` → stdout.
  - `fi_af_collect <engine> <out> <last>` → `FI_AF_TEXT`; it adds to `FI_AF_COST` (USD, Claude) and `FI_AF_TOKENS` (Codex).
  - `fi_af_parse_result <text>` → `FI_AF_RESULT` (`fixed|already-fixed|decide|manual|none`) and `FI_AF_RESULT_TEXT`.
  - `fi_af_parse_verdict <text>` → `FI_AF_APPROVE` (`true|false`) and `FI_AF_REASON`.
  - `fi_af_budget_left` → stdout, the USD left of `runBudget`. It returns 1 below $0.10.

- [ ] **Step 1: Create the stand-ins.** `tests/standins/claude`:

```bash
#!/usr/bin/env bash
# Stand-in `claude` for the v3 auto-fix tests: no network, no cost.
#   FI_STANDIN_TRACE   append one line per call: argv joined by 0x1f
#   FI_STANDIN_EDIT    shell run in cwd by fixer calls (the "fix")
#   FI_STANDIN_RESULT  fixer final line (default "FI-RESULT: fixed")
#   FI_STANDIN_VERDICTS file of verifier JSON verdicts, one per line, popped
#                      in order (default {"approve":true,"reason":"ok"})
#   FI_STANDIN_COST    total_cost_usd per call (default 0.25)
#   FI_STANDIN_SLEEP   seconds to sleep first (watchdog tests)
set -euo pipefail
if [[ -n "${FI_STANDIN_TRACE:-}" ]]; then
  ( IFS=$'\x1f'; printf 'claude\x1f%s\n' "$*" ) >>"$FI_STANDIN_TRACE"
fi
[[ -n "${FI_STANDIN_SLEEP:-}" ]] && sleep "$FI_STANDIN_SLEEP"
verifier=0 prev=""
for a in "$@"; do
  [[ "$prev" == "--model" && "$a" == "opus" ]] && verifier=1
  prev="$a"
done
if (( verifier )); then
  text='{"approve":true,"reason":"ok"}'
  if [[ -n "${FI_STANDIN_VERDICTS:-}" && -s "$FI_STANDIN_VERDICTS" ]]; then
    IFS= read -r text <"$FI_STANDIN_VERDICTS"
    tail -n +2 "$FI_STANDIN_VERDICTS" >"$FI_STANDIN_VERDICTS.tmp"
    mv "$FI_STANDIN_VERDICTS.tmp" "$FI_STANDIN_VERDICTS"
  fi
else
  [[ -n "${FI_STANDIN_EDIT:-}" ]] && bash -c "$FI_STANDIN_EDIT"
  text="Done."$'\n'"${FI_STANDIN_RESULT:-FI-RESULT: fixed}"
fi
jq -n --arg r "$text" --argjson c "${FI_STANDIN_COST:-0.25}" \
  '{type:"result",subtype:"success",is_error:false,result:$r,total_cost_usd:$c,permission_denials:[]}'
```

`tests/standins/codex`:

```bash
#!/usr/bin/env bash
# Stand-in `codex` (exec only) for the v3 auto-fix tests. Same FI_STANDIN_*
# variables as tests/standins/claude. Writes the last message to -o <file>
# and prints JSONL events with token usage, like `codex exec --json`.
set -euo pipefail
if [[ -n "${FI_STANDIN_TRACE:-}" ]]; then
  ( IFS=$'\x1f'; printf 'codex\x1f%s\n' "$*" ) >>"$FI_STANDIN_TRACE"
fi
[[ -n "${FI_STANDIN_SLEEP:-}" ]] && sleep "$FI_STANDIN_SLEEP"
last="" sandbox="" cd_dir="" prev=""
for a in "$@"; do
  case "$prev" in
    -o|--output-last-message) last="$a" ;;
    -s|--sandbox) sandbox="$a" ;;
    -C|--cd) cd_dir="$a" ;;
  esac
  prev="$a"
done
[[ -n "$cd_dir" ]] && cd "$cd_dir"
if [[ "$sandbox" == "read-only" ]]; then
  text='{"approve":true,"reason":"ok"}'
  if [[ -n "${FI_STANDIN_VERDICTS:-}" && -s "$FI_STANDIN_VERDICTS" ]]; then
    IFS= read -r text <"$FI_STANDIN_VERDICTS"
    tail -n +2 "$FI_STANDIN_VERDICTS" >"$FI_STANDIN_VERDICTS.tmp"
    mv "$FI_STANDIN_VERDICTS.tmp" "$FI_STANDIN_VERDICTS"
  fi
else
  [[ -n "${FI_STANDIN_EDIT:-}" ]] && bash -c "$FI_STANDIN_EDIT"
  text="Done."$'\n'"${FI_STANDIN_RESULT:-FI-RESULT: fixed}"
fi
[[ -n "$last" ]] && printf '%s\n' "$text" >"$last"
printf '{"type":"thread.started"}\n'
printf '{"type":"turn.completed","usage":{"input_tokens":1200,"cached_input_tokens":0,"output_tokens":300}}\n'
```

Run `chmod +x tests/standins/claude tests/standins/codex`. Then append to `tests/autofix-helpers.bash`:

```bash
# Put the stand-in claude/codex (and the gh shim) first on PATH.
fi_use_standins() {
  export PATH="$TEST_REPO_ROOT/tests/standins:$TEST_REPO_ROOT/tests/bin-shims:$PATH"
  export FI_STANDIN_TRACE="$TMP/standin.trace"
}
```

- [ ] **Step 2: Write the failing tests** in `tests/autofix-engine.bats`:

```bash
#!/usr/bin/env bats
# v3 auto-fix engine layer: argv pinning, watchdog, parsing (spec §4.5, §5, §9).

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_fixture; fi_use_standins
  fi_af_context   # setup already sourced the CLI (a second source hits its readonly vars)
  AFI_id=t1 AFI_wt="$REPO" AFI_root="$REPO"
}
teardown() { fi_teardown_tmp; }

@test "autofix engine: claude fixer argv - dontAsk, no prompts, allowlist, prompt last" {
  fi_af_allowlist 'sh test.sh'
  fi_af_fixer_cmd claude "THE PROMPT" "$TMP/last"
  printf '%s\n' "${FI_AF_CMD[@]}" > "$TMP/argv"
  [ "${FI_AF_CMD[0]}" = claude ]
  [ "${FI_AF_CMD[${#FI_AF_CMD[@]}-1]}" = "THE PROMPT" ]
  [ "${FI_AF_CMD[${#FI_AF_CMD[@]}-3]}" = "--output-format" ]
  [ "${FI_AF_CMD[${#FI_AF_CMD[@]}-2]}" = "json" ]
  grep -qx -- '-p' "$TMP/argv"
  grep -qx 'dontAsk' "$TMP/argv"
  grep -qx -- '--permission-prompts' "$TMP/argv"
  grep -qx 'none' "$TMP/argv"
  grep -qx 'sonnet' "$TMP/argv"
  grep -qx -- '--max-budget-usd' "$TMP/argv"
  grep -qx -- '--max-turns' "$TMP/argv"
  grep -qx 'Bash(sh test.sh)' "$TMP/argv"
  grep -qx 'Bash(sh test.sh \*)' "$TMP/argv"
  ! grep -q 'Bash(git' "$TMP/argv"
  ! grep -qx 'bypassPermissions' "$TMP/argv"
}

@test "autofix engine: bats and pytest runners may be called with a single file" {
  fi_af_allowlist 'bats tests/'
  printf '%s\n' "${FI_AF_TOOLS[@]}" | grep -qx 'Bash(bats \*)'
  fi_af_allowlist 'npm test'
  ! printf '%s\n' "${FI_AF_TOOLS[@]}" | grep -qx 'Bash(npm \*)'
}

@test "autofix engine: claude verifier argv - opus, high effort, read-only tools" {
  fi_af_verifier_cmd claude "V" "$TMP/last" "$TMP/schema"
  printf '%s\n' "${FI_AF_CMD[@]}" > "$TMP/argv"
  grep -qx 'opus' "$TMP/argv"
  grep -qx 'high' "$TMP/argv"
  grep -qx 'Read' "$TMP/argv" && grep -qx 'Grep' "$TMP/argv" && grep -qx 'Glob' "$TMP/argv"
  ! grep -qx 'Edit' "$TMP/argv"
  ! grep -q '^Bash' "$TMP/argv"
  [ "${FI_AF_CMD[${#FI_AF_CMD[@]}-1]}" = "V" ]
}

@test "autofix engine: codex argv - workspace-write fixer, read-only verifier" {
  fi_af_fixer_cmd codex "P" "$TMP/last"
  [ "${FI_AF_CMD[0]}" = codex ] && [ "${FI_AF_CMD[1]}" = exec ]
  printf '%s\n' "${FI_AF_CMD[@]}" | grep -qx 'workspace-write'
  printf '%s\n' "${FI_AF_CMD[@]}" | grep -qx -- '--ephemeral'
  fi_af_verifier_cmd codex "V" "$TMP/last" "$TMP/schema"
  printf '%s\n' "${FI_AF_CMD[@]}" | grep -qx 'read-only'
  printf '%s\n' "${FI_AF_CMD[@]}" | grep -qx 'model_reasoning_effort=high'
  printf '%s\n' "${FI_AF_CMD[@]}" | grep -qx -- '--output-schema'
}

@test "autofix engine: the child runs in cwd with the recursion-guard env" {
  run fi_af_child "$TMP/o" "$TMP/e" "$TMP" sh -c 'pwd; echo "child=$FOUND_ISSUES_AUTOFIX_CHILD"'
  [ "$status" -eq 0 ]
  grep -q "child=1" "$TMP/o"
  [ "$(head -1 "$TMP/o")" = "$(cd "$TMP" && pwd)" ]
}

@test "autofix engine: the watchdog kills a hung child with 124" {
  FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS=1 run fi_af_child "$TMP/o" "$TMP/e" "$TMP" sleep 30
  [ "$status" -eq 124 ]
}

@test "autofix engine: result line - last FI-RESULT wins, markdown tolerated" {
  fi_af_parse_result $'thinking\nFI-RESULT: fixed\nmore\n**FI-RESULT: decide plus or table?**'
  [ "$FI_AF_RESULT" = decide ]
  [ "$FI_AF_RESULT_TEXT" = "plus or table?" ]
  fi_af_parse_result 'no marker here'
  [ "$FI_AF_RESULT" = none ]
  fi_af_parse_result $'`FI-RESULT: already-fixed uses + since abc123`'
  [ "$FI_AF_RESULT" = already-fixed ]
  [ "$FI_AF_RESULT_TEXT" = "uses + since abc123" ]
}

@test "autofix engine: verdict - fenced JSON, prose around it, garbage rejects" {
  fi_af_parse_verdict $'Here:\n```json\n{"approve": true, "reason": "fixes it"}\n```'
  [ "$FI_AF_APPROVE" = true ] && [ "$FI_AF_REASON" = "fixes it" ]
  fi_af_parse_verdict '{"approve":false,"reason":"also edits README"}'
  [ "$FI_AF_APPROVE" = false ] && [ "$FI_AF_REASON" = "also edits README" ]
  fi_af_parse_verdict 'I approve!'
  [ "$FI_AF_APPROVE" = false ]
  fi_af_parse_verdict '{"approve":"yes"}'
  [ "$FI_AF_APPROVE" = false ]
}

@test "autofix engine: cost from claude json, tokens from codex jsonl" {
  FI_AF_COST=0 FI_AF_TOKENS=0
  FI_STANDIN_COST=0.4 claude -p x --output-format json > "$TMP/c.json"
  fi_af_collect claude "$TMP/c.json" ""
  [ "$FI_AF_COST" = "0.4000" ]
  [[ "$FI_AF_TEXT" == *"FI-RESULT: fixed"* ]]
  codex exec -o "$TMP/last" "x" > "$TMP/x.jsonl"
  fi_af_collect codex "$TMP/x.jsonl" "$TMP/last"
  [ "$FI_AF_TOKENS" = 1500 ]
  [[ "$FI_AF_TEXT" == *"FI-RESULT: fixed"* ]]
}

@test "autofix engine: budget left shrinks with spend and runs out" {
  git config found-issues.autofix.runBudget 1
  FI_AF_COST=0.25
  [ "$(fi_af_budget_left)" = "0.75" ]
  FI_AF_COST=0.95
  run fi_af_budget_left
  [ "$status" -eq 1 ]
}

@test "autofix engine: the fixer prompt names the branch rule, the test command and the result contract" {
  AFI_branch=fi/autofix/x-1 AFI_entry='- [open] 2026-10-01 src/calc.sh:1 — add subtracts (fix: small)'
  p="$(fi_af_fixer_prompt 'sh test.sh' 'tests fail: expected 5')"
  [[ "$p" == *"fi/autofix/x-1"* ]]
  [[ "$p" == *"sh test.sh"* ]]
  [[ "$p" == *"add subtracts"* ]]
  [[ "$p" == *"FI-RESULT: fixed"* ]]
  [[ "$p" == *"tests fail: expected 5"* ]]
  [[ "$p" == *"Do not edit docs/found-issues.md"* ]]
}
```

- [ ] **Step 3: Run to confirm failure**

Run: `bats tests/autofix-engine.bats`
Expected: FAIL — `fi_af_allowlist: command not found`.

- [ ] **Step 4: Create `lib/autofix-engine.sh`**

```bash
#!/usr/bin/env bash
# autofix-engine.sh — launcher A's engine children: a headless `claude -p`
# or `codex exec` fixer and a read-only verifier, under a bash watchdog
# (spec 2026-10-03 §4.5, §5 steps 3-5, §9).
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Children only edit files in the item's worktree. They never run git or gh
# and never write the ledger or the state dir (the Codex workspace-write
# sandbox could not); they end with an FI-RESULT line that bash acts on.
#
# Allowlist syntax pinned live 2026-10-03 (Claude Code 2.1.289): Bash(x:*)
# and Bash(x *) are prefix matches, Bash(x) is exact, compound commands are
# denied, and denials never prompt under dontAsk + --permission-prompts none.
#
# Functions:
#   fi_af_child <out> <err> <cwd> cmd...
#   fi_af_allowlist <test-command>
#   fi_af_fixer_prompt <test-command> <feedback>
#   fi_af_verifier_prompt <diff>
#   fi_af_fixer_cmd <engine> <prompt> <last-file>
#   fi_af_verifier_cmd <engine> <prompt> <last-file> <schema-file>
#   fi_af_collect <engine> <out> <last-file>
#   fi_af_parse_result <text>
#   fi_af_parse_verdict <text>
#   fi_af_budget_left

# shellcheck disable=SC2154  # AFI_* are set by fi_af_item_read (autofix-queue.sh)

FI_AF_TOOLS=() FI_AF_CMD=() FI_AF_TEXT="" FI_AF_COST="0" FI_AF_TOKENS=0
FI_AF_RESULT="" FI_AF_RESULT_TEXT="" FI_AF_APPROVE="false" FI_AF_REASON=""

# macOS ships no `timeout`. Poll once a second; on the limit, TERM then KILL.
fi_af_child() {
  local out="$1" err="$2" cwd="$3" secs cpid waited=0 rc=0
  shift 3
  secs="${FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS:-$(( $(fi_af_int runTimeoutMin 20) * 60 ))}"
  ( cd "$cwd" && FOUND_ISSUES_AUTOFIX_CHILD=1 exec "$@" ) </dev/null >"$out" 2>"$err" &
  cpid=$!
  while kill -0 "$cpid" 2>/dev/null; do
    if (( waited >= secs )); then
      kill -TERM "$cpid" 2>/dev/null || true
      sleep 2
      kill -KILL "$cpid" 2>/dev/null || true
      wait "$cpid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$cpid" || rc=$?
  return $rc
}

# Read/Edit tools plus the repo's test command, exactly and with appended
# arguments. Pure test runners may also run a single test file.
fi_af_allowlist() {
  local t="$1" first="${1%% *}"
  FI_AF_TOOLS=(Read Edit Write Glob Grep "Bash($t)" "Bash($t *)")
  case "$first" in
    bats|pytest) FI_AF_TOOLS+=("Bash($first *)") ;;
  esac
}

fi_af_fixer_prompt() {
  local testcmd="$1" feedback="$2"
  cat <<EOF
You are the found-issues auto-fixer. This run is sanctioned and unattended:
you are in a dedicated git worktree on branch ${AFI_branch} (never main), and
nobody will answer questions or permission prompts.

The issue, from the repo's found-issues ledger:
${AFI_entry}

Do exactly this:
1. Check whether the symptom is still present in this checkout.
2. Add or extend a test that fails because of this symptom. The repo's test
   command is: ${testcmd}
3. Make the smallest change that fixes the symptom. Change nothing unrelated.
   Do not edit docs/found-issues.md or any found-issues ledger.
4. Run the test command until it passes.
Never run git, gh, or any command other than the test command; the
orchestrator commits, pushes and opens the PR.

End your reply with exactly one line, one of:
FI-RESULT: fixed
FI-RESULT: already-fixed <evidence>
FI-RESULT: decide <the question a human must answer first>
FI-RESULT: manual <why this cannot be fixed or proven by a test>
EOF
  if [[ -n "$feedback" ]]; then
    printf '\nThe previous attempt was rejected and the worktree was reset. Why:\n%s\n' "$feedback"
  fi
}

fi_af_verifier_prompt() {
  local diff="$1"
  [[ ${#diff} -gt 60000 ]] && diff="${diff:0:60000}"$'\n[diff truncated]'
  cat <<EOF
You are a strict reviewer of an unattended bug fix. You may read files in this
checkout; do not edit anything.

The issue:
${AFI_entry}

The change (git diff against the default branch):
${diff}

Approve only if all three hold: the change fixes the cited symptom; it
changes nothing unrelated; and it adds or extends a test that reproduces the
symptom (fails without the fix).

Reply with only a JSON object: {"approve": true or false, "reason": "<one sentence>"}
EOF
}

fi_af_fixer_cmd() {
  local engine="$1" prompt="$2" last="$3"
  if [[ "$engine" == "codex" ]]; then
    FI_AF_CMD=(codex exec --sandbox workspace-write -C "$AFI_wt" --ephemeral --json -o "$last" "$prompt")
  else
    FI_AF_CMD=(claude -p --model sonnet --max-budget-usd "$(fi_af_budget_left || printf '0.10')"
      --max-turns 40 --no-session-persistence
      --permission-mode dontAsk --permission-prompts none
      --allowedTools "${FI_AF_TOOLS[@]}"
      --output-format json "$prompt")
  fi
}

fi_af_verifier_cmd() {
  local engine="$1" prompt="$2" last="$3" schema="$4"
  if [[ "$engine" == "codex" ]]; then
    printf '%s\n' '{"type":"object","properties":{"approve":{"type":"boolean"},"reason":{"type":"string"}},"required":["approve","reason"],"additionalProperties":false}' >"$schema"
    FI_AF_CMD=(codex exec --sandbox read-only -C "$AFI_wt" --ephemeral --json
      -c model_reasoning_effort=high --output-schema "$schema" -o "$last" "$prompt")
  else
    FI_AF_CMD=(claude -p --model opus --effort high --max-budget-usd "$(fi_af_budget_left || printf '0.10')"
      --max-turns 15 --no-session-persistence
      --permission-mode dontAsk --permission-prompts none
      --allowedTools Read Grep Glob
      --output-format json "$prompt")
  fi
}

fi_af_collect() {
  local engine="$1" out="$2" last="$3" c t
  FI_AF_TEXT=""
  if [[ "$engine" == "codex" ]]; then
    [[ -n "$last" && -f "$last" ]] && FI_AF_TEXT="$(cat "$last")"
    t="$(jq -s '[.[] | select(.type=="turn.completed") | (.usage.input_tokens // 0) + (.usage.output_tokens // 0)] | add // 0' "$out" 2>/dev/null || true)"
    [[ "$t" =~ ^[0-9]+$ ]] && FI_AF_TOKENS=$((FI_AF_TOKENS + t))
  else
    FI_AF_TEXT="$(jq -r '.result // empty' "$out" 2>/dev/null || true)"
    c="$(jq -r '.total_cost_usd // 0' "$out" 2>/dev/null || true)"
    [[ "$c" =~ ^[0-9.eE+-]+$ ]] || c=0
    FI_AF_COST="$(awk -v a="$FI_AF_COST" -v b="$c" 'BEGIN { printf "%.4f", a + b }')"
  fi
}

fi_af_parse_result() {
  FI_AF_RESULT="none" FI_AF_RESULT_TEXT=""
  local line re='^[[:space:]*`]*FI-RESULT:[[:space:]]*(fixed|already-fixed|decide|manual)([[:space:]]+(.*))?$'
  while IFS= read -r line; do
    line="${line%$'\r'}"
    while [[ "$line" == *'*' || "$line" == *'`' || "$line" == *' ' ]]; do line="${line%?}"; done
    if [[ "$line" =~ $re ]]; then
      FI_AF_RESULT="${BASH_REMATCH[1]}"
      FI_AF_RESULT_TEXT="${BASH_REMATCH[3]}"
    fi
  done <<<"$1"
}

fi_af_parse_verdict() {
  FI_AF_APPROVE="false" FI_AF_REASON="no parseable verdict"
  local t="$1" v
  [[ "$t" == *"{"*"}"* ]] || return 0
  t="{${t#*\{}"
  t="${t%\}*}}"
  v="$(printf '%s' "$t" | jq -r 'if (.approve | type) == "boolean" then "\(.approve)\t\(.reason // "")" else empty end' 2>/dev/null || true)"
  [[ -n "$v" ]] || return 0
  FI_AF_APPROVE="${v%%$'\t'*}"
  FI_AF_REASON="${v#*$'\t'}"
  FI_AF_REASON="${FI_AF_REASON//$'\n'/ }"
}

# Spec §7: runBudget caps the whole run (every fixer and verifier child).
fi_af_budget_left() {
  awk -v b="$(fi_af_budget)" -v s="$FI_AF_COST" 'BEGIN { l = b - s; if (l < 0.10) exit 1; printf "%.2f", l }'
}
```

Then source it in `bin/found-issues` after `autofix-queue.sh`, using the usual shellcheck comment.

- [ ] **Step 5: Run to confirm pass**

Run: `bats tests/autofix-engine.bats`
Expected: `11 tests, 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add lib/autofix-engine.sh bin/found-issues tests/standins tests/autofix-helpers.bash tests/autofix-engine.bats
git commit -m "feat(v3) autofix engine layer: pinned argv, watchdog, result/verdict/cost parsing"
```

---

### Task 6: Ship — diff, ledger reset, PR, annotation, auto-merge, merge-when-green

**Files:**
- Create: `lib/autofix-ship.sh`
- Modify: `bin/found-issues` (source it after `autofix-engine.sh`)
- Modify: `tests/bin-shims/gh` (`pr create`, `pr merge`)
- Modify: `lib/autofix.sh` (`diff`, `ship`, `merge-when-green`)
- Test: `tests/autofix-ship.bats`

**Interfaces:**
- Consumes:
  - `AFI_*` of a running item;
  - `fi_af_child`, `fi_af_log`;
  - `fi_af_find_entry [<ledger>]` (Task 3, key-exact);
  - `fi_ledger_*`;
  - `fi_parse_entry_vars` → `FE_symptom`.
- **Deviation from spec §5.6:** ship appends `(PR: owner/repo#N)` to the entry by dedup key instead of running `annotate-pr <N> --pick <loc>`. `--pick` matches by location and cannot tell apart two entries on the same line; the Task 6 test pins this.
- Produces:
  - `fi_af_ledger_paths <wt>` → the ledger paths that exist in the worktree tree, as stdout lines.
  - `fi_af_reset_ledger <wt> <base>`.
  - `fi_af_diff <wt> <base>` → stdout, ledger excluded.
  - `fi_af_run_tests <wt> <cmd> <log>` → rc.
  - `fi_af_annotate_ledger <ledger|""> <annotation>` → 0 written, 1 entry absent, 3 the ledger changed underneath.
  - `fi_af_ship` → 0 and sets `FI_AF_PR` and `FI_AF_MERGE` (`auto|merge-when-green|none`); on failure returns 1 and sets `FI_AF_WHY`.
  - `fi_af_spawn <cwd> <found-issues args…>`.
  - `fi_af_merge_when_green <N>` → 0 merged/closed, 1 failed/timeout.
  - `FI_SELF`.
  - CLI `autofix diff <id>`, `autofix ship <id>`, `autofix merge-when-green <N>`.

- [ ] **Step 1: Extend the gh shim.** In `tests/bin-shims/gh`, document two new env vars in the header:

```bash
#   GH_MOCK_PR_CREATE_URL URL printed by `gh pr create` (default https://github.com/foo/bar/pull/7)
#   GH_MOCK_PR_MERGE      "ok" (default) or "fail" — exit of `gh pr merge`
```

and add two cases before `"auth status")`:

```bash
  "pr create")
    printf '%s\n' "${GH_MOCK_PR_CREATE_URL:-https://github.com/foo/bar/pull/7}"
    exit 0
    ;;
  "pr merge")
    [[ "${GH_MOCK_PR_MERGE:-ok}" == "ok" ]] && exit 0
    printf 'auto-merge is not allowed for this repository\n' >&2
    exit 1
    ;;
```

- [ ] **Step 2: Write the failing tests** in `tests/autofix-ship.bats`:

```bash
#!/usr/bin/env bats
# v3 auto-fix ship (spec §5 step 6, audit prompt-9).

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_fixture; fi_use_standins
  export GH_MOCK_TRACE="$TMP/gh.trace"
  export GH_MOCK_PR_VIEW=$'7\t{"number":7,"state":"OPEN","statusCheckRollup":[]}'
  fi_af_queue_fixture; ST="$FI_AF_ST"
  "$FI_BIN" autofix claim "$ID" >/dev/null
  WT="$REPO/.claude/worktrees/fi-autofix-$ID"
  BR="fi/autofix/src-calc-sh-1-$ID"
}
teardown() { fi_teardown_tmp; }

fix_it() { sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"; }

@test "autofix ship: commits the fix, pushes, opens the PR, arms auto-merge" {
  fix_it
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #7"* ]]
  git -C "$TMP/remote.git" rev-parse --verify -q "refs/heads/$BR"
  msg="$(git -C "$TMP/remote.git" log -1 --format=%s "$BR~1")"
  [ "$msg" = "fix: add subtracts (found-issues src/calc.sh:1)" ]
  grep -q '^pr create --base main --head '"$BR" "$GH_MOCK_TRACE"
  grep -q '^pr merge 7 --auto --squash$' "$GH_MOCK_TRACE"
}

@test "autofix ship: annotates both the PR branch ledger and the source ledger" {
  fix_it
  "$FI_BIN" autofix ship "$ID"
  git -C "$TMP/remote.git" show "$BR:docs/found-issues.md" | grep -q 'add subtracts (fix: small) (PR: foo/bar#7)$'
  grep -q 'add subtracts (fix: small) (PR: foo/bar#7)$' "$REPO/docs/found-issues.md"
}

@test "autofix ship: an entry that origin never saw annotates only the source ledger" {
  printf -- '- [open] 2026-10-02 src/calc.sh:1 — add ignores negatives (fix: small)\n' >> "$REPO/docs/found-issues.md"
  fi_af_context   # setup already sourced the CLI (a second source hits its readonly vars)
  fi_af_queue_spot "$(grep 'ignores negatives' docs/found-issues.md)" >/dev/null
  id2="$(ls "$ST/queue" | head -1)"
  "$FI_BIN" autofix release "$ID" --manual "test reshuffle" >/dev/null
  "$FI_BIN" autofix claim "$id2" >/dev/null
  wt2="$REPO/.claude/worktrees/fi-autofix-$id2"
  sed -i.bak 's/ - / + /' "$wt2/src/calc.sh"; rm -f "$wt2/src/calc.sh.bak"
  run "$FI_BIN" autofix ship "$id2"
  [ "$status" -eq 0 ]
  br2="$(git -C "$TMP/remote.git" for-each-ref --format='%(refname:short)' "refs/heads/fi/autofix/*$id2")"
  [ "$(git -C "$TMP/remote.git" rev-list --count "main..$br2")" = 1 ]
  grep -q 'add ignores negatives (fix: small) (PR: foo/bar#7)$' "$REPO/docs/found-issues.md"
  # same file:line, different entry: left alone on both sides
  ! grep -q 'add subtracts .*(PR: foo/bar#7)' "$REPO/docs/found-issues.md"
  ! git -C "$TMP/remote.git" show "$br2:docs/found-issues.md" | grep -q '(PR: foo/bar#7)'
}

@test "autofix ship: ledger edits made in the worktree never reach the fix commit" {
  fix_it
  printf -- '- [open] 2026-10-03 junk.sh — child sync noise\n' >> "$WT/docs/found-issues.md"
  "$FI_BIN" autofix diff "$ID" > "$TMP/diff"
  ! grep -q 'child sync noise' "$TMP/diff"
  grep -qF '+add() { echo $(( $1 + $2 )); }' "$TMP/diff"
  "$FI_BIN" autofix ship "$ID"
  ! git -C "$TMP/remote.git" show "$BR~1" -- docs/found-issues.md | grep -q 'child sync noise'
  ! git -C "$TMP/remote.git" show "$BR:docs/found-issues.md" | grep -q 'child sync noise'
}

@test "autofix ship: red tests refuse to ship and push nothing" {
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tests fail"* ]]
  ! git -C "$TMP/remote.git" rev-parse --verify -q "refs/heads/$BR"
  [ ! -s "$GH_MOCK_TRACE" ] || ! grep -q 'pr create' "$GH_MOCK_TRACE"
}

@test "autofix ship: auto-merge refused falls back to merge-when-green, which merges a check-less PR" {
  fix_it
  export GH_MOCK_PR_MERGE=fail FOUND_ISSUES_AUTOFIX_MERGE_SLEEP=0
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"merge-when-green"* ]]
  # the detached watcher inherited GH_MOCK_PR_MERGE=fail, so its merge call
  # exits 1 — the trace line proves it saw a check-less PR and tried to merge
  for _ in $(seq 1 40); do grep -q '^pr merge 7 --squash$' "$GH_MOCK_TRACE" && break; sleep 0.25; done
  grep -q '^pr merge 7 --squash$' "$GH_MOCK_TRACE"
}

@test "autofix merge-when-green: waits on pending, merges on green, refuses red" {
  export FOUND_ISSUES_AUTOFIX_MERGE_SLEEP=0 FOUND_ISSUES_AUTOFIX_MERGE_POLLS=2
  export GH_MOCK_PR_VIEW=$'7\t{"state":"OPEN","statusCheckRollup":[{"conclusion":"","status":"IN_PROGRESS"}]}'
  run "$FI_BIN" autofix merge-when-green 7
  [ "$status" -eq 1 ]
  [[ "$output" == *"still pending"* ]]
  export GH_MOCK_PR_VIEW=$'7\t{"state":"OPEN","statusCheckRollup":[{"conclusion":"FAILURE"}]}'
  run "$FI_BIN" autofix merge-when-green 7
  [ "$status" -eq 1 ]
  [[ "$output" == *"checks failed"* ]]
  export GH_MOCK_PR_VIEW=$'7\t{"state":"OPEN","statusCheckRollup":[{"conclusion":"SUCCESS"},{"state":"SUCCESS"}]}'
  run "$FI_BIN" autofix merge-when-green 7
  [ "$status" -eq 0 ]
  grep -q '^pr merge 7 --squash$' "$GH_MOCK_TRACE"
  export GH_MOCK_PR_VIEW=$'7\t{"state":"MERGED","statusCheckRollup":[]}'
  run "$FI_BIN" autofix merge-when-green 7
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 3: Run to confirm failure**

Run: `bats tests/autofix-ship.bats`
Expected: FAIL — `autofix: unknown option 'ship'`.

- [ ] **Step 4: Create `lib/autofix-ship.sh`**

```bash
#!/usr/bin/env bash
# autofix-ship.sh — turn a verified worktree into a self-merging PR
# (spec 2026-10-03 §5 step 6; audit prompt-9: the (PR:) annotation is
# committed onto the PR branch so it reaches the default branch).
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   fi_af_ledger_paths <wt>
#   fi_af_reset_ledger <wt> <base>
#   fi_af_diff <wt> <base>
#   fi_af_run_tests <wt> <cmd> <log>
#   fi_af_annotate_ledger <ledger|""> <annotation>
#   fi_af_spawn <cwd> <found-issues args...>
#   fi_af_ship
#   fi_af_merge_when_green <N>

# shellcheck disable=SC2154  # AFI_*/FE_* come from autofix-queue.sh / parse-entries.sh

FI_AF_PR="" FI_AF_MERGE="" FI_AF_TESTCMD="" FI_AF_VERDICT_REASON=""
FI_SELF="${FI_BIN_DIR:-}/found-issues"

# The worktree's own ledger files, relative. Only paths INSIDE the worktree:
# fi_find_issues_file would walk up into the source checkout when the
# worktree has none (Review Focus 2).
fi_af_ledger_paths() {
  local p
  for p in docs/found-issues.md docs/found-issues-archive.md .found-issues.md; do
    [[ -f "$1/$p" ]] && printf '%s\n' "$p"
  done
  return 0
}

# The fixer must not change the ledger, and a headless child's SessionStart
# sync may have (Review Focus 3). Put every ledger file back to origin.
fi_af_reset_ledger() {
  local wt="$1" base="$2" p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if git -C "$wt" cat-file -e "origin/$base:$p" 2>/dev/null; then
      git -C "$wt" checkout -q "origin/$base" -- "$p" 2>/dev/null || true
    else
      rm -f "$wt/$p"
    fi
  done <<<"$(fi_af_ledger_paths "$wt")"
}

fi_af_diff() {
  fi_af_reset_ledger "$1" "$2"
  git -C "$1" add -A >/dev/null 2>&1 || true
  git -C "$1" diff --cached "origin/$2"
}

fi_af_run_tests() {
  fi_af_child "$3" "$3.err" "$1" bash -c "$2" || return $?
}

# Append a closing annotation to THIS item's entry (matched by dedup key) in
# <ledger> ("" = the source checkout's). `annotate-pr --pick <loc>` matches
# by location, so with two entries on one line it tags the wrong one or both.
fi_af_annotate_ledger() {
  fi_af_find_entry "$1" || return 1
  local new="$FI_AF_ENTRY $2" snapshot tmp line done_one=0
  snapshot="$(fi_ledger_snapshot "$FI_AF_LEDGER")"
  tmp="$(fi_ledger_tmp "$FI_AF_LEDGER")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( ! done_one )) && [[ "$line" == "$FI_AF_ENTRY" ]]; then
      printf '%s\n' "$new" >>"$tmp"; done_one=1
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$FI_AF_LEDGER"
  fi_ledger_replace "$FI_AF_LEDGER" "$tmp" "$snapshot"
}

fi_af_spawn() {
  local cwd="$1"
  shift
  ( cd "$cwd" && nohup "$FI_SELF" "$@" </dev/null >>"$FI_AF_RUNS/spawn.log" 2>&1 & )
}

_fi_af_pr_body() {
  local tlog="$1"
  printf 'Unattended fix by found-issues auto-fix (launcher A, engine %s).\n\n' "${AFI_engine:-?}"
  printf 'Issue:\n\n    %s\n\n' "$AFI_entry"
  printf 'Tests: `%s` passed. Last lines:\n\n' "$FI_AF_TESTCMD"
  tail -n 15 "$tlog" 2>/dev/null | sed 's/^/    /'
  printf '\nVerifier: approved — %s\n' "${FI_AF_VERDICT_REASON:-n/a}"
  printf 'Run cost: $%s (claude), %s tokens (codex)\n\n' "${FI_AF_COST:-0}" "${FI_AF_TOKENS:-0}"
  printf 'This PR merges itself when its checks pass (found-issues auto-fix policy).\n'
}

fi_af_ship() {
  local wt="$AFI_wt" base="$AFI_base" br="$AFI_branch" runlog="$FI_AF_RUNS/$AFI_id.log"
  local tlog="$FI_AF_RUNS/$AFI_id.ship-tests.log" bodyf="$FI_AF_RUNS/$AFI_id.pr-body.md" frag url p
  FI_AF_PR="" FI_AF_MERGE="none" FI_AF_WHY=""
  [[ -n "$FI_AF_TESTCMD" ]] || FI_AF_TESTCMD="$(fi_af_test_command "$wt")" || { FI_AF_WHY="no test command"; return 1; }
  fi_af_reset_ledger "$wt" "$base"
  fi_af_run_tests "$wt" "$FI_AF_TESTCMD" "$tlog" || { FI_AF_WHY="tests fail at ship"; return 1; }
  git -C "$wt" add -A
  if git -C "$wt" diff --cached --quiet "origin/$base"; then FI_AF_WHY="nothing to ship"; return 1; fi
  fi_parse_entry_vars "$AFI_entry" || true
  frag="${FE_symptom:-$AFI_loc}"
  frag="${frag:0:60}"
  git -C "$wt" commit -q -m "fix: $frag (found-issues $AFI_loc)" >>"$runlog" 2>&1 \
    || { FI_AF_WHY="git commit refused (a commit hook?)"; return 1; }
  git -C "$wt" push -q -u origin "$br" >>"$runlog" 2>&1 || { FI_AF_WHY="git push failed"; return 1; }
  _fi_af_pr_body "$tlog" >"$bodyf"
  url="$(cd "$wt" && gh pr create --base "$base" --head "$br" --title "fix: $frag" --body-file "$bodyf" 2>>"$runlog")" \
    || { FI_AF_WHY="gh pr create failed"; return 1; }
  FI_AF_PR="${url##*/}"
  [[ "$FI_AF_PR" =~ ^[0-9]+$ ]] || { FI_AF_WHY="no PR number in: $url"; return 1; }
  fi_af_log "$AFI_id" "opened PR #$FI_AF_PR"

  local ann="(PR: $AFI_slug#$FI_AF_PR)" wl=""
  # The PR branch's ledger, when origin already has the entry (prompt-9).
  for p in docs/found-issues.md .found-issues.md; do
    [[ -f "$wt/$p" ]] && { wl="$p"; break; }
  done
  if [[ -n "$wl" ]] && fi_af_annotate_ledger "$wt/$wl" "$ann"; then
    git -C "$wt" add -- "$wl"
    if git -C "$wt" commit -q -m "docs(found-issues): annotate $AFI_loc with PR $FI_AF_PR" >>"$runlog" 2>&1; then
      git -C "$wt" push -q origin "$br" >>"$runlog" 2>&1 || fi_af_log "$AFI_id" "ledger annotation push failed"
    fi
  fi
  # The source checkout's ledger, where sync will close the entry on merge.
  fi_af_annotate_ledger "" "$ann" || fi_af_log "$AFI_id" "source ledger annotation failed"

  if ( cd "$wt" && gh pr merge "$FI_AF_PR" --auto --squash ) >>"$runlog" 2>&1; then
    FI_AF_MERGE="auto"
  else
    fi_af_spawn "$AFI_root" autofix merge-when-green "$FI_AF_PR"
    FI_AF_MERGE="merge-when-green"
  fi
  fi_af_log "$AFI_id" "merge: $FI_AF_MERGE"
}

fi_af_merge_when_green() {
  local n="$1" i v polls="${FOUND_ISSUES_AUTOFIX_MERGE_POLLS:-60}" pause="${FOUND_ISSUES_AUTOFIX_MERGE_SLEEP:-60}"
  local jqf='[.state, ([.statusCheckRollup[]? | (.conclusion // .state // "")] | if length == 0 then "none" elif any(. == "FAILURE" or . == "ERROR" or . == "CANCELLED" or . == "TIMED_OUT" or . == "ACTION_REQUIRED" or . == "STARTUP_FAILURE") then "fail" elif all(. == "SUCCESS" or . == "SKIPPED" or . == "NEUTRAL") then "green" else "pending" end)] | join(" ")'
  for (( i = 0; i < polls; i++ )); do
    v="$(gh pr view "$n" --json state,statusCheckRollup --jq "$jqf" 2>/dev/null || true)"
    case "$v" in
      MERGED*|CLOSED*) printf 'PR #%s is already %s\n' "$n" "${v%% *}"; return 0 ;;
      "OPEN none"|"OPEN green")
        gh pr merge "$n" --squash && { printf 'merged PR #%s\n' "$n"; return 0; }
        fi_err "autofix: merging PR #$n failed"; return 1 ;;
      "OPEN fail") fi_err "autofix: PR #$n checks failed — not merging"; return 1 ;;
    esac
    sleep "$pause"
  done
  fi_err "autofix: PR #$n still pending after $polls checks — not merging"
  return 1
}
```

Then source it in `bin/found-issues` after `autofix-engine.sh`.

- [ ] **Step 5: Dispatch `diff`, `ship` and `merge-when-green`.** In `cmd_autofix`:

```bash
    diff|ship)
      [[ $# -eq 1 ]] || { fi_err "Usage: found-issues autofix $sub <id>"; return 2; }
      fi_af_context || return 1
      fi_af_item_read "$FI_AF_ST/running/$1" || { fi_err "autofix: $1 is not claimed"; return 1; }
      if [[ "$sub" == "diff" ]]; then fi_af_diff "$AFI_wt" "$AFI_base"; return; fi
      if fi_af_ship; then
        printf 'Shipped %s as PR #%s (merge: %s)\n' "$1" "$FI_AF_PR" "$FI_AF_MERGE"
        fi_af_finish "$1" shipped "PR #$FI_AF_PR, merge $FI_AF_MERGE"
      else
        fi_err "autofix: ship refused — $FI_AF_WHY"
        return 1
      fi ;;
    merge-when-green)
      [[ $# -eq 1 && "$1" =~ ^[0-9]+$ ]] || { fi_err "Usage: found-issues autofix merge-when-green <PR-number>"; return 2; }
      fi_af_merge_when_green "$1" ;;
```

A refused `ship` leaves the item running and claimed. The caller decides between retrying and releasing, and the `run` orchestrator (Task 7) releases it as failed.

- [ ] **Step 6: Run to confirm pass**

Run: `bats tests/autofix-ship.bats`
Expected: `7 tests, 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add lib/autofix-ship.sh lib/autofix.sh bin/found-issues tests/bin-shims/gh tests/autofix-ship.bats
git commit -m "feat(v3) autofix ship: PR with ledger annotation on both sides, auto-merge or merge-when-green"
```

---

### Task 7: `autofix run` (launcher A) and `autofix status`

**Files:**
- Modify: `lib/autofix.sh` (`_fi_af_run_one`, `_fi_af_run`, `_fi_af_status`, dispatch `run` and `status`)
- Test: `tests/autofix-run.bats`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - CLI `autofix run <id> [--engine claude|codex]`. It returns 0 when every item it touched reached a defined outcome, or when the item stays queued (capped or locked).
  - CLI `autofix status`.
  - `done/<id>` records `result=`, `pr=`, `cost=`, `tokens=`.

- [ ] **Step 1: Write the failing tests** in `tests/autofix-run.bats`:

```bash
#!/usr/bin/env bats
# v3 launcher A end to end with stand-in engines (spec §5, §9, §10).

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_fixture; fi_use_standins
  export GH_MOCK_TRACE="$TMP/gh.trace"
  export GH_MOCK_PR_VIEW=$'7\t{"number":7,"state":"OPEN","statusCheckRollup":[]}'
  export FI_STANDIN_EDIT="sed -i.bak 's/ - / + /' src/calc.sh && rm -f src/calc.sh.bak"
  fi_af_queue_fixture; ST="$FI_AF_ST"
}
teardown() { fi_teardown_tmp; }

@test "autofix run: claude engine ships a self-merging PR and cleans up" {
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '^result=shipped: PR #7' "$ST/done/$ID"
  grep -q '^pr=7$' "$ST/done/$ID"
  grep -q '^cost=0.5000$' "$ST/done/$ID"
  [ ! -d "$REPO/.claude/worktrees/fi-autofix-$ID" ]
  [ ! -d "$ST/lock" ]
  grep -q '(PR: foo/bar#7)' "$REPO/docs/found-issues.md"
  [ "$(grep -c '^claude' "$FI_STANDIN_TRACE")" = 2 ]
  grep -q '^pr merge 7 --auto --squash$' "$GH_MOCK_TRACE"
}

@test "autofix run: codex engine ships and records tokens" {
  run "$FI_BIN" autofix run "$ID" --engine codex
  [ "$status" -eq 0 ]
  grep -q '^result=shipped: PR #7' "$ST/done/$ID"
  grep -q '^tokens=3000$' "$ST/done/$ID"
  grep -q 'workspace-write' "$FI_STANDIN_TRACE"
  grep -q 'read-only' "$FI_STANDIN_TRACE"
}

@test "autofix run: a reject then an approve ships on attempt 2 from a reset worktree" {
  printf '%s\n' '{"approve":false,"reason":"no test added"}' '{"approve":true,"reason":"ok now"}' > "$TMP/verdicts"
  export FI_STANDIN_VERDICTS="$TMP/verdicts"
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '^result=shipped' "$ST/done/$ID"
  [ "$(grep -c '^claude' "$FI_STANDIN_TRACE")" = 4 ]
  grep -q 'no test added' "$FI_STANDIN_TRACE"
}

@test "autofix run: two failed attempts tag autofix-failed and ship nothing" {
  export FI_STANDIN_EDIT="true"
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '(autofix-failed: no change after 2 attempts)$' "$REPO/docs/found-issues.md"
  grep -q '^result=failed' "$ST/done/$ID"
  ! grep -q 'pr create' "$GH_MOCK_TRACE" 2>/dev/null
  [ ! -d "$REPO/.claude/worktrees/fi-autofix-$ID" ]
}

@test "autofix run: red tests after the edit count as a failed attempt" {
  export FI_STANDIN_EDIT="echo '# touched' >> src/calc.sh"
  run "$FI_BIN" autofix run "$ID" --engine claude
  grep -q '(autofix-failed: tests fail after 2 attempts)$' "$REPO/docs/found-issues.md"
}

@test "autofix run: FI-RESULT decide releases the entry to the decision queue" {
  export FI_STANDIN_RESULT="FI-RESULT: decide plus, or a lookup table?"
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  grep -q 'add subtracts (decide: plus, or a lookup table?)$' "$REPO/docs/found-issues.md"
  [ "$(grep -c '^claude' "$FI_STANDIN_TRACE")" = 1 ]
}

@test "autofix run: no test command releases as manual without starting an engine" {
  git config --unset found-issues.autofix.testCommand
  run "$FI_BIN" autofix run "$ID" --engine claude
  grep -q '(manual: no test command)$' "$REPO/docs/found-issues.md"
  [ ! -s "$FI_STANDIN_TRACE" ]
}

@test "autofix run: a hung engine is killed and the run still ends with an outcome" {
  export FI_STANDIN_SLEEP=30 FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS=1
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '(autofix-failed: ' "$REPO/docs/found-issues.md"
  [ ! -d "$ST/lock" ]
}

@test "autofix run: a spent budget stops before the next child" {
  git config found-issues.autofix.runBudget 0.3
  export FI_STANDIN_COST=0.25
  run "$FI_BIN" autofix run "$ID" --engine claude
  grep -q '(autofix-failed: run budget spent' "$REPO/docs/found-issues.md"
  [ "$(grep -c '^claude' "$FI_STANDIN_TRACE")" = 1 ]
}

@test "autofix run: drains the rest of the queue oldest first" {
  printf -- '- [open] 2026-10-02 test.sh:2 — second thing (fix: small)\n' >> "$REPO/docs/found-issues.md"
  git -C "$REPO" commit -qam "second entry" && git -C "$REPO" push -q
  fi_af_context   # setup already sourced the CLI (a second source hits its readonly vars)
  sleep 1
  fi_af_queue_spot "$(grep 'second thing' "$REPO/docs/found-issues.md")" >/dev/null
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$(ls "$ST/done" | wc -l | tr -d ' ')" = 2 ]
  [ -z "$(ls "$ST/queue")" ]
}

@test "autofix run: capped or locked leaves the item queued and exits 0" {
  fi_af_context   # setup already sourced the CLI (a second source hits its readonly vars)
  fi_af_lock someone-else
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  [ -f "$ST/queue/$ID" ]
  [ ! -s "$FI_STANDIN_TRACE" ]
}

@test "autofix status: shows the switch, today's count, queue and results" {
  run "$FI_BIN" autofix status
  [[ "$output" == *"Auto-fix: on"* ]]
  [[ "$output" == *"Queued (1)"* ]]
  [[ "$output" == *"src/calc.sh:1"* ]]
  "$FI_BIN" autofix run "$ID" --engine claude >/dev/null
  run "$FI_BIN" autofix status
  [[ "$output" == *"Today: 1/5 spot fixes"* ]]
  [[ "$output" == *"shipped: PR #7"* ]]
  "$FI_BIN" autofix off >/dev/null
  run "$FI_BIN" autofix status
  [[ "$output" == *"Auto-fix: off"* ]]
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `bats tests/autofix-run.bats`
Expected: FAIL — `autofix: unknown option 'run'`.

- [ ] **Step 3: Implement in `lib/autofix.sh`** (functions above `cmd_autofix`):

```bash
# One fixer child plus its bookkeeping. Sets FI_AF_RESULT/_TEXT.
_fi_af_fix_attempt() {
  local engine="$1" n="$2" feedback="$3" base="$FI_AF_RUNS/$AFI_id.fix$n" rc=0
  fi_af_allowlist "$FI_AF_TESTCMD"
  fi_af_fixer_cmd "$engine" "$(fi_af_fixer_prompt "$FI_AF_TESTCMD" "$feedback")" "$base.last"
  fi_af_child "$base.out" "$base.err" "$AFI_wt" "${FI_AF_CMD[@]}" || rc=$?
  fi_af_collect "$engine" "$base.out" "$base.last"
  fi_af_parse_result "$FI_AF_TEXT"
  (( rc == 124 )) && fi_af_log "$AFI_id" "attempt $n: fixer timed out"
  fi_af_log "$AFI_id" "attempt $n: fixer rc=$rc result=$FI_AF_RESULT"
}

_fi_af_verify() {
  local engine="$1" n="$2" base="$FI_AF_RUNS/$AFI_id.verify$n" rc=0
  fi_af_verifier_cmd "$engine" "$(fi_af_verifier_prompt "$(fi_af_diff "$AFI_wt" "$AFI_base")")" \
    "$base.last" "$FI_AF_RUNS/verdict.schema.json"
  fi_af_child "$base.out" "$base.err" "$AFI_wt" "${FI_AF_CMD[@]}" || rc=$?
  fi_af_collect "$engine" "$base.out" "$base.last"
  fi_af_parse_verdict "$FI_AF_TEXT"
  fi_af_log "$AFI_id" "attempt $n: verifier rc=$rc approve=$FI_AF_APPROVE reason=$FI_AF_REASON"
}

_fi_af_reset_wt() {
  git -C "$AFI_wt" reset -q --hard "origin/$AFI_base" >/dev/null 2>&1 || true
  git -C "$AFI_wt" clean -qfd >/dev/null 2>&1 || true
}

# Spec §5 for one claimed item: up to 2 attempts of fix -> bash tests ->
# verifier, then ship. Every path ends in fi_af_finish.
_fi_af_run_one() {
  local id="$1" engine_opt="$2" rc=0 engine n feedback="" why="" tlog
  fi_af_claim "$id" || return $?
  fi_af_item_read "$FI_AF_ST/running/$id"
  FI_AF_COST=0 FI_AF_TOKENS=0
  if ! FI_AF_TESTCMD="$(fi_af_test_command "$AFI_wt")"; then
    fi_af_finish "$id" manual "no test command"; return 0
  fi
  if ! engine="$(fi_af_engine "${engine_opt:-$AFI_engine}")" || ! command -v "$engine" >/dev/null 2>&1; then
    fi_af_finish "$id" failed "no ${engine:-claude or codex} on PATH"; return 0
  fi
  AFI_engine="$engine"
  for n in 1 2; do
    touch "$FI_AF_ST/lock" 2>/dev/null || true
    if [[ "$engine" == "claude" ]] && ! fi_af_budget_left >/dev/null; then
      why="run budget spent (\$$FI_AF_COST)"; break
    fi
    (( n == 1 )) || _fi_af_reset_wt
    _fi_af_fix_attempt "$engine" "$n" "$feedback"
    case "$FI_AF_RESULT" in
      already-fixed|decide|manual)
        fi_af_finish "$id" "$FI_AF_RESULT" "${FI_AF_RESULT_TEXT:-no reason given}"
        return 0 ;;
    esac
    if [[ -z "$(fi_af_diff "$AFI_wt" "$AFI_base")" ]]; then
      why="no change"; feedback="The attempt changed no files."; continue
    fi
    tlog="$FI_AF_RUNS/$id.tests$n.log"
    if ! fi_af_run_tests "$AFI_wt" "$FI_AF_TESTCMD" "$tlog"; then
      why="tests fail"; feedback="The test command failed. Last lines:"$'\n'"$(tail -n 20 "$tlog" 2>/dev/null)"
      continue
    fi
    if [[ "$engine" == "claude" ]] && ! fi_af_budget_left >/dev/null; then
      why="run budget spent (\$$FI_AF_COST)"; break
    fi
    _fi_af_verify "$engine" "$n"
    if [[ "$FI_AF_APPROVE" != "true" ]]; then
      why="verifier rejected: $FI_AF_REASON"; feedback="The reviewer rejected it: $FI_AF_REASON"; continue
    fi
    FI_AF_VERDICT_REASON="$FI_AF_REASON"
    if fi_af_ship; then
      fi_af_item_set "$FI_AF_ST/running/$id" pr "$FI_AF_PR"
      fi_af_item_set "$FI_AF_ST/running/$id" cost "$FI_AF_COST"
      fi_af_item_set "$FI_AF_ST/running/$id" tokens "$FI_AF_TOKENS"
      fi_af_finish "$id" shipped "PR #$FI_AF_PR, merge $FI_AF_MERGE, \$$FI_AF_COST"
      return 0
    fi
    fi_af_finish "$id" failed "ship: $FI_AF_WHY"
    return 0
  done
  fi_af_item_set "$FI_AF_ST/running/$id" cost "$FI_AF_COST"
  fi_af_item_set "$FI_AF_ST/running/$id" tokens "$FI_AF_TOKENS"
  case "$why" in
    "run budget spent"*) ;;
    *) why="$why after 2 attempts" ;;
  esac
  fi_af_finish "$id" failed "$why"
}

_fi_af_next_queued() {
  local f
  for f in "$FI_AF_ST"/queue/*; do
    [[ -f "$f" ]] && { printf '%s' "${f##*/}"; return 0; }
  done
  return 1
}

# Launcher A: run <id>, then drain the queue while claims succeed.
_fi_af_run() {
  local id="$1" engine_opt="$2" rc next
  export FI_AF_PID=$$
  fi_af_reap
  while [[ -n "$id" ]]; do
    rc=0
    _fi_af_run_one "$id" "$engine_opt" || rc=$?
    case $rc in
      3) printf 'Auto-fix: daily cap reached; %s waits for tomorrow.\n' "$id"; return 0 ;;
      4) printf 'Auto-fix: another run holds this repo; %s stays queued.\n' "$id"; return 0 ;;
    esac
    [[ -f "$FI_AF_ST/done/$id" ]] && { fi_af_item_read "$FI_AF_ST/done/$id"; printf '%s: %s\n' "$id" "$AFI_result"; }
    next="$(_fi_af_next_queued || true)"
    # An item the claim could not move (rc 1 with its file still queued)
    # would come straight back: stop rather than spin.
    [[ "$next" == "$id" ]] && break
    id="$next"
  done
}

_fi_af_status() {
  local f n=0 line
  if fi_af_enabled; then printf 'Auto-fix: on (%s)\n' "$FI_AF_SLUG"
  else printf 'Auto-fix: off — %s\n' "$FI_AF_WHY"; fi
  if [[ -f "$FI_AF_ST/day/$(fi_today).spot" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do n=$((n + 1)); done <"$FI_AF_ST/day/$(fi_today).spot"
  fi
  printf 'Today: %s/%s spot fixes\n' "$n" "$(fi_af_int dailyFixes 5)"
  local dir label count
  for dir in queue running; do
    count=0
    for f in "$FI_AF_ST/$dir"/*; do [[ -f "$f" ]] && count=$((count + 1)); done
    label="Queued"; [[ "$dir" == running ]] && label="Running"
    printf '%s (%s)\n' "$label" "$count"
    for f in "$FI_AF_ST/$dir"/*; do
      [[ -f "$f" ]] || continue
      fi_af_item_read "$f"
      printf '  %s  %s\n' "$AFI_id" "$AFI_loc"
    done
  done
  printf 'Recent:\n'
  local -a recent=()
  for f in "$FI_AF_ST"/done/*; do [[ -f "$f" ]] && recent+=("$f"); done
  local i shown=0
  for (( i = ${#recent[@]} - 1; i >= 0 && shown < 5; i-- )); do
    fi_af_item_read "${recent[$i]}"
    printf '  %s  %s — %s\n' "$AFI_id" "$AFI_loc" "$AFI_result"
    shown=$((shown + 1))
  done
  return 0
}
```

Add `tokens` to the key list in `fi_af_item_read` (`AFI_tokens`, initialized to `""` in both init lines).

Dispatch in `cmd_autofix`:

```bash
    run)
      local rid="${1:-}" eng=""
      [[ $# -gt 0 ]] && shift
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --engine) fi_need_value "autofix run" --engine $# "${2:-}" || return 2; eng="$2"; shift 2 ;;
          --engine=*) eng="${1#--engine=}"; shift ;;
          *) fi_unknown_arg "autofix run" "$1"; return 2 ;;
        esac
      done
      [[ -n "$rid" ]] || { fi_err "Usage: found-issues autofix run <id> [--engine claude|codex]"; return 2; }
      case "$eng" in ""|claude|codex) ;; *) fi_err "autofix run: --engine takes claude or codex"; return 2 ;; esac
      fi_af_context || return 1
      fi_af_enabled || { fi_err "autofix: not running — $FI_AF_WHY"; return 1; }
      _fi_af_run "$rid" "$eng" ;;
    status)
      fi_af_context || return 1
      _fi_af_status ;;
```

`run` refuses when auto-fix is off. The kill switch must stop queued work too.

Expected counts in the tests:
- Stand-in cost is 0.25 per child, so fixer + verifier = `0.5000`.
- Codex tokens are 1500 per child, so 3000.
- Budget test: a 0.3 budget minus the first fixer's 0.25 leaves 0.05 < 0.10 before the verifier, so the run fails with `run budget spent ($0.2500)` and exactly one claude call.

- [ ] **Step 4: Run to confirm pass**

Run: `bats tests/autofix-run.bats`
Expected: `12 tests, 0 failures`.

- [ ] **Step 5: Run every autofix file plus the neighbors they touch**

Run: `bats tests/autofix-*.bats tests/cli-log.bats tests/source-guards.bats tests/post-bash-dispatch.bats`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/autofix.sh lib/autofix-queue.sh tests/autofix-run.bats
git commit -m "feat(v3) launcher A: autofix run (fix, test, verify, ship, 2 attempts, drain) and status"
```

---

### Task 8: Live pinning and cost measurement (real `claude`, real `codex`)

**Files:**
- Create: `tests/autofix-live.bats` (skipped unless `FI_LIVE=1`; CI never sets it)
- Modify: `docs/superpowers/specs/2026-10-03-autofix-v3-design.md` §4.5 (record the measured facts)
- Modify: `lib/autofix-config.sh` (only if the measured fix cost needs a different `runBudget` default)

**Interfaces:**
- Consumes: the whole Phase 2 surface, the gh shim (no real GitHub), the fixture.
- Produces: measured per-run cost and duration for both engines, plus a pinned allowlist contract against the real CLI.

Cost note for the operator: this task spends real money on the operator's account. Estimate: one haiku probe (~$0.10), one sonnet fix plus one opus verify (~$0.5–2), and one Codex run on the ChatGPT plan. Announce it before running.

- [ ] **Step 1: Write `tests/autofix-live.bats`**

```bash
#!/usr/bin/env bats
# LIVE checks against the real claude/codex CLIs (spec §4.5, §10). They cost
# money and need logged-in CLIs, so they run only with FI_LIVE=1:
#   FI_LIVE=1 bats tests/autofix-live.bats
# Results (cost, seconds) are appended to $FI_LIVE_REPORT (default $TMPDIR).

load 'helpers'
load 'autofix-helpers'

setup() {
  [[ "${FI_LIVE:-}" == 1 ]] || skip "live: set FI_LIVE=1 (costs money)"
  local real_home="$HOME"
  fi_setup_tmp; fi_af_fixture
  # The real CLIs need the operator's login (~/.claude, ~/.codex); the
  # fixture's throwaway HOME would make claude answer "Not logged in".
  export HOME="$real_home"
  export PATH="$TEST_REPO_ROOT/tests/bin-shims:$PATH"
  export GH_MOCK_TRACE="$TMP/gh.trace"
  export GH_MOCK_PR_VIEW=$'7\t{"number":7,"state":"OPEN","statusCheckRollup":[]}'
  REPORT="${FI_LIVE_REPORT:-${TMPDIR:-/tmp}/fi-live-report.txt}"
}
teardown() { [[ "${FI_LIVE:-}" == 1 ]] && fi_teardown_tmp; return 0; }

@test "live: the fixer allowlist allows the test command and denies everything else" {
  source "$FI_BIN"
  fi_af_allowlist 'sh test.sh'
  run claude -p --model haiku --max-budget-usd 0.5 --max-turns 8 --no-session-persistence \
    --permission-mode dontAsk --permission-prompts none --allowedTools "${FI_AF_TOOLS[@]}" \
    --output-format json "Permission test; denials are expected. Run each exact command with the Bash tool, one per call, continuing after denials: 'sh test.sh' ; 'git status' ; 'sh test.sh && git log' ; 'curl -s example.com'. Then stop."
  printf '%s' "$output" > "$TMP/out.json"
  denied="$(jq -r '[.permission_denials[]?.tool_input.command] | join("|")' "$TMP/out.json")"
  printf 'allowlist: denied=%s cost=%s\n' "$denied" "$(jq -r .total_cost_usd "$TMP/out.json")" >> "$REPORT"
  [[ "$denied" == *"git status"* ]]
  [[ "$denied" == *"curl -s example.com"* ]]
  [[ "$denied" == *"sh test.sh && git log"* ]]
  [[ "|$denied|" != *"|sh test.sh|"* ]]
}

@test "live: claude engine fixes the fixture and reports its cost" {
  fi_af_queue_fixture
  start=$SECONDS
  run "$FI_BIN" autofix run "$ID" --engine claude
  dur=$((SECONDS - start))
  cat "$FI_AF_RUNS/$ID.log" >&3 || true
  fi_af_item_read "$FI_AF_ST/done/$ID"
  printf 'claude: result=%s cost=%s seconds=%s\n' "$AFI_result" "$AFI_cost" "$dur" >> "$REPORT"
  [[ "$AFI_result" == shipped:* ]]
}

@test "live: codex engine fixes the fixture and reports its tokens" {
  command -v codex >/dev/null || skip "codex not installed"
  fi_af_queue_fixture
  start=$SECONDS
  run "$FI_BIN" autofix run "$ID" --engine codex
  dur=$((SECONDS - start))
  fi_af_item_read "$FI_AF_ST/done/$ID"
  printf 'codex: result=%s tokens=%s seconds=%s\n' "$AFI_result" "$(grep '^tokens=' "$FI_AF_ST/done/$ID")" "$dur" >> "$REPORT"
  [[ "$AFI_result" == shipped:* ]]
}
```

- [ ] **Step 2: Confirm it is inert in CI**

Run: `bats tests/autofix-live.bats`
Expected: `3 tests, 0 failures, 3 skipped`.

- [ ] **Step 3: Run it live** (operator's account; announce the cost first)

Run: `FI_LIVE=1 FI_LIVE_REPORT="$PWD/../fi-live-report.txt" bats tests/autofix-live.bats; cat ../fi-live-report.txt`
Expected: 3 pass. The report has one `allowlist:`, one `claude:` and one `codex:` line.

If a live test fails, debug from the run log (`$FI_AF_RUNS/<id>.log`, `.fix1.out`, `.fix1.err`, `.verify1.out`) before changing code. Fix it with a failing non-live test first, in the task that owns the code.

- [ ] **Step 4: Record the findings.**
  1. In the spec, add a dated bullet list "**Phase 2 measurements (2026-10-03):**" under §4.5. It records:
     - the allowlist contract from the pinned facts above and the live test;
     - the claude fix cost and duration;
     - the codex duration and tokens;
     - whether `$2` is enough.
  2. If the measured claude run (fixer + verifier) cost more than `$1.50`, raise the `runBudget` default to the next whole dollar above 1.5 × the measured cost. Change it in `fi_af_budget` (both the `2` default and its warning text), in `fi_af_cfg runBudget 2`, and in the spec §7 table. Update the matching `autofix-config.bats` assertion.

- [ ] **Step 5: Commit**

```bash
git add tests/autofix-live.bats docs/superpowers/specs/2026-10-03-autofix-v3-design.md lib/autofix-config.sh tests/autofix-config.bats
git commit -m "test(v3) live allowlist pin and launcher A cost measurement (FI_LIVE=1 only)"
```

---

### Task 9: Help, CHANGELOG, README count, bash 3.2 and the full suite

**Files:**
- Modify: `lib/help.sh` (one `autofix` block after the `decide` block)
- Modify: `CHANGELOG.md` (`## [3.0.0] - unreleased` → `### Added`)
- Modify: `README.md` (test count)
- Modify: `docs/found-issues.md` (log anything out of scope found during the phase, with a fix tag)

- [ ] **Step 1: Help.** In `lib/help.sh`, after the `decide` lines, add (aligned with the neighbors):

```
  autofix on|off|status                 v3 auto-fix: kill switch and what is queued,
                                        running and done today.
  autofix run <id> [--engine E]         Fix a queued (fix: small) entry headlessly:
                                        worktree, fixer, tests, verifier, self-merging PR.
  autofix claim|diff|ship|release <id>  The steps of a fix, for in-session fixers.
```

Run: `bats tests/cli-hygiene.bats tests/docs-consistency.bats`
Expected: pass. If a test pins the help text or the command list, update it to the new line.

- [ ] **Step 2: CHANGELOG.** Append these bullets to the `### Added` list under `## [3.0.0] - unreleased`:

```markdown
- Auto-fix queue: with `git config found-issues.autofix true` in a GitHub
  repo, `found-issues log --fix small …` queues the entry and prints
  `AUTOFIX-QUEUED <id>` (Phase 3 wires the launch). Logged inside a fixer, it
  queues without the marker.
- `found-issues autofix run <id> [--engine claude|codex]` (launcher A). It:
  - claims under a per-repo lock (stale after 60 min) and the daily cap
    (`found-issues.autofix.dailyFixes`, default 5);
  - cuts a `fi/autofix/*` worktree from `origin/<default>`;
  - runs a headless fixer (`claude -p … --permission-mode dontAsk
    --permission-prompts none`, sonnet, or `codex exec --sandbox
    workspace-write`);
  - re-runs the tests itself;
  - gets an opus/high read-only verdict;
  - opens a PR, annotates the ledger on the PR branch and in the checkout,
    and arms auto-merge (falling back to `autofix merge-when-green`).

  At most 2 attempts. A failure tags `(autofix-failed: <reason>)`. Spend is
  capped by `found-issues.autofix.runBudget` (USD, default 2) and
  `.runTimeoutMin` (default 20).
- `found-issues autofix status | on | off | claim | diff | ship | release |
  merge-when-green`.
```

- [ ] **Step 3: README count**

```bash
n=$(rg -c '^@test ' tests/*.bats | awk -F: '{s+=$2} END{print s}'); sed -i '' -E "s/ [0-9]+ tests on/ $n tests on/" README.md
```

- [ ] **Step 4: Full suite, then bash 3.2 on the new files**

Run: `bats tests/ 2>&1 | tail -3`
Expected: `N tests, 0 failures, 3 skipped` (N = the README count; the 3 skips are the live tests).

Run:

```bash
mkdir -p /private/tmp/claude-501/b32 && ln -sf /bin/bash /private/tmp/claude-501/b32/bash
PATH=/private/tmp/claude-501/b32:$PATH bash "$(command -v bats)" tests/autofix-config.bats tests/autofix-queue.bats tests/autofix-claim.bats tests/autofix-release.bats tests/autofix-engine.bats tests/autofix-ship.bats tests/autofix-run.bats tests/cli-log.bats tests/source-guards.bats
```

Expected: 0 failures under `/bin/bash` 3.2.

- [ ] **Step 5: Verify the real entry point by hand.** Use a scratch fixture with a bare remote, the gh shim and the stand-ins, then follow the flow end to end:

```bash
found-issues log --fix small '…'   # prints AUTOFIX-QUEUED <id>
found-issues autofix status         # shows the item as Queued
found-issues autofix run <id> --engine claude
found-issues autofix status         # shows "shipped: PR #7"
```

Quote the outputs in the PR body.

- [ ] **Step 6: Commit**

```bash
git add lib/help.sh CHANGELOG.md README.md docs/found-issues.md
git commit -m "docs(v3) phase 2: help, changelog, test count"
```

- [ ] **Step 7: PR into `release/v3` and watch to terminal**

```bash
git push -u origin v3/phase2-launcher-a
gh pr create --base release/v3 --title "feat(v3) phase 2: queue, claim, ship and launcher A" --body-file <body>
GH_PR_MERGE_BASE_GUARD=off gh pr merge <N> --auto --squash
gh pr checks <N> --watch
```

Then watch the post-merge `release/v3` push run, including macOS bats on bash 3.2, to a terminal state.
