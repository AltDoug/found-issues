# Verifier brief (shared)

You are an ADVERSARIAL VERIFIER for an audit of `found-issues` (bash CLI + Claude Code/Codex hooks).
Repo root (read only from here): /Users/diogosilvasena/Documents/projects/found-issues/.claude/worktrees/audit-2026-10-03

HARD TOOL RULE: use only Read / Grep / Glob, only under the repo root. If those tools are unavailable, read-only `cat`, `sed -n`, `rg`, `ls` via Bash on paths under the repo root are acceptable. Never write, edit, run tests, or execute the CLI/hooks. (Anything else could raise permission prompts.)

Your input: one findings file `docs/audits/2026-10-03-audit/findings-<area>.json`. For EACH finding:
1. Read the cited code and every code path the claim depends on (callers, guards earlier in the flow, tests in tests/*.bats that pin the behavior).
2. Try hard to REFUTE it: an earlier guard, a caller that never passes that input, a test proving the opposite, a misread regex, a platform claim that is wrong.
3. Verdict:
   - CONFIRMED — the code path exists as claimed and the failure scenario follows (cite the decisive lines).
   - PLAUSIBLE — code reading supports it but it hinges on runtime/platform behavior (give the minimal repro the orchestrator should run).
   - REFUTED — explain what the finder missed (cite lines).
4. For CONFIRMED/PLAUSIBLE: re-grade severity (high = data loss / false close / guard bypass / session breakage; medium = wrong result or real friction/resource cost on a hot path; low = edge case or cosmetic) and say whether the suggested fix is correct and minimal; propose a better minimal fix if not.
5. Mark duplicates: the same root cause appears across files. Known cross-file duplicates: concurrent unlocked ledger rewrites (ledger-1 / status-4 / annot-6); mktemp -t in $TMPDIR non-atomic mv (ledger-2 / annot-6 part / cli-23); autosync cwd + global stamp (status-2 / status-3 / ledger-9); annotate per-line grep (annot-1 / ledger-18); promote verbatim match (prompt-7 / cli-8); pipefail SIGPIPE `printf | grep -q` (hook-1 / cli-9 / hook-19); default-branch 'main' fallback (ledger-10 / cli-13); gh auth before mode cache (ledger-8a / cli-11). Note any others you see.

Context: measured on Linux strace — sync ≈ 65 forks / 36 execs per [open] entry; SessionStart ≈ 517 forks (6 open entries); Stop ≈ 22 forks; PreToolUse Edit on non-ledger file 7 forks; Bash hooks 0 forks. Platforms: Linux, macOS /bin/bash 3.2, Windows Git Bash (process creation is expensive and leaks kernel tokens).

OUTPUT (final message only): a JSON array, one item per input finding, in input order:
{"id":"...","verdict":"CONFIRMED|PLAUSIBLE|REFUTED","severity":"high|medium|low|n/a","duplicate_of":"id or empty","reason":"2-4 sentences with decisive file:line citations","fix":"minimal correct fix, or empty if refuted","repro":"minimal repro for PLAUSIBLE, else empty"}
