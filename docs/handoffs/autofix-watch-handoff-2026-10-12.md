# found-issues auto-fix watch — Session Handoff

**Date:** 2026-10-12 · **Session:** found-issues "Ship 384"
**Status:** v3.8.4 fully shipped; auto-fix watch on kh2-midgar continues; v3.9 is designed but waits for the operator's "go 3.9" on Wanda.
**Re-verification rule (operator's standing feedback):** do NOT act on this doc's claims without re-verifying against the repo / live state first. Ground truth: `gh release list --repo AltDoug/found-issues --limit 3`, `gh pr list --repo AltDoug/found-issues --state open`, the watch tick output, `bash ~/.claude/skills/away-mode/scripts/away.sh digest`.

## TL;DR for the next session

- Nothing is mid-flight in code. v3.8.4 is released and green; the only open PR on found-issues at write time was #171 (external, jbelmana).
- The operator is asleep/away. He decides on Wanda (thread `found-issues`). The build trigger is the literal reply "go 3.9". Without it: watch only, queue nothing new.
- Your standing job is the auto-fix watch: a 30-minute tick plus one Wanda listener, watching kh2-midgar auto-fix items now running under a 60-minute timeout.
- Proposed v3.9 = per-repo readiness gate + a "superseded" retire for `lib/autofix-ship.sh:206`.
- Work only in WT (below). Never touch the main checkout.

Paths:
- WT = `/Users/diogosilvasena/Documents/projects/found-issues/.claude/worktrees/fi-watch-20261012`, branch `docs/handoff-autofix-watch-20261012`, cut from origin/main `042986d`. This doc lives here; you work here.
- Main checkout `/Users/diogosilvasena/Documents/projects/found-issues`: never edit it (peers' uncommitted changes).
- Memory dir: `/Users/diogosilvasena/.claude/projects/-Users-diogosilvasena-Documents-projects-found-issues/memory/` (`release-3-8-4-shipped.md` and `midgar-autofix-worktreefiles.md` were updated this session).

## What was done (verify via PR descriptions / commits)

- **v3.8.4 shipped.** PR #248 merged `34ad296`; fix ship ran the full suite: `tests: pass — 1830 planned, 1827 ok, 0 not ok, 3 skipped`. Release v3.8.4 is Latest (2026-10-11T14:23:11Z). Post-merge tests run 38146953124 green on all jobs including ubuntu and macos bats. claude-plugins #69 merged `8b13aa8` (marketplace 3.8.4).
  - Contents: `autofix cancel` keeps a running item's commits on `fi/rescued/<id>` (`lib/autofix-status.sh:79`, operator decision); `fi_af_root_key` caps long root names so a root over 255 bytes no longer aborts a retire and wedges the lock (`lib/autofix-status.sh:231`).
  - Verify drive: on 3.8.3 a 371-char root gave "File name too long", cancel rc=1, lock held; on 3.8.4 rc 0, lock released, rescued branch = run commit.
- **Ledger sync PR #249** merged `e40ff13` (closed the two #248 entries, archived ten 2026-10-04 fixed entries).
- **PR #250** merged `042986d` logged a new entry `lib/autofix-ship.sh:206` (decide): an auto-fix run never checks whether its base moved under the cited file, so it ships PRs superseded by a live session's fix (kh2-midgar#19, agent-config #572/#576/#592).
- **dougstation** auto-updated to found-issues 3.8.4.
- **kh2-midgar timeout 40 -> 60 min** (`found-issues.autofix.runTimeoutMin`, repo-local `.git/config` on dougstation, both checkouts read 60; ~19:20 EDT 2026-10-11, operator request). Measured: base suite (bats ~15.5 min + pytest) takes 39m44s-42m41s and is growing (pytest 24:01 -> 27:04 in 4.5 h); under 40 a fixer run also timed out (rc=124). First run under 60 (item 20261011-160732-24507) passed base tests in 42m41s and retired `manual` for $0.12 (no menu-open telemetry to assert on).
- **kh2-midgar PR #19** (auto-fix, `tools/verify/party_fx.jq:31`) closed unmerged by this session as superseded by kh2-midgar commit `6cdefeb`. The live kh2-midgar session on dougstation was asked to annotate that entry to `6cdefeb` in its phase-03 ledger (unconfirmed; that ledger is theirs).
- **Effectiveness overview given in chat:** 157 finished items 2026-10-04..10-11, $62.95 API-equivalent; 22 PRs (19 merged, 0 reverted, 3 closed as duplicates), 36 entries fixed; 89 stale (cheap, $6.88), mostly setup gaps (no test command 39, red base 26, timeouts 10). Correction sent later: sayciao and bruhsailer got test commands on 2026-10-10 and both shipped right after; only skate still lacks tests.
- **Reliability answer sent over Wanda** (thread `found-issues`): auto-fix should be on per repo only with a test suite covering the code where entries are logged, green on the landing branch, running in about 15 min or less. Proposed v3.9: per-repo readiness gate (detect test cmd, run once, record green/red + duration, set timeout ~2x measured; not-ready repos queue nothing and show one "auto-fix waiting here: <reason>" line) plus a superseded-run retire for `lib/autofix-ship.sh:206`. Recommended switching skate off.

## Remaining work

Do ALL of these, top-down; do not narrow scope.

1. Arm ONE background `~/.claude/bin/wanda-msg watch --thread found-issues --until-message` listener (background Bash, never Monitor). Recreate `tick.sh` and `CronCreate` `7,37 * * * *`, then run one tick (recipe under State snapshot).
2. Check the inbox: `~/.claude/bin/wanda-msg inbox --thread found-issues`. If the operator replied "go 3.9": build v3.9 on a fix branch in WT. Brainstorm-light design note first, TDD, then the readiness gate plus the `lib/autofix-ship.sh:206` superseded retire (his chosen variant; default = retire-as-superseded). Then the usual ship path: `fix ship`, auto-merge (AltDoug policy), release, post-merge tests on ubuntu + macos, claude-plugins marketplace bump, memory update. Without his go: watch only, queue nothing new.
3. Keep watching kh2-midgar auto-fix items under the 60-minute limit; log outcomes in `midgar-autofix-worktreefiles.md`. In flight at handoff: sweep `20261012-000344-28872` (launcher A, claimed ~00:06 EDT 2026-10-12, the first sweep under 60): did its base tests finish, what did it fix and cost?
4. Commit this handoff doc on WT's branch as a docs-only PR (auto-merge) if the predecessor did not already (`gh pr list --state open` first).

Queued decisions in `away.sh digest` (operator answers on return): build v3.9 readiness gate (recommend yes); switch skate auto-fix off (recommend off); `lib/autofix-ship.sh:206` superseded behaviour (recommend retire as superseded).

## Known live hazards (verify each before relying on it)

- Foreground Bash over 120 s is refused while away mode is on: use `run_in_background`.
- Harness gates match command text: run tests as bare `bats …`; keep the literal PR-create command text out of non-PR Bash commands.
- The post-bash hook writes `(commit-auto: …)` suggestions into the ledger after commits; strip them with `found-issues unannotate`.
- Scratchpad paths exceed 255 bytes: drive auto-fix scenarios from `mktemp -d`, never from the scratchpad.
- Never edit kh2-midgar's phase-03 ledger (the live kh2-midgar session owns it).
- 1Password quota: `wanda-msg` exit 75 means quota gone; queue the message instead of retrying. Wanda pings are gated by `away.sh push-ok --key found-issues`; a reply to the operator is not gated.
- Strict branch protection on found-issues main: a BEHIND PR needs `gh pr update-branch`.
- A launcher-B (in-session) fixer once went silent after its claim and held kh2-midgar's lock about 1 h. found-issues self-healed at 17:48:32 (lock aged past `FOUND_ISSUES_AUTOFIX_LOCK_STALE=3600` s, item requeued as a crash). By design, not a defect.
- Peer-owned worktrees: old chain worktrees B6/B7/B8 (nested under `.claude/worktrees/v3-4-0/...`) are merged, but their ledgers hold uncommitted diffs on purpose. Never `git checkout` them, never `git add -A`, never `git stash`.

## State snapshot (re-verify)

- Releases: v3.8.4 Latest, then v3.8.3 and v3.8.2 (`gh release list`). main head at write time `042986d`.
- Open ledger on main: `tests/cli-list.bats:28` (manual), `lib/autofix-ship.sh:206` (decide), plus three old `[deferred]`.
- Away mode ON on the Mac (sleep) since 2026-10-11 23:19 EDT (re-set after the kh2-midgar broadcast); dougstation was set from the live kh2-midgar session.
- Leftover temp worktree: `/var/folders/pb/b_ywfm113rzb0s98gj0cg5q00000gn/T/tmp.2vTeV7UmbQ/fi-sync384` (branch `chore/log-autofix-superseded`, merged). Removing it is a delete: ask the operator first.
- **Watch recipe:** tick script = main's `docs/handoffs/v3.8.2-assets/tick.sh` copied into your session scratchpad with a `tick.last` file (epoch seconds; seed with now-1800); `CronCreate` `7,37 * * * *`.
- **Remote helper pattern (dougstation):** write a small script locally, `scp` it to `silva@100.98.153.101:<name>.sh`, run via `ssh ... "& 'C:\Program Files\Git\bin\bash.exe' -lc 'bash ~/<name>.sh'"`. Inline quoting through PowerShell breaks on parentheses and quotes.
- **dougstation auto-fix state:** `~/.claude/found-issues/autofix/<slug>/` (queue, running, done, lock); logs `~/.cache/found-issues/autofix/<slug>/runs/<id>.log` and `.base-tests.log`. Windows-native processes need `Get-CimInstance Win32_Process` (Git Bash `ps` misses them).

## Resume prompt

> Work in /Users/diogosilvasena/Documents/projects/found-issues/.claude/worktrees/fi-watch-20261012 on branch docs/handoff-autofix-watch-20261012; never edit the main checkout, never `git add -A`, never `git stash`, never `git checkout` a ledger. Confirm `gh auth status` shows AltDoug active, and invoke the away-mode skill if `away.sh status` says ON. Read docs/handoffs/autofix-watch-handoff-2026-10-12.md end to end and re-verify every claim against live state (`gh release list`, `gh pr list --state open`, `wanda-msg inbox --thread found-issues`, `away.sh digest`). Then do the Remaining work section top-down, ALL items, never narrowing scope: arm the Wanda listener and the 7,37 tick, build v3.9 only if the operator replied "go 3.9", keep watching kh2-midgar under the 60-minute timeout, and land this handoff doc as a docs-only PR. Once you are up and safe, close the stale predecessor (the previous found-issues session) per handoff section 6. End commit messages with "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" and PR bodies with "🤖 Generated with [Claude Code](https://claude.com/claude-code)".
