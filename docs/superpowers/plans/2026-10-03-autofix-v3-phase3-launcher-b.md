# Auto-fix v3 Phase 3 — Launcher B, hook launcher selection, Stop fallback — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When `found-issues log --fix small` prints `AUTOFIX-QUEUED <id>`, the plugin's PostToolUse hook picks the right launcher with no permission prompt in any mode. In a Claude Code session in `auto` or `bypassPermissions` mode, it asks the main agent to start the plugin agent `found-issues:found-issues-fixer` in the background (launcher B). Everywhere else it starts a detached `found-issues autofix run <id>` (launcher A). Any item still unclaimed when the session's Stop hook runs gets launcher A.

**Architecture:** All B-side work runs through single `found-issues autofix …` calls: `claim`, `brief`, `test`, `verify`, `ship`, `release`. Bash owns git, gh, the ledger, and the verifier gate, so the fixer agent only edits files. Hook-side code lives in a new `lib/autofix-hook.sh`, sourced by `post-bash-dispatch.sh` and `stop-reminder.sh`, and keeps the zero-fork early exit when nothing is queued. Fixer-side CLI support lives in a new `lib/autofix-b.sh`.

**Tech Stack:** bash 3.2+ (macOS system bash), jq, git, gh, bats-core; stand-in `claude`/`codex`/`gh` binaries from Phase 2.

**Spec:** `docs/superpowers/specs/2026-10-03-autofix-v3-design.md` (§4.2–§4.4, §5, §11 phase 3). Phase 2 plan for reference: `docs/superpowers/plans/2026-10-03-autofix-v3-phase2-launcher-a.md`.

## Docs re-check (2026-10-03, Claude Code 2.1.289 docs, code.claude.com)

Hazard 9 of the phase 2 handoff, re-verified before planning:

| Fact the spec relied on | Current docs | Effect on this plan |
|---|---|---|
| Plugin agents ignore `permissionMode` | Confirmed: "Ignored fields: `permissionMode`, `hooks`, `mcpServers`, and `initialPrompt`." Supported fields include `model`, `effort`, `maxTurns`, `tools`, `background`, `isolation`. A plugin agent is named `<plugin>:<name>`. | Agent file uses only supported fields. The hook names `found-issues:found-issues-fixer`. |
| Subagents inherit auto/acceptEdits/bypass | Confirmed: "When the main conversation is in `bypassPermissions`, `acceptEdits`, or auto mode, the subagent runs in that same mode." | B stays limited to `auto` and `bypassPermissions`. |
| Background subagents surface prompts in the main session otherwise | Confirmed: "Background subagents surface every permission prompt in your main session." | Same. |
| Auto mode allows push and PR in the working repo; 3 blocks in a row resume prompting | Confirmed: "3 times in a row or 20 times total". **New:** the blocked list includes "Merging a pull request no human has approved". | The fixer never runs git or gh. The merge happens inside the bash `autofix ship`. The live check in Phase 5 E2E confirms the classifier lets `found-issues autofix ship <id>` through. |
| Hooks get `permission_mode` on PostToolUse/Stop | Field documented ("Not all events receive this field"). Codex 0.159 binary schema: required on PostToolUse and Stop. | A missing `permission_mode` selects A (spec §4.2 already says so). |
| `agent_id` marks a hook inside a subagent | Confirmed: "`agent_id` — Present only when the hook fires inside a subagent call." Stop "does not fire for subagents." The Codex PostToolUse schema also carries `agent_id`. | The recursion guard keys on `agent_id` for both harnesses. |
| **New: nested subagents** | Allowed, "up to three layers below the main conversation". | Nesting is possible, but this plan keeps the verifier in bash (Ruling 2). |
| **New: PostToolUse plain stdout** | "Plain stdout from PostToolUse hooks that exit 0 is written to the debug log only, never shown to Claude. Use `additionalContext` … in `hookSpecificOutput`." | `fi_emit_post_context` prints plain text on Claude, so B's nudge and the existing annotation prompts never reach Claude. Task 1 fixes this. |

## Rulings (deviations from the spec, for operator review)

1. **B uses the claim's worktree, not `isolation: worktree`.** `autofix claim` already creates `<root>/.claude/worktrees/fi-autofix-<id>` on `fi/autofix/<slug>-<id>` from a pinned `base_sha`, and `diff`/`ship` depend on that bookkeeping. Subagent worktrees have no documented branch-name control and follow the user's `worktree.baseRef`. The fixer edits files by absolute path inside the claim worktree. This replaces spec §5.1 "for B it renames the Claude Code worktree branch".
2. **The B verifier is `found-issues autofix verify <id>`, a bash-gated headless opus run, not a nested `found-issues-verifier` agent.** A nested agent's verdict would reach bash only as the fixer's own report, which cannot be enforced. `verify` records `verdict` plus the exact staged tree (`git write-tree`), and `ship` refuses unless the tree it is about to commit equals the approved tree. That also fixes ledger entry `lib/autofix-ship.sh:116`. So Phase 3 ships no verifier agent.
3. **The `found-issues-sweeper` agent moves to Phase 4.** The sweep CLI it would drive does not exist until Phase 4. The hook's marker handling is written so Phase 4 only adds `AUTOFIX-SWEEP-DUE`.
4. **`autofix run` exit-code contract** (ledger `(decide:)` at `lib/autofix.sh:150`). Recommended: refuse an id that is neither queued nor running (exit 1, no drain); locked → 4; capped → 3 plus a `day/<date>.capped` marker the Stop fallback reads; engine outage → 7; switched off mid-drain → 0. The hook launches `run` detached and never reads its code; the codes are for humans and scripts. **Operator picks** (Task 2 implements the recommendation; if the operator declines, Task 2 shrinks to the capped marker only).

## Global Constraints

- bash 3.2 compatible: no `declare -A`, no `${var,,}`, no `$EPOCHSECONDS`, no `printf '%(…)T'`, and guard `"${arr[@]}"` on empty arrays under `set -u`.
- Hooks: exit 0 always (PostToolUse); the Stop hook keeps its existing exit-2 block semantics; never block on auto-fix work.
- Zero-fork early exit: with no marker in the payload (PostToolUse) or an empty queue glob (Stop), no external command runs (`lib/hook-gate.sh` contract).
- Nothing auto-fix launches may show a permission prompt (spec §1). B only in `auto`/`bypassPermissions` on Claude Code.
- Fixers never run git or gh and never write the ledger (Phase 2 ruling, unchanged).
- ASCII-only `@test` names (Windows CI guard). Use `run ! cmd` or `! cmd || false`, never a bare mid-test `! cmd`.
- Detached spawns close fd 3 (`3>&-`), so bats never hangs on an orphan.
- Rules `SKILL.md` budget is 4200 bytes. The README test count is pinned by `tests/docs-consistency.bats`.
- Never write `docs/found-issues.md` by hand: use `./bin/found-issues log|resolve|annotate-pr`.

## Review Focus

1. **A command whose output re-prints an old `AUTOFIX-QUEUED <id>` line** (`cat` of a run log, `rg` over transcripts) must not relaunch anything. The hook acts only on ids whose item file is still in `queue/`. Task 6: "a marker for an id that is not queued launches nothing".
2. **Two markers in one Bash call** (`found-issues log … && found-issues log …`): A spawns one `run` (it drains), B nudges once per id, and both items are marked launched. Task 6: "two markers".
3. **A session whose cwd is a subdirectory or a worktree of the item's repo** must still match at Stop, and a session in another repo must not. Task 7: "cwd under the repo root matches" and "another repo is ignored".
4. **A fixer subagent logs a new `(fix: small)` issue.** That call carries `agent_id`, so nothing launches, and the main session's next Stop starts A for it. Task 6: "agent_id"; Task 7: "an item with no launched stamp is launched".
5. **One Bash call that both commits and logs** (`git commit … && found-issues log --fix small …`) must still produce exactly one JSON object on stdout. Task 6: "commit route plus marker emit one JSON object".

---

### Task 1: PostToolUse context reaches Claude (JSON on both harnesses)

**Files:**
- Modify: `lib/harness.sh:47-58` (`fi_emit_post_context`)
- Modify: `hooks/post-bash-dispatch.sh:33` (header comment only)
- Test: `tests/harness.bats:59-64`, `tests/post-bash-dispatch.bats` (assertions that read decoded text)

**Interfaces:**
- Produces: `fi_emit_post_context <text>` prints `{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":<text>}}` on Claude and Codex. Without jq it prints plain text on Claude (debug log only; the hook already exits early without jq) and nothing on Codex.

- [ ] **Step 1: Log the defect first**

```bash
./bin/found-issues log --fix small "lib/harness.sh:52 — fi_emit_post_context prints plain stdout on Claude Code, which the hooks docs say goes to the debug log only and never reaches Claude, so PostToolUse annotation suggestions and --pick prompts are invisible to the model"
```

Expected: `Logged: …` (no `AUTOFIX-QUEUED`: auto-fix is off in this repo).

- [ ] **Step 2: Write the failing test** — replace the `emit: plain text on claude` test in `tests/harness.bats`:

```bash
@test "emit: claude gets hookSpecificOutput JSON, not plain stdout" {
  CLAUDE_CODE_ENTRYPOINT=cli run fi_emit_post_context $'hello\nworld "q"'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"'
  printf '%s' "$output" | jq -e '.hookSpecificOutput.additionalContext == "hello\nworld \"q\""'
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bats -f 'emit: claude gets' tests/harness.bats`
Expected: FAIL (output is `hello` plain text, so jq errors).

- [ ] **Step 4: Implement**

```bash
# Emit PostToolUse context text. Both harnesses read additionalContext from
# hookSpecificOutput JSON; Claude Code writes plain PostToolUse stdout to its
# debug log only and never shows it to the model (hooks docs, re-checked
# 2026-10-03), so plain text is only the no-jq fallback.
fi_emit_post_context() {
  local text="${1:-}"
  [[ -z "$text" ]] && return 0
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$text" | jq -Rs '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: .}}'
  elif [[ "$(fi_detect_harness)" != "codex" ]]; then
    printf '%s\n' "$text"
  fi
}
```

Update the hook header line 33 to `# Output: via fi_emit_post_context (hookSpecificOutput JSON on both harnesses).`

- [ ] **Step 5: Run the hook suites; convert text assertions that now see JSON**

Run: `bats tests/harness.bats tests/post-bash-dispatch.bats tests/hook-gates.bats tests/cli-annotate-hook-auto.bats`

For each failure caused by JSON escaping (a `"` or newline inside the asserted substring), add this helper at the top of the file and assert on its output instead of `$output`:

```bash
ctx() { printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext // empty'; }
# usage: [[ "$(ctx)" == *'expected "quoted" text'* ]]
```

Tests asserting empty output (`[ -z "$output" ]`) stay unchanged. The hook-gates "same stdout gates on/off" property holds because both sides emit JSON. Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/harness.sh hooks/post-bash-dispatch.sh tests/harness.bats tests/post-bash-dispatch.bats tests/hook-gates.bats tests/cli-annotate-hook-auto.bats docs/found-issues.md
git commit -m "fix(hooks): PostToolUse context as hookSpecificOutput JSON on Claude Code too"
```

---

### Task 2: `autofix run` exit-code contract and the capped marker

**Files:**
- Modify: `lib/autofix.sh` (`_fi_af_run`, ~lines 160-185)
- Test: `tests/autofix-run.bats`

**Interfaces:**
- Produces: `found-issues autofix run <id>` returns 1 when `<id>` is neither in `queue/` nor `running/` (no drain); 4 when locked; 3 when capped and writes `$FI_AF_ST/day/<YYYY-MM-DD>.capped`; 7 on an engine outage; 0 otherwise (including switched off mid-drain).
- Consumed by Task 7: the Stop fallback skips a repo whose `day/<today>.capped` exists.

- [ ] **Step 1: Write the failing tests** (append to `tests/autofix-run.bats`, which has `ID` and the queued fixture in `setup`):

```bash
@test "autofix run: an unknown id is refused and the queue is not drained" {
  run "$FI_BIN" autofix run 20990101-000000-00000 --engine claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"no queued item 20990101-000000-00000"* ]]
  [ -f "$FI_AF_ST/queue/$ID" ]
}

@test "autofix run: a locked repo exits 4 and keeps the item queued" {
  mkdir "$FI_AF_ST/lock"; echo other >"$FI_AF_ST/lock/owner"
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 4 ]
  [ -f "$FI_AF_ST/queue/$ID" ]
}

@test "autofix run: the daily cap exits 3 and leaves a capped marker" {
  git config found-issues.autofix.dailyFixes 1
  echo earlier >"$FI_AF_ST/day/$(date +%Y-%m-%d).spot"
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 3 ]
  [ -f "$FI_AF_ST/day/$(date +%Y-%m-%d).capped" ]
}
```

If `setup` does not export `FI_AF_ST`, add `ST="$FI_AF_ST"` after `fi_af_queue_fixture` and use `$ST`. Check the existing outage test asserts `status -eq 0`; change it to `-eq 7`.

- [ ] **Step 2: Run to verify they fail**

Run: `bats -f 'unknown id|locked repo exits|daily cap exits' tests/autofix-run.bats`
Expected: FAIL (status 0 in all three).

- [ ] **Step 3: Implement** — in `_fi_af_run`, before the loop:

```bash
  if [[ ! -f "$FI_AF_ST/queue/$id" && ! -f "$FI_AF_ST/running/$id" ]]; then
    fi_err "autofix: no queued item $id"; return 1
  fi
```

and change the rc case to return the codes:

```bash
    case $rc in
      3) : >"$FI_AF_ST/day/$(fi_today).capped" 2>/dev/null || true
         printf 'Auto-fix: daily cap reached; %s waits for tomorrow.\n' "$id"; return 3 ;;
      4) printf 'Auto-fix: another run holds this repo; %s stays queued.\n' "$id"; return 4 ;;
      7) printf 'Auto-fix: engine error (%s); %s stays queued.\n' "$FI_AF_WHY" "$id"; return 7 ;;
    esac
```

Update `_fi_af_usage`'s `run` line: `Fix a queued item headlessly, then the rest of the queue (exit 3 capped, 4 locked, 7 engine outage)`.

- [ ] **Step 4: Run to verify they pass**

Run: `bats tests/autofix-run.bats`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/autofix.sh tests/autofix-run.bats
git commit -m "feat(autofix): run refuses unknown ids and returns 3/4/7 for capped/locked/outage"
```

After the PR exists, Task 10 resolves the decide entry via `annotate-pr --pick lib/autofix.sh:150`.

---

### Task 3: Fixer-side CLI — standalone claim, `brief`, `test`, lock refresh

**Files:**
- Create: `lib/autofix-b.sh`
- Modify: `bin/found-issues` (source the new lib after `autofix-ship.sh`, before `autofix.sh`)
- Modify: `lib/autofix-queue.sh` (`fi_af_item_read`: new keys; `fi_af_claim`: pid/launcher)
- Modify: `lib/autofix.sh` (`cmd_autofix` cases `brief`, `test`; usage lines)
- Test: create `tests/autofix-b.bats`

**Interfaces:**
- Consumes: `fi_af_context`, `fi_af_item_read`, `fi_af_item_set`, `fi_af_test_command`, `fi_af_run_tests`, `fi_af_log` (Phase 2).
- Produces:
  - Item keys `launcher` (`A`|`B`), `launched` (epoch seconds), `attempts`, `verdict` (`approve`|`reject`), `verdict_reason`, `verdict_tree`, parsed by `fi_af_item_read` into `AFI_launcher`, `AFI_launched`, `AFI_attempts`, `AFI_verdict`, `AFI_verdict_reason`, `AFI_verdict_tree`.
  - `fi_af_touch_lock <id>` refreshes `$FI_AF_ST/lock` when its owner is `<id>`.
  - `fi_af_b_running <id>` loads a running item (rc 1 with a message when it is not claimed) and touches the lock.
  - `fi_af_brief` prints the fixer brief for the loaded item.
  - CLI: `found-issues autofix brief <id>`; `found-issues autofix test <id>` (exit = test exit code; prints the last 30 lines and `tests: pass` or `tests: fail (exit N)`).
  - A standalone `autofix claim` (no `FI_AF_PID` in env) records `pid=` (empty) and `launcher=B`. Launcher A runs keep `pid=$FI_AF_PID` and record `launcher=A`.

- [ ] **Step 1: Write the failing tests** — `tests/autofix-b.bats`:

```bash
#!/usr/bin/env bats
# v3 launcher B fixer-side CLI (spec §4.2-§4.3, §5; phase 3 plan Task 3).

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_fixture; fi_use_standins
  fi_af_queue_fixture; ST="$FI_AF_ST"
}
teardown() { fi_teardown_tmp; }

claim() { "$FI_BIN" autofix claim "$ID" >/dev/null; WT="$REPO/.claude/worktrees/fi-autofix-$ID"; }
fix_it() { sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"; }

@test "b: a standalone claim records launcher B and no pid" {
  claim
  grep -q '^launcher=B$' "$ST/running/$ID"
  grep -q '^pid=$' "$ST/running/$ID"
}

@test "b: a standalone claim survives a later run while its lock is fresh" {
  claim
  "$FI_BIN" log --fix small "src/calc.sh:1 — add ignores a third argument" >/dev/null
  other="$(ls "$ST/queue" | head -1)"
  run "$FI_BIN" autofix run "$other" --engine claude
  [ "$status" -eq 4 ]
  [ -f "$ST/running/$ID" ]
  [ -d "$WT" ]
}

@test "b: brief names the entry, worktree, branch, test command and the allowed calls" {
  claim
  run "$FI_BIN" autofix brief "$ID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"add subtracts"* ]]
  [[ "$output" == *"$WT"* ]]
  [[ "$output" == *"fi/autofix/"* ]]
  [[ "$output" == *"sh test.sh"* ]]
  [[ "$output" == *"found-issues autofix test $ID"* ]]
  [[ "$output" == *"found-issues autofix verify $ID"* ]]
  [[ "$output" == *"found-issues autofix ship $ID"* ]]
  [[ "$output" == *"found-issues autofix release $ID"* ]]
}

@test "b: brief refuses an item that is not claimed" {
  run "$FI_BIN" autofix brief "$ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not claimed"* ]]
}

@test "b: test runs the repo test command in the worktree and reports fail then pass" {
  claim
  run "$FI_BIN" autofix test "$ID"
  [ "$status" -ne 0 ]
  [[ "$output" == *"tests: fail"* ]]
  fix_it
  run "$FI_BIN" autofix test "$ID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tests: pass"* ]]
}

@test "b: test refreshes the repo lock" {
  claim
  touch -t 202001010000 "$ST/lock"
  "$FI_BIN" autofix test "$ID" >/dev/null || true
  [ "$(find "$ST" -maxdepth 1 -name lock -mmin -5 | wc -l | tr -d ' ')" = 1 ]
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/autofix-b.bats`
Expected: FAIL. The launcher test fails (`pid=<number>`, no launcher). brief and test fail with an unknown-arg error. The "survives" test may already pass: it pins the lock analysis behind ledger entry `lib/autofix-queue.sh:263`. Keep it either way.

- [ ] **Step 3: Implement the queue changes** in `lib/autofix-queue.sh`:

Add the new keys to both the reset line and the `case` in `fi_af_item_read`:

```bash
  AFI_launcher="" AFI_launched="" AFI_attempts="0" AFI_verdict="" AFI_verdict_reason="" AFI_verdict_tree=""
```

```bash
      id|kind|root|slug|loc|key|entry|engine|queued|crashes|pid|wt|branch|base|result|pr|cost|tokens|base_sha|launcher|launched|attempts|verdict|verdict_reason|verdict_tree)
```

Add the same `AFI_*` names to the file-top global initialiser. In `fi_af_claim`, replace `fi_af_item_set "$q" pid "${FI_AF_PID:-$$}"` with:

```bash
  # Launcher A's run passes its own long-lived pid. A standalone claim is an
  # in-session fixer (launcher B): its claim process exits at once, so there
  # is no pid to record. The repo lock (refreshed by every B-side call) is
  # what keeps the item from being reaped (plan Task 3; ledger
  # lib/autofix-queue.sh:263).
  fi_af_item_set "$q" pid "${FI_AF_PID:-}"
  if [[ -n "${FI_AF_PID:-}" ]]; then fi_af_item_set "$q" launcher A; else fi_af_item_set "$q" launcher B; fi
```

- [ ] **Step 4: Create `lib/autofix-b.sh`**

```bash
#!/usr/bin/env bash
# autofix-b.sh — launcher B's fixer-side CLI: the in-session found-issues-fixer
# agent drives one claimed item through single `found-issues autofix …` calls
# (spec 2026-10-03 §4.2-§4.3, §5; phase 3 plan rulings 1-2). The agent only
# edits files; bash runs the tests, the verifier, git, gh and the ledger.
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   fi_af_touch_lock <id>
#   fi_af_b_running <id>
#   fi_af_brief
#   fi_af_b_test <id>

# shellcheck disable=SC2154  # AFI_* are set by fi_af_item_read (autofix-queue.sh)

fi_af_touch_lock() {
  local owner=""
  [[ -f "$FI_AF_ST/lock/owner" ]] && IFS= read -r owner <"$FI_AF_ST/lock/owner"
  [[ "$owner" == "$1" ]] && touch "$FI_AF_ST/lock" 2>/dev/null
  return 0
}

fi_af_b_running() {
  fi_af_item_read "$FI_AF_ST/running/$1" || { fi_err "autofix: $1 is not claimed (run: found-issues autofix claim $1)"; return 1; }
  fi_af_touch_lock "$1"
}

fi_af_brief() {
  local t
  t="$(fi_af_test_command "$AFI_wt" 2>/dev/null || printf '(none found)')"
  cat <<EOF
found-issues auto-fix brief for item ${AFI_id}. This run is sanctioned: the user
enabled found-issues auto-fix. Nobody will answer questions.

Issue (from the repo's found-issues ledger):
${AFI_entry}

Worktree: ${AFI_wt}
Branch:   ${AFI_branch} (from origin/${AFI_base}; never main)
Test command (bash runs it for you): ${t}

Edit ONLY files under the worktree path above, with Read, Edit, Write, Grep
and Glob, always by absolute path. Never edit docs/found-issues.md or any
found-issues ledger. Your only Bash calls are these, each alone, exactly as
written (no cd, &&, |, git or gh), with a 600000 ms timeout:
  found-issues autofix test ${AFI_id}      run the test command in the worktree
  found-issues autofix verify ${AFI_id}    tests + independent reviewer on your change
  found-issues autofix ship ${AFI_id}      commit, push and open the fix PR
  found-issues autofix release ${AFI_id} --already-fixed|--decide|--manual|--failed "<text>"

Do exactly this:
1. Check the symptom is still present in the worktree. If it is already fixed,
   release with --already-fixed "<evidence>". If fixing it needs a human
   decision, release with --decide "<question>". If no test can prove a fix,
   release with --manual "<why>".
2. Add or extend a test that fails because of this symptom; run autofix test
   and see it fail.
3. Make the smallest change that fixes the symptom. Change nothing unrelated.
4. Run autofix test until it passes.
5. Run autofix verify. Exit 0 = approved: run autofix ship. Exit 1 = rejected
   with a reason and one attempt left: revise, autofix test, autofix verify
   again. Any other exit: the item is finished or requeued; stop.
6. If you cannot finish, release with --failed "<why>".
End your reply with one line: the item id and its outcome.
EOF
}

fi_af_b_test() {
  local id="$1" t log rc=0 n=1
  t="$(fi_af_test_command "$AFI_wt")" || { fi_err "autofix: no test command for $id"; return 2; }
  while [[ -e "$FI_AF_RUNS/$id.btest$n.log" ]]; do n=$((n + 1)); done
  log="$FI_AF_RUNS/$id.btest$n.log"
  fi_af_run_tests "$AFI_wt" "$t" "$log" || rc=$?
  tail -n 30 "$log" 2>/dev/null
  tail -n 5 "$log.err" 2>/dev/null
  fi_af_touch_lock "$id"
  if (( rc == 0 )); then printf 'tests: pass\n'; else printf 'tests: fail (exit %s)\n' "$rc"; fi
  fi_af_log "$id" "b test $n: rc=$rc"
  return $rc
}
```

- [ ] **Step 5: Wire the CLI** — in `bin/found-issues` after the `autofix-ship.sh` source lines:

```bash
# shellcheck source=../lib/autofix-b.sh
source "$FI_LIB_DIR/autofix-b.sh"
```

In `cmd_autofix`, add before `run)`:

```bash
    brief|test)
      [[ $# -eq 1 ]] || { fi_err "Usage: found-issues autofix $sub <id>"; return 2; }
      fi_af_context || return 1
      fi_af_b_running "$1" || return 1
      if [[ "$sub" == brief ]]; then fi_af_brief; else fi_af_b_test "$1"; fi ;;
```

and in `_fi_af_usage` after `claim`:

```
  brief <id>                  The in-session fixer's instructions for a claimed item
  test <id>                   Run the repo's test command in the claimed item's worktree
```

Also in `cmd_autofix`'s `diff|ship` branch, call `fi_af_touch_lock "$1"` right after the successful `fi_af_item_read`.

- [ ] **Step 6: Run to verify they pass**

Run: `bats tests/autofix-b.bats tests/autofix-claim.bats tests/autofix-queue.bats tests/source-guards.bats`
Expected: all pass. If `source-guards.bats` pins the list of sourced libs, add `autofix-b.sh` there.

- [ ] **Step 7: Commit**

```bash
git add lib/autofix-b.sh lib/autofix-queue.sh lib/autofix.sh bin/found-issues tests/autofix-b.bats tests/source-guards.bats
git commit -m "feat(autofix): launcher B fixer CLI - standalone claim, brief, test, lock refresh"
```

---

### Task 4: `autofix verify` and tree-pinned `ship`

**Files:**
- Modify: `lib/autofix-b.sh` (add `fi_af_b_verify`)
- Modify: `lib/autofix.sh` (`_fi_af_verify` records the tree; `_fi_af_run_one` records the verdict; `cmd_autofix` `verify` case; `ship` requires approval)
- Modify: `lib/autofix-ship.sh` (`fi_af_ship` tree check; PR body launcher label)
- Test: `tests/autofix-b.bats`, `tests/autofix-ship.bats`, `tests/autofix-run.bats`

**Interfaces:**
- Consumes: `_fi_af_verify <engine> <n>` (sets `FI_AF_APPROVE`, `FI_AF_REASON`, `FI_AF_ENGINE_ERR`, adds to `FI_AF_COST`), `fi_af_requeue`, `fi_af_finish`, `fi_af_budget_left`.
- Produces:
  - `_fi_af_verify` sets `FI_AF_TREE` (the `git write-tree` of the staged change it showed the verifier).
  - `found-issues autofix verify <id>`: exit 0 approved (records `verdict=approve`, `verdict_reason`, `verdict_tree`); 1 rejected with an attempt left; 3 tests fail (no attempt counted); 2 nothing to verify; 5 rejected twice (item finished `failed`); 6 run budget spent (item finished `failed`); 7 verifier unavailable (item requeued).
  - `fi_af_ship` returns 1 with `FI_AF_WHY="the change differs from what the verifier approved"` when `AFI_verdict_tree` is set and the staged tree differs.
  - `found-issues autofix ship <id>` refuses (exit 1) unless the item has `verdict=approve`.

- [ ] **Step 1: Write the failing tests** — append to `tests/autofix-b.bats`:

```bash
@test "b: verify approves a green fix and records the verdict and tree" {
  claim; fix_it
  run "$FI_BIN" autofix verify "$ID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"approved"* ]]
  grep -q '^verdict=approve$' "$ST/running/$ID"
  grep -Eq '^verdict_tree=[0-9a-f]{40}$' "$ST/running/$ID"
  grep -q '^attempts=1$' "$ST/running/$ID"
}

@test "b: verify refuses red tests without counting an attempt" {
  claim
  printf '# touched\n' >>"$WT/src/calc.sh"
  run "$FI_BIN" autofix verify "$ID"
  [ "$status" -eq 3 ]
  run ! grep -q '^attempts=[1-9]' "$ST/running/$ID"
}

@test "b: verify with no change exits 2" {
  claim
  run "$FI_BIN" autofix verify "$ID"
  [ "$status" -eq 2 ]
}

@test "b: two rejects finish the item as failed" {
  claim; fix_it
  printf '%s\n' '{"approve":false,"reason":"no test"}' '{"approve":false,"reason":"still no test"}' >"$TMP/verdicts"
  export FI_STANDIN_VERDICTS="$TMP/verdicts"
  run "$FI_BIN" autofix verify "$ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no test"* ]]
  run "$FI_BIN" autofix verify "$ID"
  [ "$status" -eq 5 ]
  [ -f "$ST/done/$ID" ]
  grep -q '(autofix-failed: verifier rejected: still no test' "$REPO/docs/found-issues.md"
}

@test "b: an unavailable verifier requeues the item" {
  claim; fix_it
  export FI_STANDIN_ERROR="usage limit reached"
  run "$FI_BIN" autofix verify "$ID"
  [ "$status" -eq 7 ]
  [ -f "$ST/queue/$ID" ]
}

@test "b: ship refuses without an approving verdict" {
  claim; fix_it
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"autofix verify"* ]]
}

@test "b: ship refuses a tree that changed after approval" {
  claim; fix_it
  "$FI_BIN" autofix verify "$ID" >/dev/null
  printf '# later edit\n' >>"$WT/src/calc.sh"
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -eq 1 ]
  [[ "$output" == *"differs from what the verifier approved"* ]]
}

@test "b: claim, test, verify, ship end to end opens a PR labelled launcher B" {
  export GH_MOCK_TRACE="$TMP/gh.trace"
  export GH_MOCK_PR_VIEW=$'7\t{"number":7,"state":"OPEN","statusCheckRollup":[]}'
  claim; fix_it
  "$FI_BIN" autofix test "$ID" >/dev/null
  "$FI_BIN" autofix verify "$ID" >/dev/null
  run "$FI_BIN" autofix ship "$ID"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR #7"* ]]
  grep -q 'launcher B' "$FI_AF_RUNS/$ID.pr-body.md"
  [ -f "$ST/done/$ID" ]
}
```

Add a test to `tests/autofix-run.bats` for the A path's tree pin:

```bash
@test "autofix run: a test run that leaves a new file after approval is not shipped" {
  # $RANDOM, not date +%N: macOS date has no %N, so the artifact would be stable
  git config found-issues.autofix.testCommand 'sh test.sh && echo $RANDOM$RANDOM > artifact.txt'
  export FI_STANDIN_EDIT="sed -i.bak 's/ - / + /' src/calc.sh && rm -f src/calc.sh.bak"
  run "$FI_BIN" autofix run "$ID" --engine claude
  grep -q 'differs from what the verifier approved' "$FI_AF_ST/done/$ID"
}
```

In `tests/autofix-ship.bats`, change `fix_it` so the existing ship tests verify first:

```bash
fix_it() { sed -i.bak 's/ - / + /' "$WT/src/calc.sh"; rm -f "$WT/src/calc.sh.bak"; "$FI_BIN" autofix verify "$ID" >/dev/null; }
```

Ship tests that edit after `fix_it` need their extra edit moved before the verify; adjust each one so the edit happens first.

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/autofix-b.bats tests/autofix-ship.bats -f 'verify|ship'` then `bats -f 'leaves a new file' tests/autofix-run.bats`
Expected: FAIL (unknown subcommand `verify`; ship has no tree check).

- [ ] **Step 3: Record the tree in `_fi_af_verify`** (`lib/autofix.sh`). Compute the diff once, before building the prompt:

```bash
_fi_af_verify() {
  local engine="$1" n="$2" base="$FI_AF_RUNS/$AFI_id.verify$n" rc=0 d
  d="$(fi_af_diff "$AFI_wt" "${AFI_base_sha:-origin/$AFI_base}")"
  # The staged tree the verifier is shown; ship refuses any other tree
  # (ledger lib/autofix-ship.sh:116 — tests could leave artifacts).
  FI_AF_TREE="$(git -C "$AFI_wt" write-tree 2>/dev/null || true)"
  fi_af_verifier_cmd "$engine" "$(fi_af_verifier_prompt "$d")" "$base.last" "$FI_AF_RUNS/verdict.schema.json"
  fi_af_child "$base.out" "$base.err" "$AFI_wt" "${FI_AF_CMD[@]}" || rc=$?
  fi_af_collect "$engine" "$base.out" "$base.last"
  fi_af_parse_verdict "$FI_AF_TEXT"
  fi_af_log "$AFI_id" "attempt $n: verifier rc=$rc approve=$FI_AF_APPROVE reason=$FI_AF_REASON"
}
```

In `_fi_af_run_one`, after the approve check and before `fi_af_ship`:

```bash
    AFI_verdict_tree="$FI_AF_TREE"
    fi_af_item_set "$FI_AF_ST/running/$id" verdict approve
    fi_af_item_set "$FI_AF_ST/running/$id" verdict_tree "$FI_AF_TREE"
```

- [ ] **Step 4: Add the tree check and launcher label in `lib/autofix-ship.sh`**. In `fi_af_ship`, right after `if git -C "$wt" diff --cached --quiet "$ref"; then …; fi`:

```bash
  if [[ -n "${AFI_verdict_tree:-}" && "$(git -C "$wt" write-tree 2>/dev/null)" != "$AFI_verdict_tree" ]]; then
    FI_AF_WHY="the change differs from what the verifier approved (did the tests leave files?)"; return 1
  fi
```

In `_fi_af_pr_body`, change the first line to:

```bash
  printf 'Unattended fix by found-issues auto-fix (launcher %s, engine %s).\n\n' "${AFI_launcher:-A}" "${AFI_engine:-?}"
```

- [ ] **Step 5: Add `fi_af_b_verify` to `lib/autofix-b.sh`** (and list it in the header):

```bash
# Spec §5 steps 4-5 for launcher B: bash re-runs the tests, then the same
# headless read-only verifier launcher A uses. The verdict and the exact
# staged tree are recorded; ship refuses anything else.
fi_af_b_verify() {
  local id="$1" r="$FI_AF_ST/running/$1" engine n log
  if [[ -z "$(fi_af_diff "$AFI_wt" "${AFI_base_sha:-origin/$AFI_base}")" ]]; then
    printf 'nothing to verify: the worktree has no change\n'; return 2
  fi
  FI_AF_TESTCMD="$(fi_af_test_command "$AFI_wt")" || { fi_err "autofix: no test command"; return 2; }
  log="$FI_AF_RUNS/$id.bverify-tests.log"
  if ! fi_af_run_tests "$AFI_wt" "$FI_AF_TESTCMD" "$log"; then
    tail -n 20 "$log" 2>/dev/null
    printf 'tests fail: fix them (found-issues autofix test %s) before verify\n' "$id"; return 3
  fi
  engine="$(fi_af_engine "${AFI_engine:-claude}")" || engine=claude
  FI_AF_COST="${AFI_cost:-0}" FI_AF_TOKENS="${AFI_tokens:-0}"
  if [[ "$engine" == claude ]] && ! fi_af_budget_left >/dev/null; then
    fi_af_finish "$id" failed "run budget spent (\$$FI_AF_COST)"; printf 'failed: run budget spent; stop\n'; return 6
  fi
  n=$(( ${AFI_attempts:-0} + 1 ))
  _fi_af_verify "$engine" "$n"
  fi_af_item_set "$r" cost "$FI_AF_COST"
  fi_af_item_set "$r" tokens "$FI_AF_TOKENS"
  if [[ -n "$FI_AF_ENGINE_ERR" ]]; then
    fi_af_requeue "$id" "verifier unavailable: $FI_AF_ENGINE_ERR"
    printf 'verifier unavailable (%s): the item is requeued; stop\n' "$FI_AF_ENGINE_ERR"; return 7
  fi
  fi_af_item_set "$r" attempts "$n"
  fi_af_item_set "$r" verdict_reason "$FI_AF_REASON"
  fi_af_touch_lock "$id"
  if [[ "$FI_AF_APPROVE" == "true" ]]; then
    fi_af_item_set "$r" verdict approve
    fi_af_item_set "$r" verdict_tree "$FI_AF_TREE"
    printf 'approved: %s\nNext: found-issues autofix ship %s\n' "$FI_AF_REASON" "$id"; return 0
  fi
  fi_af_item_set "$r" verdict reject
  if (( n >= 2 )); then
    fi_af_finish "$id" failed "verifier rejected: $FI_AF_REASON after 2 attempts"
    printf 'rejected twice (%s): the item is marked failed; stop\n' "$FI_AF_REASON"; return 5
  fi
  printf 'rejected: %s\nOne attempt left: revise, run found-issues autofix test %s, then verify again.\n' "$FI_AF_REASON" "$id"
  return 1
}
```

- [ ] **Step 6: Wire `verify` and gate `ship`** in `cmd_autofix`. Extend the `brief|test)` case to `brief|test|verify)` with:

```bash
      case "$sub" in
        brief) fi_af_brief ;;
        test) fi_af_b_test "$1" ;;
        verify) fi_af_no_prompts; fi_af_b_verify "$1" ;;
      esac ;;
```

In the `diff|ship` branch, before `fi_af_no_prompts`:

```bash
      if [[ "$AFI_verdict" != "approve" ]]; then
        fi_err "autofix: ship needs an approving verdict — run: found-issues autofix verify $1"; return 1
      fi
      FI_AF_VERDICT_REASON="$AFI_verdict_reason"
```

Add to `_fi_af_usage`: `  verify <id>                 Tests, then the read-only verifier; records the approved tree`.

- [ ] **Step 7: Run to verify they pass**

Run: `bats tests/autofix-b.bats tests/autofix-ship.bats tests/autofix-run.bats tests/autofix-release.bats`
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add lib/autofix-b.sh lib/autofix.sh lib/autofix-ship.sh tests/autofix-b.bats tests/autofix-ship.bats tests/autofix-run.bats
git commit -m "feat(autofix): verify subcommand; ship only the verifier-approved tree"
```

---

### Task 5: The plugin agent `found-issues-fixer`

**Files:**
- Create: `agents/found-issues-fixer.md`
- Test: create `tests/autofix-agent.bats`

**Interfaces:**
- Consumes: `found-issues autofix claim|brief` (Task 3).
- Produces: plugin agent `found-issues:found-issues-fixer`, started by the main agent with the prompt `Fix found-issues auto-fix item <id>.` (Task 6's nudge text).

- [ ] **Step 1: Write the failing test** — `tests/autofix-agent.bats`:

```bash
#!/usr/bin/env bats
# The launcher B plugin agent (spec §4.2; plugin agents support name,
# description, model, effort, maxTurns, tools, background and ignore
# permissionMode/hooks/mcpServers — Claude Code docs, re-checked 2026-10-03).

load 'helpers'

AGENT="$TEST_REPO_ROOT/agents/found-issues-fixer.md"

fm() { awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {exit} f' "$AGENT"; }

@test "agent: fixer frontmatter uses only supported fields" {
  [ -f "$AGENT" ]
  fm | grep -qx 'name: found-issues-fixer'
  fm | grep -qx 'model: sonnet'
  fm | grep -qx 'background: true'
  fm | grep -Eqx 'maxTurns: [0-9]+'
  fm | grep -qx 'tools: Read, Edit, Write, Glob, Grep, Bash'
  # (no `run !` with a pipe: run would only cover the first command)
  if fm | grep -Eq '^(permissionMode|hooks|mcpServers|initialPrompt|isolation):'; then false; fi
}

@test "agent: every command the fixer is told to run is a found-issues autofix call" {
  cmds="$(grep -Eo '`[^`]+`' "$AGENT" | tr -d '`')"
  if printf '%s\n' "$cmds" | grep -Eq '^(git|gh|cd|bash|sh|rm|bats|npm)( |$)'; then false; fi
  grep -q 'found-issues autofix claim <id>' "$AGENT"
  grep -q 'found-issues autofix brief <id>' "$AGENT"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats tests/autofix-agent.bats`
Expected: FAIL (file missing).

- [ ] **Step 3: Create `agents/found-issues-fixer.md`**

```markdown
---
name: found-issues-fixer
description: Unattended found-issues auto-fixer for ONE queued auto-fix item. Start it only when a found-issues hook message asks for it, in the background, with the prompt "Fix found-issues auto-fix item <id>." Never use it for general bug fixing.
tools: Read, Edit, Write, Glob, Grep, Bash
model: sonnet
effort: medium
maxTurns: 60
background: true
---

You fix exactly one found-issues auto-fix item, unattended. The user turned
found-issues auto-fix on; nobody will answer questions, so never ask any.

1. Take the item id from your prompt (it looks like `20261003-142501-01234`).
   Run `found-issues autofix claim <id>` as one Bash call. If it exits
   non-zero, reply with its message and stop: another run has the item, the
   daily cap is reached, or the item is no longer fixable.
2. Run `found-issues autofix brief <id>` and follow it exactly. It names the
   issue, the worktree you may edit, and the only commands you may run.

Rules that hold throughout:
- Bash only for `found-issues autofix <command> <id> …`, one call at a time,
  never combined with anything else, with timeout 600000.
- Edit only inside the worktree that claim printed, by absolute path.
- Never edit `docs/found-issues.md`, never run git or gh, never start agents.
- End with one line: the item id and what happened (shipped, released, failed).
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats tests/autofix-agent.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add agents/found-issues-fixer.md tests/autofix-agent.bats
git commit -m "feat(autofix): found-issues-fixer plugin agent for launcher B"
```

---

### Task 6: PostToolUse launcher selection on `AUTOFIX-QUEUED`

**Files:**
- Create: `lib/autofix-hook.sh`
- Modify: `hooks/post-bash-dispatch.sh` (gate + new route before the merge route)
- Test: create `tests/autofix-hook.bats`; add one case to `tests/hook-gates.bats`

**Interfaces:**
- Consumes: `fi_af_item_read`, `fi_af_item_set` (sourced from `lib/autofix-queue.sh`; both are pure bash), `fi_detect_harness`.
- Produces (used by Task 7 too):
  - `fi_afh_launcher <harness> <permission_mode> <agent_id>` sets `FI_AFH_LAUNCHER` to `A`, `B` or `none`.
  - `fi_afh_ids <text>` sets the `FI_AFH_IDS` array to every `AUTOFIX-QUEUED <id>` id in the text, in order and de-duplicated.
  - `fi_afh_item <id>` sets `FI_AFH_ITEM` to `<state>/autofix/*/queue/<id>`; rc 1 when it is not queued.
  - `fi_afh_mark <item> <A|B> <epoch>` writes `launcher` and `launched`.
  - `fi_afh_launch_a <item> <engine> <fi-bin>` spawns a detached `cd <root> && <fi-bin> autofix run <id> --engine <engine>`, logging to `<repo-state>/spawn.log`.
  - `fi_afh_context_b <id>` prints the nudge text.
  - `fi_afh_now` sets `FI_AFH_NOW` (epoch) and `FI_AFH_DAY` (YYYY-MM-DD) with one `date` call.

- [ ] **Step 1: Write the failing tests** — `tests/autofix-hook.bats`:

```bash
#!/usr/bin/env bats
# v3 hook launcher selection (spec §4.1-§4.2, §4.4; phase 3 plan Task 6).

load 'helpers'
load 'autofix-helpers'

HOOK="$TEST_REPO_ROOT/hooks/post-bash-dispatch.sh"

setup() {
  fi_setup_tmp; fi_af_fixture
  fi_af_queue_fixture; ST="$FI_AF_ST"
  # A stand-in found-issues that only records how it was launched.
  mkdir -p "$TMP/fake"
  printf '#!/usr/bin/env bash\nprintf "%%s|%%s\\n" "$PWD" "$*" >>"%s/spawned"\n' "$TMP" >"$TMP/fake/found-issues"
  chmod +x "$TMP/fake/found-issues"
  export FOUND_ISSUES_BIN="$TMP/fake/found-issues"
  unset FOUND_ISSUES_HARNESS
  export CLAUDE_CODE_ENTRYPOINT=cli
}
teardown() { fi_teardown_tmp; }

# payload <permission_mode|""> <stdout> [agent_id] [command]
payload() {
  jq -cn --arg m "$1" --arg o "$2" --arg a "${3:-}" --arg c "${4:-found-issues log --fix small x}" \
    '{session_id:"s",cwd:"/x",hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:$o,stderr:"",interrupted:false}}
     + (if $m == "" then {} else {permission_mode:$m} end)
     + (if $a == "" then {} else {agent_id:$a, agent_type:"x"} end)'
}
hook() { printf '%s' "$1" | "$HOOK"; }
wait_spawn() { local i; for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/spawned" ] && return 0; sleep 0.3; done; return 1; }

@test "hook: claude default, acceptEdits, plan, dontAsk and missing modes start launcher A" {
  local m
  for m in default acceptEdits plan dontAsk ""; do
    rm -f "$TMP/spawned"; fi_af_item_set "$QITEM" launched ""
    run hook "$(payload "$m" "Logged.
AUTOFIX-QUEUED $ID")"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    wait_spawn
    grep -q "^$REPO|autofix run $ID --engine claude$" "$TMP/spawned"
    grep -q '^launcher=A$' "$QITEM"
  done
}

@test "hook: claude auto and bypassPermissions nudge the main agent (launcher B)" {
  local m
  for m in auto bypassPermissions; do
    rm -f "$TMP/spawned"
    run hook "$(payload "$m" "AUTOFIX-QUEUED $ID")"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"'
    ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
    [[ "$ctx" == *"found-issues:found-issues-fixer"* ]]
    [[ "$ctx" == *"Fix found-issues auto-fix item $ID."* ]]
    grep -q '^launcher=B$' "$QITEM"
    grep -Eq '^launched=[0-9]+$' "$QITEM"
    sleep 0.5; [ ! -e "$TMP/spawned" ]
  done
}

@test "hook: codex always starts launcher A with the codex engine" {
  export FOUND_ISSUES_HARNESS=codex
  run hook "$(payload bypassPermissions "AUTOFIX-QUEUED $ID")"
  [ "$status" -eq 0 ]
  wait_spawn
  grep -q "autofix run $ID --engine codex$" "$TMP/spawned"
}

@test "hook: a codex string tool_response is read too" {
  export FOUND_ISSUES_HARNESS=codex
  p="$(jq -cn --arg o "AUTOFIX-QUEUED $ID" '{hook_event_name:"PostToolUse",tool_name:"Bash",permission_mode:"default",tool_input:{command:"found-issues log x"},tool_response:$o}')"
  run hook "$p"
  wait_spawn
}

@test "hook: agent_id (inside a subagent) launches nothing and leaves the item unstamped" {
  run hook "$(payload bypassPermissions "AUTOFIX-QUEUED $ID" agent-123)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  sleep 0.5; [ ! -e "$TMP/spawned" ]
  run ! grep -q '^launched=' "$QITEM"
}

@test "hook: FOUND_ISSUES_AUTOFIX_CHILD launches nothing" {
  FOUND_ISSUES_AUTOFIX_CHILD=1 run hook "$(payload default "AUTOFIX-QUEUED $ID")"
  sleep 0.5; [ ! -e "$TMP/spawned" ]
}

@test "hook: a marker for an id that is not queued launches nothing" {
  run hook "$(payload default "AUTOFIX-QUEUED 20990101-000000-00000")"
  [ -z "$output" ]
  sleep 0.5; [ ! -e "$TMP/spawned" ]
}

@test "hook: a marker only in the command, not the output, launches nothing" {
  run hook "$(payload default "" "" "echo AUTOFIX-QUEUED $ID")"
  sleep 0.5; [ ! -e "$TMP/spawned" ]
}

@test "hook: two markers start one launcher A run and stamp both items" {
  "$FI_BIN" log --fix small "src/calc.sh:1 — add ignores a third argument" >/dev/null
  id2="$(ls "$ST/queue" | grep -v "^$ID$" | head -1)"
  run hook "$(payload default "AUTOFIX-QUEUED $ID
AUTOFIX-QUEUED $id2")"
  wait_spawn; sleep 0.5
  [ "$(wc -l <"$TMP/spawned" | tr -d ' ')" = 1 ]
  grep -q '^launcher=A$' "$ST/queue/$id2"
}

@test "hook: FOUND_ISSUES_AUTOFIX_LAUNCHER=headless forces launcher A in bypass mode" {
  FOUND_ISSUES_AUTOFIX_LAUNCHER=headless run hook "$(payload bypassPermissions "AUTOFIX-QUEUED $ID")"
  [ -z "$output" ]
  wait_spawn
}

@test "hook: commit route plus marker emit one JSON object" {
  export FOUND_ISSUES_BIN="$FI_BIN"
  printf 'x\n' >f.txt; git add f.txt; git commit -q -m x
  run hook "$(payload auto "AUTOFIX-QUEUED $ID" "" "git commit -m x && found-issues log --fix small y")"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -s 'length')" = 1 ]
}
```

In `tests/hook-gates.bats`, add:

```bash
@test "hook-gate: an AUTOFIX-QUEUED marker in the output reaches the full path" {
  rm -f "$TMP/jq-calls"
  payload post 'found-issues log --fix small "a:1 — b"' 'AUTOFIX-QUEUED 20261003-000000-00001' >"$TMP/p.json"
  run_hook "$POST" "$TMP/p.json" post
  [ -e "$TMP/jq-calls" ]
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/autofix-hook.bats` and `bats -f 'AUTOFIX-QUEUED marker' tests/hook-gates.bats`
Expected: FAIL (no spawns, no context; the gate exits before jq).

- [ ] **Step 3: Create `lib/autofix-hook.sh`**

```bash
#!/usr/bin/env bash
# autofix-hook.sh — hook-side launchers for v3 auto-fix (spec 2026-10-03
# §4.1-§4.4): which launcher an AUTOFIX-QUEUED marker gets, the detached
# launcher A spawn, the launcher B nudge, and the Stop-hook fallback.
#
# Sourced by hooks/post-bash-dispatch.sh and hooks/stop-reminder.sh, after
# lib/autofix-queue.sh (fi_af_item_read / fi_af_item_set). Defines functions
# only. Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   fi_afh_launcher <harness> <permission_mode> <agent_id>
#   fi_afh_ids <text>
#   fi_afh_item <id>
#   fi_afh_now
#   fi_afh_mark <item> <A|B> <epoch>
#   fi_afh_launch_a <item> <engine> <fi-bin>
#   fi_afh_context_b <id>
#   fi_afh_stop <payload> <engine> <fi-bin>

FI_AFH_LAUNCHER="" FI_AFH_ITEM="" FI_AFH_NOW="" FI_AFH_DAY=""
FI_AFH_IDS=()

fi_afh_state() { printf '%s' "${FOUND_ISSUES_STATE_DIR:-$HOME/.claude/found-issues}/autofix"; }

# Spec §4.2 table plus the §4.4 recursion guard. Launcher B only where a
# background subagent inherits a mode that never prompts (Claude Code docs,
# re-checked 2026-10-03: auto and bypassPermissions; acceptEdits still
# prompts for Bash). A missing mode is treated as one that prompts.
fi_afh_launcher() {
  local harness="$1" mode="$2" agent="$3"
  FI_AFH_LAUNCHER=none
  [[ "${FOUND_ISSUES_AUTOFIX_CHILD:-}" == "1" || -n "$agent" ]] && return 0
  FI_AFH_LAUNCHER=A
  [[ "$harness" == "codex" || "${FOUND_ISSUES_AUTOFIX_LAUNCHER:-}" == "headless" ]] && return 0
  case "$mode" in auto|bypassPermissions) FI_AFH_LAUNCHER=B ;; esac
  return 0
}

fi_afh_ids() {
  local rest="$1" id seen=" " re='AUTOFIX-QUEUED[[:space:]]+([0-9]{8}-[0-9]{6}-[0-9]{5})'
  FI_AFH_IDS=()
  while [[ "$rest" =~ $re ]]; do
    id="${BASH_REMATCH[1]}"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
    [[ "$seen" == *" $id "* ]] && continue
    seen+="$id "
    FI_AFH_IDS+=("$id")
  done
}

fi_afh_item() {
  local f
  FI_AFH_ITEM=""
  for f in "$(fi_afh_state)"/*/queue/"$1"; do
    [[ -f "$f" ]] && { FI_AFH_ITEM="$f"; return 0; }
  done
  return 1
}

fi_afh_now() {
  local s
  s="$(date '+%s %Y-%m-%d')"
  FI_AFH_NOW="${s%% *}" FI_AFH_DAY="${s#* }"
}

fi_afh_mark() {
  fi_af_item_set "$1" launcher "$2"
  fi_af_item_set "$1" launched "$3"
}

# Detached and fd-clean: the session never waits on it and bats never hangs
# on an inherited fd 3.
fi_afh_launch_a() {
  local item="$1" engine="$2" bin="$3" log
  fi_af_item_read "$item" || return 1
  [[ -d "$AFI_root" ]] || return 1
  log="${item%/queue/*}/spawn.log"
  ( cd "$AFI_root" && nohup "$bin" autofix run "$AFI_id" --engine "$engine" \
      </dev/null >>"$log" 2>&1 3>&- & ) >/dev/null 2>&1
}

fi_afh_context_b() {
  cat <<EOF
## found-issues auto-fix: item $1 is queued

The user turned on found-issues auto-fix. Start the plugin agent
found-issues:found-issues-fixer now, in the background, with exactly this
prompt:

  Fix found-issues auto-fix item $1.

Do not fix the issue yourself and do not wait for the agent; carry on with
your current task.
EOF
}
```

(`fi_afh_stop` is added in Task 7.)

- [ ] **Step 4: Wire the hook** — in `hooks/post-bash-dispatch.sh`:

Gate: replace the gate block's condition with:

```bash
  fi_gate_has commit \
    || { fi_gate_has gh && fi_gate_has create merge close reopen; } \
    || [[ "$input" == *AUTOFIX-QUEUED* ]] \
    || exit 0
```

and add a comment line above it: `# ... or an AUTOFIX-QUEUED marker anywhere in the payload (it lives in tool_response, not the command; plain substring test, zero forks).`

New route, placed just before the `gh pr merge/close/reopen` route:

```bash
# ============ route: AUTOFIX-QUEUED → launcher A or B (v3 spec §4.2) ============
# The marker comes from `found-issues log` OUTPUT. Only ids whose item is
# still in queue/ count, so re-printed old markers (a cat of a log) do
# nothing. A gets one detached `autofix run` (it drains the queue); B gets
# one nudge per id. Inside a subagent (agent_id) or a fixer child nothing
# launches; the main session's Stop fallback picks those up.
if [[ "$input" == *AUTOFIX-QUEUED* && -f "$lib_dir/autofix-queue.sh" && -f "$lib_dir/autofix-hook.sh" ]]; then
  # shellcheck source=../lib/autofix-queue.sh
  source "$lib_dir/autofix-queue.sh"
  # shellcheck source=../lib/autofix-hook.sh
  source "$lib_dir/autofix-hook.sh"
  fi_afh_ids "$(printf '%s' "$input" | jq -r '.tool_response | if type == "string" then . else tostring end' 2>/dev/null || true)"
  if (( ${#FI_AFH_IDS[@]} > 0 )); then
    __fi_harness="$(fi_detect_harness 2>/dev/null || printf claude)"
    fi_afh_launcher "$__fi_harness" "$(get_field '.permission_mode')" "$(get_field '.agent_id')"
    if [[ "$FI_AFH_LAUNCHER" != none ]]; then
      fi_afh_now
      __fi_first=""
      for __fi_id in "${FI_AFH_IDS[@]}"; do
        fi_afh_item "$__fi_id" || continue
        fi_afh_mark "$FI_AFH_ITEM" "$FI_AFH_LAUNCHER" "$FI_AFH_NOW"
        if [[ "$FI_AFH_LAUNCHER" == B ]]; then
          ctx+="$(fi_afh_context_b "$__fi_id")"$'\n\n'
        elif [[ -z "$__fi_first" ]]; then
          __fi_first="$FI_AFH_ITEM"
        fi
      done
      [[ -n "$__fi_first" ]] && fi_afh_launch_a "$__fi_first" "$__fi_harness" "$FI_BIN"
    fi
  fi
fi
```

Note: `FI_BIN` may be a bare command name (`found-issues`); `nohup` resolves it on PATH, so this is fine. The route sits before the final `fi_emit_post_context`, so the output stays one JSON object.

- [ ] **Step 5: Run to verify they pass**

Run: `bats tests/autofix-hook.bats tests/hook-gates.bats tests/post-bash-dispatch.bats`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/autofix-hook.sh hooks/post-bash-dispatch.sh tests/autofix-hook.bats tests/hook-gates.bats
git commit -m "feat(autofix): PostToolUse launcher selection - B nudge in auto/bypass, detached A elsewhere"
```

---

### Task 7: Stop-hook claim fallback

**Files:**
- Modify: `lib/autofix-hook.sh` (add `fi_afh_stop`)
- Modify: `hooks/stop-reminder.sh` (read stdin once at the top, run the fallback, reuse the input in both harness branches)
- Test: create `tests/autofix-stop.bats`; the existing `tests/stop-reminder.bats` and `tests/codex-wiring.bats` must stay green

**Interfaces:**
- Consumes: Task 6's `fi_afh_*` and Task 2's `day/<date>.capped`.
- Produces: `fi_afh_stop <payload> <engine> <fi-bin>`. For the first queued item whose root contains the payload's `cwd`, it starts launcher A, unless any of these holds: the queue glob is empty (returns before any fork), the payload carries `agent_id`, `FOUND_ISSUES_AUTOFIX_CHILD=1`, the kill switch is set (`FOUND_ISSUES_AUTOFIX=off` or the `disabled` file), the repo lock exists, today's capped marker exists, or the item was launched less than `FOUND_ISSUES_AUTOFIX_STOP_GRACE` seconds ago (default 60).

- [ ] **Step 1: Write the failing tests** — `tests/autofix-stop.bats`:

```bash
#!/usr/bin/env bats
# v3 Stop-hook claim fallback (spec §4.3; phase 3 plan Task 7).

load 'helpers'
load 'autofix-helpers'

STOP="$TEST_REPO_ROOT/hooks/stop-reminder.sh"

setup() {
  fi_setup_tmp; fi_af_fixture
  fi_af_queue_fixture; ST="$FI_AF_ST"
  mkdir -p "$TMP/fake"
  printf '#!/usr/bin/env bash\nprintf "%%s|%%s\\n" "$PWD" "$*" >>"%s/spawned"\n' "$TMP" >"$TMP/fake/found-issues"
  chmod +x "$TMP/fake/found-issues"
  export FOUND_ISSUES_BIN="$TMP/fake/found-issues"
  export FOUND_ISSUES_STOP_REMINDER=off   # isolate the fallback from the marker check
  unset FOUND_ISSUES_HARNESS
}
teardown() { fi_teardown_tmp; }

stop() { # $1 cwd [$2 agent_id]
  jq -cn --arg c "$1" --arg a "${2:-}" \
    '{session_id:"s1",hook_event_name:"Stop",cwd:$c,stop_hook_active:false,permission_mode:"bypassPermissions"} + (if $a == "" then {} else {agent_id:$a} end)' \
    | "$STOP"
}
wait_spawn() { local i; for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/spawned" ] && return 0; sleep 0.3; done; return 1; }
no_spawn() { sleep 0.5; [ ! -e "$TMP/spawned" ]; }

@test "stop: an item with no launched stamp is launched with launcher A" {
  run stop "$REPO"
  [ "$status" -eq 0 ]
  wait_spawn
  grep -q "^$REPO|autofix run $ID --engine claude$" "$TMP/spawned"
  grep -q '^launcher=A$' "$QITEM"
}

@test "stop: cwd under the repo root matches" {
  run stop "$REPO/src"
  wait_spawn
}

@test "stop: another repo is ignored" {
  mkdir -p "$TMP/other"
  run stop "$TMP/other"
  no_spawn
}

@test "stop: an item nudged within the grace period is left for its fixer" {
  fi_af_item_set "$QITEM" launched "$(date +%s)"
  run stop "$REPO"
  no_spawn
  fi_af_item_set "$QITEM" launched "$(( $(date +%s) - 120 ))"
  run stop "$REPO"
  wait_spawn
}

@test "stop: a held repo lock is left alone" {
  mkdir "$ST/lock"
  run stop "$REPO"
  no_spawn
}

@test "stop: today's capped marker is left alone" {
  : >"$ST/day/$(date +%Y-%m-%d).capped"
  run stop "$REPO"
  no_spawn
}

@test "stop: kill switch, agent_id and fixer children launch nothing" {
  FOUND_ISSUES_AUTOFIX=off run stop "$REPO"; no_spawn
  run stop "$REPO" agent-9; no_spawn
  FOUND_ISSUES_AUTOFIX_CHILD=1 run stop "$REPO"; no_spawn
  mkdir -p "$FOUND_ISSUES_STATE_DIR/autofix"; : >"$FOUND_ISSUES_STATE_DIR/autofix/disabled"
  run stop "$REPO"; no_spawn
}

@test "stop: an empty queue runs no external command" {
  rm -f "$ST"/queue/*
  mkdir -p "$TMP/shim"
  for c in date jq git; do
    printf '#!/usr/bin/env bash\necho %s >>"%s/ext-calls"\nexit 0\n' "$c" "$TMP" >"$TMP/shim/$c"; chmod +x "$TMP/shim/$c"
  done
  PATH="$TMP/shim:$PATH" run stop "$REPO"
  [ "$status" -eq 0 ]
  [ ! -e "$TMP/ext-calls" ]
}

@test "stop: codex uses the codex engine and still gives the marker nudge" {
  export FOUND_ISSUES_HARNESS=codex
  unset FOUND_ISSUES_STOP_REMINDER
  out="$(jq -cn --arg c "$REPO" '{session_id:"s2",hook_event_name:"Stop",cwd:$c,stop_hook_active:false,last_assistant_message:"done",transcript_path:null,permission_mode:"default",turn_id:"t"}' | "$STOP")"
  wait_spawn
  grep -q "autofix run $ID --engine codex$" "$TMP/spawned"
  printf '%s' "$out" | jq -e '.decision == "block"'
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/autofix-stop.bats`
Expected: FAIL (nothing spawns), except the "launch nothing" and "empty queue" cases, which pass vacuously before the change and must still pass after it.

- [ ] **Step 3: Add `fi_afh_stop` to `lib/autofix-hook.sh`**

```bash
# Spec §4.3: an item still queued when the session stops gets launcher A, so
# a skipped launcher B nudge (or an item queued inside a fixer) never
# strands. Zero forks while the queue is empty: one glob, then return.
fi_afh_stop() {
  local input="$1" engine="$2" bin="$3" st_root f st cwd
  local re_agent='"agent_id"[[:space:]]*:[[:space:]]*"[^"]' re_cwd='"cwd"[[:space:]]*:[[:space:]]*"([^"\\]*)"'
  local -a items=()
  [[ "${FOUND_ISSUES_AUTOFIX_CHILD:-}" == "1" ]] && return 0
  case "${FOUND_ISSUES_AUTOFIX:-}" in off|0|false|no) return 0 ;; esac
  st_root="$(fi_afh_state)"
  [[ -e "$st_root/disabled" ]] && return 0
  for f in "$st_root"/*/queue/*; do [[ -f "$f" ]] && items+=("$f"); done
  (( ${#items[@]} > 0 )) || return 0
  [[ "$input" =~ $re_agent ]] && return 0
  cwd="$PWD"
  [[ "$input" =~ $re_cwd ]] && cwd="${BASH_REMATCH[1]}"
  fi_afh_now
  for f in "${items[@]}"; do
    st="${f%/queue/*}"
    [[ -d "$st/lock" || -e "$st/day/$FI_AFH_DAY.capped" ]] && continue
    fi_af_item_read "$f" || continue
    [[ -n "$AFI_root" && ( "$cwd" == "$AFI_root" || "$cwd" == "$AFI_root"/* ) ]] || continue
    if [[ "$AFI_launched" =~ ^[0-9]+$ ]] \
       && (( FI_AFH_NOW - AFI_launched < ${FOUND_ISSUES_AUTOFIX_STOP_GRACE:-60} )); then
      continue
    fi
    fi_afh_mark "$f" A "$FI_AFH_NOW"
    fi_afh_launch_a "$f" "$engine" "$bin"
    return 0
  done
  return 0
}
```

- [ ] **Step 4: Wire `hooks/stop-reminder.sh`**

At the top, right after `set -euo pipefail`, read stdin once and run the fallback before every opt-out:

```bash
# Read the payload once: the auto-fix fallback and both harness branches
# below use it.
IFS= read -r -d '' __fi_stop_input || true

# v3 auto-fix (spec §4.3): an item still queued at Stop gets launcher A.
# Runs before every opt-out below (the marker nudge being off must not
# strand a queued fix). Zero forks unless something is queued.
__fi_stop_dir="${BASH_SOURCE[0]%/*}"
[[ "$__fi_stop_dir" == "${BASH_SOURCE[0]}" ]] && __fi_stop_dir=.
if [[ -f "$__fi_stop_dir/../lib/autofix-queue.sh" && -f "$__fi_stop_dir/../lib/autofix-hook.sh" ]]; then
  # shellcheck source=../lib/autofix-queue.sh
  source "$__fi_stop_dir/../lib/autofix-queue.sh"
  # shellcheck source=../lib/autofix-hook.sh
  source "$__fi_stop_dir/../lib/autofix-hook.sh"
  __fi_engine=claude
  [[ "${FOUND_ISSUES_HARNESS:-}" == "codex" ]] && __fi_engine=codex
  __fi_bin="${FOUND_ISSUES_BIN:-}"
  if [[ -z "$__fi_bin" ]]; then
    if [[ -x "$__fi_stop_dir/../bin/found-issues" ]]; then __fi_bin="$__fi_stop_dir/../bin/found-issues"
    else __fi_bin=found-issues; fi
  fi
  fi_afh_stop "$__fi_stop_input" "$__fi_engine" "$__fi_bin" || true
fi
```

Then:
- Move the existing `FOUND_ISSUES_STOP_REMINDER=off` check below this block (unchanged otherwise).
- In `fi_codex_stop`, replace `IFS= read -r -d '' input || true` with `input="$__fi_stop_input"`.
- Replace `input="$(cat)"` with `input="$__fi_stop_input"`.

- [ ] **Step 5: Run to verify they pass**

Run: `bats tests/autofix-stop.bats tests/stop-reminder.bats tests/codex-wiring.bats`
Expected: all pass. Some `stop-reminder.bats` tests pipe input through `echo '…' |`; reading with `read -d ''` handles that the same way as `cat`.

- [ ] **Step 6: Commit**

```bash
git add lib/autofix-hook.sh hooks/stop-reminder.sh tests/autofix-stop.bats
git commit -m "feat(autofix): Stop-hook fallback starts launcher A for items still queued"
```

---

### Task 8: Spec, changelog, ledger and README count

**Files:**
- Modify: `docs/superpowers/specs/2026-10-03-autofix-v3-design.md` (§4.2, §4.3, §5 step 1 and step 5 B-lines, §11 phase 3–4 lines)
- Modify: `CHANGELOG.md` (`[3.0.0] - unreleased` → Added/Fixed)
- Modify: `README.md` (test count only)

- [ ] **Step 1: Update the spec.** Under §4.2, add a dated block "Re-verified 2026-10-03 (Claude Code docs at code.claude.com, CLI 2.1.289)" holding the plan's docs table rows: inheritance, prompts surfacing, nested subagents allowed (3 layers), PostToolUse plain stdout never shown to Claude (hence JSON), and auto mode blocking "Merging a pull request no human has approved" (the merge runs inside bash `autofix ship`; Phase 5 E2E checks the classifier). Replace §5 step 1's "For B it renames the Claude Code worktree branch" with "B uses the same claim worktree (Ruling 1, phase 3 plan)". Replace §5 step 5's B line with "**B:** `found-issues autofix verify <id>` runs the same headless verifier; it records the verdict and the approved tree, and `ship` refuses any other tree (phase 3 Ruling 2)". In §11, change phase 3 to "Plugin agent `found-issues-fixer`, launcher B CLI (`claim`/`brief`/`test`/`verify`), hook launcher selection, Stop fallback, recursion guard" and add "`found-issues-sweeper` agent" to phase 4.

- [ ] **Step 2: Update the CHANGELOG** under `## [3.0.0] - unreleased`:

```markdown
- Launcher B: in a Claude Code session in auto or bypassPermissions mode, a
  queued `(fix: small)` item is fixed in the background by the plugin agent
  `found-issues:found-issues-fixer`, which works only through
  `found-issues autofix claim|brief|test|verify|ship|release`. Other modes
  and Codex start a detached `found-issues autofix run` (launcher A). Items
  still queued when the session stops get launcher A
  (`FOUND_ISSUES_AUTOFIX_STOP_GRACE`, default 60 s). Inside a subagent or a
  fixer nothing launches. `FOUND_ISSUES_AUTOFIX_LAUNCHER=headless` forces
  launcher A.
- `found-issues autofix verify <id>`; `autofix ship` ships only the exact tree
  the verifier approved. `autofix run` refuses unknown ids and exits 3 capped,
  4 locked, 7 engine outage.
```

and under `### Fixed` (create it if missing):

```markdown
- PostToolUse context (annotation suggestions, `--pick` prompts) now reaches
  Claude: Claude Code shows `hookSpecificOutput.additionalContext` to the
  model but writes plain PostToolUse stdout to its debug log only.
```

- [ ] **Step 3: README count** — run:

```bash
n=$(rg -c '^@test ' tests/*.bats | awk -F: '{s+=$2} END{print s}'); sed -i '' -E "s/ [0-9]+ tests on/ $n tests on/" README.md
bats tests/docs-consistency.bats
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-10-03-autofix-v3-design.md CHANGELOG.md README.md
git commit -m "docs(v3): phase 3 rulings, re-verified docs facts, changelog"
```

---

### Task 9: Live probe of launcher B (needs operator approval of about $3)

The only check bats cannot do: a real Claude Code session receives the JSON nudge, starts `found-issues:found-issues-fixer`, and the fixer drives claim → brief → test → verify → ship without any denied or prompting call. Run it only if the operator approves the spend.

**Files:**
- Create: `<scratchpad>/probe-b.sh` (not committed)

- [ ] **Step 1: Write the probe script** (in the session scratchpad, run with `bash <file>`; hazard 12 forbids inline pushes to a `$var` bare remote)

```bash
#!/usr/bin/env bash
set -euo pipefail
WT=/Users/diogosilvasena/Documents/projects/found-issues/.claude/worktrees/v3-phase3
P="$(cd "$(dirname "$0")" && pwd)/probe"
rm -rf "$P"; mkdir -p "$P"
export FOUND_ISSUES_STATE_DIR="$P/state" FOUND_ISSUES_MODE=github-pr FOUND_ISSUES_AUTOFIX_STOP_GRACE=3600
export GH_MOCK_TRACE="$P/gh.trace" GH_MOCK_PR_VIEW=$'7\t{"number":7,"state":"OPEN","statusCheckRollup":[]}'
export PATH="$WT/bin:$WT/tests/bin-shims:$PATH"
git init -q --bare -b main "$P/remote.git"
mkdir -p "$P/repo/src" "$P/repo/docs"; cd "$P/repo"
git init -q -b main; git config user.email p@x; git config user.name p
git remote add origin https://github.com/foo/bar.git
git config url."$P/remote.git".insteadOf https://github.com/foo/bar.git
printf 'add() { echo $(( $1 - $2 )); }\n' > src/calc.sh
printf '. ./src/calc.sh\n[ "$(add 2 3)" = 5 ]\n' > test.sh
printf '# found-issues\n' > docs/found-issues.md
git add -A; git commit -q -m init; git push -q -u origin main
git fetch -q origin; git remote set-head origin main >/dev/null
git config found-issues.autofix true; git config found-issues.autofix.testCommand 'sh test.sh'
claude -p --plugin-dir "$WT" --permission-mode bypassPermissions --max-budget-usd 3 \
  --settings '{"enabledPlugins":{"found-issues@altdoug-plugins":false}}' \
  --output-format json \
  "Run exactly this one Bash command, then follow any found-issues instruction you receive and wait for any agent you start to finish before you reply: found-issues log --fix small 'src/calc.sh:1 — add subtracts instead of adding'" \
  > "$P/result.json" 2> "$P/stderr.txt" || true
echo "--- result"; jq '{is_error, total_cost_usd, num_turns, permission_denials, result: (.result|tostring|.[0:600])}' "$P/result.json"
echo "--- items"; for d in queue running done; do ls "$FOUND_ISSUES_STATE_DIR"/autofix/*/"$d" 2>/dev/null | sed "s/^/$d: /"; done
cat "$FOUND_ISSUES_STATE_DIR"/autofix/*/done/* 2>/dev/null
echo "--- gh"; cat "$GH_MOCK_TRACE" 2>/dev/null
```

- [ ] **Step 2: Run it** with `bash <scratchpad>/probe-b.sh`, timeout 600000.

Expected evidence: `permission_denials: []`; one item in `done/` with `launcher=B` and `result=shipped: PR #7 …`; the gh trace shows `pr create` and `pr merge 7 --auto --squash`. Quote the output verbatim in the PR body. If headless `-p` does not keep a background subagent alive, record that verbatim. B's real-session check then stays in Phase 5 E2E (spec §10). Log any defect found with `./bin/found-issues log`.

---

### Task 10: Full verification, review, PR, post-merge watch

- [ ] **Step 1: Full suite and bash 3.2 subset**

```bash
bats tests/ 2>&1 | tail -5
mkdir -p /private/tmp/claude-501/b32 && ln -sf /bin/bash /private/tmp/claude-501/b32/bash
PATH=/private/tmp/claude-501/b32:$PATH bash "$(command -v bats)" tests/autofix-*.bats tests/post-bash-dispatch.bats tests/stop-reminder.bats tests/codex-wiring.bats tests/hook-gates.bats tests/harness.bats tests/source-guards.bats 2>&1 | tail -5
```

Expected: both exit 0. Quote the summary lines.

- [ ] **Step 2: End-to-end CLI run (the `verify` skill)**: drive the fixture flow through the real entrypoints. Pipe a real-shaped PostToolUse payload into `hooks/post-bash-dispatch.sh` with `permission_mode: bypassPermissions` and see the JSON nudge. Then do `claim`/`test`/`verify`/`ship` with the stand-ins, and pipe a Stop payload into `hooks/stop-reminder.sh` with a second queued item and see `autofix run` spawn. Capture the output verbatim.

- [ ] **Step 3: Whole-branch review** by one read-only opus Agent (`model: opus`; tools limited to Read/Grep/Glob/Bash read-only; told to write nothing and never trigger prompts). Give it the spec, this plan and `git diff origin/release/v3...HEAD`. Fix every Critical and Important finding with RED→GREEN tests. Log the remaining minors with `./bin/found-issues log --fix …`.

- [ ] **Step 4: PR into `release/v3`** — `git status` and `git branch --show-current` first (must be `v3/phase3-launcher-b`). Push with `git push -u origin v3/phase3-launcher-b`. Probe `gh pr create --dry-run` in its own call (pr-verify-gate). If the gate asks, write the skip reason (opus agent review + E2E run as evidence) into the printed `.pr-verify-skipped` path in a separate call. Then `gh pr create --base release/v3`. Run `./bin/found-issues annotate-pr <N> --pick lib/harness.sh:52,lib/autofix.sh:150,lib/autofix-ship.sh:116` only for entries the PR fixes. For `lib/autofix-queue.sh:263`, if Task 3's survival test passed before any code change, resolve it with `./bin/found-issues resolve "standalone autofix claim records its own short-lived pid" --verified ai` and state the evidence in the PR body.

- [ ] **Step 5: Merge and watch** — `GH_PR_MERGE_BASE_GUARD=off gh pr merge <N> --auto --squash` (merges at once: release/v3 has no required checks). Then watch the post-merge `release/v3` push run until it reaches a terminal state: `gh run list -R AltDoug/found-issues --branch release/v3 -L 1`, then `gh run watch <id> --exit-status`. macOS bats (bash 3.2) only runs here. On a failure, read the log, fix it on a new branch, and repeat.

- [ ] **Step 6: Handoff** for Phase 4 (`/handoff`): what shipped, rulings, live probe result, and the Phase 5 reminder to enable auto-fix on this Mac.
