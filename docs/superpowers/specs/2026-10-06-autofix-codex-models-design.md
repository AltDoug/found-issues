# Auto-fix on Codex: pinned models and a token cap — design

**Date:** 2026-10-06 · **Target release:** 3.3.0 (minor: Codex runs change model by default; money caps and the per-sweep count limit become opt-in)
**Status:** approved for planning. Scope fixed by the operator on 2026-10-05; the three open questions were answered on 2026-10-06 (see Decisions at the end). **Amended 2026-10-06** with three later operator decisions (Decisions 4-6): every cap is opt-in, and a sweep ships in batches (§8, §9). The Task 0 measurement now only informs the docs.

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
- When the user sets a token cap, a Codex run stops starting new children once its token count reaches it, and parks the item the same way a spent claude budget does today ("run budget spent"). With no cap set (the default) nothing stops a Codex run on tokens.
- With no `runBudget` / `sweepBudget` set (the new default), a claude run has no dollar cap and its children get no `--max-budget-usd`.
- A sweep fixes every entry fixable at claim time and opens one PR per batch of `autofix.sweepBatch` fixes (default 8).
- `autofix status`, the run log and `doctor` show the Codex model per role and the tokens (against the cap when one is set).

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

| Key | Type | Default (amended, Decision 5) |
|---|---|---|
| `autofix.codexRunTokens` | int | unset = no cap (opt-in) |
| `autofix.codexSweepTokens` | int | unset = no cap (opt-in) |

The Task 0 measurement no longer sets defaults. It gives the docs a suggested value (about 3× the measured median spot run and sweep) for users who want a cap.

- Check point: wherever the claude engine checks `fi_af_budget_left` today (before each fix attempt, before each verify, before classify), the codex engine checks `FI_AF_TOKENS < cap` when a cap is set. One helper `fi_af_tokens_left` mirrors `fi_af_budget_left`, and the three `engine == claude` guards become an engine-neutral `fi_af_run_budget_left`. With no cap, the gate always passes.
- At the cap the run parks as `run budget spent (<N> tokens)`, the same outcome text family as `run budget spent ($X)`.
- A single child can still overshoot: tokens are known only when a turn completes. The watchdog (`fi_af_child`) is not extended to stream-parse usage in 3.3.0 (open question 3).

## 3. Visibility

- Run log: one line per Codex child, `codex <role>: model <m> (effort <e>), <t> tokens, run total <T>/<cap>` (`run total <T>` when no cap is set).
- `autofix status`: the Codex rows show tokens as `<T>/<cap> tokens` (`<T> tokens` when no cap is set).
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

On a throwaway private repo (recreate `AltDoug/fi-v3-e2e`, delete after): 3 spot fixes and 1 sweep on `--engine codex` with the proposed models, then the same with `inherit`. Record tokens per child and wall time. The docs suggest a cap from these numbers (about 3× the median spot run, 3× the median sweep); the defaults stay unset (Decision 5). Check whether `codex exec --json` emits usage before `turn.completed` (decides open question 3).

## 7. Release

3.3.0 (minor: default Codex model changes, money caps become opt-in, sweeps ship in batches). CHANGELOG `Changed` names the new Codex defaults and the `inherit` escape hatch, the removed default dollar caps, and `sweepMax` → `sweepBatch`. README auto-fix section, `docs/configuration.md` and the setup disclosure (`commands/setup.md`, `codex-skills/fi-setup`) state the new defaults.

## 8. Money caps become opt-in (Decision 6)

- `autofix.runBudget` and `autofix.sweepBudget` lose their defaults ($3 / $10). Unset means no dollar cap: `fi_af_run_budget_left claude` always passes and no claude child (fixer, verifier, classifier) gets `--max-budget-usd`.
- Set, they behave exactly as in 3.2.x: checked before each child, `--max-budget-usd <left>` on each claude child, `run budget spent ($X)` at the cap.
- A sweep's budget (dollars or tokens) covers the whole sweep across its batches (§9): the continuation item carries `cost` and `tokens` forward.
- What still bounds an unattended run: `dailyFixes`, `dailySweeps`, `runTimeoutMin` per child, and the fix-attempt limit. `doctor` prints `no dollar cap` / `no token cap` for unset caps; the setup disclosure says plainly that runs have no dollar cap unless one is set.

## 9. Sweep batches (Decision 4)

- `autofix.sweepMax` (entries one sweep fixes, default 8) is replaced by `autofix.sweepBatch` (fixes per PR, default 8). A set `sweepMax` is still read as the batch size when `sweepBatch` is unset, so a user's existing setting keeps its number.
- At claim time a sweep takes every candidate that passes `_fi_af_sweep_ready` (no count limit). It fixes entries in order. When the batch holds `sweepBatch` fixes and the next entry is in a different file, the batch closes: it ships as one PR (the 3.2.x ship path, unchanged).
- If entries remain after a batch ships, the sweep queues a **continuation**: a new sweep item with `cont=1`, today's `cap_day` (no new daily slot), the chain's `cost`/`tokens`, and `skip_files` (every file an earlier batch of this chain changed). Launcher A's queue drain picks it up straight away; launcher B gets it at the next hook launch like any queued sweep.
- A continuation claims like a sweep, with a fresh worktree and branch from `origin/<base>`, a base test run, and a recomputed candidate list. It skips classify and the daily cap, and leaves out entries in `skip_files` (logged `sweep: skip <loc> (file in an earlier batch's PR)`), which stay eligible for the next sweep after those PRs merge. This keeps batch PRs free of conflicts with one another. Entries an earlier batch shipped are excluded already, because their source-ledger `(PR: …)` annotation makes them not fixable.
- A batch whose ship fails takes the 3.2.1 retry path (keep the branch, requeue, retry ship). No continuation is queued, and the remaining entries wait for the next sweep. A run-budget stop or an engine outage ships the current batch and queues no continuation.
- `autofix status` shows a continuation as `sweep (batch <n>)`. The PR title is `fix: found-issues sweep (<k> entries, batch <n>)`. Batch 1 keeps today's title when it is the only batch.

## Decisions (operator, 2026-10-06)

1. Pinned models by default; `inherit` is the opt-out.
2. Fixer and classifier `gpt-6.1-sol` (medium / low effort), verifier `gpt-6-astra` (high). Re-check the Codex model list when the plan is written.
3. Overshoot by one child is acceptable: the cap is checked before each fix, verify and classify child, like the claude dollar budget. No streamed mid-child kill in 3.3.0.

Later decisions (operator, 2026-10-06, relayed by the peer session "Autofix Codex"; releasing them in 3.3.0 was that session's ruling, agreed by the 3.2.1 session):

4. No per-sweep COUNT limit: a sweep fixes every fixable entry and ships a PR every 8 fixes (§9). The batch size is a setting, default 8. `dailySweeps` stays.
5. Codex token caps `autofix.codexRunTokens` / `autofix.codexSweepTokens` are opt-in (unset = no cap). Pinned per-role models stay the default. The Task 0 measurement only informs the docs (§2).
6. No MONEY cap by default: `runBudget` and `sweepBudget` become opt-in (unset = no cap; claude children then get no `--max-budget-usd`) (§8).
7. (3.2.1, already shipped) The setup sweep-trigger picker does not raise sweepMax/sweepBudget.
