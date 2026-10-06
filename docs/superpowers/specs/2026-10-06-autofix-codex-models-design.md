# Auto-fix on Codex: pinned models and a token cap — design

**Date:** 2026-10-06 · **Target release:** 3.3.0 (minor: Codex runs change model by default)
**Status:** approved for planning. Scope fixed by the operator on 2026-10-05; the three open questions were answered on 2026-10-06 (see Decisions at the end). Token-cap defaults still come from the Task 0 measurement.

## Why

The claude engine pins a model per role and stops at a dollar budget. The codex engine does neither:

- Every Codex child runs `codex exec` with no `-m` (`lib/autofix-engine.sh:175` fixer, `:189-190` verifier, `lib/autofix-classify.sh:114` classifier), so it inherits the user's `~/.codex/config.toml` default. On this Mac that is gpt-6-astra, the most expensive tier, for every unattended fix, verify and classify call. Only the verifier sets anything (`-c model_reasoning_effort=high`).
- `runBudget` / `sweepBudget` apply to the claude engine only: the checks are guarded `[[ "$engine" == "claude" ]]` (`lib/autofix.sh:101,131`, `lib/autofix-b.sh:135`) and `fi_af_budget_left` (`lib/autofix-engine.sh:249`) compares dollars, which Codex does not report. Codex tokens are counted after each child (`fi_af_collect`, `lib/autofix-engine.sh:203-206`, summing `turn.completed` usage) and shown in the PR body and status, but nothing stops a run on them.
- Measured on the 3.0.0 live e2e (2026-10-04, `docs/e2e/v3-live-e2e-2026-10-04.md`): one Codex spot fix used 202,661 tokens; one two-entry Codex sweep used 406,111 tokens. Both were trivial one-line bugs. A hard bug, with two fix attempts and two verifies, has no ceiling except `runTimeoutMin`.

Risk: auto-fix runs unattended and can draw down the user's ChatGPT plan usage, at the top model tier, with no limit.

**Operator decision (2026-10-05):** model pinning plus a per-run token cap for Codex ship as their own 3.3.0 release, after 3.2.0.

## Goal and success criteria

- A default install runs Codex fixer, verifier and classifier on fixed models chosen per role, not the user's interactive default.
- A user can choose `inherit` to keep today's behaviour, or name any model.
- A Codex run stops starting new children once its token count reaches the cap, and parks the item the same way a spent claude budget does today ("run budget spent").
- `autofix status`, the run log and `doctor` show the Codex model per role and the tokens against the cap.

## 1. Models per role

New config keys (same `found-issues config` machinery, `lib/autofix-config.sh:168-176` table):

| Key | Type | Default (*proposed*) | Used by |
|---|---|---|---|
| `autofix.codexModel` | model or `inherit` | `gpt-6.1-sol` | fixer, classifier |
| `autofix.codexVerifierModel` | model or `inherit` | `gpt-6-astra` | verifier |

Reasoning effort is fixed per role in code, as the claude engine's is: fixer `medium`, classifier `low`, verifier `high` (unchanged). `inherit` drops both `-m` and the effort override for that role, so the user's config.toml decides everything.

Each `codex exec` gets `-m <model> -c model_reasoning_effort=<effort>` unless the key is `inherit`. Values are passed through unchanged. found-issues does not keep a model list that goes stale. A model Codex rejects surfaces as an engine error (an outage, so not an attempt), which the run already handles.

## 2. Token cap

New keys, Codex only (the claude engine keeps its dollar budgets):

| Key | Type | Default (*proposed, after measurement*) |
|---|---|---|
| `autofix.codexRunTokens` | int | 600000 (about 3× the measured trivial spot fix) |
| `autofix.codexSweepTokens` | int | 1500000 |

- Check point: wherever the claude engine checks `fi_af_budget_left` today (before each fix attempt, before each verify, before classify), the codex engine checks `FI_AF_TOKENS < cap`. One helper `fi_af_tokens_left` mirrors `fi_af_budget_left`, and the three `engine == claude` guards become an engine-neutral `fi_af_run_budget_left`.
- At the cap the run parks as `run budget spent (<N> tokens)`, the same outcome text family as `run budget spent ($X)`.
- A single child can still overshoot: tokens are known only when a turn completes. The watchdog (`fi_af_child`) is not extended to stream-parse usage in 3.3.0 (open question 3).

## 3. Visibility

- Run log: one line per Codex child, `codex <role>: model <m> (effort <e>), <t> tokens, run total <T>/<cap>`.
- `autofix status`: the Codex rows show tokens as `<T>/<cap> tokens`.
- `doctor` Auto-fix section: `Codex models: fixer <m> (medium), verifier <m> (high), classifier <m> (low)`, or `inherit (~/.codex/config.toml: <model>)` when inheriting.
- PR body: `Run cost:` line adds the model names.

## 4. Errors

- Unknown or retired model → Codex exits non-zero with an error event → `FI_AF_ENGINE_ERR` path (outage, requeue, not an attempt). `doctor` warns when the last Codex run failed this way.
- Non-numeric token cap → `fi_af_int` default, as other int keys do.

## 5. Testing

- Codex shim (as the existing engine tests use) records argv. Asserts: `-m`/effort per role with defaults; none with `inherit`; custom names passed through.
- Token cap: shim emits `turn.completed` usage summing past the cap after attempt 1 → run parks "run budget spent (… tokens)" without starting the verifier.
- Claude engine unchanged: its existing budget tests stay green.

## 6. Measurement before the plan (Task 0)

On a throwaway private repo (recreate `AltDoug/fi-v3-e2e`, delete after): 3 spot fixes and 1 sweep on `--engine codex` with the proposed models, then the same with `inherit`. Record tokens per child and wall time. Set the cap defaults from these numbers (about 3× the median spot run, 3× the median sweep). Check whether `codex exec --json` emits usage before `turn.completed` (decides open question 3).

## 7. Release

3.3.0 (minor: default Codex model changes). CHANGELOG `Changed` names the new defaults and the `inherit` escape hatch. README auto-fix section and `docs/configuration.md` list the four keys.

## Decisions (operator, 2026-10-06)

1. Pinned models by default; `inherit` is the opt-out.
2. Fixer and classifier `gpt-6.1-sol` (medium / low effort), verifier `gpt-6-astra` (high). Re-check the Codex model list when the plan is written.
3. Overshoot by one child is acceptable: the cap is checked before each fix, verify and classify child, like the claude dollar budget. No streamed mid-child kill in 3.3.0.
