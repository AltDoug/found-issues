# Auto-fix v3 Phase 4 — Sweep, sweeper agent, `/found-issues:fix` on shared plumbing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the repo's fixable-now count reaches `sweepThreshold` (default 5), or a fixable critical `(fix: medium)` is recorded, `log`/`tag`/`decide`/`sync` queue one sweep and print `AUTOFIX-SWEEP-DUE <id>`. The PostToolUse hook launches it like a spot item (B: the plugin agent `found-issues:found-issues-sweeper`; A: a detached `found-issues autofix run <id>`). The sweep classifies untagged entries, wakes free-text `(until:)` entries whose blocker is gone, fixes up to `sweepMax` (8) entries one commit each, and ships ONE self-merging PR. The interactive `/found-issues:fix` command moves onto the same plumbing (audit prompt-8..10), and SessionStart stops injecting reply directives into headless sessions (prompt-11).

**Architecture:** A sweep is a queue item with `kind=sweep`, so it reuses Phase 2/3's lock, caps, claim, reap, launcher selection and Stop fallback unchanged. The claim for a sweep runs the classify/wake pass, then writes the ordered entry list to `<state>/sweeps/<id>.entries`. Per-entry progress lives in the item (`cur`, `head`, `fixed`). Both launchers drive each entry through the same fix loop the spot run uses (refactored out of `_fi_af_run_one`), with the entry's base pinned to the sweep's last good commit. An approved entry becomes one commit; anything else is settled on the source ledger and the worktree resets to that commit. Ship pins the PR to the HEAD tree of the approved commits. New code lives in `lib/autofix-sweep.sh` (selection, trigger, claim, per-entry state, run, ship), `lib/autofix-classify.sh` (the classify/wake pass), and `lib/fix-plumbing.sh` (`found-issues fix workspace|test|ship`).

**Tech Stack:** bash 3.2+ (macOS system bash), jq, awk, sort, git, gh, bats-core; stand-in `claude`/`codex`/`gh` from Phases 2-3.

**Spec:** `docs/superpowers/specs/2026-10-03-autofix-v3-design.md` (§3.1-§3.2, §4.1-§4.3, §6, §7, §8 settings, §11 phase 4). Phase 3 plan for reference: `docs/superpowers/plans/2026-10-03-autofix-v3-phase3-launcher-b.md`. Audit findings prompt-8..11: `docs/audits/2026-10-03-audit/findings-prompt.json` on branch `fix/audit-2026-10-03` (commit 7cb8f23).

## Docs re-check

No new Claude Code facts are relied on beyond Phase 3's re-check (2026-10-03, CLI 2.1.289): plugin agents support `model`, `effort`, `maxTurns`, `tools`, `background`; B runs only in `auto`/`bypassPermissions`; plain PostToolUse stdout never reaches Claude (Phase 3 Task 1 already emits JSON). `CLAUDE_CODE_ENTRYPOINT` is `cli` for interactive sessions and something else (`sdk-cli`, `sdk-ts`, …) for headless ones; `hooks/stop-reminder.sh:115` already relies on that.

## Rulings (deviations from or readings of the spec, for operator review)

Written while the operator was away (2026-10-04 night, standing instruction "do everything you can without me"); each carries the cost if wrong.

1. **A sweep is a queue item with `kind=sweep`.** It shares the repo lock, reap, the claim/launcher machinery and the Stop fallback with spot items, so "one fixer per repo at a time" still holds. Cap: its own `day/<date>.sweep` file against `dailySweeps` (default 1). *Cost if wrong: a second state machine later.*
2. **Classify and wake run inside the sweep's claim** as ONE headless, read-only pass (sonnet; Codex `--sandbox read-only`). It sees at most 20 untagged `[open]` entries and 10 `[deferred]` entries whose `(until:)` is free text. Tags go through `fi_tag_resolve` (the off-limits override still applies) and `fi_tag_apply`; wakes go through the same `[deferred]`→`[open]` retag sync uses. Both write the SOURCE ledger only, like `found-issues tag` does. *Cost if wrong: claim is slower (one model call) on the B path.*
3. **Per-entry verify, one commit per approved entry.** Each entry's diff, reset and verifier run against the sweep's last good commit (`head`). `ship` pins the PR to `head`'s tree (any test artifact left in the tree refuses the ship), keeping Phase 3's "only the approved tree ships" rule. *Cost if wrong: none for safety; a verifier call per entry.*
4. **Sweep budget is a new setting `found-issues.autofix.sweepBudget`, default 10** (Claude Code's `total_cost_usd` estimate against plan usage, not billing). The $3 `runBudget` would stop a sweep after two or three entries (Phase 3 measured about $1.07 per entry). *Cost if wrong: one default to change.*
5. **Branch `fi/sweep/<YYYYMMDD>-<5-digit id suffix>`**, worktree `<root>/.claude/worktrees/fi-sweep-<id>`. The spec's `<n>` collided on a second run the same day (audit prompt-8). *Cost if wrong: a branch name.*
6. **Sweep candidates** are `[open]` entries that are fixable now (`(fix: small|medium)`, or `(decided:)` with no open `(decide:)`), carry no PR/commit reference or suggestion and no `(autofix-failed:)`, and have no spot item queued or running. Order: critical first, then by file group (each group placed by its oldest entry), then oldest, then ledger order. The trigger counts the same set. `(fix: small)` entries that were never spot-queued (logged while auto-fix was off) are swept. *Cost if wrong: an ordering tweak.*
7. **A budget stop or an engine outage mid-sweep leaves the current entry untouched** (no `(autofix-failed:)`): the sweep ships what is committed. A sweep that commits nothing ends `stale`, with no PR. A sweep item never writes the ledger itself; only its entries do. *Cost if wrong: an entry retried next sweep.*
8. **Interactive `/found-issues:fix` shares the plumbing through `found-issues fix workspace|test|ship`** (prompt-8, -9, -10). `fix workspace` creates `<root>/.claude/worktrees/fi-fix-<YYYYMMDD>-<rand>` on `fix/found-issues-<YYYYMMDD>-<rand>` from a freshly fetched `origin/<default>` (unique per run). `fix test` runs the detected test command (so allowed-tools no longer needs `Bash(bats:*)`). `fix ship` refuses a dirty worktree or red tests, then pushes, opens the PR, annotates the picked entries in the source ledger, and commits that annotation onto the PR branch when the branch has the ledger. It never merges: interactive runs keep the operator's merge decision (the AltDoug auto-merge policy is applied by the session, not the CLI). The already-fixed bucket closes entries with `found-issues resolve "<fragment>" --verified ai` instead of `/found-issues:sync`, which archives. *Cost if wrong: one command's behavior.*
9. **Interactive list reads use `--cwd <source root>`** so `list --json` and `annotate-pr` read the same ledger while edits happen in the worktree (prompt-8). Range entries are picked as `path:line-line_end`, built from `list --json`'s `line_end` (prompt-10, doc fix; the JSON shape is unchanged).
10. **prompt-11:** the first-run hint and the daily statusline nudge in `hooks/session-start.sh` fire only when `CLAUDE_CODE_ENTRYPOINT` is empty or `cli`; the onboarding marker is not consumed by a headless session.

## Global Constraints

- bash 3.2 compatible: no `declare -A`, no `${var,,}`, no `$EPOCHSECONDS`, no `printf '%(…)T'`, `mapfile`/`readarray`; guard `"${arr[@]}"` on empty arrays under `set -u`.
- Hooks: PostToolUse always exits 0; zero-fork early exit when no marker is in the payload (`lib/hook-gate.sh` contract); never block on auto-fix work.
- Nothing auto-fix launches may show a permission prompt (spec §1). B only in `auto`/`bypassPermissions` on Claude Code.
- Fixers and the sweeper never run git or gh and never write the ledger; bash does (Phase 2 ruling).
- `autofix off` / `FOUND_ISSUES_AUTOFIX=off` stop sweeps exactly as they stop spot items (Phase 3 review I1): claim refuses, verify/ship requeue (exit 8).
- ASCII-only `@test` names. Use `! cmd || false`, never a bare mid-test `! cmd`.
- Detached spawns close fd 3 (`3>&-`).
- Rules `SKILL.md` budget 4200 bytes; README test count pinned by `tests/docs-consistency.bats`; Codex skills regenerated by `scripts/gen-codex-skills.sh` after any `commands/*.md` edit.
- Never write `docs/found-issues.md` by hand: `./bin/found-issues log|resolve|annotate-pr`.

## Review Focus

1. **A sweep and a spot item for the same entry.** A `(fix: small)` logged while a sweep is running gets its own spot item; the sweep's candidate list was fixed at claim, so the sweep must not pick it later, and the spot claim must retire it as stale if the sweep's PR annotated it first. Task 2: "candidates skip an entry with a queued spot item"; Task 5: "a spot item for an entry the sweep shipped retires stale".
2. **A failing entry in the middle of a sweep** must not leak its half-made change into the next entry's commit or diff. Task 5: "a rejected entry is reset and the next entry's diff is clean".
3. **Test artifacts at ship** (an untracked file the test run writes): the ship refuses instead of shipping a tree nobody approved. Task 5: "ship refuses a tree that differs from the approved commits".
4. **The classifier returning garbage** (no JSON, numbers out of range, unknown kinds, an off-limits path tagged `fix`): nothing is written except valid tags, and off-limits becomes `manual`. Task 4: "classifier garbage writes nothing", "an off-limits path classified fix becomes manual".
5. **Repeated triggers on one day**: a second `log` after a sweep was queued, claimed or shipped today must not queue another sweep. Task 2: "a pending sweep or today's cap blocks a second sweep".

---

### Task 1: Extract the shared fix loop (no behavior change)

**Files:**
- Modify: `lib/autofix.sh` (`_fi_af_run_one` lines ~84-160)
- Test: existing `tests/autofix-run.bats`, `tests/autofix-b.bats`, `tests/autofix-ship.bats` (must stay green)

**Interfaces:**
- Produces: `_fi_af_fix_loop <id> <engine>` — runs up to 2 attempts on the loaded entry (`AFI_entry`, `AFI_wt`, `AFI_base_sha`) and sets `FI_AF_OUTCOME` (`approved|already-fixed|decide|manual|failed|outage`) and `FI_AF_OUTCOME_TEXT`. On `approved`, `FI_AF_TREE` holds the approved staged tree and `FI_AF_VERDICT_REASON` the reason. A budget stop is `failed` with text starting `run budget spent`.

- [ ] **Step 1: Run the run/ship suites for a baseline**

Run: `bats tests/autofix-run.bats tests/autofix-ship.bats tests/autofix-b.bats 2>&1 | tail -3` — expect `0 not ok`.

- [ ] **Step 2: Replace the body of `_fi_af_run_one` from the `for n in 1 2` loop down with a call to the new function**

```bash
# Spec §5 steps 2-5 for the loaded entry (AFI_entry, AFI_wt, AFI_base_sha):
# up to 2 attempts of fix -> bash tests -> verifier. Shared by a spot run
# and by each entry of a sweep. Sets FI_AF_OUTCOME (approved | already-fixed
# | decide | manual | failed | outage) and FI_AF_OUTCOME_TEXT; on approved
# the worktree holds the verified change and FI_AF_TREE its staged tree.
_fi_af_fix_loop() {
  local id="$1" engine="$2" n feedback="" why="" tlog ref
  ref="${AFI_base_sha:-origin/$AFI_base}"
  FI_AF_OUTCOME="" FI_AF_OUTCOME_TEXT=""
  for n in 1 2; do
    touch "$FI_AF_ST/lock" 2>/dev/null || true
    if [[ "$engine" == "claude" ]] && ! fi_af_budget_left >/dev/null; then
      why="run budget spent (\$$FI_AF_COST)"; break
    fi
    (( n == 1 )) || _fi_af_reset_wt
    _fi_af_fix_attempt "$engine" "$n" "$feedback"
    # An outage (usage limit, logged out, network) is not an attempt.
    if [[ -n "$FI_AF_ENGINE_ERR" && -z "$(fi_af_diff "$AFI_wt" "$ref")" ]]; then
      FI_AF_OUTCOME=outage FI_AF_OUTCOME_TEXT="$FI_AF_ENGINE_ERR"; return 0
    fi
    case "$FI_AF_RESULT" in
      already-fixed|decide)
        FI_AF_OUTCOME="$FI_AF_RESULT" FI_AF_OUTCOME_TEXT="${FI_AF_RESULT_TEXT:-no reason given}"
        return 0 ;;
      manual)
        # A fixer that changed code but could not prove it says manual; bash
        # runs the tests and the verifier anyway, so its change still counts.
        if [[ -z "$(fi_af_diff "$AFI_wt" "$ref")" ]]; then
          FI_AF_OUTCOME=manual FI_AF_OUTCOME_TEXT="${FI_AF_RESULT_TEXT:-no reason given}"
          return 0
        fi
        fi_af_log "$id" "attempt $n: fixer said manual but left a change; testing and verifying it" ;;
    esac
    if [[ -z "$(fi_af_diff "$AFI_wt" "$ref")" ]]; then
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
    FI_AF_OUTCOME=approved
    return 0
  done
  case "$why" in
    "run budget spent"*) ;;
    *) why="$why after 2 attempts" ;;
  esac
  FI_AF_OUTCOME=failed FI_AF_OUTCOME_TEXT="$why"
}
```

and the tail of `_fi_af_run_one` becomes:

```bash
  AFI_engine="$engine"
  _fi_af_fix_loop "$id" "$engine"
  case "$FI_AF_OUTCOME" in
    outage)
      FI_AF_WHY="$FI_AF_OUTCOME_TEXT"
      fi_af_requeue "$id" "engine error: $FI_AF_OUTCOME_TEXT"
      return 7 ;;
    approved)
      AFI_verdict_tree="$FI_AF_TREE"
      fi_af_item_set "$FI_AF_ST/running/$id" verdict_tree "$FI_AF_TREE"
      fi_af_item_set "$FI_AF_ST/running/$id" verdict approve
      if fi_af_ship; then
        fi_af_item_set "$FI_AF_ST/running/$id" pr "$FI_AF_PR"
        _fi_af_end "$id" shipped "PR #$FI_AF_PR, merge $FI_AF_MERGE, \$$FI_AF_COST"
      else
        _fi_af_end "$id" failed "ship: $FI_AF_WHY"
      fi ;;
    *) _fi_af_end "$id" "$FI_AF_OUTCOME" "$FI_AF_OUTCOME_TEXT" ;;
  esac
  return 0
```

- [ ] **Step 3: Re-run the same suites** — expect the same counts, `0 not ok`.
- [ ] **Step 4: Commit** `refactor(autofix): extract the shared fix loop from the spot run`.

---

### Task 2: Sweep candidates, trigger and queueing

**Files:**
- Create: `lib/autofix-sweep.sh`
- Modify: `bin/found-issues` (source `autofix-sweep.sh` after `autofix-b.sh`), `lib/autofix-queue.sh` (`fi_af_item_read` keys `head`, `cur`, `fixed`), `lib/log.sh` (`_fi_log_autofix` end), `lib/tag.sh` (after a 0 from `fi_tag_apply`), `lib/decide.sh` (after a 0 from `fi_tag_apply`), `lib/sync.sh` (after `fi_ledger_replace`, not on `--dry-run`), `lib/autofix.sh` (usage settings line; status sweeps line)
- Test: create `tests/autofix-sweep.bats`; extend `tests/autofix-helpers.bash`

**Interfaces:**
- Consumes: `fi_af_enabled`, `fi_af_dirs`, `fi_af_int`, `fi_af_cap_ok`, `fi_af_new_id`, `fi_af_item_write`, `fi_entries`, `fi_entry_dedup_key_v`, `fi_parse_entry_vars`, `fi_find_issues_file`, `fi_repo_root_cached`.
- Produces:
  - `fi_af_fixable_now <entry>` → 0 when fixable now (Ruling 6).
  - `fi_af_sweep_candidates <ledger> <root> <max>` → prints ordered entry lines (Ruling 6), at most `<max>`.
  - `fi_af_sweep_pending` → 0 when a `kind=sweep` item is in `queue/` or `running/`.
  - `fi_af_sweep_check` → queues a sweep when due and prints `AUTOFIX-SWEEP-DUE <id>` (inside a fixer: `Auto-fix: sweep queued <id> (inside a fixer; …)`). Never fails its caller.
  - Item keys `head`, `cur`, `fixed` → `AFI_head`, `AFI_cur`, `AFI_fixed`.
  - Settings: `dailySweeps` (1), `sweepThreshold` (5), `sweepMax` (8), `sweepBudget` (10).

- [ ] **Step 1: Fixture helper** — append to `tests/autofix-helpers.bash`:

```bash
# A ledger with <n> fixable (fix: medium) entries on separate files. Like a
# real repo, the suite passes at base (no test sees the bugs); each fix adds
# its own test. The spot fixture's add bug stays in src/calc.sh, untested,
# and its entry is dropped so nothing spot-queues. cwd = the repo; sets REPO.
fi_af_sweep_fixture() {
  local n="${1:-5}" i
  fi_af_fixture
  printf '# found-issues\n\n' > docs/found-issues.md
  printf '. ./src/calc.sh\n' > test.sh
  for (( i = 1; i <= n; i++ )); do
    printf 'f%s() { echo $(( $1 - 1 )); }\n' "$i" > "src/f$i.sh"
    printf '. ./src/f%s.sh\n' "$i" >> test.sh
    printf -- '- [open] 2026-10-0%s src/f%s.sh:1 — f%s subtracts one (fix: medium)\n' "$i" "$i" "$i" >> docs/found-issues.md
  done
  printf 'true\n' >> test.sh
  git add -A && git commit -q -m "sweep fixture" && git push -q origin main
}
```

- [ ] **Step 2: Write the failing tests** — `tests/autofix-sweep.bats`:

```bash
#!/usr/bin/env bats
# v3 sweep: candidates, trigger, claim, run, ship (spec §4.1, §6, §7; phase 4 plan).

load 'helpers'
load 'autofix-helpers'

setup() { fi_setup_tmp; }
teardown() { fi_teardown_tmp; }

sweeps() { ls "$FOUND_ISSUES_STATE_DIR/autofix/foo__bar/queue" 2>/dev/null | while read -r f; do grep -l '^kind=sweep$' "$FOUND_ISSUES_STATE_DIR/autofix/foo__bar/queue/$f"; done; }

@test "sweep: candidates are fixable-now entries, critical first, then file groups, then oldest" {
  fi_af_fixture
  cat > docs/found-issues.md <<'EOF'
# found-issues

- [open] 2026-10-02 src/b.sh:1 — b late (fix: medium)
- [open] 2026-10-01 src/a.sh:1 — a oldest (fix: small)
- [open] [!] 2026-10-05 src/c.sh:1 — c critical (fix: medium)
- [open] 2026-10-03 src/a.sh:9 — a later (decided: yes)
- [open] 2026-09-01 src/d.sh:1 — d large (fix: large)
- [open] 2026-09-01 src/e.sh:1 — e question (decide: which?)
- [open] 2026-09-01 src/f.sh:1 — f in a PR (fix: medium) (PR: foo/bar#3)
- [open] 2026-09-01 src/g.sh:1 — g failed before (fix: small) (autofix-failed: tests fail)
- [deferred] 2026-09-01 src/h.sh:1 — h deferred (fix: medium)
EOF
  source "$FI_BIN"; fi_af_context
  run fi_af_sweep_candidates docs/found-issues.md "$REPO" 10
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
  [[ "${lines[0]}" == *"c critical"* ]]
  [[ "${lines[1]}" == *"a oldest"* ]]
  [[ "${lines[2]}" == *"a later"* ]]
  [[ "${lines[3]}" == *"b late"* ]]
  run fi_af_sweep_candidates docs/found-issues.md "$REPO" 2
  [ "${#lines[@]}" -eq 2 ]
}

@test "sweep: candidates skip an entry with a queued spot item" {
  fi_af_fixture
  fi_af_queue_fixture
  run fi_af_sweep_candidates docs/found-issues.md "$REPO" 10
  [ -z "$output" ]
}

@test "sweep: the fifth fixable entry queues one sweep and prints the marker" {
  fi_af_sweep_fixture 4
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUTOFIX-SWEEP-DUE "* ]]
  id="$(printf '%s\n' "$output" | sed -n 's/^AUTOFIX-SWEEP-DUE //p')"
  f="$FOUND_ISSUES_STATE_DIR/autofix/foo__bar/queue/$id"
  grep -q '^kind=sweep$' "$f"
  grep -q '^loc=sweep$' "$f"
}

@test "sweep: four fixable entries do not queue a sweep" {
  fi_af_sweep_fixture 3
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  [[ "$output" != *"AUTOFIX-SWEEP-DUE"* ]]
}

@test "sweep: a critical fix medium queues a sweep on its own" {
  fi_af_fixture
  printf '# found-issues\n\n' > docs/found-issues.md
  run "$FI_BIN" log --critical --fix medium 'src/calc.sh:1 — add subtracts'
  [[ "$output" == *"AUTOFIX-SWEEP-DUE "* ]]
}

@test "sweep: a pending sweep or today's cap blocks a second sweep" {
  fi_af_sweep_fixture 5
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  [[ "$output" == *"AUTOFIX-SWEEP-DUE "* ]]
  run "$FI_BIN" log --fix medium 'src/calc.sh:2 — add is slow'
  [[ "$output" != *"AUTOFIX-SWEEP-DUE"* ]]
  rm -f "$FOUND_ISSUES_STATE_DIR"/autofix/foo__bar/queue/*
  printf 'x\n' > "$FOUND_ISSUES_STATE_DIR/autofix/foo__bar/day/$(date +%Y-%m-%d).sweep"
  run "$FI_BIN" log --fix medium 'src/calc.sh:3 — add is loud'
  [[ "$output" != *"AUTOFIX-SWEEP-DUE"* ]]
}

@test "sweep: auto-fix off queues nothing" {
  fi_af_sweep_fixture 5
  git config found-issues.autofix false
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  [[ "$output" != *"AUTOFIX-SWEEP-DUE"* ]]
}

@test "sweep: tag and decide also trigger" {
  fi_af_sweep_fixture 4
  "$FI_BIN" log 'src/calc.sh:1 — add subtracts' >/dev/null
  run "$FI_BIN" tag 'add subtracts' --fix medium
  [[ "$output" == *"AUTOFIX-SWEEP-DUE "* ]]
}

@test "sweep: inside a fixer the sweep is queued without the marker" {
  fi_af_sweep_fixture 4
  FOUND_ISSUES_AUTOFIX_CHILD=1 run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  [[ "$output" != *"AUTOFIX-SWEEP-DUE"* ]]
  [[ "$output" == *"sweep queued"* ]]
}
```

(`fi_af_queue_fixture` sources `$FI_BIN`, so the second test can call `fi_af_sweep_candidates` directly.)

- [ ] **Step 3: Run to verify they fail** — `bats tests/autofix-sweep.bats` → all `not ok` (`fi_af_sweep_candidates: command not found`, no marker).

- [ ] **Step 4: Implement** — `lib/autofix-sweep.sh` (first part):

```bash
#!/usr/bin/env bash
# autofix-sweep.sh — v3 auto-sweep: which entries a sweep takes, when one is
# due, the sweep claim, per-entry progress, the launcher A loop and the one
# self-merging PR (spec 2026-10-03 §4.1, §6, §7; phase 4 plan rulings 1-7).
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   fi_af_fixable_now <entry>
#   fi_af_sweep_candidates <ledger> <root> <max>
#   fi_af_sweep_pending
#   fi_af_sweep_check

# shellcheck disable=SC2154  # AFI_*/FE_* come from autofix-queue.sh / parse-entries.sh

FI_AF_SPOT_KEYS=""

# Spec §3.1/§5.1: still [open], (fix: small|medium) or answered, no fix
# reference or suggestion, never failed. Large, decide and manual wait.
fi_af_fixable_now() {
  fi_parse_entry_vars "$1" || return 1
  [[ "$FE_status" == "open" ]] || return 1
  [[ -z "$FE_prs$FE_prs_auto$FE_commits$FE_commits_auto$FE_autofix_failed" ]] || return 1
  case "$FE_fixtag" in small|medium) return 0 ;; esac
  [[ -n "$FE_decided" && -z "$FE_decide" ]]
}

# One value from an item file, builtin (fi_af_item_read would clobber AFI_*).
_fi_af_field() {
  local line
  [[ -f "$1" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "$2="* ]] && { printf '%s' "${line#*=}"; return 0; }
  done <"$1"
  return 1
}

# Dedup keys of spot items waiting or running: a sweep leaves those to their
# own fixer (Review Focus 1).
_fi_af_spot_keys() {
  local f k
  FI_AF_SPOT_KEYS=$'\n'
  for f in "$FI_AF_ST"/queue/* "$FI_AF_ST"/running/*; do
    [[ -f "$f" ]] || continue
    [[ "$(_fi_af_field "$f" kind)" == "spot" ]] || continue
    k="$(_fi_af_field "$f" key)" && FI_AF_SPOT_KEYS+="$k"$'\n'
  done
}

# Ruling 6 order: critical first; then file groups, each placed by its
# oldest entry; then oldest; then ledger order. awk computes each group's
# oldest date (bash 3.2 has no associative arrays).
fi_af_sweep_candidates() {
  local file="$1" root="$2" max="$3" entry crit n=0
  _fi_af_spot_keys
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    fi_af_fixable_now "$entry" || continue
    crit=1; [[ "$FE_critical" == "yes" ]] && crit=0
    local path="$FE_path" date="$FE_date"
    fi_entry_dedup_key_v "$entry" "$root" || continue
    [[ "$FI_AF_SPOT_KEYS" == *$'\n'"$FI_KEY"$'\n'* ]] && continue
    n=$((n + 1))
    printf '%s\t%s\t%s\t%05d\t%s\n' "$crit" "$path" "$date" "$n" "$entry"
  done < <(fi_entries "$file" open 2>/dev/null || true) \
    | awk -F'\t' '{ r[NR] = $0; k = $1 SUBSEP $2; if (!(k in g) || $3 < g[k]) g[k] = $3; c[NR] = $1; p[NR] = $2 }
        END { for (i = 1; i <= NR; i++) print c[i] "\t" g[c[i] SUBSEP p[i]] "\t" r[i] }' \
    | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2 -k4,4 -k5,5 -k6,6 \
    | head -n "$max" | cut -f7-
}

fi_af_sweep_pending() {
  local f
  for f in "$FI_AF_ST"/queue/* "$FI_AF_ST"/running/*; do
    [[ -f "$f" ]] || continue
    [[ "$(_fi_af_field "$f" kind)" == "sweep" ]] && return 0
  done
  return 1
}

# Spec §4.1: after log, tag, decide or sync wrote the ledger. One sweep at
# a time and dailySweeps a day; due at sweepThreshold candidates or on one
# critical (fix: medium). Never fails its caller.
fi_af_sweep_check() {
  local slug root file entry n=0 crit=0 engine
  fi_af_enabled || return 0
  slug="$(fi_repo_id 2>/dev/null)" || return 0
  fi_repo_root_cached
  root="$FI_REPO_ROOT"
  [[ -n "$root" ]] || return 0
  file="$(fi_find_issues_file "$root" 2>/dev/null)" || return 0
  [[ -f "$file" ]] || return 0
  fi_af_dirs "$slug"
  fi_af_sweep_pending && return 0
  fi_af_cap_ok sweep "$(fi_af_int dailySweeps 1)" || return 0
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    n=$((n + 1))
    fi_parse_entry_vars "$entry"
    [[ "$FE_critical" == "yes" && "$FE_fixtag" == "medium" ]] && crit=1
  done < <(fi_af_sweep_candidates "$file" "$root" 1000)
  (( n > 0 )) || return 0
  (( crit || n >= $(fi_af_int sweepThreshold 5) )) || return 0
  engine="$(fi_af_engine 2>/dev/null || true)"
  fi_af_new_id
  fi_af_item_write "$FI_AF_ST/queue/$FI_AF_ID" "id=$FI_AF_ID" "kind=sweep" \
    "root=$root" "slug=$slug" "loc=sweep" "engine=$engine" \
    "queued=$(date +%Y-%m-%dT%H:%M:%S)" "crashes=0"
  if [[ "${FOUND_ISSUES_AUTOFIX_CHILD:-}" == "1" ]]; then
    printf 'Auto-fix: sweep queued %s (inside a fixer; the main session launches it)\n' "$FI_AF_ID"
  else
    printf 'AUTOFIX-SWEEP-DUE %s\n' "$FI_AF_ID"
  fi
}
```

Spot items must carry `kind=spot` (they already do: `fi_af_queue_spot` writes `kind=spot`).

Wire the trigger:
- `lib/log.sh` — at the end of `_fi_log_autofix`, and for untagged writes nothing: replace the function's last line `fi_af_queue_spot "$1" || true` with `fi_af_queue_spot "$1" || true` followed by `fi_af_sweep_check || true`, and change the early `[[ "$FE_status" == "open" && "$FE_fixtag" == "small" ]] || return 0` to `if [[ "$FE_status" == "open" && "$FE_fixtag" == "small" ]]; then fi_af_queue_spot "$1" || true; fi` then `fi_af_sweep_check || true`.
- `lib/tag.sh` — in `cmd_tag`'s `case` on the apply rc: `0) fi_af_sweep_check || true; return 0 ;;`.
- `lib/decide.sh` — after the successful `fi_tag_apply`: `fi_af_sweep_check || true`.
- `lib/sync.sh` — after the final successful `fi_ledger_replace` (not on `--dry-run`), when `woke > 0`: `fi_af_sweep_check || true`.
- `lib/autofix-queue.sh` `fi_af_item_read`: add `head|cur|fixed` to the key `case` and reset `AFI_head="" AFI_cur="0" AFI_fixed="0"` with the others (both the global init and the function's reset).
- `lib/autofix.sh` usage: `found-issues.autofix.{engine,testCommand,dailyFixes,runBudget,runTimeoutMin,dailySweeps,sweepThreshold,sweepMax,sweepBudget}.` Status: after the spot line, print `Today: <n>/<dailySweeps> sweeps` from `day/<date>.sweep`.

- [ ] **Step 5: Run to verify they pass** — `bats tests/autofix-sweep.bats tests/autofix-queue.bats tests/cli-log*.bats tests/cli-tag*.bats tests/cli-decide*.bats` → `0 not ok`.
- [ ] **Step 6: Commit** `feat(autofix): sweep candidates and the AUTOFIX-SWEEP-DUE trigger`.

---

### Task 3: Sweep claim and per-entry state

**Files:**
- Modify: `lib/autofix-sweep.sh` (claim, load, commit, settle, advance), `lib/autofix-queue.sh` (`fi_af_claim` dispatch, `fi_af_worktree_add` sweep branch, `fi_af_finish` ledger step factored out and skipped for sweeps)
- Test: `tests/autofix-sweep.bats`

**Interfaces:**
- Consumes: Task 2, `fi_af_lock`, `fi_af_reap`, `fi_af_worktree_add`, `fi_af_ledger_resolve`, `fi_af_ledger_tag`, `fi_af_reset_ledger`, `fi_entry_loc_v`.
- Produces:
  - `fi_af_sweep_claim <id>` (called by `fi_af_claim` with the lock held and the queue item read): rc 0 claimed, 3 capped, 5 nothing fixable (finished `stale`), 6 worktree failed. Files `$FI_AF_ST/sweeps/<id>.entries` (one entry line each, ordered) and `<id>.outcomes` (`<loc>\t<outcome>\t<text>`). Item keys `head` = `base_sha`, `cur` = 1, `fixed` = 0.
  - `fi_af_sweep_load <id>` → 0 with `AFI_entry`, `AFI_loc`, `AFI_key` set to entry `cur` and `AFI_base_sha` = `head`; 1 when `cur` is past the last entry.
  - `fi_af_sweep_commit <id>` → commits the approved change (`FI_AF_TREE`) as `fix: <symptom fragment> (found-issues <loc>)`, moves `head`, `fixed`+1, `verdict_tree` = new `head^{tree}`, records `fixed`, advances. rc 1 (with `FI_AF_WHY`) when the staged tree is not the approved one or the commit fails.
  - `fi_af_sweep_settle <id> <outcome> <text>` → resets the worktree to `head`, applies the entry's ledger outcome (`already-fixed` → resolve; `decide`/`manual` → tag; `failed` → `(autofix-failed:)`), records it, advances.
  - `_fi_af_ledger_outcome <outcome> <text>` → the ledger step `fi_af_finish` used to inline (no-op for `shipped|stale`).

- [ ] **Step 1: Write the failing tests** (append to `tests/autofix-sweep.bats`):

```bash
sweep_queue() { # queue a sweep for the fixture; sets SID and ST
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  SID="$(printf '%s\n' "$output" | sed -n 's/^AUTOFIX-SWEEP-DUE //p')"
  ST="$FOUND_ISSUES_STATE_DIR/autofix/foo__bar"
  [ -n "$SID" ]
}

@test "sweep claim: a worktree on fi/sweep/<date>-<n>, the ordered entry list, cur 1" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_queue
  run "$FI_BIN" autofix claim "$SID"
  [ "$status" -eq 0 ]
  WT="$REPO/.claude/worktrees/fi-sweep-$SID"
  [ "$output" = "$WT" ]
  [ "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" = "fi/sweep/${SID%%-*}-${SID##*-}" ]
  [ "$(wc -l < "$ST/sweeps/$SID.entries" | tr -d ' ')" = 5 ]
  grep -q '^cur=1$' "$ST/running/$SID"
  grep -q '^fixed=0$' "$ST/running/$SID"
  [ "$(sed -n 's/^head=//p' "$ST/running/$SID")" = "$(git -C "$WT" rev-parse HEAD)" ]
  [ -s "$ST/day/$(date +%Y-%m-%d).sweep" ]
}

@test "sweep claim: honours sweepMax" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_queue
  git config found-issues.autofix.sweepMax 2
  "$FI_BIN" autofix claim "$SID" >/dev/null
  [ "$(wc -l < "$ST/sweeps/$SID.entries" | tr -d ' ')" = 2 ]
}

@test "sweep claim: nothing fixable any more finishes the sweep stale" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_queue
  sed -i.bak 's/(fix: medium)/(fix: large)/' docs/found-issues.md; rm -f docs/found-issues.md.bak
  run "$FI_BIN" autofix claim "$SID"
  [ "$status" -eq 5 ]
  [ -f "$ST/done/$SID" ]
  grep -q '^result=stale: nothing fixable now$' "$ST/done/$SID"
}

@test "sweep state: commit moves head and advances; settle resets and tags the source ledger" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_queue
  "$FI_BIN" autofix claim "$SID" >/dev/null
  WT="$REPO/.claude/worktrees/fi-sweep-$SID"
  source "$FI_BIN"; fi_af_context
  fi_af_item_read "$ST/running/$SID"
  fi_af_sweep_load "$SID"
  first="$AFI_loc"
  sed -i.bak 's/- 1/+ 0/' "$WT/${AFI_loc%%:*}"; rm -f "$WT/${AFI_loc%%:*}.bak"
  git -C "$WT" add -A; FI_AF_TREE="$(git -C "$WT" write-tree)"
  fi_af_sweep_commit "$SID"
  grep -q '^cur=2$' "$ST/running/$SID"
  grep -q '^fixed=1$' "$ST/running/$SID"
  [[ "$(git -C "$WT" log -1 --format=%s)" == "fix: "*"(found-issues $first)" ]]
  fi_af_item_read "$ST/running/$SID"
  fi_af_sweep_load "$SID"
  printf 'junk\n' > "$WT/junk.txt"
  fi_af_sweep_settle "$SID" failed "tests fail after 2 attempts"
  [ ! -e "$WT/junk.txt" ]
  grep -q '^cur=3$' "$ST/running/$SID"
  grep -qF "$AFI_loc — " docs/found-issues.md
  grep -F "$AFI_loc — " docs/found-issues.md | grep -q '(autofix-failed: tests fail after 2 attempts)'
  grep -q "	fixed	" "$ST/sweeps/$SID.outcomes"
  grep -q "	failed	" "$ST/sweeps/$SID.outcomes"
}

@test "sweep claim: the kill switch refuses it like a spot claim" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_queue
  "$FI_BIN" autofix off >/dev/null
  run "$FI_BIN" autofix claim "$SID"
  [ "$status" -eq 1 ]
  [ -f "$ST/queue/$SID" ]
}
```

- [ ] **Step 2: Run to verify they fail.**

- [ ] **Step 3: Implement.**

`lib/autofix-queue.sh`:
- `fi_af_claim`: right after `if ! fi_af_item_read "$q"; then …; fi`, add
  ```bash
  if [[ "$AFI_kind" == "sweep" ]]; then fi_af_sweep_claim "$id"; return; fi
  ```
- `fi_af_worktree_add`: compute names by kind:
  ```bash
  if [[ "$AFI_kind" == "sweep" ]]; then
    AFI_branch="fi/sweep/${AFI_id%%-*}-${AFI_id##*-}"
    AFI_wt="$AFI_root/.claude/worktrees/fi-sweep-$AFI_id"
  else
    s="${AFI_loc//[^A-Za-z0-9]/-}"; s="${s:0:40}"
    AFI_branch="fi/autofix/$s-$AFI_id"
    AFI_wt="$AFI_root/.claude/worktrees/fi-autofix-$AFI_id"
  fi
  ```
- `fi_af_finish`: move the outcome `case` into `_fi_af_ledger_outcome "$outcome" "$text"` (returns its rc; rc 2 for an unknown outcome), and skip it when `AFI_kind` is `sweep` (a sweep item has no entry of its own, Ruling 7).

`lib/autofix-sweep.sh` (second part):

```bash
# Spec §6 steps 1-3 at claim time (lock held, queue item read): cap, the
# fresh worktree, the classify/wake pass (Task 4), then the entry list.
fi_af_sweep_claim() {
  local id="$1" q="$FI_AF_ST/queue/$1" r="$FI_AF_ST/running/$1" file n=0 line
  if ! fi_af_cap_ok sweep "$(fi_af_int dailySweeps 1)"; then fi_af_unlock "$id"; return 3; fi
  fi_af_item_set "$q" pid "${FI_AF_PID:-}"
  if [[ -n "${FI_AF_PID:-}" ]]; then fi_af_item_set "$q" launcher A; else fi_af_item_set "$q" launcher B; fi
  mv "$q" "$r" || { fi_af_unlock "$id"; return 1; }
  fi_af_cap_take sweep "$id"
  if ! fi_af_worktree_add; then fi_af_finish "$id" failed "$FI_AF_WHY"; return 6; fi
  fi_af_item_set "$r" wt "$AFI_wt"
  fi_af_item_set "$r" branch "$AFI_branch"
  fi_af_item_set "$r" base "$AFI_base"
  fi_af_item_set "$r" base_sha "$AFI_base_sha"
  fi_af_item_set "$r" head "$AFI_base_sha"
  fi_af_item_set "$r" cur 1
  fi_af_item_set "$r" fixed 0
  mkdir -p "$FI_AF_ST/sweeps"
  file="$(fi_find_issues_file "$AFI_root" 2>/dev/null)" || file=""
  if [[ -n "$file" && -f "$file" ]]; then
    declare -F fi_af_classify >/dev/null && fi_af_classify "$file" "$id"
    fi_af_sweep_candidates "$file" "$AFI_root" "$(fi_af_int sweepMax 8)" >"$FI_AF_ST/sweeps/$id.entries"
  else
    : >"$FI_AF_ST/sweeps/$id.entries"
  fi
  : >"$FI_AF_ST/sweeps/$id.outcomes"
  while IFS= read -r line || [[ -n "$line" ]]; do n=$((n + 1)); done <"$FI_AF_ST/sweeps/$id.entries"
  if (( n == 0 )); then fi_af_finish "$id" stale "nothing fixable now"; return 5; fi
  fi_af_log "$id" "claimed sweep: $n entries in $AFI_wt ($AFI_branch from origin/$AFI_base)"
}

# Entry number $AFI_cur of the sweep, with its base pinned to the last good
# commit so diff, reset and the verifier see only this entry's change.
fi_af_sweep_load() {
  local id="$1" f="$FI_AF_ST/sweeps/$1.entries" i=0 line
  [[ "$AFI_cur" =~ ^[0-9]+$ ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    i=$((i + 1))
    (( i == AFI_cur )) || continue
    AFI_entry="$line"
    fi_entry_loc_v "$line" || return 1
    AFI_loc="$FE_loc"
    fi_entry_dedup_key_v "$line" "$AFI_root" || return 1
    AFI_key="$FI_KEY"
    AFI_base_sha="${AFI_head:-$AFI_base_sha}"
    return 0
  done <"$f"
  return 1
}

_fi_af_sweep_record() {
  printf '%s\t%s\t%s\n' "$AFI_loc" "$1" "${2//$'\t'/ }" >>"$FI_AF_ST/sweeps/$AFI_id.outcomes"
}

_fi_af_sweep_advance() {
  local r="$FI_AF_ST/running/$AFI_id"
  AFI_cur=$(( AFI_cur + 1 ))
  fi_af_item_set "$r" cur "$AFI_cur"
  fi_af_item_set "$r" attempts 0
  fi_af_item_set "$r" verdict ""
  AFI_attempts=0 AFI_verdict=""
}

# The verifier approved FI_AF_TREE: commit exactly that tree.
fi_af_sweep_commit() {
  local id="$1" r="$FI_AF_ST/running/$1" frag
  FI_AF_WHY=""
  fi_af_reset_ledger "$AFI_wt" "$AFI_head"
  git -C "$AFI_wt" add -A >/dev/null 2>&1
  if [[ -z "$FI_AF_TREE" || "$(git -C "$AFI_wt" write-tree 2>/dev/null)" != "$FI_AF_TREE" ]]; then
    FI_AF_WHY="the change differs from what the verifier approved"; return 1
  fi
  fi_parse_entry_vars "$AFI_entry" || true
  frag="${FE_symptom:-$AFI_loc}"
  frag="${frag:0:60}"
  git -C "$AFI_wt" commit -q -m "fix: $frag (found-issues $AFI_loc)" >>"$FI_AF_RUNS/$id.log" 2>&1 \
    || { FI_AF_WHY="git commit refused (a commit hook?)"; return 1; }
  AFI_head="$(git -C "$AFI_wt" rev-parse HEAD)"
  AFI_fixed=$(( ${AFI_fixed:-0} + 1 ))
  fi_af_item_set "$r" head "$AFI_head"
  fi_af_item_set "$r" fixed "$AFI_fixed"
  fi_af_item_set "$r" verdict_tree "$(git -C "$AFI_wt" rev-parse "HEAD^{tree}")"
  _fi_af_sweep_record fixed "${FI_AF_VERDICT_REASON:-approved}"
  fi_af_log "$id" "sweep: committed $AFI_loc"
  _fi_af_sweep_advance
}

# Any outcome but fixed: drop this entry's change, record the outcome on the
# source ledger, move on.
fi_af_sweep_settle() {
  local id="$1" outcome="$2" text="$3" rc=0
  text="${text//$'\n'/ }"
  text="${text:0:160}"
  git -C "$AFI_wt" reset -q --hard "$AFI_head" >/dev/null 2>&1 || true
  git -C "$AFI_wt" clean -qfd >/dev/null 2>&1 || true
  _fi_af_ledger_outcome "$outcome" "$text" || rc=$?
  (( rc == 0 )) || fi_af_log "$id" "ledger not updated for $AFI_loc $outcome (rc $rc)"
  _fi_af_sweep_record "$outcome" "$text"
  fi_af_log "$id" "sweep: $AFI_loc $outcome: $text"
  _fi_af_sweep_advance
}
```

- [ ] **Step 4: Run to verify they pass** (plus `tests/autofix-claim.bats tests/autofix-release.bats tests/autofix-run.bats` for the `fi_af_finish` refactor).
- [ ] **Step 5: Commit** `feat(autofix): sweep claim, entry list and per-entry commit/settle`.

---

### Task 4: Classify and wake pass

**Files:**
- Create: `lib/autofix-classify.sh`
- Modify: `bin/found-issues` (source it before `autofix-sweep.sh`), `tests/standins/claude`, `tests/standins/codex` (classifier response), `lib/autofix-queue.sh` (`_fi_af_ledger_swap`)
- Test: create `tests/autofix-classify.bats`

**Interfaces:**
- Consumes: `fi_entries`, `fi_parse_entry_vars`, `fi_tag_resolve`, `fi_tag_apply`, `fi_entry_retag`, `fi_af_child`, `fi_af_collect`, `fi_af_engine`, `fi_af_budget_left`.
- Produces:
  - `fi_af_classify <ledger> <id>` (best effort, never fails the claim): runs the classifier in `$AFI_wt` when there is anything to classify or wake; applies valid tags and wakes to `<ledger>`; adds the cost to the item.
  - `fi_af_classify_apply <ledger> <json> <list-file>`: the pure apply step (testable without a model). `<list-file>` lines are `U<n>\t<entry>` and `W<n>\t<entry>`.
  - `_fi_af_ledger_swap <ledger> <old-line> <new-line>` → 0 written, 1 line gone, 3 ledger changed.
  - Classifier JSON: `{"tags":[{"n":"U1","kind":"fix|decide|manual","value":"small|medium|large|<text>"}],"wake":["W1"]}`.

- [ ] **Step 1: Write the failing tests** — `tests/autofix-classify.bats`:

```bash
#!/usr/bin/env bats
# v3 sweep classify/wake pass (spec §3.1, §6 steps 2-3; phase 4 plan Task 4).

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_fixture; fi_use_standins
  cat > docs/found-issues.md <<'EOF'
# found-issues

- [open] 2026-10-01 src/calc.sh:1 — add subtracts
- [open] 2026-10-01 .github/workflows/ci.yml:3 — ci typo
- [open] 2026-10-01 src/calc.sh:1 — already tagged (fix: small)
- [deferred] 2026-10-01 src/calc.sh:1 — waits on upstream (until: when upstream ships 2.0)
- [deferred] 2026-10-01 src/calc.sh:1 — waits on a date (until: date:2099-01-01)
EOF
  git add -A && git commit -q -m ledger
  source "$FI_BIN"; fi_af_context
}
teardown() { fi_teardown_tmp; }

list_file() {
  printf 'U1\t%s\nU2\t%s\nW1\t%s\n' \
    "- [open] 2026-10-01 src/calc.sh:1 — add subtracts" \
    "- [open] 2026-10-01 .github/workflows/ci.yml:3 — ci typo" \
    "- [deferred] 2026-10-01 src/calc.sh:1 — waits on upstream (until: when upstream ships 2.0)" > "$TMP/list"
}

@test "classify apply: valid tags and wakes are written" {
  list_file
  fi_af_classify_apply docs/found-issues.md '{"tags":[{"n":"U1","kind":"fix","value":"medium"}],"wake":["W1"]}' "$TMP/list"
  grep -qF -- '- [open] 2026-10-01 src/calc.sh:1 — add subtracts (fix: medium)' docs/found-issues.md
  grep -qF -- '- [open] 2026-10-01 src/calc.sh:1 — waits on upstream' docs/found-issues.md
  ! grep -q 'until: when upstream' docs/found-issues.md || false
}

@test "classify apply: an off-limits path classified fix becomes manual" {
  list_file
  fi_af_classify_apply docs/found-issues.md '{"tags":[{"n":"U2","kind":"fix","value":"small"}],"wake":[]}' "$TMP/list"
  grep -F 'ci typo' docs/found-issues.md | grep -q '(manual: off-limits: ci)'
}

@test "classify apply: classifier garbage writes nothing" {
  list_file
  before="$(cksum < docs/found-issues.md)"
  fi_af_classify_apply docs/found-issues.md 'no json here' "$TMP/list"
  fi_af_classify_apply docs/found-issues.md '{"tags":[{"n":"U9","kind":"fix","value":"small"},{"n":"U1","kind":"fix","value":"huge"},{"n":"U1","kind":"rm -rf","value":"x"}],"wake":["W7","U1"]}' "$TMP/list"
  [ "$(cksum < docs/found-issues.md)" = "$before" ]
}

@test "classify: the pass sees only untagged open and free-text deferred entries" {
  export FI_STANDIN_CLASSIFY='{"tags":[{"n":"U1","kind":"fix","value":"small"}],"wake":[]}'
  AFI_wt="$REPO" AFI_id=c1 AFI_engine=claude
  fi_af_classify docs/found-issues.md c1
  grep -qF -- '- [open] 2026-10-01 src/calc.sh:1 — add subtracts (fix: small)' docs/found-issues.md
  p="$(grep -a 'found-issues classifier' "$FI_STANDIN_TRACE" | tr '\037' '\n')"
  [[ "$p" == *"U1"*"add subtracts"* ]]
  [[ "$p" == *"W1"*"waits on upstream"* ]]
  [[ "$p" != *"already tagged"* ]]
  [[ "$p" != *"waits on a date"* ]]
}

@test "classify: nothing to classify runs no model" {
  printf '# found-issues\n\n- [open] 2026-10-01 src/calc.sh:1 — tagged (fix: small)\n' > docs/found-issues.md
  AFI_wt="$REPO" AFI_id=c1 AFI_engine=claude
  fi_af_classify docs/found-issues.md c1
  [ ! -s "$FI_STANDIN_TRACE" ]
}
```

- [ ] **Step 2: Stand-ins** — in `tests/standins/claude`, before the `verifier=0` scan:

```bash
# The sweep classifier (phase 4): reply with FI_STANDIN_CLASSIFY or nothing.
for a in "$@"; do
  if [[ "$a" == *"found-issues classifier"* ]]; then
    jq -n --arg r "${FI_STANDIN_CLASSIFY:-{\"tags\":[],\"wake\":[]\}}" --argjson c "${FI_STANDIN_COST:-0.25}" \
      '{type:"result",subtype:"success",is_error:false,result:$r,total_cost_usd:$c,permission_denials:[]}'
    exit 0
  fi
done
```

and the matching branch in `tests/standins/codex` (writes `FI_STANDIN_CLASSIFY` to the `-o` file).

- [ ] **Step 3: Run to verify they fail.**

- [ ] **Step 4: Implement** — `lib/autofix-classify.sh`:

```bash
#!/usr/bin/env bash
# autofix-classify.sh — the sweep's classify/wake pass (spec 2026-10-03 §3.1,
# §6 steps 2-3; phase 4 ruling 2): one headless read-only model call tags
# untagged [open] entries and judges free-text (until:) triggers; bash
# validates every answer and writes the ledger.
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   fi_af_classify <ledger> <id>
#   fi_af_classify_apply <ledger> <json> <list-file>

# shellcheck disable=SC2154  # AFI_*/FE_* come from autofix-queue.sh / parse-entries.sh

_fi_af_classify_list() {
  local file="$1" out="$2" entry u=0 w=0
  : >"$out"
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    fi_parse_entry_vars "$entry" || continue
    if [[ "$FE_status" == "open" ]]; then
      [[ -z "$FE_fixtag$FE_decide$FE_decided$FE_manual$FE_autofix_failed$FE_prs$FE_commits" ]] || continue
      (( u < 20 )) || continue
      u=$((u + 1)); printf 'U%s\t%s\n' "$u" "$entry" >>"$out"
    elif [[ "$FE_status" == "deferred" && -n "$FE_until" ]]; then
      case "$FE_until" in date:*|pr:*) continue ;; esac
      (( w < 10 )) || continue
      w=$((w + 1)); printf 'W%s\t%s\n' "$w" "$entry" >>"$out"
    fi
  done < <(fi_entries "$file" all 2>/dev/null || true)
}

_fi_af_classify_prompt() {
  cat <<EOF
You are the found-issues classifier. This run is unattended and read-only:
read files in this checkout if you need to, edit nothing, ask nothing.

Tag each U entry with exactly one of:
- {"kind":"fix","value":"small"}: no human decision needed, ready now, a test can prove the fix, a few lines
- {"kind":"fix","value":"medium"}: the same, but a larger change in one area
- {"kind":"fix","value":"large"}: no decision needed, but big
- {"kind":"decide","value":"<the question a human must answer>"}: more than one reasonable fix, an interface others depend on, product taste, anything outside the repo, irreversible actions, or "is this even a bug?"
- {"kind":"manual","value":"<why>"}: no test or build can prove a fix
Leave out any U entry you are unsure about.

For each W entry, wake it only if its (until: ...) trigger has clearly
happened, judged from this checkout.

Entries:
$(cat "$1")

Reply with only a JSON object:
{"tags":[{"n":"U1","kind":"fix","value":"small"}],"wake":["W1"]}
EOF
}

# Every answer is validated: known ids only, known kinds and sizes only,
# fi_tag_resolve applies the off-limits override, and a W id only wakes.
fi_af_classify_apply() {
  local file="$1" json="$2" list="$3" rows row n kind value entry rc
  rows="$(printf '%s' "$json" | jq -r '
      ((.tags // []) | .[]? | select(type == "object") | ["T", (.n|tostring), (.kind|tostring), (.value|tostring)] | @tsv),
      ((.wake // []) | .[]? | ["W", tostring, "", ""] | @tsv)' 2>/dev/null)" || return 0
  while IFS=$'\t' read -r row n kind value; do
    [[ -n "$row" ]] || continue
    entry=""
    while IFS=$'\t' read -r lid lentry; do
      [[ "$lid" == "$n" ]] && { entry="$lentry"; break; }
    done <"$list"
    [[ -n "$entry" ]] || continue
    if [[ "$row" == "T" ]]; then
      [[ "$n" == U* ]] || continue
      case "$kind" in fix|decide|manual) ;; *) continue ;; esac
      fi_parse_entry_vars "$entry" || continue
      fi_tag_resolve "$kind" "$value" "$FE_path" "$AFI_root" 2>/dev/null || continue
      rc=0; fi_tag_apply "$file" "$entry" "$FI_TAG_KIND" "$FI_TAG_VALUE" >/dev/null || rc=$?
    else
      [[ "$n" == W* ]] || continue
      fi_entry_retag "$entry" drop-until "" || continue
      rc=0; _fi_af_ledger_swap "$file" "$entry" "- [open]${FI_RETAGGED#- \[deferred\]}" || rc=$?
    fi
  done <<<"$rows"
  return 0
}

fi_af_classify() {
  local file="$1" id="$2" list="$FI_AF_RUNS/$2.classify.list" base="$FI_AF_RUNS/$2.classify" engine rc=0
  _fi_af_classify_list "$file" "$list"
  [[ -s "$list" ]] || return 0
  engine="$(fi_af_engine "${AFI_engine:-}" 2>/dev/null)" || return 0
  command -v "$engine" >/dev/null 2>&1 || return 0
  if [[ "$engine" == "codex" ]]; then
    printf '%s\n' '{"type":"object","properties":{"tags":{"type":"array","items":{"type":"object","properties":{"n":{"type":"string"},"kind":{"type":"string"},"value":{"type":"string"}},"required":["n","kind","value"],"additionalProperties":false}},"wake":{"type":"array","items":{"type":"string"}}},"required":["tags","wake"],"additionalProperties":false}' >"$base.schema.json"
    FI_AF_CMD=(codex exec --sandbox read-only -C "$AFI_wt" --ephemeral --json
      --output-schema "$base.schema.json" -o "$base.last" "$(_fi_af_classify_prompt "$list")")
  else
    FI_AF_CMD=(claude -p --model sonnet --max-budget-usd "$(fi_af_budget_left || printf '0.10')"
      --max-turns 20 --no-session-persistence
      --permission-mode dontAsk --permission-prompts none
      --allowedTools Read Grep Glob
      --output-format json "$(_fi_af_classify_prompt "$list")")
  fi
  fi_af_child "$base.out" "$base.err" "$AFI_wt" "${FI_AF_CMD[@]}" || rc=$?
  fi_af_collect "$engine" "$base.out" "$base.last"
  [[ -f "$FI_AF_ST/running/$id" ]] && fi_af_item_set "$FI_AF_ST/running/$id" cost "$FI_AF_COST"
  fi_af_log "$id" "classify: rc=$rc"
  local t="$FI_AF_TEXT"
  [[ "$t" == *"{"*"}"* ]] || return 0
  t="{${t#*\{}"; t="${t%\}*}}"
  fi_af_classify_apply "$file" "$t" "$list"
}
```

`_fi_af_ledger_swap` in `lib/autofix-queue.sh` (and `fi_af_ledger_resolve` rewritten to use it):

```bash
# Replace the first line equal to <old> with <new>, serialized like every
# ledger write: 0 written, 1 line gone, 3 ledger changed underneath.
_fi_af_ledger_swap() {
  local file="$1" old="$2" new="$3" snapshot tmp line done_one=0
  snapshot="$(fi_ledger_snapshot "$file")"
  tmp="$(fi_ledger_tmp "$file")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( ! done_one )) && [[ "$line" == "$old" ]]; then
      printf '%s\n' "$new" >>"$tmp"; done_one=1
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$file"
  (( done_one )) || { rm -f "$tmp"; return 1; }
  fi_ledger_replace "$file" "$tmp" "$snapshot"
}
```

- [ ] **Step 5: Run to verify they pass** (plus `tests/autofix-sweep.bats`, `tests/autofix-release.bats`).
- [ ] **Step 6: Commit** `feat(autofix): sweep classify and wake pass`.

---

### Task 5: Sweep run (launcher A) and the one sweep PR

**Files:**
- Modify: `lib/autofix-sweep.sh` (run loop, finish, ship), `lib/autofix-ship.sh` (`_fi_af_publish` shared by spot and sweep ship), `lib/autofix.sh` (`_fi_af_run_one` dispatch), `lib/autofix-config.sh` (`fi_af_budget` reads `sweepBudget` for sweeps)
- Test: `tests/autofix-sweep.bats`

**Interfaces:**
- Consumes: Tasks 1-4, `fi_af_run_tests`, `fi_af_spawn`, `fi_af_annotate_ledger`.
- Produces:
  - `_fi_af_run_sweep <id> <engine-opt>` (from `_fi_af_run_one` after a successful sweep claim).
  - `fi_af_sweep_finish <id>` → ships when `fixed > 0` (finish `shipped`, prints nothing), else finishes `stale`. rc 0 shipped/stale, 1 ship failed (finished `failed`).
  - `fi_af_sweep_ship` → sets `FI_AF_PR`, `FI_AF_MERGE`; rc 1 with `FI_AF_WHY`.
  - `_fi_af_publish <title> <bodyfile> <locs-keys-file>`: push, PR, annotate each `<key>\t<loc>` row on the PR branch ledger (one commit) and the source ledger, arm auto-merge or spawn merge-when-green. `fi_af_ship` calls it with its single entry.

- [ ] **Step 1: Write the failing tests** (append):

```bash
sweep_edit() { # the stand-in fixer fixes whichever entry its prompt names, with a test
  export FI_STANDIN_EDIT='case "$FI_STANDIN_PROMPT" in *"src/calc.sh:1"*) sed -i.bak "s/ - / + /" src/calc.sh; rm -f src/calc.sh.bak; printf "[ \"\$(add 2 3)\" = 5 ]\n" >> test.sh ;; esac; for f in src/f*.sh; do n="${f#src/f}"; n="${n%.sh}"; case "$FI_STANDIN_PROMPT" in *"src/f$n.sh:1"*) sed -i.bak "s/- 1/+ 0/" "$f"; rm -f "$f.bak"; printf "[ \"\$(f%s 2)\" = 2 ]\n" "$n" >> test.sh ;; esac; done'
}

@test "sweep run: fixes every entry, one commit each, one PR, every entry annotated" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit
  export GH_MOCK_TRACE="$TMP/gh.trace"
  export GH_MOCK_PR_VIEW=$'9\t{"number":9,"state":"OPEN","statusCheckRollup":[]}'
  export GH_MOCK_PR_CREATE_URL=https://github.com/foo/bar/pull/9
  sweep_queue
  run "$FI_BIN" autofix run "$SID" --engine claude
  [ "$status" -eq 0 ]
  [ -f "$ST/done/$SID" ]
  grep -q '^result=shipped: PR #9' "$ST/done/$SID"
  br="fi/sweep/${SID%%-*}-${SID##*-}"
  [ "$(git -C "$TMP/remote.git" rev-list --count "main..$br")" -ge 5 ]
  [ "$(grep -c '^pr create' "$GH_MOCK_TRACE")" = 1 ]
  [ "$(grep -c '(PR: foo/bar#9)' docs/found-issues.md)" = 5 ]
  grep -q '^pr merge 9 --auto --squash --repo foo/bar$' "$GH_MOCK_TRACE"
}

@test "sweep run: a rejected entry is reset and the next entry's diff is clean" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit
  export GH_MOCK_TRACE="$TMP/gh.trace" GH_MOCK_PR_CREATE_URL=https://github.com/foo/bar/pull/9
  export GH_MOCK_PR_VIEW=$'9\t{"number":9,"state":"OPEN","statusCheckRollup":[]}'
  printf '%s\n' '{"approve":false,"reason":"no"}' '{"approve":false,"reason":"no"}' > "$TMP/verdicts"
  export FI_STANDIN_VERDICTS="$TMP/verdicts"
  sweep_queue
  "$FI_BIN" autofix run "$SID" --engine claude
  first="$(head -1 "$ST/sweeps/$SID.entries")"
  grep -F "${first%% (fix: medium)}" docs/found-issues.md | grep -q '(autofix-failed: verifier rejected: no after 2 attempts)'
  [ "$(grep -c '	fixed	' "$ST/sweeps/$SID.outcomes")" = 4 ]
  # no commit on the branch touches the first entry's file
  f1="$(printf '%s' "$first" | sed -E 's/^.* (src\/[^:]+):.*/\1/')"
  br="fi/sweep/${SID%%-*}-${SID##*-}"
  [ -z "$(git -C "$TMP/remote.git" log --format=%H "main..$br" -- "$f1")" ]
}

@test "sweep run: nothing fixed ends stale with no PR" {
  fi_af_sweep_fixture 4; fi_use_standins
  export FI_STANDIN_RESULT='FI-RESULT: manual cannot test'
  export GH_MOCK_TRACE="$TMP/gh.trace"
  sweep_queue
  "$FI_BIN" autofix run "$SID" --engine claude
  grep -q '^result=stale: sweep fixed nothing' "$ST/done/$SID"
  ! grep -q '^pr create' "$GH_MOCK_TRACE" 2>/dev/null || false
}

@test "sweep run: ship refuses a tree that differs from the approved commits" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit
  export GH_MOCK_TRACE="$TMP/gh.trace"
  # $$ differs per run: the ship-time test run rewrites the artifact.
  git config found-issues.autofix.testCommand 'sh test.sh && echo $$ > artifact.out'
  git config found-issues.autofix.sweepMax 1
  sweep_queue
  "$FI_BIN" autofix run "$SID" --engine claude
  grep -q 'result=failed: ship: ' "$ST/done/$SID"
  ! grep -q '^pr create' "$GH_MOCK_TRACE" 2>/dev/null || false
}

@test "sweep run: a spot item for an entry the sweep shipped retires stale" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit
  export GH_MOCK_TRACE="$TMP/gh.trace" GH_MOCK_PR_CREATE_URL=https://github.com/foo/bar/pull/9
  export GH_MOCK_PR_VIEW=$'9\t{"number":9,"state":"OPEN","statusCheckRollup":[]}'
  sweep_queue
  "$FI_BIN" autofix run "$SID" --engine claude
  entry="$(grep -m1 'f1 subtracts' docs/found-issues.md)"
  source "$FI_BIN"; fi_af_context
  FI_AF_ID=20991231-000000-00001
  fi_entry_dedup_key_v "$entry" "$REPO"
  fi_af_item_write "$ST/queue/$FI_AF_ID" "id=$FI_AF_ID" kind=spot "root=$REPO" slug=foo/bar loc=src/f1.sh:1 "key=$FI_KEY" "entry=$entry" engine=claude crashes=0
  run "$FI_BIN" autofix claim "$FI_AF_ID"
  [ "$status" -eq 5 ]
}
```

(`FI_STANDIN_PROMPT`: the stand-in exports its last argument under that name before running `FI_STANDIN_EDIT`; add `export FI_STANDIN_PROMPT="${!#}"` above the `bash -c "$FI_STANDIN_EDIT"` line in `tests/standins/claude`.)

- [ ] **Step 2: Run to verify they fail.**

- [ ] **Step 3: Implement.**

`lib/autofix-config.sh` `fi_af_budget`: when `AFI_kind` is `sweep`, read `sweepBudget` with default 10 (same validation message naming the key).

`lib/autofix.sh` `_fi_af_run_one`, right after `fi_af_claim "$id" || return $?` and the item read:

```bash
  if [[ "$AFI_kind" == "sweep" ]]; then _fi_af_run_sweep "$id" "$engine_opt"; return; fi
```

`lib/autofix-ship.sh` — split `fi_af_ship` after its commit step into `_fi_af_publish` (body moved, with the single-entry annotation becoming the loop below). `fi_af_ship` ends with:

```bash
  printf '%s\t%s\n' "$AFI_key" "$AFI_loc" >"$FI_AF_RUNS/$AFI_id.publish"
  _fi_af_publish "fix: $frag" "$bodyf" "$FI_AF_RUNS/$AFI_id.publish"
```

where `bodyf` is written by `_fi_af_pr_body "$tlog" >"$bodyf"` before the call, and

```bash
# Push, open the PR, annotate every <key>\t<loc> row on the PR branch's
# ledger (one commit) and in the source ledger, then arm auto-merge.
_fi_af_publish() {
  local title="$1" bodyf="$2" rows="$3" wt="$AFI_wt" br="$AFI_branch" base="$AFI_base"
  local runlog="$FI_AF_RUNS/$AFI_id.log" url p wl="" ann key loc keep_key="$AFI_key" keep_loc="$AFI_loc" n=0
  git -C "$wt" push -q -u origin "$br" >>"$runlog" 2>&1 || { FI_AF_WHY="git push failed"; return 1; }
  url="$(cd "$wt" && gh pr create --repo "$AFI_slug" --base "$base" --head "$br" --title "$title" --body-file "$bodyf" 2>>"$runlog")" \
    || { FI_AF_WHY="gh pr create failed"; return 1; }
  FI_AF_PR="${url##*/}"
  [[ "$FI_AF_PR" =~ ^[0-9]+$ ]] || { FI_AF_WHY="no PR number in: $url"; return 1; }
  fi_af_log "$AFI_id" "opened PR #$FI_AF_PR"
  ann="(PR: $AFI_slug#$FI_AF_PR)"
  for p in docs/found-issues.md .found-issues.md; do
    [[ -f "$wt/$p" ]] && { wl="$p"; break; }
  done
  while IFS=$'\t' read -r key loc; do
    [[ -n "$key" ]] || continue
    AFI_key="$key" AFI_loc="$loc"
    if [[ -n "$wl" ]] && fi_af_annotate_ledger "$wt/$wl" "$ann"; then n=$((n + 1)); fi
    fi_af_annotate_ledger "" "$ann" || fi_af_log "$AFI_id" "source ledger annotation failed for $loc"
  done <"$rows"
  AFI_key="$keep_key" AFI_loc="$keep_loc"
  if (( n > 0 )); then
    git -C "$wt" add -- "$wl"
    if git -C "$wt" commit -q -m "docs(found-issues): annotate PR $FI_AF_PR" >>"$runlog" 2>&1; then
      git -C "$wt" push -q origin "$br" >>"$runlog" 2>&1 || fi_af_log "$AFI_id" "ledger annotation push failed"
    fi
  fi
  if ( cd "$wt" && gh pr merge "$FI_AF_PR" --auto --squash --repo "$AFI_slug" ) >>"$runlog" 2>&1; then
    FI_AF_MERGE="auto"
  else
    fi_af_spawn "$AFI_root" autofix merge-when-green "$FI_AF_PR" --repo "$AFI_slug"
    FI_AF_MERGE="merge-when-green"
  fi
  fi_af_log "$AFI_id" "merge: $FI_AF_MERGE"
}
```

The spot ship's annotation commit message changes from `annotate <loc> with PR <N>` to `annotate PR <N>`; update the one test that pins it if any (`rg -n 'annotate .* with PR' tests/`).

`lib/autofix-sweep.sh` (third part):

```bash
# Launcher A for a claimed sweep: each entry through the shared fix loop,
# then one PR (spec §6 steps 4-5).
_fi_af_run_sweep() {
  local id="$1" engine_opt="$2" r="$FI_AF_ST/running/$1" engine
  fi_af_item_read "$r"
  FI_AF_COST="${AFI_cost:-0}" FI_AF_TOKENS="${AFI_tokens:-0}"
  if ! FI_AF_TESTCMD="$(fi_af_test_command "$AFI_wt")"; then
    fi_af_finish "$id" stale "no test command"; return 0
  fi
  if ! engine="$(fi_af_engine "${engine_opt:-$AFI_engine}")" || ! command -v "$engine" >/dev/null 2>&1; then
    fi_af_finish "$id" failed "no ${engine:-claude or codex} on PATH"; return 0
  fi
  AFI_engine="$engine"
  while fi_af_sweep_load "$id"; do
    fi_af_enabled || break
    _fi_af_fix_loop "$id" "$engine"
    fi_af_item_set "$r" cost "$FI_AF_COST"
    fi_af_item_set "$r" tokens "$FI_AF_TOKENS"
    case "$FI_AF_OUTCOME" in
      outage) fi_af_log "$id" "sweep: engine error: $FI_AF_OUTCOME_TEXT"; _fi_af_reset_wt; break ;;
      approved)
        fi_af_sweep_commit "$id" || fi_af_sweep_settle "$id" failed "commit: $FI_AF_WHY" ;;
      failed)
        if [[ "$FI_AF_OUTCOME_TEXT" == "run budget spent"* ]]; then _fi_af_reset_wt; break; fi
        fi_af_sweep_settle "$id" failed "$FI_AF_OUTCOME_TEXT" ;;
      *) fi_af_sweep_settle "$id" "$FI_AF_OUTCOME" "$FI_AF_OUTCOME_TEXT" ;;
    esac
  done
  fi_af_sweep_finish "$id"
  return 0
}

fi_af_sweep_finish() {
  local id="$1" r="$FI_AF_ST/running/$1"
  fi_af_item_read "$r" || return 1
  if (( ${AFI_fixed:-0} == 0 )); then
    fi_af_finish "$id" stale "sweep fixed nothing ($(_fi_af_sweep_tally "$id"))"; return 0
  fi
  if fi_af_sweep_ship; then
    fi_af_item_set "$r" pr "$FI_AF_PR"
    fi_af_finish "$id" shipped "PR #$FI_AF_PR, $AFI_fixed fixed, merge $FI_AF_MERGE, \$${FI_AF_COST:-$AFI_cost}"
    return 0
  fi
  fi_af_finish "$id" failed "ship: $FI_AF_WHY"
  return 1
}

_fi_af_sweep_tally() {
  local loc out text t="" k
  for k in fixed already-fixed decide manual failed; do
    local c=0
    while IFS=$'\t' read -r loc out text; do [[ "$out" == "$k" ]] && c=$((c + 1)); done <"$FI_AF_ST/sweeps/$1.outcomes"
    (( c > 0 )) && t+="${t:+, }$c $k"
  done
  printf '%s' "${t:-no entries}"
}

_fi_af_sweep_pr_body() {
  local tlog="$1" loc out text
  printf 'Unattended sweep by found-issues auto-fix (launcher %s, engine %s): %s.\n\n' \
    "${AFI_launcher:-A}" "${AFI_engine:-?}" "$(_fi_af_sweep_tally "$AFI_id")"
  printf '| Entry | Outcome | Note |\n|---|---|---|\n'
  while IFS=$'\t' read -r loc out text; do
    printf '| `%s` | %s | %s |\n' "$loc" "$out" "${text//|/\\|}"
  done <"$FI_AF_ST/sweeps/$AFI_id.outcomes"
  printf '\nOne commit per fixed entry; each was approved by the verifier.\n\n'
  printf 'Tests: `%s` passed. Last lines:\n\n' "$FI_AF_TESTCMD"
  tail -n 15 "$tlog" 2>/dev/null | sed 's/^/    /'
  printf '\nRun cost: $%s (claude), %s tokens (codex)\n\n' "${FI_AF_COST:-0}" "${FI_AF_TOKENS:-0}"
  printf 'This PR merges itself when its checks pass (found-issues auto-fix policy).\n'
}

# The commits are made; ship re-runs the tests at head and refuses any tree
# other than head's (Review Focus 3), then publishes one PR.
fi_af_sweep_ship() {
  local wt="$AFI_wt" tlog="$FI_AF_RUNS/$AFI_id.ship-tests.log" bodyf="$FI_AF_RUNS/$AFI_id.pr-body.md"
  local rows="$FI_AF_RUNS/$AFI_id.publish" loc out text line i=0
  FI_AF_PR="" FI_AF_MERGE="none" FI_AF_WHY=""
  [[ -n "$FI_AF_TESTCMD" ]] || FI_AF_TESTCMD="$(fi_af_test_command "$wt")" || { FI_AF_WHY="no test command"; return 1; }
  fi_af_run_tests "$wt" "$FI_AF_TESTCMD" "$tlog" || { FI_AF_WHY="tests fail at ship"; return 1; }
  fi_af_reset_ledger "$wt" "$AFI_head"
  git -C "$wt" add -A >/dev/null 2>&1
  if [[ -z "$AFI_verdict_tree" || "$(git -C "$wt" write-tree 2>/dev/null)" != "$AFI_verdict_tree" ]]; then
    FI_AF_WHY="the tree differs from the approved commits (did the tests leave files?)"; return 1
  fi
  : >"$rows"
  while IFS=$'\t' read -r loc out text; do
    [[ "$out" == "fixed" ]] || continue
    i=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      fi_entry_loc_v "$line" || continue
      [[ "$FE_loc" == "$loc" ]] || continue
      fi_entry_dedup_key_v "$line" "$AFI_root" && printf '%s\t%s\n' "$FI_KEY" "$loc" >>"$rows"
      break
    done <"$FI_AF_ST/sweeps/$AFI_id.entries"
  done <"$FI_AF_ST/sweeps/$AFI_id.outcomes"
  _fi_af_sweep_pr_body "$tlog" >"$bodyf"
  _fi_af_publish "fix: found-issues sweep ($AFI_fixed entries)" "$bodyf" "$rows"
}
```

- [ ] **Step 4: Run to verify they pass** (plus `tests/autofix-ship.bats tests/autofix-run.bats tests/autofix-b.bats`).
- [ ] **Step 5: Commit** `feat(autofix): sweep run and one self-merging sweep PR`.

---

### Task 6: Launcher B for sweeps — CLI and the `found-issues-sweeper` agent

**Files:**
- Create: `agents/found-issues-sweeper.md`
- Modify: `lib/autofix-b.sh` (`fi_af_b_running` loads the current entry; `fi_af_sweep_brief`; sweep branches in `fi_af_b_verify`), `lib/autofix.sh` (`next` subcommand; sweep branches in `claim` output, `release`, `ship`; usage)
- Test: create `tests/autofix-sweep-b.bats`; extend `tests/autofix-agent.bats`

**Interfaces:**
- Produces:
  - `found-issues autofix next <id>` (sweeps only): prints `Entry <cur>/<n>: <entry line>` plus the worktree path, or `No entries left. Run: found-issues autofix ship <id>`; exit 0 either way; exit 2 for a spot item.
  - `autofix verify <id>` on a sweep: exit 0 = approved AND committed (`Next: found-issues autofix next <id>`); 1 rejected, one attempt left; 2 nothing to verify; 3 tests fail; 5 rejected twice (entry failed, sweep continues: `Next: found-issues autofix next <id>`); 6 budget spent and 7 verifier unavailable (`run: found-issues autofix ship <id>`); 8 switched off (requeued).
  - `autofix release <id> --… "<text>"` on a sweep settles the CURRENT entry and prints the `next` hint.
  - `autofix ship <id>` on a sweep runs `fi_af_sweep_finish` and prints `Shipped sweep <id> as PR #<N> (merge: …)` or `Sweep <id> fixed nothing; finished.`
  - The agent `found-issues:found-issues-sweeper`.

- [ ] **Step 1: Write the failing tests** — `tests/autofix-sweep-b.bats`:

```bash
#!/usr/bin/env bats
# v3 launcher B for sweeps (spec §4.2, §6; phase 4 plan Task 6).

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_sweep_fixture 4; fi_use_standins
  export GH_MOCK_TRACE="$TMP/gh.trace" GH_MOCK_PR_CREATE_URL=https://github.com/foo/bar/pull/9
  export GH_MOCK_PR_VIEW=$'9\t{"number":9,"state":"OPEN","statusCheckRollup":[]}'
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  SID="$(printf '%s\n' "$output" | sed -n 's/^AUTOFIX-SWEEP-DUE //p')"
  ST="$FOUND_ISSUES_STATE_DIR/autofix/foo__bar"
  "$FI_BIN" autofix claim "$SID" >/dev/null
  WT="$REPO/.claude/worktrees/fi-sweep-$SID"
}
teardown() { fi_teardown_tmp; }

fix_current() { # fix the entry `next` names, with a test
  loc="$("$FI_BIN" autofix next "$SID" | sed -n 's/^Entry [0-9]*\/[0-9]*: .* \(src\/f[0-9]*\.sh\):1 .*/\1/p')"
  n="${loc#src/f}"; n="${n%.sh}"
  sed -i.bak 's/- 1/+ 0/' "$WT/$loc"; rm -f "$WT/$loc.bak"
  printf '[ "$(f%s 2)" = 2 ]\n' "$n" >> "$WT/test.sh"
}

@test "sweep b: brief lists next, test, verify, release and ship" {
  run "$FI_BIN" autofix brief "$SID"
  [ "$status" -eq 0 ]
  for c in next test verify release ship; do [[ "$output" == *"found-issues autofix $c $SID"* ]]; done
  [[ "$output" == *"$WT"* ]]
}

@test "sweep b: next names entry 1 of 5" {
  run "$FI_BIN" autofix next "$SID"
  [[ "${lines[0]}" == "Entry 1/5: "* ]]
}

@test "sweep b: verify approves, commits and advances" {
  fix_current
  run "$FI_BIN" autofix verify "$SID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"autofix next $SID"* ]]
  grep -q '^cur=2$' "$ST/running/$SID"
  grep -q '^fixed=1$' "$ST/running/$SID"
  [ -z "$(git -C "$WT" status --porcelain)" ]
}

@test "sweep b: two rejects fail the entry and the sweep goes on" {
  fix_current
  printf '%s\n' '{"approve":false,"reason":"no"}' '{"approve":false,"reason":"no"}' > "$TMP/v"
  export FI_STANDIN_VERDICTS="$TMP/v"
  run "$FI_BIN" autofix verify "$SID"; [ "$status" -eq 1 ]
  run "$FI_BIN" autofix verify "$SID"; [ "$status" -eq 5 ]
  [[ "$output" == *"autofix next $SID"* ]]
  grep -q '^cur=2$' "$ST/running/$SID"
  [ -f "$ST/running/$SID" ]
}

@test "sweep b: release settles only the current entry" {
  run "$FI_BIN" autofix release "$SID" --manual "needs hardware"
  [ "$status" -eq 0 ]
  grep -q '^cur=2$' "$ST/running/$SID"
  grep -q '(manual: needs hardware)' docs/found-issues.md
  [ -f "$ST/running/$SID" ]
}

@test "sweep b: ship after the last entry opens one PR; with nothing fixed it finishes" {
  fix_current; "$FI_BIN" autofix verify "$SID" >/dev/null
  for i in 2 3 4 5; do "$FI_BIN" autofix release "$SID" --failed "skip" >/dev/null; done
  run "$FI_BIN" autofix next "$SID"
  [[ "$output" == *"No entries left"* ]]
  run "$FI_BIN" autofix ship "$SID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #9"* ]]
  [ -f "$ST/done/$SID" ]
}

@test "sweep b: ship with nothing fixed finishes stale, no PR" {
  for i in 1 2 3 4 5; do "$FI_BIN" autofix release "$SID" --failed "skip" >/dev/null; done
  run "$FI_BIN" autofix ship "$SID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fixed nothing"* ]]
  ! grep -q '^pr create' "$GH_MOCK_TRACE" 2>/dev/null || false
}
```

`tests/autofix-agent.bats`: add a test that `agents/found-issues-sweeper.md` exists with `name: found-issues-sweeper`, `background: true`, `model: sonnet`, and that every command it names is a `found-issues autofix` call (same check as the fixer's).

- [ ] **Step 2: Run to verify they fail.**

- [ ] **Step 3: Implement.**

`lib/autofix-b.sh`:

```bash
fi_af_b_running() {
  fi_af_item_read "$FI_AF_ST/running/$1" || { fi_err "autofix: $1 is not claimed (run: found-issues autofix claim $1)"; return 1; }
  fi_af_touch_lock "$1"
  [[ "$AFI_kind" == "sweep" ]] && { fi_af_sweep_load "$1" || AFI_entry=""; }
  return 0
}
```

`fi_af_brief` starts with `[[ "$AFI_kind" == "sweep" ]] && { fi_af_sweep_brief; return; }`, and:

```bash
fi_af_sweep_brief() {
  local t n=0 line
  t="$(fi_af_test_command "$AFI_wt" 2>/dev/null || printf '(none found)')"
  while IFS= read -r line || [[ -n "$line" ]]; do n=$((n + 1)); done <"$FI_AF_ST/sweeps/$AFI_id.entries"
  cat <<EOF
found-issues auto-fix sweep ${AFI_id}. This run is sanctioned: the user enabled
found-issues auto-fix. Nobody will answer questions.

Worktree: ${AFI_wt}
Branch:   ${AFI_branch} (from origin/${AFI_base}; never main)
Entries:  ${n}, fixed one at a time in the order given
Test command (bash runs it for you): ${t}

Edit ONLY files under the worktree path above, with Read, Edit, Write, Grep
and Glob, always by absolute path. Never edit docs/found-issues.md or any
found-issues ledger. Your only Bash calls are these, each alone, exactly as
written (no cd, &&, |, git or gh), with a 600000 ms timeout:
  found-issues autofix next ${AFI_id}      the entry to fix now
  found-issues autofix test ${AFI_id}      run the test command in the worktree
  found-issues autofix verify ${AFI_id}    tests + reviewer; on approval bash commits this entry
  found-issues autofix release ${AFI_id} --already-fixed|--decide|--manual|--failed "<text>"
                                           give up on THIS entry and move on
  found-issues autofix ship ${AFI_id}      when next says no entries are left

Loop:
1. Run autofix next. If it says no entries are left, run autofix ship and stop.
2. Check the symptom is still present in the worktree. Already fixed: release
   --already-fixed "<evidence>". Needs a human decision: release --decide
   "<question>". No test can prove a fix: release --manual "<why>". Then go to 1.
3. Add or extend a test that fails because of this symptom; autofix test.
4. Make the smallest change that fixes it. Change nothing unrelated.
5. Run autofix test until it passes.
6. Run autofix verify. Exit 0 or 5: go to 1. Exit 1: revise, autofix test,
   verify again. Any other exit: run autofix ship and stop.
If you cannot fix an entry, release it with --failed "<why>" and go to 1.
End your reply with one line: the sweep id and its outcome.
EOF
}
```

`fi_af_b_verify` sweep branches (the spot paths unchanged):
- no current entry (`AFI_entry` empty): `printf 'no entry in progress: run found-issues autofix next %s\n'`, return 2.
- budget: sweep → `printf 'run budget spent: run found-issues autofix ship %s\n'`, return 6 (no finish).
- verifier unavailable: sweep → `_fi_af_reset_wt`; message `verifier unavailable (…): run found-issues autofix ship <id>`; return 7.
- approve: sweep → `FI_AF_VERDICT_REASON="$FI_AF_REASON"; fi_af_sweep_commit "$id" || { fi_af_sweep_settle "$id" failed "commit: $FI_AF_WHY"; printf …; return 5; }`; print `approved and committed: <reason>\nNext: found-issues autofix next <id>`; return 0.
- second reject: sweep → `fi_af_sweep_settle "$id" failed "verifier rejected: $FI_AF_REASON after 2 attempts"`; print `rejected twice (…): entry marked failed.\nNext: found-issues autofix next <id>`; return 5.

`lib/autofix.sh` `cmd_autofix`:
- `claim` rc 0: for a sweep print the worktree (`$AFI_wt`, set by the claim) — unchanged output shape.
- new case `next)`: usage check; `fi_af_context`; `fi_af_b_running "$1" || return 1`; spot → `fi_err "autofix: next is for sweeps"; return 2`; empty `AFI_entry` → `No entries left. Run: found-issues autofix ship <id>`; else count entries and print `Entry $AFI_cur/$n: $AFI_entry` and `Worktree: $AFI_wt`.
- `release`: when `running/<id>` has `kind=sweep`: `fi_af_b_running`; no current entry → error rc 1; else map `--failed` → `failed` and call `fi_af_sweep_settle "$rid" "$outcome" "$text"`; print `Released <loc> (<outcome>). Next: found-issues autofix next <id>`.
- `ship`: after `fi_af_b_enabled`, when `AFI_kind` is `sweep`: `fi_af_no_prompts`; `FI_AF_COST="${AFI_cost:-0}"`; `fi_af_sweep_finish "$1"`; print by result (`done/<id>` result line).
- usage: add `next <id>` and the sweep note on verify/release/ship.

`agents/found-issues-sweeper.md`:

```markdown
---
name: found-issues-sweeper
description: Unattended found-issues auto-sweep for ONE queued sweep item. Start it only when a found-issues hook message asks for it, in the background, with the prompt "Run found-issues auto-fix sweep <id>." Never use it for general bug fixing.
tools: Read, Edit, Write, Glob, Grep, Bash
model: sonnet
effort: medium
maxTurns: 200
background: true
---

You run exactly one found-issues auto-fix sweep, unattended. The user turned
found-issues auto-fix on; nobody will answer questions, so never ask any.

1. Take the sweep id from your prompt (it looks like `20261003-142501-01234`).
   Run `found-issues autofix claim <id>` as one Bash call. If it exits
   non-zero, reply with its message and stop.
2. Run `found-issues autofix brief <id>` and follow it exactly. It names the
   worktree you may edit, the loop to follow, and the only commands you may run.

Rules that hold throughout:
- Bash only for `found-issues autofix <command> <id> …`, one call at a time,
  never combined with anything else, with timeout 600000.
- Edit only inside the worktree that claim printed, by absolute path.
- Never edit `docs/found-issues.md`, never run git or gh, never start agents.
- End with one line: the sweep id and what happened (shipped PR, nothing fixed, stopped).
```

- [ ] **Step 4: Run to verify they pass** (plus `tests/autofix-b.bats tests/autofix-agent.bats`).
- [ ] **Step 5: Commit** `feat(autofix): launcher B for sweeps - next, per-entry verify/release, sweeper agent`.

---

### Task 7: Hook — `AUTOFIX-SWEEP-DUE` launches the sweep

**Files:**
- Modify: `lib/autofix-hook.sh` (`fi_afh_ids`, `fi_afh_context_b`), `hooks/post-bash-dispatch.sh` (gate substring, route condition, context call)
- Test: `tests/autofix-hook.bats`, `tests/autofix-stop.bats`, `tests/hook-gates.bats`

**Interfaces:**
- Produces: `fi_afh_ids` collects ids from both `AUTOFIX-QUEUED <id>` and `AUTOFIX-SWEEP-DUE <id>`; `fi_afh_context_b <id> <item-path>` names `found-issues:found-issues-sweeper` with prompt `Run found-issues auto-fix sweep <id>.` for a `kind=sweep` item, else the fixer text unchanged.

- [ ] **Step 1: Write the failing tests** (append to `tests/autofix-hook.bats`):

```bash
sweep_item() {
  SWID=20261004-000000-00042
  fi_af_item_write "$ST/queue/$SWID" "id=$SWID" kind=sweep "root=$REPO" slug=foo/bar loc=sweep engine=claude crashes=0
}

@test "hook: a sweep marker in bypass nudges the sweeper agent" {
  sweep_item
  run hook "$(payload bypassPermissions "AUTOFIX-SWEEP-DUE $SWID")"
  [ "$status" -eq 0 ]
  ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" == *"found-issues:found-issues-sweeper"* ]]
  [[ "$ctx" == *"Run found-issues auto-fix sweep $SWID."* ]]
  [[ "$ctx" != *"found-issues-fixer"* ]]
  grep -q '^launcher=B$' "$ST/queue/$SWID"
}

@test "hook: a sweep marker in default mode starts launcher A" {
  sweep_item
  run hook "$(payload default "AUTOFIX-SWEEP-DUE $SWID")"
  wait_spawn
  grep -q "autofix run $SWID --engine claude$" "$TMP/spawned"
}
```

`tests/autofix-stop.bats`: `stop: a queued sweep gets launcher A at Stop` (write a sweep item, `stop "$REPO"`, `wait_spawn`, grep its id). `tests/hook-gates.bats`: the gate passes a payload containing only `AUTOFIX-SWEEP-DUE`.

- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement**:
  - `fi_afh_ids` regex → `AUTOFIX-(QUEUED|SWEEP-DUE)[[:space:]]+([0-9]{8}-[0-9]{6}-[0-9]{5})`, id = `BASH_REMATCH[2]`.
  - `fi_afh_context_b <id> [<item>]`: `local kind=""; [[ -n "${2:-}" ]] && kind="$(_fi_afh_kind "$2")"`, where `_fi_afh_kind` is a builtin read of the `kind=` line; for `sweep` print:
    ```
    ## found-issues auto-fix: sweep $1 is queued

    The user turned on found-issues auto-fix. Start the plugin agent
    found-issues:found-issues-sweeper now, in the background, with exactly this
    prompt:

      Run found-issues auto-fix sweep $1.

    Do not fix anything yourself and do not wait for the agent; carry on with
    your current task.
    ```
  - `post-bash-dispatch.sh`: the gate and the route test `*AUTOFIX-QUEUED*` OR `*AUTOFIX-SWEEP-DUE*`; the B line passes `"$FI_AFH_ITEM"` as the second argument.
- [ ] **Step 4: Run to verify they pass** (whole `tests/autofix-hook.bats tests/autofix-stop.bats tests/hook-gates.bats tests/post-bash-dispatch.bats`).
- [ ] **Step 5: Commit** `feat(autofix): AUTOFIX-SWEEP-DUE marker launches the sweep (B sweeper or A)`.

---

### Task 8: `/found-issues:fix` on the shared plumbing (prompt-8, -9, -10)

**Files:**
- Create: `lib/fix-plumbing.sh`
- Modify: `bin/found-issues` (source; dispatch `fix) cmd_fix "$@" ;;`), `lib/help.sh` (usage lines), `commands/fix.md`, `codex-skills/fi-fix/SKILL.md` (regenerated)
- Test: create `tests/cli-fix.bats`; `tests/docs-consistency.bats` / codex-skill sync tests must stay green

**Interfaces:**
- Produces:
  - `found-issues fix workspace` → prints `worktree=<path>`, `branch=<br>`, `base=<base>`, `source=<root>`, `test=<cmd|none>`; exit 1 outside a git repo with an `origin`, or when fetch / worktree add fails.
  - `found-issues fix test <worktree>` → runs the detected test command there; prints the last 30 lines and `tests: pass` / `tests: fail (exit N)`; exits with the test's code (2 when no test command).
  - `found-issues fix ship <worktree> --title "<t>" --body-file <f> --pick <loc>[,<loc>…]` → refuses a dirty worktree (exit 1), red tests (exit 1) or zero commits ahead of `origin/<base>` (exit 1); pushes, opens the PR, runs `annotate-pr <N> --pick …` in the source checkout, annotates the PR branch ledger the same way (when the branch has one) and commits+pushes it; prints `PR #<N>: <url>`. Never merges.

- [ ] **Step 1: Write the failing tests** — `tests/cli-fix.bats`:

```bash
#!/usr/bin/env bats
# found-issues fix workspace|test|ship — /found-issues:fix plumbing (audit prompt-8..10).

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_fixture
  export PATH="$TEST_REPO_ROOT/tests/bin-shims:$PATH"
  export GH_MOCK_TRACE="$TMP/gh.trace" GH_MOCK_PR_CREATE_URL=https://github.com/foo/bar/pull/11
  export GH_MOCK_PR_VIEW=$'11\t{"number":11,"state":"OPEN","files":[]}'
}
teardown() { fi_teardown_tmp; }

ws() { out="$("$FI_BIN" fix workspace)"; WT="$(printf '%s\n' "$out" | sed -n 's/^worktree=//p')"; }

@test "fix workspace: a fresh worktree from origin on a unique branch" {
  ws
  [ -d "$WT" ]
  br="$(git -C "$WT" rev-parse --abbrev-ref HEAD)"
  [[ "$br" == fix/found-issues-$(date +%Y%m%d)-* ]]
  [ "$(git -C "$WT" rev-parse HEAD)" = "$(git rev-parse origin/main)" ]
  [[ "$out" == *"test=sh test.sh"* ]]
  [[ "$out" == *"source=$REPO"* ]]
  out1="$out"; ws
  [ "$out" != "$out1" ]
}

@test "fix test: runs the detected command in the worktree" {
  ws
  run "$FI_BIN" fix test "$WT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"tests: fail"* ]]
  sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"
  run "$FI_BIN" fix test "$WT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tests: pass"* ]]
}

@test "fix ship: refuses a dirty worktree and a branch with no commits" {
  ws
  printf 'b\n' > "$TMP/body"
  run "$FI_BIN" fix ship "$WT" --title t --body-file "$TMP/body" --pick src/calc.sh:1
  [ "$status" -eq 1 ]
  [[ "$output" == *"no commits"* ]]
  sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"
  run "$FI_BIN" fix ship "$WT" --title t --body-file "$TMP/body" --pick src/calc.sh:1
  [ "$status" -eq 1 ]
  [[ "$output" == *"uncommitted"* ]]
}

@test "fix ship: pushes, opens the PR, annotates source and branch ledgers, never merges" {
  ws
  sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"
  git -C "$WT" commit -qam "fix: add subtracts (found-issues src/calc.sh:1)"
  printf 'b\n' > "$TMP/body"
  run "$FI_BIN" fix ship "$WT" --title "fix: add" --body-file "$TMP/body" --pick src/calc.sh:1
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #11"* ]]
  grep -q '(PR: foo/bar#11)' docs/found-issues.md
  br="$(git -C "$WT" rev-parse --abbrev-ref HEAD)"
  git -C "$TMP/remote.git" show "$br:docs/found-issues.md" | grep -q '(PR: foo/bar#11)'
  ! grep -q '^pr merge' "$GH_MOCK_TRACE" || false
}

@test "fix.md: no bats-only allowed-tools, workspace/test/ship plumbing, resolve not sync" {
  f="$TEST_REPO_ROOT/commands/fix.md"
  ! grep -q 'Bash(bats:' "$f" || false
  grep -q 'found-issues fix workspace' "$f"
  grep -q 'found-issues fix test' "$f"
  grep -q 'found-issues fix ship' "$f"
  grep -q -- '--cwd' "$f"
  grep -q 'resolve ".*" --verified ai' "$f"
  ! grep -q 'run `/found-issues:sync`' "$f" || false
  grep -q 'line_end' "$f"
}
```

- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement** `lib/fix-plumbing.sh`:

```bash
#!/usr/bin/env bash
# fix-plumbing.sh — `found-issues fix workspace|test|ship`: the interactive
# /found-issues:fix command on the auto-fix plumbing (spec 2026-10-03 §6;
# audit prompt-8 isolation, prompt-9 committed annotations, prompt-10 any
# test stack). The approval gate stays in the command; this is mechanics.
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   cmd_fix <workspace|test|ship> [...]

_fi_fix_usage() {
  cat <<'EOF'
Usage: found-issues fix workspace
       found-issues fix test <worktree>
       found-issues fix ship <worktree> --title "<title>" --body-file <file> --pick <loc>[,<loc>...]
EOF
}

_fi_fix_workspace() {
  local root base stamp wt br t
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || { fi_err "fix: not in a git repo"; return 1; }
  git -C "$root" remote get-url origin >/dev/null 2>&1 || { fi_err "fix: no origin remote"; return 1; }
  base="$(cd "$root" && fi_resolve_default_branch)"
  git -C "$root" fetch -q origin "$base" 2>/dev/null || { fi_err "fix: git fetch origin $base failed"; return 1; }
  printf -v stamp '%s-%05d' "$(date +%Y%m%d)" "$RANDOM"
  wt="$root/.claude/worktrees/fi-fix-$stamp"
  br="fix/found-issues-$stamp"
  mkdir -p "$root/.claude/worktrees"
  git -C "$root" worktree add -q -b "$br" "$wt" "origin/$base" >/dev/null 2>&1 \
    || { fi_err "fix: git worktree add failed"; return 1; }
  t="$(fi_af_test_command "$wt" 2>/dev/null || printf 'none')"
  printf 'worktree=%s\nbranch=%s\nbase=%s\nsource=%s\ntest=%s\n' "$wt" "$br" "$base" "$root" "$t"
}

_fi_fix_test() {
  local wt="$1" t log rc=0
  [[ -d "$wt" ]] || { fi_err "fix test: no such worktree: $wt"; return 2; }
  t="$(fi_af_test_command "$wt")" || { fi_err "fix test: no test command found (set found-issues.autofix.testCommand)"; return 2; }
  log="$(mktemp "${TMPDIR:-/tmp}/fi-fix-test.XXXXXX")"
  fi_af_run_tests "$wt" "$t" "$log" || rc=$?
  tail -n 30 "$log" 2>/dev/null; tail -n 5 "$log.err" 2>/dev/null
  rm -f "$log" "$log.err"
  if (( rc == 0 )); then printf 'tests: pass\n'; else printf 'tests: fail (exit %s)\n' "$rc"; fi
  return $rc
}

_fi_fix_ship() {
  local wt="" title="" bodyf="" picks="" root base br slug url pr t log
  [[ $# -gt 0 ]] && { wt="$1"; shift; }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title) fi_need_value "fix ship" --title $# "${2:-}" || return 2; title="$2"; shift 2 ;;
      --body-file) fi_need_value "fix ship" --body-file $# "${2:-}" || return 2; bodyf="$2"; shift 2 ;;
      --pick) fi_need_value "fix ship" --pick $# "${2:-}" || return 2; picks="$2"; shift 2 ;;
      *) fi_unknown_arg "fix ship" "$1"; return 2 ;;
    esac
  done
  [[ -d "$wt" && -n "$title" && -f "$bodyf" && -n "$picks" ]] || { _fi_fix_usage >&2; return 2; }
  root="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || { fi_err "fix ship: $wt is not a git worktree"; return 1; }
  root="${root%/.git}"
  slug="$(cd "$root" && fi_repo_id 2>/dev/null)" || { fi_err "fix ship: origin is not a GitHub repo"; return 1; }
  base="$(cd "$root" && fi_resolve_default_branch)"
  br="$(git -C "$wt" rev-parse --abbrev-ref HEAD)"
  [[ "$br" != "$base" && "$br" != HEAD ]] || { fi_err "fix ship: $wt is on $br, not a fix branch"; return 1; }
  [[ -z "$(git -C "$wt" status --porcelain)" ]] || { fi_err "fix ship: $wt has uncommitted changes — commit each fix first"; return 1; }
  [[ -n "$(git -C "$wt" rev-list "origin/$base..HEAD" 2>/dev/null)" ]] || { fi_err "fix ship: $br has no commits ahead of origin/$base"; return 1; }
  _fi_fix_test "$wt" >/dev/null || { fi_err "fix ship: tests fail in $wt — not shipping"; return 1; }
  fi_af_no_prompts
  git -C "$wt" push -q -u origin "$br" 2>/dev/null || { fi_err "fix ship: git push failed"; return 1; }
  url="$(cd "$wt" && gh pr create --repo "$slug" --base "$base" --head "$br" --title "$title" --body-file "$bodyf")" \
    || { fi_err "fix ship: gh pr create failed"; return 1; }
  pr="${url##*/}"
  [[ "$pr" =~ ^[0-9]+$ ]] || { fi_err "fix ship: no PR number in: $url"; return 1; }
  ( cd "$root" && "$FI_SELF" annotate-pr "$pr" --pick "$picks" ) || fi_err "fix ship: source ledger annotation failed — run: found-issues annotate-pr $pr --pick $picks"
  if [[ -f "$wt/docs/found-issues.md" || -f "$wt/.found-issues.md" ]]; then
    if ( cd "$wt" && "$FI_SELF" annotate-pr "$pr" --pick "$picks" --cwd "$wt" ) >/dev/null 2>&1 \
       && [[ -n "$(git -C "$wt" status --porcelain)" ]]; then
      git -C "$wt" add -A -- docs/found-issues.md .found-issues.md 2>/dev/null
      git -C "$wt" commit -q -m "docs(found-issues): annotate PR $pr" && git -C "$wt" push -q origin "$br" \
        || fi_err "fix ship: could not commit the annotation onto $br"
    fi
  fi
  printf 'PR #%s: %s\n' "$pr" "$url"
}

cmd_fix() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    workspace) _fi_fix_workspace ;;
    test) [[ $# -eq 1 ]] || { _fi_fix_usage >&2; return 2; }; _fi_fix_test "$1" ;;
    ship) _fi_fix_ship "$@" ;;
    -h|--help|"") _fi_fix_usage ;;
    *) fi_unknown_arg fix "$sub"; return 2 ;;
  esac
}
```

(If `annotate-pr` has no `--cwd`, annotate the branch ledger with `fi_annotate_apply_picks`' public entry or run it from `$wt` after confirming `fi_find_issues_file` resolves inside `$wt` — the implementer checks `rg -n 'cwd' lib/annotate.sh` first and picks the variant that cannot walk up into the source ledger; Phase 2 Review Focus 2 is the hazard.)

Rewrite `commands/fix.md` (frontmatter `allowed-tools: Bash(found-issues:*), Bash(git:*), Bash(gh:*), Read, Edit, Write, Glob, Grep, Agent`):
- Phase 1: `found-issues list --json --cwd <repo root>` (and `--status=deferred`); picks use the entry's location: `path:line`, or `path:line-line_end` when `line_end` is non-null, or bare `path`.
- Phase 2 bucket 1 (already-fixed): `found-issues annotate-commit <sha> --pick <loc>` when the fixing commit is known, else `found-issues resolve "<unique symptom fragment>" --verified ai`. Never `/found-issues:sync` from this command (it archives).
- Phase 3: `found-issues fix workspace` first; work ONLY in the printed `worktree`; one commit per entry/group with `git -C <worktree> commit`; tests via `found-issues fix test <worktree>` (any stack).
- Phase 4: `found-issues fix ship <worktree> --title … --body-file … --pick <loc>,<loc>` (it pushes, opens the PR, annotates the source ledger and the PR branch). Merge per the repo's policy (the CLI never merges).
- Keep the approval gate, buckets, failure rule and the final report format unchanged.

Then `bash scripts/gen-codex-skills.sh` and commit the regenerated `codex-skills/fi-fix/SKILL.md`.

- [ ] **Step 4: Run to verify they pass** (plus `tests/docs-consistency.bats` and every `tests/*codex*skill*.bats`).
- [ ] **Step 5: Commit** `feat(fix): /found-issues:fix on shared plumbing - fix workspace|test|ship (prompt-8..10)`.

---

### Task 9: SessionStart directives only in interactive sessions (prompt-11)

**Files:**
- Modify: `hooks/session-start.sh` (the two `if [[ "$harness" == "claude" ]]; then` blocks around the onboarding hint and the statusline nudge)
- Test: `tests/session-start.bats`

- [ ] **Step 1: Write the failing tests**:

```bash
@test "session-start: a headless session gets no onboarding hint and keeps the marker unset" {
  export HOME="$TMP/home"; mkdir -p "$HOME"
  CLAUDE_CODE_ENTRYPOINT=sdk-cli run bash "$TEST_REPO_ROOT/hooks/session-start.sh" </dev/null
  [[ "$output" != *"found-issues setup hint"* ]]
  [ ! -e "$HOME/.claude/found-issues/.onboarded" ]
}

@test "session-start: an interactive cli session still gets the onboarding hint" {
  export HOME="$TMP/home"; mkdir -p "$HOME"
  CLAUDE_CODE_ENTRYPOINT=cli run bash "$TEST_REPO_ROOT/hooks/session-start.sh" </dev/null
  [[ "$output" == *"found-issues setup hint"* ]]
}
```

(Match the file's existing harness/env setup for these tests — copy the nearest existing onboarding test's preamble.)

- [ ] **Step 2: Run to verify the first fails.**
- [ ] **Step 3: Implement**: before the onboarding block, `fi_ss_interactive=0; [[ -z "${CLAUDE_CODE_ENTRYPOINT:-}" || "$CLAUDE_CODE_ENTRYPOINT" == "cli" ]] && fi_ss_interactive=1`, and both blocks become `if [[ "$harness" == "claude" && "$fi_ss_interactive" == 1 ]]; then`. Comment: headless runs (auto-fix children, `claude -p`) must not receive "prepend to your reply" directives or consume the one-time marker (audit prompt-11).
- [ ] **Step 4: Run** `bats tests/session-start*.bats` → `0 not ok`.
- [ ] **Step 5: Commit** `fix(session-start): reply directives only in interactive sessions (prompt-11)`.

---

### Task 10: Docs — spec as-built, changelog, help, README count

**Files:** `docs/superpowers/specs/2026-10-03-autofix-v3-design.md` (§6 "As built (phase 4)" block: rulings 1-10 in one line each; §7 table adds `sweepBudget` 10; §8 settings list adds `.sweepBudget`), `CHANGELOG.md` (Unreleased → v3.0.0 phase 4 bullets), `lib/help.sh` (`fix` and `autofix next`), `README.md` (test count), rules SKILL.md only if the tag guidance needs the sweep (stay under 4200 bytes).

- [ ] **Step 1:** Edit the docs.
- [ ] **Step 2:** Recount: `n=$(rg -c '^@test ' tests/*.bats | awk -F: '{s+=$2} END{print s}'); sed -i '' -E "s/ [0-9]+ tests on/ $n tests on/" README.md`.
- [ ] **Step 3:** `bats tests/docs-consistency.bats` → `0 not ok`.
- [ ] **Step 4: Commit** `docs(v3): phase 4 rulings, sweep settings, changelog`.

---

### Task 11: Full verification, review, PR, post-merge watch

- [ ] **Step 1: Full suite and bash 3.2 subset** (background, output to files):

```bash
bats tests/ > full.log 2>&1; echo "exit=$?" >> full.log
PATH=/private/tmp/claude-501/b32:$PATH bash "$(command -v bats)" tests/autofix-*.bats tests/cli-fix.bats tests/post-bash-dispatch.bats tests/stop-reminder.bats tests/codex-wiring.bats tests/hook-gates.bats tests/harness.bats tests/source-guards.bats tests/session-start.bats > b32.log 2>&1; echo "exit=$?" >> b32.log
```

Expected: both `exit=0`, `0 not ok`.

- [ ] **Step 2: End-to-end CLI run** (`verify`): a scratch repo with 5 `(fix: medium)` entries and the stand-ins; `found-issues log --fix medium …` → `AUTOFIX-SWEEP-DUE`; pipe a `bypassPermissions` PostToolUse payload into `hooks/post-bash-dispatch.sh` → sweeper nudge; drive `claim`/`brief`/`next`/`test`/`verify`/`release`/`ship`; then a second scratch run through a default-mode payload → detached `autofix run` → one PR. Quote the output.
- [ ] **Step 3: Whole-branch review** by ONE read-only opus Agent (no writes, no prompts) over `git diff origin/release/v3...HEAD`, the spec, this plan's Rulings and Review Focus. Fix Critical/Important RED→GREEN; log minors with `./bin/found-issues log --fix …` (line numbers re-derived with `rg -n` after the fixes).
- [ ] **Step 4: PR into `release/v3`** — `git status`, `git branch --show-current` (= `v3/phase4-sweep`); push; `gh pr create --dry-run` probe in its own call; skip-reason file if the gate asks; `gh pr create --base release/v3`. Annotate fixed ledger entries with `--pick` (none of the open entries is expected to be fixed by this phase except the prompt-8..11 ones if they are in the ledger — check with `./bin/found-issues list | rg 'commands/fix.md|session-start.sh:96'`).
- [ ] **Step 5: Merge and watch** — `GH_PR_MERGE_BASE_GUARD=off gh pr merge <N> --auto --squash`; find the post-merge `release/v3` push run; `gh run watch <id> --exit-status` to a terminal state.
- [ ] **Step 6: Handoff** for Phase 5, with the end-of-Phase-5 reminder to enable auto-fix on this Mac.
