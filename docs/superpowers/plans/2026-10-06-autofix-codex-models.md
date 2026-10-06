# Auto-fix on Codex: pinned models and a token cap — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Codex auto-fix children run on fixed per-role models (unless the user picks `inherit`), and a Codex run stops starting new children once its token count reaches a cap, parking the item as `run budget spent (<N> tokens)`.

**Architecture:** Two new model keys and two new token-cap keys join the existing `_FI_CFG_KEYS` table. One helper builds each Codex role's `-m`/effort argv. One engine-neutral gate, `fi_af_run_budget_left <engine>`, replaces the three `engine == claude` budget guards and adds a gate before classify: dollars for claude (unchanged), tokens for codex. Codex `turn.failed` events become `FI_AF_ENGINE_ERR`, so a rejected model is an outage, not an attempt. Status, the run log, doctor and the PR body show models and tokens against the cap.

**Tech Stack:** bash 3.2+ (macOS system bash), jq, bats-core 1.14, `codex exec --json` (codex-cli 0.160.1 measured), stand-in engines in `tests/standins/`.

**Spec:** `docs/superpowers/specs/2026-10-06-autofix-codex-models-design.md` (approved for planning 2026-10-06). Read it before Task 1.

## Global Constraints

- Release 3.3.0 (minor). If 3.2.1 (baseline test run, ledger `[!] lib/autofix.sh:127`, operator decision 2026-10-06) merges first, start this branch from that `origin/main` and bump `FI_VERSION` from whatever it then reads to `3.3.0`.
- Defaults (operator decision 2026-10-06, models re-checked 2026-10-06 with `codex debug models` on codex-cli 0.160.1: both are listed and both support low/medium/high): `autofix.codexModel` = `gpt-6.1-sol` (fixer `medium`, classifier `low`), `autofix.codexVerifierModel` = `gpt-6-astra` (verifier `high`).
- `inherit` drops BOTH `-m` and the `-c model_reasoning_effort=…` override for that role; `~/.codex/config.toml` decides everything.
- Model values pass through unchanged. found-issues keeps no model list.
- Token-cap defaults: `autofix.codexRunTokens` and `autofix.codexSweepTokens` = about 3× the median measured in Task 3 (spec proposal before measurement: 600000 / 1500000).
- The cap is checked before each fix, verify and classify child. One child may overshoot it; there is no streamed mid-child kill in 3.3.0 (operator decision 3).
- The claude engine's dollar budget behaviour and outcome text (`run budget spent ($X)`) are unchanged; every existing budget test stays green.
- bash 3.2 under `set -euo pipefail` (`bin/found-issues:29`): expand a possibly-empty array as `${A[@]+"${A[@]}"}`, never `"${A[@]}"`.
- bats: test names ASCII only (the PR guard fails on em-dashes); a mid-test negation is `! cmd || false`, never a bare `! cmd`.
- Each task that adds `@test`s bumps the README test count (`README.md:11`, currently `1279 tests`) in the same commit.
- Never `git add -A`; never hand-edit `docs/found-issues.md` (use `./bin/found-issues`).

## Review Focus

1. **`inherit` on one role, a pinned model on the other** (e.g. `codexVerifierModel=inherit`, `codexModel` default): the fixer still gets `-m gpt-6.1-sol -c model_reasoning_effort=medium` and the verifier gets neither. Pinned in Task 1 (`inherit is per role`).
2. **A rejected model on the VERIFIER** (not the fixer): today `_fi_af_fix_loop` treats a verifier with no verdict as a reject, which burns an attempt and tags the entry autofix-failed. Expected: an outage that requeues. Pinned in Task 2 (`a verifier engine error requeues`).
3. **A sweep whose classifier already used tokens**: the cap counts classifier tokens too, and the sweep still ships what it committed before the cap. Pinned in Task 4 (sweep cap test, cap chosen to give "1 fixed" with or without a classify child).
4. **A non-numeric or zero token cap** (`codexRunTokens=lots`, `0`): falls back to the default with the `fi_af_int` warning; `config` refuses to set it. Pinned in Task 4 (`token cap keys`).
5. **A model name with characters a shell or TOML would mangle** (`gpt-6.1-sol`, `org/model:tag`): passed as one argv element, unchanged; `config` refuses whitespace and empty values. Pinned in Task 1 (`config validates model names`).

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
- Produces: `fi_af_collect codex …` sets `FI_AF_ENGINE_ERR` to the inner `error.message` of the last `turn.failed` event (empty when none), and `FI_AF_CHILD_TOKENS` to this child's tokens (Task 5 logs it).

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

No code. It sets the token-cap defaults for Task 4 and answers whether `codex exec --json` streams usage before `turn.completed`.

**Files:**
- Create: `docs/e2e/v3.3-codex-tokens-2026-10-XX.md` (XX = the day it runs)

**Interfaces:**
- Produces: `RUN_CAP` and `SWEEP_CAP`, two integers that Task 4 writes into `_FI_CFG_KEYS`.

- [ ] **Step 1: Recreate the throwaway repo** the way the 3.0.0/3.2.0 e2e did (read `docs/e2e/v3-live-e2e-2026-10-04.md` for the fixture shape: a small `src/` with one-line bugs, `test.sh`, a ledger with `(fix: small)` entries). `gh repo create AltDoug/fi-v3-e2e --private`, push the fixture, set `found-issues.autofix true` and `autofix.testCommand "sh test.sh"` locally. Seed 6 fixable entries: 3 for spot runs, plus 3 for one sweep (`autofix.sweepThreshold 3`).

- [ ] **Step 2: Run 3 spot fixes and 1 sweep on the branch CLI with the pinned defaults.** Use this checkout's `bin/found-issues` by absolute path (the installed plugin CLI is older): `"$BR/bin/found-issues" autofix run <id> --engine codex`, one at a time. After each, record from `~/.claude/found-issues/autofix/AltDoug__fi-v3-e2e/runs/<id>.log` and the `done/<id>` file: `tokens=`, per-child tokens (`jq -s '[.[]|select(.type=="turn.completed")|.usage]' <id>.fix1.out`, `.verify1.out`, `.classify.out`), wall time and result.

- [ ] **Step 3: Repeat with `inherit`** on both keys (3 spot fixes + 1 sweep, fresh entries). Record the same numbers.

- [ ] **Step 4: Streaming usage check.** `jq -c 'select(.usage) | .type' <id>.fix1.out | sort | uniq -c`. If any type other than `turn.completed` carries usage, write that down for a future release; 3.3.0 does NOT change (operator decision 3).

- [ ] **Step 5: Write the e2e doc and compute the caps.** A table per run (role, model, effort, tokens, seconds); `RUN_CAP` = 3 × the median pinned-model spot `tokens=`, rounded up to the next 100000; `SWEEP_CAP` = 3 × the pinned-model sweep `tokens=`, rounded up to the next 100000. If the pinned numbers are within 20% of 600000/3 and 1500000/3, keep 600000 / 1500000 and say so.

- [ ] **Step 6: Operator checkpoint, then delete the repo.** Ask via AskUserQuestion: "Delete AltDoug/fi-v3-e2e now?" (recommended: yes, the doc holds the numbers). Only on yes: `GH_REPO_DELETE_GUARD=off gh repo delete AltDoug/fi-v3-e2e --yes`. Close any PRs the runs opened first if the operator says keep.

- [ ] **Step 7: Commit the doc**

```bash
git add docs/e2e/v3.3-codex-tokens-2026-10-XX.md
git commit -m "docs(e2e): measure Codex tokens per role for the 3.3.0 cap defaults"
```

---

### Task 4: Token cap

**Files:**
- Modify: `lib/autofix-config.sh` (`_FI_CFG_KEYS`)
- Modify: `lib/autofix-engine.sh` (after `fi_af_budget_left` at `:249-251`, header list)
- Modify: `lib/autofix.sh:101-103` and `:131-133` (`_fi_af_fix_loop` guards)
- Modify: `lib/autofix-b.sh:135-141` (`autofix verify` guard)
- Modify: `lib/autofix-classify.sh` (`fi_af_classify`, gate after the engine is resolved)
- Modify: `tests/standins/codex` (`FI_STANDIN_TOKENS`)
- Test: `tests/autofix-engine.bats`, `tests/autofix-config.bats`, `tests/autofix-run.bats`, `tests/autofix-sweep.bats`, `tests/autofix-b.bats`

**Interfaces:**
- Consumes: `RUN_CAP`, `SWEEP_CAP` from Task 3; `FI_AF_TOKENS` (existing).
- Produces: `fi_af_token_cap` (prints the cap for `AFI_kind`), `fi_af_tokens_left` (rc 1 at or past the cap, else prints what is left), `fi_af_run_budget_left <engine>` (rc 0 = may start another child), `fi_af_spent_text <engine>` (`run budget spent ($X)` | `run budget spent (<N> tokens)`). Task 5 uses `fi_af_token_cap`.

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
```

`tests/autofix-config.bats`:

```bash
@test "config: token cap keys default, validate and fall back" {
  [ "$(fi_af_int codexRunTokens RUN_CAP)" = RUN_CAP ]
  run "$FI_BIN" config autofix.codexRunTokens 0
  [ "$status" -eq 2 ]
  git config found-issues.autofix.codexSweepTokens lots
  run fi_af_int codexSweepTokens 1500000
  [ "${lines[${#lines[@]}-1]}" = 1500000 ]
  run "$FI_BIN" config
  [[ "$output" == *"found-issues.autofix.codexRunTokens"* ]]
  [[ "$output" == *"found-issues.autofix.codexSweepTokens"* ]]
}
```

(Replace the literal `RUN_CAP` in the first line with Task 3's number, e.g. `[ "$(fi_af_token_cap)" = 600000 ]` run with no `AFI_kind` set. Check the default through `fi_af_token_cap`, not through `fi_af_int`'s second argument.)

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

`_FI_CFG_KEYS`, after `autofix.sweepBudget`:

```
autofix.codexRunTokens|int|<RUN_CAP>
autofix.codexSweepTokens|int|<SWEEP_CAP>
```

(The literal numbers from Task 3, e.g. `600000` / `1500000`.)

`lib/autofix-engine.sh`, after `fi_af_budget_left` (and the four names in the header list):

```bash
# 3.3.0 spec §2: Codex reports tokens, not dollars, so its runs stop on a
# token cap instead (a sweep has its own). Checked before each child; one
# child may overshoot (operator decision 3, 2026-10-06).
fi_af_token_cap() {
  if [[ "${AFI_kind:-}" == "sweep" ]]; then fi_af_int codexSweepTokens <SWEEP_CAP>
  else fi_af_int codexRunTokens <RUN_CAP>; fi
}

fi_af_tokens_left() {
  local cap
  cap="$(fi_af_token_cap)"
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

- [ ] **Step 6: Bump the README count (+6) and commit**

```bash
git add lib/autofix-config.sh lib/autofix-engine.sh lib/autofix.sh lib/autofix-b.sh lib/autofix-classify.sh \
  tests/standins/codex tests/autofix-engine.bats tests/autofix-config.bats tests/autofix-run.bats \
  tests/autofix-sweep.bats tests/autofix-b.bats README.md
git commit -m "feat(autofix): stop Codex runs at a per-run token cap"
```

---

### Task 5: Visibility (run log, status, doctor, PR body)

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
  grep -q 'codex fixer: model gpt-6.1-sol (medium), 1500 tokens, run total 1500/' "$FI_AF_RUNS/$ID.log"
  grep -q 'codex verifier: model gpt-6-astra (high), 1500 tokens, run total 3000/' "$FI_AF_RUNS/$ID.log"
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
```

`tests/autofix-doctor.bats`:

```bash
@test "doctor auto-fix: codex models per role and the token caps" {
  git config found-issues.autofix.codexVerifierModel inherit
  mkdir -p "$TMP/codexhome"; printf 'model = "gpt-6-astra"\n' > "$TMP/codexhome/config.toml"
  CODEX_HOME="$TMP/codexhome" run "$FI_BIN" doctor
  [[ "$output" == *"Codex models: fixer gpt-6.1-sol (medium), verifier inherit (~/.codex/config.toml: gpt-6-astra), classifier gpt-6.1-sol (low)"* ]]
  [[ "$output" == *"Codex tokens per run"* ]]
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
Expected: the five new tests FAIL (no `codex fixer:` log line, no `/600000 tokens`, no `Codex models:` line).

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
  fi_af_log "$1" "codex $2: model $FI_AF_MDESC, $FI_AF_CHILD_TOKENS tokens, run total $FI_AF_TOKENS/$(fi_af_token_cap)"
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

and extend the `Caps:` printf with `, %s Codex tokens per run, %s per sweep` fed by `"$(fi_af_int codexRunTokens <RUN_CAP>)" "$(fi_af_int codexSweepTokens <SWEEP_CAP>)"`.

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

- [ ] **Step 5: Bump the README count (+5) and commit**

```bash
git add lib/autofix-engine.sh lib/autofix.sh lib/autofix-classify.sh lib/autofix-status.sh \
  lib/autofix-ship.sh lib/autofix-sweep.sh tests/autofix-run.bats tests/autofix-status.bats \
  tests/autofix-doctor.bats README.md
git commit -m "feat(autofix): show Codex models and tokens against the cap"
```

---

### Task 6: Docs, full verification and release 3.3.0

**Files:**
- Modify: `docs/configuration.md:192-202` (the four keys), `README.md` (auto-fix section, version line `:231`), `CHANGELOG.md`
- Modify: `bin/found-issues:31`, `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json` (version)
- Modify (after merge): `AltDoug/claude-plugins` marketplace entry

- [ ] **Step 1: Docs.** `docs/configuration.md`, rows after `autofix.engine` and after `autofix.sweepBudget`:

```
| `autofix.codexModel` | `gpt-6.1-sol` | Codex fixer (effort medium) and classifier (effort low) model, or `inherit` for `~/.codex/config.toml` |
| `autofix.codexVerifierModel` | `gpt-6-astra` | Codex verifier model (effort high), or `inherit` |
| `autofix.codexRunTokens` | `<RUN_CAP>` | Codex tokens per spot run; checked before each child, so one child can overshoot |
| `autofix.codexSweepTokens` | `<SWEEP_CAP>` | Codex tokens per sweep |
```

README auto-fix section: one sentence that Codex runs use pinned models (`inherit` to keep your own) and stop at a token cap. Version line → v3.3.0.

`CHANGELOG.md`:

```
## [3.3.0] - <release-commit date>

### Changed
- Codex auto-fix runs no longer inherit your interactive Codex model. The fixer and classifier run on `gpt-6.1-sol` (effort medium / low), the verifier on `gpt-6-astra` (effort high). Set `found-issues config autofix.codexModel inherit` (and/or `autofix.codexVerifierModel inherit`) to keep using `~/.codex/config.toml`.

### Added
- Codex token cap: `autofix.codexRunTokens` (<RUN_CAP>) and `autofix.codexSweepTokens` (<SWEEP_CAP>). A run stops starting children at the cap and parks as `run budget spent (<N> tokens)`.
- Run log, `autofix status`, `doctor` and the PR body show the Codex model per role and tokens against the cap; `doctor` warns when the last Codex run failed on its model.

### Fixed
- A failed Codex turn (for example a model your account cannot use) is an outage that requeues, with the real error text, instead of a failed attempt; this now also holds for the verifier.
```

- [ ] **Step 2: Version bump.** `FI_VERSION="3.3.0"` in `bin/found-issues`; `"version": "3.3.0"` in both plugin manifests. Run `bats tests/check-version.bats tests/docs-consistency.bats` and expect pass.

- [ ] **Step 3: Full suite.** `bats tests/ tests/hooks/` and expect `0 not ok`. Quote the `1..N` line and the count of `not ok` in the PR body. Check that the README count equals `N`.

- [ ] **Step 4: End-to-end verification (verify skill).** On a real repo with Codex installed, drive one spot run with the branch CLI: `"$BR/bin/found-issues" autofix run <id> --engine codex`. Then read the run log for the two `codex fixer:`/`codex verifier:` lines, `autofix status` for `<T>/<cap> tokens`, and `doctor` for the `Codex models:` line. Capture them verbatim for the PR. Task 3's repo (if the operator kept it) serves; otherwise reuse the Task 3 recreate steps and ask before deleting again.

- [ ] **Step 5: Review, then PR.** Run `/code-review` on the branch (adversarial review before a release PR is standing practice here). Fix confirmed findings in new commits. Open the PR `release: v3.3.0 — Codex auto-fix: pinned models and a token cap` and arm `gh pr merge <N> --auto --squash`. Watch every check to a terminal state. After the merge: watch the post-merge `tests` run and `release.yml` to success, and confirm `gh release list -R AltDoug/found-issues -L 1` shows v3.3.0 Latest.

- [ ] **Step 6: Marketplace.** In `AltDoug/claude-plugins`, bump `found-issues` to 3.3.0 (same shape as #51), PR, merge.

---

## Self-review (done while writing, 2026-10-06)

- Spec coverage: §1 → Task 1; §2 → Task 4 (check points: fix attempt and verify via `_fi_af_fix_loop`, launcher B verify, classify); §3 → Task 5 (all four surfaces); §4 → Task 2 (unknown model = outage, fixer and verifier) + Task 5 (doctor warning) + Task 4 (non-numeric cap via `fi_af_int`); §5 → tests in Tasks 1, 2 and 4; §6 → Task 3; §7 → Task 6.
- Spec drift found and handled: §4 says a rejected model "surfaces as an engine error … which the run already handles". Measured 2026-10-06, it does not: `fi_af_collect` never reads `turn.failed`, and the verifier path has no engine-error check. Task 2 adds both.
- `RUN_CAP`/`SWEEP_CAP` are the only values left open on purpose: Task 3 produces them by a stated formula, with 600000/1500000 as the fallback.
