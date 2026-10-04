# Auto-fix and auto-sweep (v3.0.0) — design

**Date:** 2026-10-03 · **Status:** approved in brainstorming (all six sections), pending spec review
**Release:** 3.0.0 (operator decision 2026-10-03). Built on the `release/v3` integration branch; one release PR to `main`.

## 1. Goal

When the operator turns it on, issues found during normal work are no longer only logged and left for later:

- An issue that needs **no human decision**, is **fixable now**, can be **proven fixed by the repo's tests** and is **small** gets fixed right away. The fix lands as its own PR from its own worktree, and that PR merges itself.
- When **5 issues are fixable now**, or a fixable critical medium-sized issue exists, one **sweep** fixes up to 8 of them in a single PR.
- Issues that need a human decision go to a **decision queue**. The operator answers them in batches, and each answer makes its issue fixable.
- **Nothing the feature launches ever shows the operator a permission prompt**, in any session permission mode, on Claude Code or Codex.

Success = with the toggle on, a session that logs a `(fix: small)` issue produces a merged fix PR, plus a closed ledger entry after the next sync, with zero operator actions. Crossing the threshold produces exactly one sweep PR, never a pile-up.

## 2. Non-goals (v3.0.0)

- Auto-fixing anything that needs a decision, is large, cannot be proven by tests, or is on the off-limits list (§3.3).
- Repos without GitHub PR mode (`gh` authenticated, GitHub remote). Tags and the decision queue still work there, but nothing auto-launches.
- Automatic rebase of conflicting fix PRs.
- Auto-generated plans for `(fix: large)` issues.
- Desktop notifications.

## 3. Classification

### 3.1 Four questions, one tag

"Easy" is not used. The logging agent answers four questions and records exactly one fix tag:

1. Does the fix need a human decision?
2. Can it be fixed now, or is it blocked?
3. Can a fix be proven correct automatically by a test or build?
4. How big is it: small, medium or large?

| Tag | Meaning | Route |
|---|---|---|
| `(fix: small)` | no decision, ready, provable, small | spot fix (§5) |
| `(fix: medium)` | no decision, ready, provable, medium | counts toward the sweep threshold (§6) |
| `(fix: large)` | no decision but big | never automatic; listed as "needs a plan" |
| `(decide: <question>)` | needs a human decision | decision queue (§3.4) |
| `(manual: <why>)` | unprovable, outside the repo, or off-limits | left for a human |
| `[deferred]` + `(until: <trigger>)` | blocked | wakes up when the trigger fires (§6 step 3) |

**"Needs a decision"** means any of:
- more than one reasonable fix with different behavior;
- a change to an interface or command others depend on;
- product or UX taste;
- anything outside the repo (dashboards, DNS, credentials, another repo);
- irreversible actions (deleting data, migrations, force-push);
- "is this even a bug?".

### 3.2 Severity is priority, not a gate

`[!]` keeps its current meaning and only orders work:
- a critical `(fix: small)` is fixed first;
- a critical `(fix: medium)` triggers a sweep immediately;
- a critical `(decide: …)` is shown to the operator directly at session start instead of only being counted.

### 3.3 Off-limits list (CLI-enforced)

Whatever the logger tagged, `log` and `tag` force `(manual: off-limits: <category>)` when the cited path is one of:
- CI/workflow config: `.github/`, `.gitlab-ci*`, `.circleci/`, `Jenkinsfile`;
- secrets or auth: a path segment or file stem that is exactly `auth`, `secrets`, `credentials` (or starts with `auth.`/`secret.`), plus `.env*`, `*.pem`, `*.key`;
- dependency manifests or lockfiles, by exact file name: `package.json`, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `bun.lock`, `bun.lockb`, `go.mod`, `go.sum`, `Cargo.toml`, `Cargo.lock`, `pyproject.toml`, `poetry.lock`, `uv.lock`, `requirements*.txt`, `Gemfile`, `Gemfile.lock`;
- migrations: a `migrations/` or `db/migrate/` path segment;
- a path outside the repo, or one git does not track.

The list lives in one function with a test per category.

### 3.4 Decision queue

- `found-issues decide` lists the open `(decide: …)` entries, critical first.
- `found-issues decide <entry> --answer "<text>"` records `(decided: <text>)` and removes `(decide: …)`. The entry then counts as fixable-now, and the fixer re-checks its size before acting (it may still turn out large).
- Interactive SessionStart prints `N decisions waiting — /found-issues:decide`. A new `/found-issues:decide` command walks the queue with one picker per question.

### 3.5 New CLI surface

- `found-issues log --fix small|medium|large | --decide "<question>" | --manual "<why>" "<loc — symptom>"`. Logging untagged stays valid.
- `found-issues tag <entry> --fix …|--decide …|--manual …` re-tags an existing entry. This is the only sanctioned writer of tags.
- `found-issues defer <entry> --until pr:<owner/repo#N>|date:<YYYY-MM-DD>|"<free text>"`.
- New tags live in the annotation tail. The parser exposes `FE_fix`, `FE_decide`, `FE_decided`, `FE_manual`, `FE_until` and `FE_autofix_failed`, and `list --json` includes them. Old entries stay valid (untagged = "unclassified").
- **Closing safety:** none of the new tags is a closing token. `sync` and `annotate` behavior is unchanged except for `until:` wake-ups.

## 4. Triggers and launchers

### 4.1 Triggers (CLI, deterministic)

- `log` records a `(fix: small)` entry with auto-fix enabled (§8) and not inside a fixer (§4.4). It writes a queue item to `<state>/autofix/<repo-id>/queue/<id>` and prints `AUTOFIX-QUEUED <id>`.
- `log` or `sync` brings the fixable-now count to `sweepThreshold` (default 5), or records a fixable critical `(fix: medium)`, and no sweep has run today. It queues a sweep and prints `AUTOFIX-SWEEP-DUE <id>`.
- The PostToolUse Bash hook (`post-bash-dispatch.sh`, both harnesses) acts on those markers. Its gate is a builtin substring test, keeping the `lib/hook-gate.sh` zero-fork early-exit contract.

### 4.2 Launcher selection (in the hook)

| Harness | `permission_mode` (hook stdin) | Launcher |
|---|---|---|
| Claude Code | `auto`, `bypassPermissions` | **B: in-session.** The hook returns `additionalContext` telling the main agent to start the plugin agent `found-issues-fixer` (or `found-issues-sweeper`) in the background for item `<id>`. |
| Claude Code | `default`, `acceptEdits`, `plan`, `dontAsk`, missing | **A: headless.** The hook starts a detached `found-issues autofix run <id>`. |
| Codex | any | **A: headless**, Codex engine (§9) |

- **Why acceptEdits goes to A:** it still prompts for Bash, including test commands.
- **Why B is restricted to auto and bypass:** docs (2026-10-03) say plugin agents ignore `permissionMode`, a subagent inherits the parent's mode in auto/acceptEdits/bypass, and background subagents surface prompts in the main session otherwise.
- **The auto-mode classifier:** in auto mode it allows pushes and PRs in the working repo. Three blocks in a row pause auto mode and bring back prompting. So the B fixer never runs raw git or gh; it makes single `found-issues autofix …` calls.

### 4.3 Claim-or-fallback

- A fixer's first action is `found-issues autofix claim <id>`.
- If an item queued for launcher B is still unclaimed when the session's Stop hook runs, the Stop hook starts launcher A for it. The check is a builtin glob over the queue directory. A skipped nudge therefore never strands an item.

### 4.4 Recursion guard

- Issues logged inside a fixer are tagged and queued but launch nothing.
- **Detection, launcher B:** the hook input carries `agent_id`.
- **Detection, launcher A:** the environment carries `FOUND_ISSUES_AUTOFIX_CHILD=1`.
- The main session picks those items up at its next trigger.

### 4.5 Launcher A command (Claude engine)

```
claude -p --model sonnet --max-budget-usd <runBudget> \
  --permission-mode dontAsk --permission-prompts none \
  --allowedTools Read Edit Write Glob Grep "Bash(<test command pattern>)" "Bash(found-issues autofix:*)" \
  --output-format json  < /dev/null   # cwd = the item's worktree
```

**Spike findings (2026-10-03, Claude Code 2.1.289):**
- **`--bare` cannot be used.** It returned `"Not logged in · Please run /login"` under OAuth. The child therefore loads the user's hooks, plugins and CLAUDE.md.
- **The user's CLAUDE.md reaches the child.** In the spike, the operator's git-boundaries rule refused a commit on `main`. Fixers always run on a `fi/autofix/*` branch, and the fixer prompt states the branch and that the run is sanctioned.
- **Off-allowlist calls are denied without a prompt.** `git commit` was denied, listed in `permission_denials`, and the run returned in 11 s.
- **The allowlist pattern syntax needs test-pinning in phase 2.** `Bash(cat:*)` appeared not to apply.
- **Context overhead is real.** A single haiku turn cost about $0.09–0.10. The $2 per-run cap is sized for sonnet with that overhead. Phase 2 measures a real fix run and adjusts the default if needed.

**Phase 2 measurements (2026-10-03, Claude Code 2.1.289, codex-cli 0.159.0, `tests/autofix-live.bats`):**
- **Allowlist contract.** Under `--permission-mode dontAsk --permission-prompts none`:
  - `Bash(x:*)`, `Bash(x *)` and multi-word `Bash(x sub:*)` are prefix matches; `Bash(x)` is exact.
  - Claude Code also auto-allows read-only commands (`git status`, `git log`, even `sh test.sh && git log -1`).
  - Anything that writes is denied without a prompt: `touch`, `git commit`, `curl`, and `sh test.sh; echo "exit=$?"`.
  - Denials land in `permission_denials`.
- **Fixer prompts must be engine-specific.** The first live run failed both engines. Sonnet wrapped the test command in `; echo "exit=$?"`, was denied, and gave up. Codex, told to run nothing but the tests, could not read a file. The Claude prompt now says to run the test command alone and to read with tools; the Codex prompt allows read-only shell. A `manual` result that left a change still goes through bash tests and the verifier.
- **Claude engine.** One fix shipped in 49 s for **$1.58**. That was two sonnet fixer runs and two opus verifier runs: the verifier rejected attempt 1 for adding no test. The `runBudget` default is now **$3** (the next whole dollar above 1.5 × measured).
- **Codex engine.** One fix shipped in 51 s on 167,389 tokens (ChatGPT plan, no USD cost reported).

## 5. Fixer flow (both launchers)

1. **Claim.** `autofix claim <id>` checks:
   - the entry is still `[open]`, still `(fix: small|medium)` or `(decided: …)`, and carries no PR or commit annotation;
   - the daily cap allows it;
   - the repo lock is free (atomic `mkdir`; stale after 60 min).

   For A it then runs `git fetch` and `git worktree add <repo>/.claude/worktrees/fi-autofix-<id> -b fi/autofix/<slug>-<ts> origin/<default>`. For B it renames the Claude Code worktree branch to the same scheme.
2. **Re-check.** Is the symptom still present at `origin/<default>`?
   - Already fixed → `autofix release <id> --already-fixed "<evidence>"`.
   - Hidden decision → `--decide "<question>"`, which retags the entry.
   - Unprovable → `--manual "<why>"`.
3. **Failing test first** with the repo's test command:
   - Detection: `found-issues.autofix.testCommand`, else `bats tests/`, `npm test`, `pytest`, `go test ./...`, `cargo test` or `make test`, by marker files.
   - If no command is found, the issue is released as `(manual: no test command)`.
4. **Minimal fix**, then full tests and build. At most 2 attempts. If it still fails, the worktree is discarded and the entry gets `(autofix-failed: <reason>)`, which is never retried automatically.
5. **Verifier**, on opus at high effort. It gets only `autofix diff <id>` output and the entry `raw`.
   - **B:** a nested plugin agent `found-issues-verifier` with tools `Read, Grep, Glob`.
   - **A:** a second `claude -p --model opus --allowedTools Read Grep Glob`, or `codex exec -s read-only`.
   - **Verdict:** JSON `{approve, reason}`. Approve only if the diff fixes the cited symptom, changes nothing else, and the test reproduces the symptom. A reject counts as an attempt.
6. **Ship.** `autofix ship <id>` is bash and does the following, in order:
   - re-runs the test command itself and refuses on red;
   - commits as `fix: <symptom fragment> (found-issues <loc>)`;
   - pushes and runs `gh pr create` (body: entry, test evidence, verifier verdict, run cost);
   - runs `annotate-pr <N> --pick <loc>` in the worktree and commits that ledger change onto the PR branch, then pushes (audit prompt-9);
   - runs `gh pr merge <N> --auto --squash`. If auto-merge cannot be armed, a detached `autofix merge-when-green <N>` waits on `gh pr checks` and merges on green, or right away when the repo has no checks.
7. **Close.** The next sync flips the entry on merge, as today. The run log gets a one-line result.

**PR merge policy:** fix PRs **always** merge themselves (operator decision 2026-10-03). Setup must state this before enabling (§8).

## 6. Sweep

**Trigger:** §4.1. Max 1 per repo per day, at most `sweepMax` (default 8) entries.

1. **Workspace.** A fresh worktree from `origin/<default>` after `git fetch`, on branch `fi/sweep/<YYYYMMDD>-<n>`. It refuses a dirty tree and uses `--cwd` on every `list`/`status` call (audit prompt-8).
2. **Classify untagged entries.** A read-only pass that writes tags via `found-issues tag`.
3. **Wake blocked entries.**
   - `sync` handles `until: pr:` (merged) and `until: date:` (passed) mechanically, as `[deferred]` → `[open]` with the tag kept.
   - The sweep re-judges free-text triggers.
4. **Fix** up to `sweepMax` fixable-now entries: critical first, same-file groups, then oldest. Each runs §5 steps 2–5 and becomes one commit. A failure reverts that entry only.
5. **Ship** one PR. Each fixed entry is annotated with `--pick`, the ledger is committed into the PR, and auto-merge is armed (shared `autofix ship` path).
6. **Never touched:** `(decide:)`, `(manual:)` and `(fix: large)` entries. Large ones are listed as "needs a plan" in the summary.

**Interactive `/found-issues:fix`** keeps its approval gate. It shares steps 1, 5 and the test-command detection, which fixes audit prompt-8, prompt-9 and prompt-10.

**Headless runs see a clean context (audit prompt-11).** SessionStart onboarding and statusline nudges run only when `CLAUDE_CODE_ENTRYPOINT` is empty or `cli`.

## 7. Caps

| Setting | Default |
|---|---|
| Spot fixes per repo per day | 5 |
| Sweeps per repo per day | 1 |
| Max entries per sweep | 8 |
| Per background run | $3 (`--max-budget-usd`; was $2, raised after the Phase 2 measurement) |
| Turn cap per fixer | `maxTurns` in the agent definition (B) and turn limit (A) |

Over the cap, an item waits for the next day and the summary says so.

## 8. Settings, setup, visibility, safety

- **Settings live in git config.** `found-issues.autofix` (bool; `--global` = default, local = per-repo override), plus `.autofix.engine` (`auto|claude|codex`), `.testCommand`, `.dailyFixes`, `.dailySweeps`, `.sweepThreshold`, `.sweepMax` and `.runBudget`. `found-issues config` wraps them.
- **Kill switches:** `found-issues autofix off` and `FOUND_ISSUES_AUTOFIX=off`.
- **Setup:** `/found-issues:setup` gains an auto-fix step that states, before enabling:
  - fix PRs merge themselves;
  - runs bill the user's account, including in the background;
  - the default caps;
  - how to turn it off.
- **Statusline:** `🔧N` (running) and `❓N` (decisions waiting), read from a state file by the existing builtin segment path (no new forks).
- **`found-issues autofix status`:** queue, running, today's counts against caps, and recent results with PR links and cost (from `total_cost_usd`).
- **SessionStart summary** (interactive only): "Since last session: fixed N (PR …), M failed (reason), K decisions waiting".
- **Logs:** one per run under `<cache>/autofix/<repo-id>/runs/`.
- **Cancel:** `autofix cancel <id>` kills a running background fix and its process group.
- **Failure handling:**
  - a crashed run is requeued once, then `(autofix-failed: crashed)`;
  - a conflicting PR is reported, not rebased;
  - A worktrees are removed after ship or failure; B worktrees are left to Claude Code's cleanup and the reaper.
- **`doctor`:** an auto-fix section showing enabled state, test command, gh auth, `claude`/`codex` on PATH, and caps.

## 9. Codex

- Always launcher A with the Codex engine: `codex exec --sandbox workspace-write -C <worktree> --ephemeral -o <last-msg>`. The verifier uses `-s read-only` and higher reasoning effort.
- **The engine is chosen by `engine=auto`:** Codex sessions use Codex, Claude sessions use Claude.
- **Spike (2026-10-03, codex-cli 0.159.0):** it edited in the sandbox with no prompt, a failed push surfaced as an error, and it took 69 s. The found-issues rules reached `codex exec`.
- Push, PR and merge run in our bash, outside the Codex sandbox.
- Triggers come from the existing Codex PostToolUse Bash hook.
- `fi-*` skills and the rules text get the tag instructions, regenerated by `gen-codex-skills.sh`.

## 10. Testing

- **bats** for:
  - tag parsing and `list --json` fields;
  - off-limits categories;
  - queue, claim, lock and stale-lock behavior;
  - caps;
  - trigger markers;
  - launcher selection for every combination of `permission_mode` and harness;
  - the recursion guard;
  - the claim fallback at Stop;
  - `until:` wake-ups;
  - config resolution (global vs local);
  - `ship` against a local bare remote and the `gh` stand-in;
  - `release` paths;
  - `--cwd` consistency.
- **Stand-in `claude` and `codex` binaries** on PATH make scripted edits, so full spot-fix and sweep flows run end to end in CI at zero cost.
- **Bash 3.2 subset** locally before each phase PR (macOS CI runs only post-merge on main).
- **Live E2E before the 3.0.0 release**, on a private throwaway GitHub repo:
  - one spot fix and one sweep through each launcher;
  - real Claude and real Codex;
  - launcher B in a real auto-mode session.

  Evidence is quoted in the release PR.

## 11. Delivery

Six phases. Phases 1–5 build and release 3.0.0; phase 6 audits the whole plugin and burns its own ledger down.

- **Phase PRs** target `release/v3` (phase 1 adds `release/v3` to the CI workflow's `push`/`pull_request` branch lists):
  1. Tags, `tag`/`decide`, decision queue, `/found-issues:decide`, off-limits, `until:` parsing and wake-ups.
  2. Queue, claim, lock, caps, `release`, `ship`, `merge-when-green`, launcher A (Claude + Codex engines), allowlist pinning, cost measurement.
  3. Plugin agents `found-issues-fixer`/`-verifier`/`-sweeper`, launcher B, hook launcher selection, Stop fallback, recursion guard.
  4. Sweep, and `/found-issues:fix` on the shared plumbing (prompt-8..11).
  5. Statusline, status, SessionStart summary, setup disclosure, doctor, docs (`docs/versioning.md` breaking-change note), 3.0.0 bump, live E2E.
- **Final step:** one PR `release/v3` → `main` bumps to 3.0.0, then the marketplace bump follows the source release.

### Phase 6 — whole-plugin audit and ledger burn-down (added 2026-10-03, operator request)

Runs on `main` after 3.0.0 is released, against the **whole plugin**, not just the v3 diff.

1. **Full audit, same method as `docs/audits/2026-10-03-audit/`:**
   - read-only sonnet finders per area (ledger/sync, hooks, annotate, CLI, statusline, prompts and commands, Codex, and the new auto-fix code);
   - an adversarial opus verifier per finding;
   - orchestrator runtime repros, and a re-measurement of process counts.

   Output goes to `docs/audits/<date>-audit/`. No finder or verifier may write files outside its scratch directory or trigger permission prompts.
2. **Log every confirmed finding** with `found-issues log` and a fix tag (dogfooding §3). Lows are logged too; nothing is "too small to track".
3. **Burn down found-issues' own ledger to zero**, or as close to zero as can be done properly:
   - `(fix: …)` entries go through the v3 sweep (dogfooding §6), with interactive `/found-issues:fix` for anything the sweep releases.
   - `(decide: …)` entries go to the operator via `/found-issues:decide`; once decided, they are fixed.
   - `(manual: …)` entries are either fixed by hand with a test, or kept with a written reason.
   - Every fix is TDD, has its own PR, merges on green, and its post-merge macOS run is watched to a terminal state. New problems found along the way are logged and fixed under the same rules.
   - Releases follow SemVer: 3.0.x for fixes, 3.1.0 if anything is added. Each source release gets its marketplace bump.
4. **Driven by `/goal`**, drafted via `prompt-handoff`. The condition is reached when:
   - `docs/found-issues.md` on `main` has no `[open]` entries, or every remaining `[open]` entry carries `(decide:)` awaiting the operator or `(manual:)` with a reason;
   - the last full `bats tests/` run in the session passed and was shown;
   - every fix PR is merged with its post-merge `tests` run green.

   It stops after a stated turn cap.
- **Merge `main` into `release/v3`** whenever `main` moves.

## 12. Risks

| Risk | Mitigation |
|---|---|
| Agents over-tag `fix: small` | Fixer re-check, opus verifier, CLI re-runs tests, 2-attempt limit, caps |
| Background spend is invisible | Caps, per-run cost in status and summary, setup disclosure, kill switch |
| User CLAUDE.md or hooks interfere with launcher A | Fixer prompt names the branch and the sanctioned scope; denials end the run cleanly and are logged |
| Auto-mode classifier pauses after 3 blocks (launcher B) | B fixers only run `found-issues autofix …` and test commands |
| Allowlist pattern syntax differs by Claude Code version | Pinned by test in phase 2; `doctor` reports the CLI version |
| Docs facts change (plugin agent fields, permission inheritance) | The facts B relies on are listed in §4.2 with date; `doctor` re-checks the observable ones |
