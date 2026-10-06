# Auto-fix on Codex: pinned models and a token cap — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Codex auto-fix children run on fixed per-role models (unless the user picks `inherit`). A Codex run with a token cap set stops starting new children once its token count reaches it, parking the item as `run budget spent (<N> tokens)`. Every cap is opt-in: no token cap, no dollar cap, and no per-sweep entry limit by default. A sweep fixes everything fixable and ships one PR per batch of `autofix.sweepBatch` fixes (default 8).

> **Amended 2026-10-06** (spec Decisions 4-6, relayed by peer session "Autofix Codex"): token caps unset by default (Task 4), Task 3 informs docs only, new Task 5 (dollar caps opt-in) and Task 6 (sweep batches). Visibility is now Task 7 and the release Task 8. Run order: 1, 2, 3, 4, 5, 6, 7, 8. Task 3 needs live Codex runs and an operator checkpoint, so the controller runs it, not a subagent.

**Architecture:** Two new model keys and two new token-cap keys join the existing `_FI_CFG_KEYS` table. One helper builds each Codex role's `-m`/effort argv. One engine-neutral gate, `fi_af_run_budget_left <engine>`, replaces the three `engine == claude` budget guards and adds a gate before classify: dollars for claude (unchanged), tokens for codex. Codex `turn.failed` events become `FI_AF_ENGINE_ERR`, so a rejected model is an outage, not an attempt. Status, the run log, doctor and the PR body show models and tokens against the cap.

**Tech Stack:** bash 3.2+ (macOS system bash), jq, bats-core 1.14, `codex exec --json` (codex-cli 0.160.1 measured), stand-in engines in `tests/standins/`.

**Spec:** `docs/superpowers/specs/2026-10-06-autofix-codex-models-design.md` (approved for planning 2026-10-06). Read it before Task 1.

## Global Constraints

- Release 3.3.0 (minor). If 3.2.1 (baseline test run, ledger `[!] lib/autofix.sh:127`, operator decision 2026-10-06) merges first, start this branch from that `origin/main` and bump `FI_VERSION` from whatever it then reads to `3.3.0`.
- Defaults (operator decision 2026-10-06, models re-checked 2026-10-06 with `codex debug models` on codex-cli 0.160.1: both are listed and both support low/medium/high): `autofix.codexModel` = `gpt-6.1-sol` (fixer `medium`, classifier `low`), `autofix.codexVerifierModel` = `gpt-6-astra` (verifier `high`).
- `inherit` drops BOTH `-m` and the `-c model_reasoning_effort=…` override for that role; `~/.codex/config.toml` decides everything.
- Model values pass through unchanged. found-issues keeps no model list.
- Token caps: `autofix.codexRunTokens` and `autofix.codexSweepTokens` have NO default (unset = no cap; spec Decision 5). Task 3's numbers only produce a suggested value for the docs.
- Dollar caps: `autofix.runBudget` and `autofix.sweepBudget` have NO default (unset = no cap, no `--max-budget-usd`; spec Decision 6, Task 5).
- A set cap is checked before each fix, verify and classify child. One child may overshoot it; there is no streamed mid-child kill in 3.3.0 (operator decision 3).
- With a dollar budget SET, the claude engine's behaviour and outcome text (`run budget spent ($X)`) are unchanged; existing budget tests stay green once they set the budget explicitly.
- Sweeps: `autofix.sweepMax` becomes `autofix.sweepBatch` (fixes per PR, default 8); a set `sweepMax` is read as the batch size when `sweepBatch` is unset (spec §9, Task 6).
- bash 3.2 under `set -euo pipefail` (`bin/found-issues:29`): expand a possibly-empty array as `${A[@]+"${A[@]}"}`, never `"${A[@]}"`.
- bats: test names ASCII only (the PR guard fails on em-dashes); a mid-test negation is `! cmd || false`, never a bare `! cmd`.
- Each task that adds `@test`s bumps the README test count (`README.md:11`; read the current number, it was `1310 tests` at 3.2.1) in the same commit.
- Never `git add -A`; never hand-edit `docs/found-issues.md` (use `./bin/found-issues`).

## Review Focus

1. **`inherit` on one role, a pinned model on the other** (e.g. `codexVerifierModel=inherit`, `codexModel` default): the fixer still gets `-m gpt-6.1-sol -c model_reasoning_effort=medium` and the verifier gets neither. Pinned in Task 1 (`inherit is per role`).
2. **A rejected model on the VERIFIER** (not the fixer): today `_fi_af_fix_loop` treats a verifier with no verdict as a reject, which burns an attempt and tags the entry autofix-failed. Expected: an outage that requeues. Pinned in Task 2 (`a verifier engine error requeues`).
3. **A sweep whose classifier already used tokens**: the cap counts classifier tokens too, and the sweep still ships what it committed before the cap. Pinned in Task 4 (sweep cap test, cap chosen to give "1 fixed" with or without a classify child).
4. **A non-numeric or zero token cap** (`codexRunTokens=lots`, `0`): treated as no cap, with a warning on stderr; `config` refuses to set it. Pinned in Task 4 (`token cap keys`).
5. **A model name with characters a shell or TOML would mangle** (`gpt-6.1-sol`, `org/model:tag`): passed as one argv element, unchanged; `config` refuses whitespace and empty values. Pinned in Task 1 (`config validates model names`).
6. **No cap anywhere** (the new default): a claude child's argv has no `--max-budget-usd`, the gate never stops a run, and nothing prints an empty `$` or `/` (status, doctor, run log, PR body). Pinned in Tasks 4, 5 and 7.
7. **A sweep with more than one batch**: batch 2 never touches a file batch 1 changed, does not take a second daily slot, carries the chain's cost forward, and a failed batch ship queues no continuation. Pinned in Task 6.

---

### Task 1: Per-role Codex models

**Files:**
- Modify: `lib/autofix-config.sh` (header list, `_FI_CFG_KEYS` at `:168-177`, `_fi_cfg_valid` at `:196-216`, new `fi_af_codex_margs` after `fi_af_budget` at `:43-52`)
- Modify: `lib/autofix-engine.sh:172-198` (`fi_af_fixer_cmd`, `fi_af_verifier_cmd`)
- Modify: `lib/autofix-classify.sh:110-114` (codex classifier argv)
- Modify: `lib/autofix.sh` help text (`Settings:` lines, about `:42-44`)
- Test: `tests/autofix-engine.bats`, `tests/autofix-config.bats`

**Interfaces:**
- Produces: `fi_af_codex_margs <fixer|verifier|classifier>`, which sets the array `FI_AF_MARGS` (empty for `inherit`) and the string `FI_AF_MDESC` (`gpt-6.1-sol (medium)` or `inherit`). Tasks 3, 4 and 5 read `FI_AF_MDESC`.
- Produces: config kind `model` (any `^[A-Za-z0-9._:/-]+$`, or `inherit`).

- [ ] **Step 1: Write the failing tests** (append to `tests/autofix-engine.bats`)

```bash
@test "autofix engine: codex roles get pinned models and efforts by default" {
  fi_af_fixer_cmd codex "P" "$TMP/last"
  printf '%s\n' "${FI_AF_CMD[@]}" > "$TMP/fix"
  grep -qx 'gpt-6.1-sol' "$TMP/fix"
  grep -qx 'model_reasoning_effort=medium' "$TMP/fix"
  [ "${FI_AF_CMD[${#FI_AF_CMD[@]}-1]}" = "P" ]
  fi_af_verifier_cmd codex "V" "$TMP/last" "$TMP/schema"
  printf '%s\n' "${FI_AF_CMD[@]}" > "$TMP/ver"
  grep -qx 'gpt-6-astra' "$TMP/ver"
  grep -qx 'model_reasoning_effort=high' "$TMP/ver"
  fi_af_codex_margs classifier
  [ "${FI_AF_MARGS[*]}" = "-m gpt-6.1-sol -c model_reasoning_effort=low" ]
  [ "$FI_AF_MDESC" = "gpt-6.1-sol (low)" ]
}

@test "autofix engine: inherit is per role and drops both -m and effort" {
  git config found-issues.autofix.codexVerifierModel inherit
  fi_af_verifier_cmd codex "V" "$TMP/last" "$TMP/schema"
  printf '%s\n' "${FI_AF_CMD[@]}" > "$TMP/ver"
  ! grep -qx -- '-m' "$TMP/ver" || false
  ! grep -q 'model_reasoning_effort' "$TMP/ver" || false
  grep -qx 'read-only' "$TMP/ver"
  fi_af_fixer_cmd codex "P" "$TMP/last"
  printf '%s\n' "${FI_AF_CMD[@]}" | grep -qx 'gpt-6.1-sol'
  fi_af_codex_margs verifier
  [ "${#FI_AF_MARGS[@]}" -eq 0 ]
  [ "$FI_AF_MDESC" = "inherit" ]
}

@test "autofix engine: a custom codex model passes through as one argv element" {
  git config found-issues.autofix.codexModel 'org/model:tag-1.2'
  fi_af_fixer_cmd codex "P" "$TMP/last"
  printf '%s\n' "${FI_AF_CMD[@]}" | grep -qx 'org/model:tag-1.2'
}

@test "autofix engine: the codex classifier argv carries the classifier model" {
  printf -- '- [open] 2026-10-01 src/calc.sh:1 — untagged thing\n' >> docs/found-issues.md
  export FI_STANDIN_TRACE="$TMP/trace"
  FI_AF_RUNS="$TMP"; AFI_engine=codex
  fi_af_classify docs/found-issues.md t1 || true
  grep -q 'model_reasoning_effort=low' "$TMP/trace"
  grep -q 'gpt-6.1-sol' "$TMP/trace"
}
```

And to `tests/autofix-config.bats`:

```bash
@test "config validates model names" {
  run "$FI_BIN" config autofix.codexModel 'gpt 6'
  [ "$status" -eq 2 ]
  [[ "$output" == *"takes a Codex model name"* ]]
  run "$FI_BIN" config autofix.codexModel inherit
  [ "$status" -eq 0 ]
  run "$FI_BIN" config autofix.codexVerifierModel gpt-6-astra
  [ "$status" -eq 0 ]
  run "$FI_BIN" config
  [[ "$output" == *"found-issues.autofix.codexModel"*"inherit"*"(local)"* ]]
}
```

If `fi_af_classify` needs more fixture than shown (it reads `_fi_af_classify_list` output), copy the setup from the existing classifier tests in `tests/autofix-classify.bats` (`rg -n '@test' tests/autofix-classify.bats`), keeping the two trace asserts.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats tests/autofix-engine.bats tests/autofix-config.bats`
Expected: the five new tests FAIL (`fi_af_codex_margs: command not found`, no `gpt-6.1-sol` in argv, `unknown setting autofix.codexModel`); all old tests pass.

- [ ] **Step 3: Implement**

`lib/autofix-config.sh` — add two rows to `_FI_CFG_KEYS` after `autofix.engine`:

```
autofix.codexModel|model|gpt-6.1-sol
autofix.codexVerifierModel|model|gpt-6-astra
```

Add a `model)` case to `_fi_cfg_valid`, before `text)`:

```bash
    model)
      [[ "$FI_CFG_VAL" =~ ^[A-Za-z0-9._:/-]+$ ]] \
        || { fi_err "config: found-issues.$FI_CFG_KEY takes a Codex model name (e.g. gpt-6.1-sol) or inherit"; return 1; } ;;
```

Add the helper after `fi_af_budget` (and `#   fi_af_codex_margs <role>` to the header list):

```bash
# 3.3.0 spec §1: the -m/effort pair for one Codex role. Effort is fixed per
# role in code, as the claude engine's is. inherit leaves both out, so the
# user's ~/.codex/config.toml decides. Sets FI_AF_MARGS and FI_AF_MDESC.
FI_AF_MARGS=() FI_AF_MDESC=""
fi_af_codex_margs() {
  local key=codexModel def=gpt-6.1-sol effort=medium m
  case "$1" in
    classifier) effort=low ;;
    verifier) key=codexVerifierModel def=gpt-6-astra effort=high ;;
  esac
  m="$(fi_af_cfg "$key" "$def")"
  FI_AF_MARGS=()
  if [[ "$m" == inherit ]]; then FI_AF_MDESC=inherit; return 0; fi
  FI_AF_MARGS=(-m "$m" -c "model_reasoning_effort=$effort")
  FI_AF_MDESC="$m ($effort)"
}
```

`lib/autofix-engine.sh` — codex branches:

```bash
  if [[ "$engine" == "codex" ]]; then
    fi_af_codex_margs fixer
    FI_AF_CMD=(codex exec --sandbox workspace-write -C "$AFI_wt" --ephemeral --json
      ${FI_AF_MARGS[@]+"${FI_AF_MARGS[@]}"} -o "$last" "$prompt")
```

```bash
  if [[ "$engine" == "codex" ]]; then
    printf '%s\n' '{"type":"object",…unchanged…}' >"$schema"
    fi_af_codex_margs verifier
    FI_AF_CMD=(codex exec --sandbox read-only -C "$AFI_wt" --ephemeral --json
      ${FI_AF_MARGS[@]+"${FI_AF_MARGS[@]}"} --output-schema "$schema" -o "$last" "$prompt")
```

(The verifier's literal `-c model_reasoning_effort=high` goes away; `fi_af_codex_margs verifier` now supplies it.)

`lib/autofix-classify.sh` — codex branch:

```bash
    fi_af_codex_margs classifier
    FI_AF_CMD=(codex exec --sandbox read-only -C "$AFI_wt" --ephemeral --json
      ${FI_AF_MARGS[@]+"${FI_AF_MARGS[@]}"}
      --output-schema "$base.schema.json" -o "$base.last" "$(_fi_af_classify_prompt "$list")")
```

`lib/autofix.sh` help, `Settings:` block:

```
found-issues.autofix.{engine,testCommand,dailyFixes,runBudget,runTimeoutMin,
dailySweeps,sweepThreshold,sweepMax,sweepBudget,codexModel,codexVerifierModel}.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats tests/autofix-engine.bats tests/autofix-config.bats tests/autofix-classify.bats tests/autofix-run.bats`
Expected: all pass, including the existing `codex argv - workspace-write fixer, read-only verifier` (it still finds `model_reasoning_effort=high`).

- [ ] **Step 5: Bump the README count (+5) and commit**

```bash
git add lib/autofix-config.sh lib/autofix-engine.sh lib/autofix-classify.sh lib/autofix.sh \
  tests/autofix-engine.bats tests/autofix-config.bats README.md
git commit -m "feat(autofix): pin Codex models per role, with inherit as the opt-out"
```

---

### Task 2: Codex engine errors become outages (fixer and verifier)

Measured 2026-10-06, codex-cli 0.160.1, `codex exec -m no-such-model-xyz --json`: exit 1; stdout ends with

```
{"type":"error","message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'no-such-model-xyz' model is not supported when using Codex with a ChatGPT account.\"}}"}
{"type":"turn.failed","error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'no-such-model-xyz' model is not supported when using Codex with a ChatGPT account.\"}}"}}
```

and the last stderr line is `Reading additional input from stdin...`. So today the fixer's outage text is `codex exited 1: Reading additional input from stdin...`, and a verifier on a bad model reads as "no parseable verdict", a REJECT that burns an attempt.

**Files:**
- Modify: `lib/autofix-engine.sh:200-217` (`fi_af_collect` codex branch)
- Modify: `lib/autofix.sh` (`_fi_af_fix_loop`, right after `_fi_af_verify "$engine" "$n"`)
- Modify: `tests/standins/codex` (new `FI_STANDIN_CODEX_FAIL`)
- Test: `tests/autofix-engine.bats`, `tests/autofix-run.bats`

**Interfaces:**
- Consumes: nothing new.
- Produces: `fi_af_collect codex …` sets `FI_AF_ENGINE_ERR` to the inner `error.message` of the last `turn.failed` event (empty when none), and `FI_AF_CHILD_TOKENS` to this child's tokens (Task 7 logs it).

- [ ] **Step 1: Teach the stand-in to fail like Codex.** In `tests/standins/codex`, just before the final two `printf` lines:

```bash
if [[ -n "${FI_STANDIN_CODEX_FAIL:-}" && ( "$sandbox" == "$FI_STANDIN_CODEX_FAIL" || "$FI_STANDIN_CODEX_FAIL" == all ) ]]; then
  printf '{"type":"thread.started"}\n'
  printf '%s\n' '{"type":"turn.failed","error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The '"'"'bad-model'"'"' model is not supported when using Codex with a ChatGPT account.\"}}"}}'
  echo 'Reading additional input from stdin...' >&2
  exit 1
fi
```

(`FI_STANDIN_CODEX_FAIL=read-only` fails only the verifier, `workspace-write` only the fixer, `all` both. The early exit also skips writing `-o`.)

- [ ] **Step 2: Write the failing tests**

`tests/autofix-engine.bats`:

```bash
@test "autofix engine: a codex turn.failed becomes the engine error text" {
  FI_AF_TOKENS=0
  FI_STANDIN_CODEX_FAIL=all codex exec -o "$TMP/last" "x" > "$TMP/f.jsonl" 2>/dev/null || true
  fi_af_collect codex "$TMP/f.jsonl" "$TMP/last"
  [ "$FI_AF_ENGINE_ERR" = "The 'bad-model' model is not supported when using Codex with a ChatGPT account." ]
  [ "$FI_AF_TOKENS" = 0 ]
  codex exec -o "$TMP/last" "x" > "$TMP/ok.jsonl"
  fi_af_collect codex "$TMP/ok.jsonl" "$TMP/last"
  [ -z "$FI_AF_ENGINE_ERR" ]
  [ "$FI_AF_CHILD_TOKENS" = 1500 ]
}
```

`tests/autofix-run.bats`:

```bash
@test "autofix run: a codex fixer on a rejected model requeues as an outage" {
  export FI_STANDIN_CODEX_FAIL=workspace-write
  run "$FI_BIN" autofix run "$ID" --engine codex
  [ "$status" -eq 7 ]
  [ -f "$ST/queue/$ID" ]
  grep -q "requeued: engine error: The 'bad-model' model is not supported" "$FI_AF_RUNS/$ID.log"
  ! grep -q 'autofix-failed' "$REPO/docs/found-issues.md" || false
}

@test "autofix run: a verifier engine error requeues instead of counting as a reject" {
  export FI_STANDIN_CODEX_FAIL=read-only
  run "$FI_BIN" autofix run "$ID" --engine codex
  [ "$status" -eq 7 ]
  [ -f "$ST/queue/$ID" ]
  [ ! -d "$REPO/.claude/worktrees/fi-autofix-$ID" ]
  ! grep -q 'autofix-failed' "$REPO/docs/found-issues.md" || false
}
```

(`FI_AF_RUNS` is set in the test shell by `fi_af_queue_fixture`, which sources the CLI; it is `$FOUND_ISSUES_CACHE_DIR/…/autofix/<key>/runs`, `lib/autofix-config.sh:79`.)

- [ ] **Step 3: Run them to verify they fail**

Run: `bats tests/autofix-engine.bats tests/autofix-run.bats`
Expected: the engine test FAILS (`FI_AF_ENGINE_ERR` empty); the verifier run test FAILS (status 0, the entry tagged `autofix-failed: verifier rejected: no parseable verdict…`); the fixer run test FAILS on the log text (it says `codex exited 1: Reading additional input from stdin...`).

- [ ] **Step 4: Implement.** `fi_af_collect`, codex branch:

```bash
  if [[ "$engine" == "codex" ]]; then
    [[ -n "$last" && -f "$last" ]] && FI_AF_TEXT="$(cat "$last")"
    t="$(jq -s '[.[] | select(.type=="turn.completed") | (.usage.input_tokens // 0) + (.usage.output_tokens // 0)] | add // 0' "$out" 2>/dev/null || true)"
    [[ "$t" =~ ^[0-9]+$ ]] || t=0
    FI_AF_CHILD_TOKENS="$t"
    FI_AF_TOKENS=$((FI_AF_TOKENS + t))
    # 3.3.0 spec §4: a rejected model (or any failed turn) is an outage.
    # Measured: the message is a JSON error envelope inside a string.
    FI_AF_ENGINE_ERR="$(jq -rs '[.[] | select(.type=="turn.failed") | (.error.message // "turn failed")] | last // empty | ((fromjson? | .error.message // .message) // .)' "$out" 2>/dev/null || true)"
    FI_AF_ENGINE_ERR="${FI_AF_ENGINE_ERR//$'\n'/ }"
```

Add `FI_AF_CHILD_TOKENS=0` to the globals at the top of the file.

`_fi_af_fix_loop` in `lib/autofix.sh`, directly after `_fi_af_verify "$engine" "$n"`:

```bash
    # A verifier that could not run (outage, rejected model) is not a reject.
    if [[ -n "$FI_AF_ENGINE_ERR" ]]; then
      FI_AF_OUTCOME=outage FI_AF_OUTCOME_TEXT="$FI_AF_ENGINE_ERR"; return 0
    fi
```

(The spot path requeues and removes the worktree, `fi_af_requeue`; the sweep path logs, resets the worktree and stops, `_fi_af_run_sweep`'s `outage)` case. Both already exist. Claude's verifier only sets `FI_AF_ENGINE_ERR` on `is_error`/`error_*`, so claude rejects are unchanged.)

- [ ] **Step 5: Run to verify they pass**

Run: `bats tests/autofix-engine.bats tests/autofix-run.bats tests/autofix-sweep.bats tests/autofix-b.bats`
Expected: all pass.

- [ ] **Step 6: Bump the README count (+3) and commit**

```bash
git add lib/autofix-engine.sh lib/autofix.sh tests/standins/codex tests/autofix-engine.bats tests/autofix-run.bats README.md
git commit -m "fix(autofix): a failed Codex turn is an outage, also on the verifier"
```

---

### Task 3: Live measurement (spec §6, "Task 0")

No code. Amended (spec Decision 5): it no longer sets defaults. It produces a SUGGESTED token cap for the docs (Task 8) and answers whether `codex exec --json` streams usage before `turn.completed`. The controller runs it (live Codex usage, an operator checkpoint), not a subagent. Run it after Tasks 1-2 (it needs the pinned models).

**Files:**
- Create: `docs/e2e/v3.3-codex-tokens-2026-10-XX.md` (XX = the day it runs)

**Interfaces:**
- Produces: `RUN_CAP` and `SWEEP_CAP`, two integers that Task 8 quotes in `docs/configuration.md` as suggested values ("e.g."). Nothing in code uses them.

- [ ] **Step 1: Recreate the throwaway repo** the way the 3.0.0/3.2.0 e2e did (read `docs/e2e/v3-live-e2e-2026-10-04.md` for the fixture shape: a small `src/` with one-line bugs, `test.sh`, a ledger with `(fix: small)` entries). `gh repo create AltDoug/fi-v3-e2e --private`, push the fixture, set `found-issues.autofix true` and `autofix.testCommand "sh test.sh"` locally. Seed 6 fixable entries: 3 for spot runs, plus 3 for one sweep (`autofix.sweepThreshold 3`).

- [ ] **Step 2: Run 3 spot fixes and 1 sweep on the branch CLI with the pinned defaults.** Use this checkout's `bin/found-issues` by absolute path (the installed plugin CLI is older): `"$BR/bin/found-issues" autofix run <id> --engine codex`, one at a time. After each, record from `~/.claude/found-issues/autofix/AltDoug__fi-v3-e2e/runs/<id>.log` and the `done/<id>` file: `tokens=`, per-child tokens (`jq -s '[.[]|select(.type=="turn.completed")|.usage]' <id>.fix1.out`, `.verify1.out`, `.classify.out`), wall time and result.

- [ ] **Step 3: Repeat with `inherit`** on both keys (3 spot fixes + 1 sweep, fresh entries). Record the same numbers.

- [ ] **Step 4: Streaming usage check.** `jq -c 'select(.usage) | .type' <id>.fix1.out | sort | uniq -c`. If any type other than `turn.completed` carries usage, write that down for a future release; 3.3.0 does NOT change (operator decision 3).

- [ ] **Step 5: Write the e2e doc and compute the suggested caps.** A table per run (role, model, effort, tokens, seconds); `RUN_CAP` = 3 × the median pinned-model spot `tokens=`, rounded up to the next 100000; `SWEEP_CAP` = 3 × the pinned-model sweep `tokens=`, rounded up to the next 100000. If the pinned numbers are within 20% of 600000/3 and 1500000/3, keep 600000 / 1500000 and say so. These are suggestions for the docs; the keys stay unset by default. Note that a 3.3.0 sweep has no entry limit, so the sweep number is per sweep of the measured size.

- [ ] **Step 6: Operator checkpoint, then delete the repo.** Ask via AskUserQuestion: "Delete AltDoug/fi-v3-e2e now?" (recommended: yes, the doc holds the numbers). Only on yes: `GH_REPO_DELETE_GUARD=off gh repo delete AltDoug/fi-v3-e2e --yes`. Close any PRs the runs opened first if the operator says keep.

- [ ] **Step 7: Commit the doc**

```bash
git add docs/e2e/v3.3-codex-tokens-2026-10-XX.md
git commit -m "docs(e2e): measure Codex tokens per role for the 3.3.0 cap defaults"
```

---

### Task 4: Token cap

**Files:**
- Modify: `lib/autofix-config.sh` (`_FI_CFG_KEYS`, new `fi_af_cap_int` after `fi_af_int`)
- Modify: `lib/autofix-engine.sh` (after `fi_af_budget_left` at `:249-251`, header list)
- Modify: `lib/autofix.sh:101-103` and `:131-133` (`_fi_af_fix_loop` guards)
- Modify: `lib/autofix-b.sh:135-141` (`autofix verify` guard)
- Modify: `lib/autofix-classify.sh` (`fi_af_classify`, gate after the engine is resolved)
- Modify: `tests/standins/codex` (`FI_STANDIN_TOKENS`)
- Test: `tests/autofix-engine.bats`, `tests/autofix-config.bats`, `tests/autofix-run.bats`, `tests/autofix-sweep.bats`, `tests/autofix-b.bats`

**Interfaces:**
- Consumes: `FI_AF_TOKENS` (existing). Nothing from Task 3 (amended: caps are opt-in).
- Produces: `fi_af_cap_int <key>` (prints a set positive integer; prints nothing when unset; warns and prints nothing when invalid), `fi_af_token_cap` (prints the cap for `AFI_kind`, or nothing when no cap is set), `fi_af_tokens_left` (rc 1 at or past a set cap, else prints what is left; rc 0 and prints nothing when no cap), `fi_af_run_budget_left <engine>` (rc 0 = may start another child), `fi_af_spent_text <engine>` (`run budget spent ($X)` | `run budget spent (<N> tokens)`). Task 5 reuses `fi_af_run_budget_left`; Task 7 uses `fi_af_token_cap`.

- [ ] **Step 1: Stand-in token knob.** In `tests/standins/codex` replace the final `turn.completed` line with:

```bash
printf '{"type":"turn.completed","usage":{"input_tokens":%s,"cached_input_tokens":0,"output_tokens":300}}\n' "${FI_STANDIN_TOKENS:-1200}"
```

(Default stays 1200 + 300 = 1500 per child; every existing token assert keeps passing.)

- [ ] **Step 2: Write the failing tests**

`tests/autofix-engine.bats`:

```bash
@test "autofix engine: tokens left shrink with use and run out at the cap" {
  git config found-issues.autofix.codexRunTokens 1000
  FI_AF_TOKENS=400
  [ "$(fi_af_tokens_left)" = 600 ]
  fi_af_run_budget_left codex
  FI_AF_TOKENS=1000
  run fi_af_tokens_left
  [ "$status" -eq 1 ]
  ! fi_af_run_budget_left codex || false
  [ "$(fi_af_spent_text codex)" = "run budget spent (1000 tokens)" ]
  FI_AF_COST=0.50
  [ "$(fi_af_spent_text claude)" = 'run budget spent ($0.50)' ]
  fi_af_run_budget_left claude
  AFI_kind=sweep
  git config found-issues.autofix.codexSweepTokens 5000
  [ "$(fi_af_token_cap)" = 5000 ]
}

@test "autofix engine: no token cap set means the codex gate never stops" {
  FI_AF_TOKENS=999999999
  [ -z "$(fi_af_token_cap)" ]
  fi_af_tokens_left
  [ -z "$(fi_af_tokens_left)" ]
  fi_af_run_budget_left codex
}
```

`tests/autofix-config.bats`:

```bash
@test "config: token cap keys are unset by default, validate and fall back to no cap" {
  [ -z "$(fi_af_token_cap)" ]
  run "$FI_BIN" config autofix.codexRunTokens 0
  [ "$status" -eq 2 ]
  git config found-issues.autofix.codexSweepTokens lots
  run fi_af_cap_int codexSweepTokens
  [[ "$output" == *"not a positive integer"* ]]
  [ "${lines[${#lines[@]}-1]}" != lots ]
  AFI_kind=sweep
  [ -z "$(fi_af_token_cap 2>/dev/null)" ]
  run "$FI_BIN" config
  [[ "$output" == *"found-issues.autofix.codexRunTokens"* ]]
  [[ "$output" == *"found-issues.autofix.codexSweepTokens"* ]]
}
```

(The warning goes to stderr, which bats `run` merges into `output`; the cap itself prints nothing. Check how `fi_cfg_show_line` renders an empty default (`testCommand` already has one) and assert that word, e.g. `none`, for both keys.)

`tests/autofix-run.bats`:

```bash
@test "autofix run: codex stops at the token cap before the verifier" {
  git config found-issues.autofix.codexRunTokens 1000
  run "$FI_BIN" autofix run "$ID" --engine codex
  [ "$status" -eq 0 ]
  grep -q '^result=failed: run budget spent (1500 tokens)' "$ST/done/$ID"
  grep -q '(autofix-failed: run budget spent (1500 tokens))' "$REPO/docs/found-issues.md"
  [ "$(grep -c 'read-only' "$FI_STANDIN_TRACE")" = 0 ]
}

@test "autofix run: the claude budget ignores the codex token cap" {
  git config found-issues.autofix.codexRunTokens 1
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '^result=shipped' "$ST/done/$ID"
}
```

(Check the exact `result=` and ledger tag forms against the existing claude budget test at `tests/autofix-run.bats:93-99` and keep the same shape; the claude one asserts `(autofix-failed: run budget spent`.)

`tests/autofix-sweep.bats` (mirror of `the run budget stops the sweep without failing the current entry`, `:347-353`):

```bash
@test "sweep run: the codex token cap stops the sweep and ships what it committed" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock
  # 1500 tokens per child: with or without a classify child, entry 1 is
  # fixed and verified and the cap stops entry 2 before its verifier.
  git config found-issues.autofix.codexSweepTokens 3500
  sweep_queue
  "$FI_BIN" autofix run "$SID" --engine codex
  grep -q '^result=shipped: PR #9, 1 fixed' "$ST/done/$SID"
  ! grep -q 'autofix-failed' docs/found-issues.md || false
}
```

`tests/autofix-b.bats` — find the existing claude budget test for `autofix verify` (`rg -n 'budget' tests/autofix-b*.bats`; if there is none, use the setup of the first `autofix verify` test in that file) and add:

```bash
@test "autofix verify (launcher B): a codex item past its token cap fails without a verifier" {
  # <setup copied from the file's first `autofix verify` test, claimed with engine=codex>
  fi_af_item_set "$ST/running/$ID" engine codex
  fi_af_item_set "$ST/running/$ID" tokens 700000
  git config found-issues.autofix.codexRunTokens 600000
  run "$FI_BIN" autofix verify "$ID"
  [ "$status" -eq 6 ]
  [[ "$output" == *"failed: run budget spent; stop"* ]]
  ! grep -q 'read-only' "$FI_STANDIN_TRACE" 2>/dev/null || false
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `bats tests/autofix-engine.bats tests/autofix-config.bats tests/autofix-run.bats tests/autofix-sweep.bats tests/autofix-b.bats`
Expected: the new tests FAIL (`fi_af_tokens_left: command not found`; the codex run ships PR #7; the sweep reports `2 fixed` or more; B verify runs the verifier). The claude-ignores-cap test passes already, which is correct: it guards the change.

- [ ] **Step 4: Implement**

`_FI_CFG_KEYS`, after `autofix.sweepBudget` (empty default = no cap, spec Decision 5):

```
autofix.codexRunTokens|int|
autofix.codexSweepTokens|int|
```

`lib/autofix-config.sh`, after `fi_af_int` (and in the header list):

```bash
# 3.3.0: an opt-in cap. Unset prints nothing (no cap); a value that is not a
# positive integer warns and also means no cap.
fi_af_cap_int() {
  local v
  v="$(fi_af_cfg "$1" "")"
  [[ -n "$v" ]] || return 0
  if [[ ! "$v" =~ ^[0-9]+$ ]] || (( 10#$v < 1 )); then
    fi_err "found-issues: found-issues.autofix.$1=$v is not a positive integer — no cap"
    return 0
  fi
  printf '%s' "$((10#$v))"
}
```

`lib/autofix-engine.sh`, after `fi_af_budget_left` (and the four names in the header list):

```bash
# 3.3.0 spec §2: Codex reports tokens, not dollars, so its runs stop on a
# token cap instead (a sweep has its own). Opt-in: unset = no cap (Decision
# 5). Checked before each child; one child may overshoot (Decision 3).
fi_af_token_cap() {
  if [[ "${AFI_kind:-}" == "sweep" ]]; then fi_af_cap_int codexSweepTokens
  else fi_af_cap_int codexRunTokens; fi
}

fi_af_tokens_left() {
  local cap
  cap="$(fi_af_token_cap)"
  [[ -n "$cap" ]] || return 0
  (( FI_AF_TOKENS < cap )) || return 1
  printf '%s' $(( cap - FI_AF_TOKENS ))
}

# Engine-neutral gate: dollars for claude, tokens for codex.
fi_af_run_budget_left() {
  if [[ "$1" == codex ]]; then fi_af_tokens_left >/dev/null
  else fi_af_budget_left >/dev/null; fi
}

fi_af_spent_text() {
  if [[ "$1" == codex ]]; then printf 'run budget spent (%s tokens)' "$FI_AF_TOKENS"
  else printf 'run budget spent ($%s)' "$FI_AF_COST"; fi
}
```

`lib/autofix.sh`, both guards in `_fi_af_fix_loop` become:

```bash
    if ! fi_af_run_budget_left "$engine"; then
      why="$(fi_af_spent_text "$engine")"; break
    fi
```

`lib/autofix-b.sh`, the guard in `autofix verify`:

```bash
  if ! fi_af_run_budget_left "$engine"; then
    if (( sweep )); then
      printf '%s: run found-issues autofix ship %s\n' "$(fi_af_spent_text "$engine")" "$id"; return 6
    fi
    fi_af_finish "$id" failed "$(fi_af_spent_text "$engine")"
    printf 'failed: run budget spent; stop\n'; return 6
  fi
```

`lib/autofix-classify.sh`, in `fi_af_classify` right after the `command -v "$engine"` check:

```bash
  if ! fi_af_run_budget_left "$engine"; then
    fi_af_log "$id" "classify: skipped ($(fi_af_spent_text "$engine"))"; return 0
  fi
```

(The sweep loop's `"run budget spent"*` match in `_fi_af_run_sweep` and the `case "$why"` in `_fi_af_fix_loop` already accept both texts.)

- [ ] **Step 5: Run to verify they pass**

Run: `bats tests/autofix-engine.bats tests/autofix-config.bats tests/autofix-run.bats tests/autofix-sweep.bats tests/autofix-b.bats tests/autofix-classify.bats`
Expected: all pass, including `a spent budget stops before the next child` and `the run budget stops the sweep without failing the current entry` (claude, unchanged).

- [ ] **Step 6: Bump the README count (+7) and commit**

```bash
git add lib/autofix-config.sh lib/autofix-engine.sh lib/autofix.sh lib/autofix-b.sh lib/autofix-classify.sh \
  tests/standins/codex tests/autofix-engine.bats tests/autofix-config.bats tests/autofix-run.bats \
  tests/autofix-sweep.bats tests/autofix-b.bats README.md
git commit -m "feat(autofix): stop Codex runs at a per-run token cap"
```

---

### Task 5: Dollar caps become opt-in (spec §8, Decision 6)

**Files:**
- Modify: `lib/autofix-config.sh` (`_FI_CFG_KEYS` `runBudget`/`sweepBudget` defaults, `fi_af_budget` `:41-52` and its header comment)
- Modify: `lib/autofix-engine.sh` (`fi_af_budget_left` `:248-251`, `fi_af_fixer_cmd`, `fi_af_verifier_cmd`, new `fi_af_budget_args`)
- Modify: `lib/autofix-classify.sh:117` (classifier argv)
- Modify: `lib/autofix-status.sh:280-282` (doctor `Caps:` line)
- Modify: `commands/setup.md:338-340` (disclosure), then regenerate `codex-skills/fi-setup` the way `tests/codex-skills-drift.bats` expects (read that test for the generator command)
- Test: `tests/autofix-engine.bats`, `tests/autofix-run.bats`, `tests/autofix-config.bats`, `tests/autofix-doctor.bats`, `tests/setup-autofix-disclosure.bats`, `tests/cli-config.bats`

**Interfaces:**
- Consumes: `fi_af_run_budget_left <engine>` (Task 4).
- Produces: `fi_af_budget` prints the dollar cap for `AFI_kind`, or nothing when unset. `fi_af_budget_left` returns rc 0 and prints nothing when no budget is set. `fi_af_budget_args` sets the array `FI_AF_BARGS` to `(--max-budget-usd <left>)` when a budget is set, else to an empty array. Task 6 relies on unset meaning unlimited for a whole sweep chain.

- [ ] **Step 1: Write the failing tests**

`tests/autofix-engine.bats`: in the existing first test (the claude fixer argv test, `:15-35`), change `grep -qx -- '--max-budget-usd' "$TMP/argv"` to `! grep -qx -- '--max-budget-usd' "$TMP/argv" || false`, then add:

```bash
@test "autofix engine: a set runBudget puts --max-budget-usd on every claude child" {
  git config found-issues.autofix.runBudget 2
  fi_af_allowlist 'sh test.sh'
  fi_af_fixer_cmd claude "P" "$TMP/last"
  printf '%s\n' "${FI_AF_CMD[@]}" > "$TMP/argv"
  grep -qx -- '--max-budget-usd' "$TMP/argv"
  grep -qx '2.00' "$TMP/argv"
  fi_af_verifier_cmd claude "P" "$TMP/last" "$TMP/schema"
  printf '%s\n' "${FI_AF_CMD[@]}" > "$TMP/argv"
  grep -qx -- '--max-budget-usd' "$TMP/argv"
}

@test "autofix engine: no budget set means no dollar cap" {
  FI_AF_COST=500
  [ -z "$(fi_af_budget)" ]
  fi_af_budget_left
  [ -z "$(fi_af_budget_left)" ]
  fi_af_run_budget_left claude
  fi_af_verifier_cmd claude "P" "$TMP/last" "$TMP/schema"
  printf '%s\n' "${FI_AF_CMD[@]}" > "$TMP/argv"
  ! grep -qx -- '--max-budget-usd' "$TMP/argv" || false
}
```

(Match the setup lines the neighbouring tests use; if `fi_af_verifier_cmd` needs `AFI_wt`/`AFI_id`, copy them from the existing verifier argv test.)

`tests/autofix-run.bats`, after `a spent budget stops before the next child`:

```bash
@test "autofix run: with no budget set a claude run never stops on cost" {
  export FI_STANDIN_COST=50
  run "$FI_BIN" autofix run "$ID" --engine claude
  [ "$status" -eq 0 ]
  grep -q '^result=shipped' "$ST/done/$ID"
  ! grep -q -- '--max-budget-usd' "$FI_STANDIN_TRACE" || false
}
```

(Check that the stand-in trace records argv; if it records only the program name, drop the last line: the engine test above pins argv.)

`tests/autofix-doctor.bats`:

```bash
@test "doctor auto-fix: unset caps read as no cap" {
  run "$FI_BIN" doctor
  [[ "$output" == *"no dollar cap per run"* ]]
  [[ "$output" == *"no dollar cap per sweep"* ]]
  git config found-issues.autofix.runBudget 3
  run "$FI_BIN" doctor
  [[ "$output" == *'$3 per run'* ]]
}
```

`tests/setup-autofix-disclosure.bats`, the `the caps it states are the code defaults` test: replace the `\$3 per fix run, \$10 per sweep, 20 minutes per run` line and the two `key=runBudget def=3` / `key=sweepBudget def=10` lines with:

```bash
  grep -q 'no dollar cap unless you set one' "$S"
  grep -q '20 minutes per run' "$S"
  grep -qF 'autofix.runBudget|usd|' "$TEST_REPO_ROOT/lib/autofix-config.sh"
  grep -qF 'autofix.sweepBudget|usd|' "$TEST_REPO_ROOT/lib/autofix-config.sh"
```

(`autofix.runBudget|usd|` followed by end of line: use `grep -qx 'autofix.runBudget|usd|'` if the key table lines have no leading spaces; check.)

`tests/autofix-config.bats` / `tests/cli-config.bats`: wherever a test relies on the $3 / $10 defaults (`rg -n 'runBudget|sweepBudget|budget' tests/`), set the budget explicitly in that test. Add one assertion that `"$FI_BIN" config autofix.runBudget` with nothing set reports the key as unset (the same word `testCommand` shows when unset).

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/autofix-engine.bats tests/autofix-run.bats tests/autofix-doctor.bats tests/setup-autofix-disclosure.bats tests/autofix-config.bats tests/cli-config.bats`
Expected: the new and changed tests FAIL (the default argv still has `--max-budget-usd`; the $50 stand-in run stops on budget; doctor prints `$3 per run`).

- [ ] **Step 3: Implement**

`_FI_CFG_KEYS`:

```
autofix.runBudget|usd|
autofix.sweepBudget|usd|
```

`fi_af_budget` (`lib/autofix-config.sh`), comment and body:

```bash
# Dollar cap for this run, or nothing: opt-in since 3.3.0 (spec §8). A
# sweep has its own key, which covers every batch of the sweep.
fi_af_budget() {
  local v key=runBudget
  [[ "${AFI_kind:-}" == "sweep" ]] && key=sweepBudget
  v="$(fi_af_cfg "$key" "")"
  [[ -n "$v" ]] || return 0
  if [[ ! "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    fi_err "found-issues: found-issues.autofix.$key=$v is not a USD amount — no dollar cap"
    return 0
  fi
  printf '%s' "$v"
}
```

`lib/autofix-engine.sh`:

```bash
# Spec §7/§8: runBudget caps the whole run (every child) when set; unset is
# no cap (3.3.0, Decision 6).
fi_af_budget_left() {
  local b
  b="$(fi_af_budget)"
  [[ -n "$b" ]] || return 0
  awk -v b="$b" -v s="$FI_AF_COST" 'BEGIN { l = b - s; if (l < 0.10) exit 1; printf "%.2f", l }'
}

# The claude child's --max-budget-usd, only when a budget is set.
fi_af_budget_args() {
  local b
  FI_AF_BARGS=()
  [[ -n "$(fi_af_budget)" ]] || return 0
  b="$(fi_af_budget_left || printf '0.10')"
  FI_AF_BARGS=(--max-budget-usd "$b")
}
```

In `fi_af_fixer_cmd`, `fi_af_verifier_cmd` (`lib/autofix-engine.sh`) and the classifier (`lib/autofix-classify.sh:117`), call `fi_af_budget_args` before building the claude argv, and replace `--max-budget-usd "$(fi_af_budget_left || printf '0.10')"` with `${FI_AF_BARGS[@]+"${FI_AF_BARGS[@]}"}` (bash 3.2: an empty array must use this form). Declare `FI_AF_BARGS=()` at the top of `lib/autofix-engine.sh` with the other globals.

Doctor `Caps:` line (`lib/autofix-status.sh:280-282`): keep the other fields; print each dollar cap as `$<n> per run` / `$<n> per sweep` when set, else `no dollar cap per run` / `no dollar cap per sweep`. Task 6 changes the `up to %s entries` part, so leave that field as is here.

`commands/setup.md:340`: replace `$3 per fix run, $10 per sweep, 20 minutes per run` with `20 minutes per run. Runs have no dollar cap unless you set one (found-issues config autofix.runBudget <usd>, autofix.sweepBudget <usd>)`, keeping the rest of the sentence. Make sure the line contains `no dollar cap unless you set one` and `20 minutes per run`. Regenerate the Codex skill copy.

- [ ] **Step 4: Run to verify they pass**

Run: `bats tests/autofix-engine.bats tests/autofix-run.bats tests/autofix-doctor.bats tests/setup-autofix-disclosure.bats tests/autofix-config.bats tests/cli-config.bats tests/codex-skills-drift.bats tests/autofix-sweep.bats tests/autofix-classify.bats tests/autofix-b.bats`
Expected: all pass. That includes `a spent budget stops before the next child` and `the run budget stops the sweep without failing the current entry`, which already set a budget.

- [ ] **Step 5: Bump the README count (+4) and commit**

```bash
git add lib/autofix-config.sh lib/autofix-engine.sh lib/autofix-classify.sh lib/autofix-status.sh \
  commands/setup.md codex-skills/fi-setup tests/autofix-engine.bats tests/autofix-run.bats \
  tests/autofix-doctor.bats tests/setup-autofix-disclosure.bats tests/autofix-config.bats tests/cli-config.bats README.md
git commit -m "feat(autofix): dollar caps are opt-in; no --max-budget-usd when unset"
```

---

### Task 6: Sweep batches (spec §9, Decision 4)

**Files:**
- Modify: `lib/autofix-config.sh` (`_FI_CFG_KEYS`: `autofix.sweepMax|int|8` → `autofix.sweepBatch|int|8`; new `fi_af_sweep_batch`)
- Modify: `lib/autofix-sweep.sh` (`fi_af_sweep_claim` `:226-279`, `_fi_af_sweep_ready` `:175-192`, `_fi_af_run_sweep` `:360-403`, `fi_af_sweep_finish` `:421-436`, `fi_af_sweep_ship` title `:500`, header list)
- Modify: `lib/autofix-status.sh` (sweep rows: `sweep (batch <n>)`; doctor `Caps:` field `up to %s entries` → `%s fixes per PR`)
- Modify: `lib/help.sh:86` (`autofix run <sweep-id>` description), `commands/setup.md:338,355-362` (the "up to 8" wording), Codex skill copy
- Test: `tests/autofix-sweep.bats`, `tests/cli-config.bats`, `tests/setup-autofix-disclosure.bats`, `tests/autofix-status.bats`

**Interfaces:**
- Consumes: `fi_af_budget` / `fi_af_token_cap` (Tasks 4-5): unset means the chain runs until no entry is left.
- Produces: `fi_af_sweep_batch` (prints `sweepBatch`, else a set `sweepMax`, else 8). Sweep item fields `cont` (batch number, empty or 1 for the first), `skip_files` (`:`-separated repo paths), `cap_day`, and carried `cost`/`tokens`. Log lines `sweep: batch <n> closes at <k> fixes` and `sweep: skip <loc> (file in an earlier batch's PR)`.

Design (spec §9), restated for the implementer:
1. Claim takes every ready candidate (drop the `head -n sweepMax`). A continuation (`cont` ≥ 2) skips classify and the cap (it carries `cap_day` = today), and `_fi_af_sweep_ready` drops entries whose `_fi_af_entry_file` is in `skip_files`.
2. `_fi_af_run_sweep`: after each `fi_af_sweep_commit`, if `AFI_fixed >= fi_af_sweep_batch` AND the next entry (line `AFI_cur` of `sweeps/<id>.entries`, if any) is in a different file than the entry just committed, log `sweep: batch <n> closes at <k> fixes` and stop the loop. Record that entries remain (a local flag), but only if a next entry exists.
3. `fi_af_sweep_finish`: on a successful ship with the flag set and `fi_af_enabled`, queue the continuation: `fi_af_new_id`, `fi_af_item_write "$FI_AF_ST/queue/$FI_AF_ID"` with the same fields `fi_af_sweep_check` writes plus `cont=<n+1>`, `cap_day=<today>`, `cost=$FI_AF_COST`, `tokens=$FI_AF_TOKENS`, `base=$AFI_base` and `skip_files=<old skip_files plus the files of this batch's fixed entries>`. Log `sweep: queued batch <n+1> as <new id>`. Write the queue item BEFORE `fi_af_finish` moves this one to `done/`, so `fi_af_sweep_pending` never sees a gap in which a Stop hook could queue a second, unrelated sweep.
4. Ship failure (`_fi_af_sweep_ship_failed`), a budget stop, an engine outage, or `autofix off`: no continuation.
5. `_fi_af_run_sweep` seeds `FI_AF_COST`/`FI_AF_TOKENS` from the item (it already does), so a carried `cost`/`tokens` counts against `sweepBudget`/`codexSweepTokens` across the chain.
6. PR title: `fix: found-issues sweep ($AFI_fixed entries)` for a single batch; `fix: found-issues sweep ($AFI_fixed entries, batch <n>)` when the chain has more than one batch, i.e. when `cont` ≥ 2 or a continuation was queued.

- [ ] **Step 1: Write the failing tests** in `tests/autofix-sweep.bats` (reuse `fi_af_sweep_fixture`, `fi_use_standins`, `sweep_edit`, `gh_mock`, `sweep_queue` exactly as the neighbouring tests do; read `:200-360` first). Rename `sweep claim: honours sweepMax` to `sweep claim: takes every fixable entry, no count limit` and change it to set `sweepBatch 2` with 4 fixable entries and assert all 4 are in `sweeps/<id>.entries`. Add:

```bash
@test "sweep run: ships a PR per batch and queues the next batch" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock
  git config found-issues.autofix.sweepBatch 2
  sweep_queue
  "$FI_BIN" autofix run "$SID" --engine claude
  grep -q '^result=shipped: PR #[0-9]*, 2 fixed' "$ST/done/$SID"
  grep -q 'sweep: batch 1 closes at 2 fixes' "$FI_AF_RUNS/$SID.log"
  # Launcher A drains the continuation in the same run.
  n="$(grep -l '^cont=2' "$ST"/done/* | wc -l | tr -d ' ')"
  [ "$n" = 1 ]
  ! grep -q 'autofix-failed' docs/found-issues.md || false
}

@test "sweep run: a continuation takes no second daily slot and carries cost" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock
  git config found-issues.autofix.sweepBatch 2
  git config found-issues.autofix.dailySweeps 1
  sweep_queue
  "$FI_BIN" autofix run "$SID" --engine claude
  c="$(grep -l '^cont=2' "$ST"/done/*)"
  grep -q '^result=shipped' "$c"
  [ "$(grep -c . "$ST/day/$(date +%Y-%m-%d).sweep")" = 1 ]
  awk -F= '$1=="cost" && $2+0 > 0.5 { ok=1 } END { exit !ok }' "$c"
}

@test "sweep run: a batch closes only at a file boundary" {
  # <fixture where entries 1 and 2 cite the same file and sort next to each other>
  git config found-issues.autofix.sweepBatch 1
  sweep_queue
  "$FI_BIN" autofix run "$SID" --engine claude
  grep -q '^result=shipped: PR #[0-9]*, 2 fixed' "$ST/done/$SID"
}

@test "sweep claim: a continuation skips files in skip_files" {
  # <queue a sweep item by hand with cont=2, cap_day=today and
  #  skip_files=<the file entry 1 cites>, then claim it>
  grep -q "file in an earlier batch's PR" "$FI_AF_RUNS/$SID.log"
  # <assert entry 1 is not in sweeps/$SID.entries and no classify child ran>
}

@test "sweep run: a failed batch ship queues no continuation" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_edit; gh_mock
  git config found-issues.autofix.sweepBatch 2
  export GH_MOCK_PUSH_FAIL=1   # use whatever the 3.2.1 ship-retry tests use to fail the push
  sweep_queue
  "$FI_BIN" autofix run "$SID" --engine claude || true
  ! grep -l '^cont=2' "$ST"/queue/* "$ST"/done/* 2>/dev/null || false
}

@test "config: sweepMax still sets the batch size when sweepBatch is unset" {
  git config found-issues.autofix.sweepMax 3
  [ "$(fi_af_sweep_batch)" = 3 ]
  git config found-issues.autofix.sweepBatch 5
  [ "$(fi_af_sweep_batch)" = 5 ]
}
```

(The `<…>` parts depend on `fi_af_sweep_fixture`, which decides which files hold which entries: read it, and extend it or write the ledger by hand. For the push failure, copy the mechanism from the 3.2.1 tests: `rg -n 'ship_tries' tests/autofix-sweep.bats`. The README bump below counts 6 new tests.)

`tests/cli-config.bats:14,30-35`: replace `autofix.sweepMax` with `autofix.sweepBatch` in the key list and the set/get test. `tests/setup-autofix-disclosure.bats`: `up to 8 entries` → `8 fixes per PR`; `fi_af_int sweepMax 8` → `autofix.sweepBatch|int|8`.

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/autofix-sweep.bats tests/cli-config.bats tests/setup-autofix-disclosure.bats`
Expected: the new tests FAIL (only 2 entries in the entries file; no continuation; `fi_af_sweep_batch: command not found`).

- [ ] **Step 3: Implement** per the design above. `fi_af_sweep_batch` in `lib/autofix-config.sh`:

```bash
# 3.3.0 spec §9: fixes per sweep PR. sweepMax (<= 3.2.x: entries per sweep)
# still sets it when sweepBatch is unset.
fi_af_sweep_batch() {
  if [[ -n "$(fi_af_cfg sweepBatch "")" ]]; then fi_af_int sweepBatch 8
  elif [[ -n "$(fi_af_cfg sweepMax "")" ]]; then fi_af_int sweepMax 8
  else printf '8'; fi
}
```

Doctor `Caps:` field: `(at %s fixable, %s fixes per PR)` fed by `fi_af_sweep_batch`. `autofix status`: where a sweep row prints its kind or loc, print `sweep (batch <cont>)` when `AFI_cont` ≥ 2 (add `cont` and `skip_files` to the `AFI_*` fields `fi_af_item_read` loads, `lib/autofix-queue.sh:37` and `:52`). `lib/help.sh:86`: `A sweep: every fixable entry, one PR per sweepBatch fixes`. `commands/setup.md`: line 338 `one sweep fixes them all, one PR per 8 fixes`; the picker text at `:355-362` drops "a sweep fixes up to 8" (say "a sweep fixes every fixable entry"). Keep the strings the disclosure test greps. Regenerate the Codex skill copy.

- [ ] **Step 4: Run to verify they pass**

Run: `bats tests/autofix-sweep.bats tests/cli-config.bats tests/setup-autofix-disclosure.bats tests/autofix-status.bats tests/autofix-doctor.bats tests/codex-skills-drift.bats tests/autofix-b.bats tests/autofix-cancel.bats`
Expected: all pass.

- [ ] **Step 5: Bump the README count (+6) and commit**

```bash
git add lib/autofix-config.sh lib/autofix-sweep.sh lib/autofix-status.sh lib/autofix-queue.sh lib/help.sh \
  commands/setup.md codex-skills/fi-setup tests/autofix-sweep.bats tests/cli-config.bats \
  tests/setup-autofix-disclosure.bats README.md
git commit -m "feat(autofix): sweeps fix every fixable entry and ship one PR per batch"
```

---

### Task 7: Visibility (run log, status, doctor, PR body)

**Files:**
- Modify: `lib/autofix-engine.sh` (new `fi_af_codex_note`; model-error marker in `fi_af_collect`)
- Modify: `lib/autofix.sh` (`_fi_af_fix_attempt`, `_fi_af_verify`), `lib/autofix-classify.sh` (`fi_af_classify`)
- Modify: `lib/autofix-status.sh` (running rows `:117-119`, recent rows `:147-155`, `fi_af_doctor` `:247-276`)
- Modify: `lib/autofix-ship.sh:122`, `lib/autofix-sweep.sh:402` (`Run cost:` lines)
- Test: `tests/autofix-run.bats`, `tests/autofix-status.bats`, `tests/autofix-doctor.bats`

**Interfaces:**
- Consumes: `fi_af_codex_margs`/`FI_AF_MDESC` (Task 1), `FI_AF_CHILD_TOKENS` and the `turn.failed` text (Task 2), `fi_af_token_cap` (Task 4).
- Produces: `fi_af_codex_note <id> <role>`, `fi_af_codex_desc <role>` (doctor text, resolves `inherit` against config.toml), marker file `$FI_AF_ROOT/codex-model-error`.

- [ ] **Step 1: Write the failing tests**

`tests/autofix-run.bats`:

```bash
@test "autofix run: the run log names each codex child's model and tokens against the cap" {
  run "$FI_BIN" autofix run "$ID" --engine codex
  [ "$status" -eq 0 ]
  grep -q 'codex fixer: model gpt-6.1-sol (medium), 1500 tokens, run total 1500$' "$FI_AF_RUNS/$ID.log"
  grep -q 'codex verifier: model gpt-6-astra (high), 1500 tokens, run total 3000$' "$FI_AF_RUNS/$ID.log"
  grep -q 'Run cost: .*codex models: fixer gpt-6.1-sol (medium), verifier gpt-6-astra (high)' "$FI_AF_RUNS/$ID.pr-body.md"
}
```

`tests/autofix-status.bats`:

```bash
@test "autofix status: a codex run shows tokens against its cap" {
  export GH_MOCK_PR_VIEW=$'7\t{"number":7,"state":"OPEN","statusCheckRollup":[]}'
  export FI_STANDIN_EDIT="sed -i.bak 's/ - / + /' src/calc.sh && rm -f src/calc.sh.bak"
  git config found-issues.autofix.codexRunTokens 600000
  "$FI_BIN" autofix run "$ID" --engine codex >/dev/null
  run "$FI_BIN" autofix status
  [[ "$output" == *"3000/600000 tokens"* ]]
}

@test "autofix status: a codex run with no token cap shows its tokens alone" {
  export GH_MOCK_PR_VIEW=$'7\t{"number":7,"state":"OPEN","statusCheckRollup":[]}'
  export FI_STANDIN_EDIT="sed -i.bak 's/ - / + /' src/calc.sh && rm -f src/calc.sh.bak"
  "$FI_BIN" autofix run "$ID" --engine codex >/dev/null
  run "$FI_BIN" autofix status
  [[ "$output" == *" 3000 tokens"* ]]
  [[ "$output" != *"3000/"* ]]
}
```

`tests/autofix-doctor.bats`:

```bash
@test "doctor auto-fix: codex models per role and the token caps" {
  git config found-issues.autofix.codexVerifierModel inherit
  mkdir -p "$TMP/codexhome"; printf 'model = "gpt-6-astra"\n' > "$TMP/codexhome/config.toml"
  CODEX_HOME="$TMP/codexhome" run "$FI_BIN" doctor
  [[ "$output" == *"Codex models: fixer gpt-6.1-sol (medium), verifier inherit (~/.codex/config.toml: gpt-6-astra), classifier gpt-6.1-sol (low)"* ]]
  [[ "$output" == *"no token cap per run"* ]]
  git config found-issues.autofix.codexRunTokens 600000
  CODEX_HOME="$TMP/codexhome" run "$FI_BIN" doctor
  [[ "$output" == *"600000 Codex tokens per run"* ]]
}

@test "doctor auto-fix: warns when the last codex child failed on its model" {
  export FI_STANDIN_CODEX_FAIL=workspace-write
  "$FI_BIN" autofix run "$ID" --engine codex >/dev/null || true
  run "$FI_BIN" doctor
  [[ "$output" == *"Last Codex run failed on its model"* ]]
  [[ "$output" == *"found-issues config autofix.codexModel"* ]]
}
```

(`tests/autofix-doctor.bats` has no queue fixture; add `fi_af_queue_fixture` at the start of the second test. The doctor line prints `~/.codex/config.toml` literally even when `CODEX_HOME` points elsewhere: it is a label, not a path.)

- [ ] **Step 2: Run to verify they fail**

Run: `bats tests/autofix-run.bats tests/autofix-status.bats tests/autofix-doctor.bats`
Expected: the six new tests FAIL (no `codex fixer:` log line, no `/600000 tokens`, no `Codex models:` line).

- [ ] **Step 3: Implement**

`lib/autofix-engine.sh`, add to `fi_af_collect`'s codex branch after `FI_AF_ENGINE_ERR` is set:

```bash
    fi_af_root
    if [[ -n "$FI_AF_ENGINE_ERR" ]] && [[ "$(printf '%s' "$FI_AF_ENGINE_ERR" | tr '[:upper:]' '[:lower:]')" == *model* ]]; then
      printf '%s\n' "$FI_AF_ENGINE_ERR" >"$FI_AF_ROOT/codex-model-error" 2>/dev/null || true
    elif [[ -z "$FI_AF_ENGINE_ERR" ]] && (( t > 0 )); then
      rm -f "$FI_AF_ROOT/codex-model-error" 2>/dev/null || true
    fi
```

And two helpers after `fi_af_spent_text`:

```bash
# 3.3.0 spec §3: one run-log line per Codex child.
fi_af_codex_note() {
  fi_af_codex_margs "$2"
  local cap
  cap="$(fi_af_token_cap)"
  fi_af_log "$1" "codex $2: model $FI_AF_MDESC, $FI_AF_CHILD_TOKENS tokens, run total $FI_AF_TOKENS${cap:+/$cap}"
}

# Doctor's description of one role; inherit names config.toml's model.
fi_af_codex_desc() {
  local m
  fi_af_codex_margs "$1"
  if [[ "$FI_AF_MDESC" != inherit ]]; then printf '%s' "$FI_AF_MDESC"; return 0; fi
  m="$(sed -n 's/^model[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "${CODEX_HOME:-$HOME/.codex}/config.toml" 2>/dev/null | head -n 1)"
  printf 'inherit (~/.codex/config.toml: %s)' "${m:-its default}"
}
```

(`fi_af_codex_note` writes `model inherit` for an inheriting role; that is the spec's `model <m>` with `<m>` = `inherit`.)

Call sites, each right after the existing `fi_af_collect`:
- `_fi_af_fix_attempt` (`lib/autofix.sh`): `[[ "$engine" == codex ]] && fi_af_codex_note "$AFI_id" fixer`
- `_fi_af_verify` (`lib/autofix.sh`): `[[ "$engine" == codex ]] && fi_af_codex_note "$AFI_id" verifier`
- `fi_af_classify` (`lib/autofix-classify.sh`): `[[ "$engine" == codex ]] && fi_af_codex_note "$id" classifier`

Under `set -e`, write each as `if [[ "$engine" == codex ]]; then fi_af_codex_note …; fi` so a false test does not end the function with rc 1.

`lib/autofix-status.sh`, after each `into %s (%s)` line (running and recent rows):

```bash
        if [[ "$AFI_engine" == codex && "$AFI_tokens" =~ ^[0-9]+$ ]] && (( AFI_tokens > 0 )); then
          printf '      %s/%s tokens\n' "$AFI_tokens" "$(fi_af_token_cap)"
        fi
```

(`fi_af_token_cap` reads `AFI_kind`, already loaded by `fi_af_item_read`. In the recent loop the `into` line is unindented by two spaces relative to the running one; match each loop's indentation.)

`fi_af_doctor`, after the `Engine:` line:

```bash
  printf '   Codex models: fixer %s, verifier %s, classifier %s\n' \
    "$(fi_af_codex_desc fixer)" "$(fi_af_codex_desc verifier)" "$(fi_af_codex_desc classifier)"
  fi_af_root
  if [[ -s "$FI_AF_ROOT/codex-model-error" ]]; then
    printf '%s Last Codex run failed on its model: %s\n' "$w" "$(head -n 1 "$FI_AF_ROOT/codex-model-error")"
    printf '   Fix: found-issues config autofix.codexModel <model> (or inherit); same for autofix.codexVerifierModel\n'
  fi
```

and extend the `Caps:` line (Tasks 5-6 already reworked it) with the token caps: `<n> Codex tokens per run` / `<n> per sweep` when set (`fi_af_cap_int codexRunTokens` / `codexSweepTokens`), else `no token cap per run` / `no token cap per sweep`.

PR bodies (`lib/autofix-ship.sh:122` and `lib/autofix-sweep.sh:402`): keep the line and append the models for codex runs:

```bash
  printf 'Run cost: $%s (claude), %s tokens (codex)' "${FI_AF_COST:-0}" "${FI_AF_TOKENS:-0}"
  if [[ "${AFI_engine:-}" == codex ]]; then
    printf ' — codex models: fixer %s, verifier %s' "$(fi_af_codex_margs fixer; printf '%s' "$FI_AF_MDESC")" "$(fi_af_codex_margs verifier; printf '%s' "$FI_AF_MDESC")"
  fi
  printf '\n\n'
```

(In `autofix-sweep.sh` keep the leading `\n` the existing line has.)

- [ ] **Step 4: Run to verify they pass**

Run: `bats tests/autofix-run.bats tests/autofix-status.bats tests/autofix-doctor.bats tests/autofix-sweep.bats`
Expected: all pass.

- [ ] **Step 5: Bump the README count (+6) and commit**

```bash
git add lib/autofix-engine.sh lib/autofix.sh lib/autofix-classify.sh lib/autofix-status.sh \
  lib/autofix-ship.sh lib/autofix-sweep.sh tests/autofix-run.bats tests/autofix-status.bats \
  tests/autofix-doctor.bats README.md
git commit -m "feat(autofix): show Codex models and tokens against the cap"
```

---

### Task 8: Docs, full verification and release 3.3.0

**Files:**
- Modify: `docs/configuration.md:192-202` (the four keys), `README.md` (auto-fix section, version line `:231`), `CHANGELOG.md`
- Modify: `bin/found-issues:31`, `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json` (version)
- Modify (after merge): `AltDoug/claude-plugins` marketplace entry

- [ ] **Step 1: Docs.** `docs/configuration.md`, rows after `autofix.engine` and after `autofix.sweepBudget`:

```
| `autofix.codexModel` | `gpt-6.1-sol` | Codex fixer (effort medium) and classifier (effort low) model, or `inherit` for `~/.codex/config.toml` |
| `autofix.codexVerifierModel` | `gpt-6-astra` | Codex verifier model (effort high), or `inherit` |
| `autofix.codexRunTokens` | unset (no cap) | Codex tokens per spot run, e.g. `<RUN_CAP>` (Task 3: about 3× a measured spot run); checked before each child, so one child can overshoot |
| `autofix.codexSweepTokens` | unset (no cap) | Codex tokens per sweep (all batches), e.g. `<SWEEP_CAP>` |

Also change the `runBudget` / `sweepBudget` rows to default `unset (no cap)` (keep the USD wording; `sweepBudget` covers all batches of a sweep), replace the `sweepMax` row with `| \`autofix.sweepBatch\` | \`8\` | Fixes per sweep PR; a sweep fixes every fixable entry, one PR per batch (\`sweepMax\` is read when this is unset) |`, and fix the `config autofix.sweepMax --unset` example at `:191`.
```

README auto-fix section: one sentence that Codex runs use pinned models (`inherit` to keep your own) and stop at a token cap. Version line → v3.3.0.

`CHANGELOG.md`:

```
## [3.3.0] - <release-commit date>

### Changed
- Codex auto-fix runs no longer inherit your interactive Codex model. The fixer and classifier run on `gpt-6.1-sol` (effort medium / low), the verifier on `gpt-6-astra` (effort high). Set `found-issues config autofix.codexModel inherit` (and/or `autofix.codexVerifierModel inherit`) to keep using `~/.codex/config.toml`.
- No dollar cap by default: `autofix.runBudget` and `autofix.sweepBudget` are now unset unless you set them (they were $3 / $10), and claude children get no `--max-budget-usd` without one. Daily caps and the per-child timeout still apply.
- A sweep no longer stops at 8 entries: it fixes every fixable entry and opens one PR per `autofix.sweepBatch` fixes (default 8). `autofix.sweepMax` is replaced by `autofix.sweepBatch` and still read when `sweepBatch` is unset.

### Added
- Opt-in Codex token caps: `autofix.codexRunTokens` and `autofix.codexSweepTokens` (unset = no cap). A run stops starting children at the cap and parks as `run budget spent (<N> tokens)`.
- Run log, `autofix status`, `doctor` and the PR body show the Codex model per role and tokens against the cap; `doctor` warns when the last Codex run failed on its model.

### Fixed
- A failed Codex turn (for example a model your account cannot use) is an outage that requeues, with the real error text, instead of a failed attempt; this now also holds for the verifier.
```

- [ ] **Step 2: Version bump.** `FI_VERSION="3.3.0"` in `bin/found-issues`; `"version": "3.3.0"` in both plugin manifests. Run `bats tests/check-version.bats tests/docs-consistency.bats` and expect pass.

- [ ] **Step 3: Full suite.** `bats tests/` (bare; there is no `tests/hooks/`) and expect `0 not ok`. Quote the `1..N` line and the count of `not ok` in the PR body. Check that the README count equals `N`.

- [ ] **Step 4: End-to-end verification (verify skill).** On a real repo with Codex installed, drive one spot run with the branch CLI: `"$BR/bin/found-issues" autofix run <id> --engine codex`. Then read the run log for the two `codex fixer:`/`codex verifier:` lines, `autofix status` for `<T>/<cap> tokens`, and `doctor` for the `Codex models:` line. Capture them verbatim for the PR. Task 3's repo (if the operator kept it) serves; otherwise reuse the Task 3 recreate steps and ask before deleting again.

- [ ] **Step 5: Review, then PR.** Run `/code-review` on the branch (adversarial review before a release PR is standing practice here). Fix confirmed findings in new commits. Open the PR `release: v3.3.0 — Codex auto-fix: pinned models and a token cap` and arm `gh pr merge <N> --auto --squash`. Watch every check to a terminal state. After the merge: watch the post-merge `tests` run and `release.yml` to success, and confirm `gh release list -R AltDoug/found-issues -L 1` shows v3.3.0 Latest.

- [ ] **Step 6: Marketplace.** In `AltDoug/claude-plugins`, bump `found-issues` to 3.3.0 (same shape as #51), PR, merge.

---

## Self-review (done while writing, 2026-10-06)

- Spec coverage: §1 → Task 1; §2 → Task 4 (check points: fix attempt and verify via `_fi_af_fix_loop`, launcher B verify, classify); §3 → Task 7 (all four surfaces); §4 → Task 2 (unknown model = outage, fixer and verifier) + Task 7 (doctor warning) + Task 4 (non-numeric cap via `fi_af_cap_int`); §5 → tests in Tasks 1, 2 and 4; §6 → Task 3; §7 → Task 8.
- Spec drift found and handled: §4 says a rejected model "surfaces as an engine error … which the run already handles". Measured 2026-10-06, it does not: `fi_af_collect` never reads `turn.failed`, and the verifier path has no engine-error check. Task 2 adds both.
- `RUN_CAP`/`SWEEP_CAP` are the only values left open on purpose: Task 3 produces them by a stated formula, with 600000/1500000 as the fallback. Amended: they are doc suggestions only; the keys default to unset.
- Amendment 2026-10-06 (spec Decisions 4-6): §2 opt-in → Task 4; §8 dollar caps opt-in → Task 5; §9 sweep batches → Task 6; visibility of unset caps → Task 7; docs and disclosure → Tasks 5, 6 and 8.
