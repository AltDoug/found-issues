# Handoff — Stop hook not firing (critical)

**Created:** 2026-05-12
**From session:** Diogo + Claude Opus 4.7 (1M ctx) — investigating "issues not being logged, statusline not changing in orchard/agent-config"
**Status:** Diagnosed but unfixed. Root cause NOT YET LOCALIZED.
**Reference PR:** https://github.com/AltDoug/found-issues/pull/80 (lands the [open] entry tracking this)
**Issue location:** [`docs/found-issues.md`](../../found-issues.md) — most recent `[open]` entry, dated 2026-05-12, path `hooks/stop-reminder.sh`

---

## The problem in one sentence

The plugin's Stop hook (`hooks/stop-reminder.sh`) is not firing in any Claude Code session, so Claude is never being nudged to log out-of-scope observations to `docs/found-issues.md`. Auto-logging across all of the operator's repos has been dead since ~2026-05-04.

## Why it matters

The Stop hook is the load-bearing piece of the plugin's "AI logs on its own" promise. Without it, Claude only writes to `docs/found-issues.md` if explicitly asked. The plugin's central value proposition is broken.

## Evidence collected today

Transcript sweep of three repos:

| Repo | Transcript | Tool uses | Hook-written `found-issues-checked` markers |
|---|---|---|---|
| `~/Documents/projects/orchard` | 2.5MB recent | Extensive Bash | **0** |
| `~/Documents/projects/agent-config` | 2.6MB recent | 32 substantive | **0** |
| `~/Documents/projects/found-issues` (the session that opened this handoff) | 4.6MB | Many | **0** (initial false positive count of 8 was all *prose self-citation* — the agent talking about the marker while diagnosing) |

Auto-log activity timeline:
- orchard: last log committed 2026-05-03; working tree had uncommitted entries up to 2026-05-04, nothing after
- agent-config: similar pattern — last entry 2026-05-10 was a manual deferred entry, no auto-logs after 2026-05-04
- Plugin installed/upgraded 2026-05-10 (v1.0.x → v1.1.0) and 2026-05-12 (→ v1.2.0). Logging stopped BEFORE the v1.1.0 install.

## What's been ruled out (don't re-investigate)

1. **Plugin not installed.** It is — `~/.claude/plugins/installed_plugins.json` shows `found-issues@altdoug-plugins` v1.2.0 (post-2026-05-12 update).
2. **CLI binary broken.** `bin/found-issues --version` reports correctly. `bin/found-issues status --format=segment` produces correct counter output (orchard: `21 other · 6 in PR`, agent-config: `3 issues`).
3. **Statusline integration broken.** Segment block IS in `~/.claude/statusline.sh` with marker comments. Simulated render shows the count correctly. The user "doesn't see the statusline changing" because the count IS stable — auto-logging stopped so nothing changes.
4. **`/found-issues:sync` broken.** Sync IS running — orchard has ~21 uncommitted auto-flips from sync detecting merged PRs. Cross-repo PR detection just shipped in v1.2.0 and was validated end-to-end against real CLOSED + MERGED PRs.
5. **SessionStart hook broken.** It works — sync runs at session start, statusline reflects current count.
6. **`FOUND_ISSUES_STOP_REMINDER=off` set.** Not set — `env | rg FOUND_ISSUES` returned nothing.
7. **Project-level `.claude/settings.json` interference.** **Invalidated by agent-config evidence** — agent-config has NO project-level settings yet shows the same gap. orchard has its own `.claude/settings.json` with hooks for ConfigChange/Elicitation/PostToolUse/etc., but that doesn't explain agent-config.
8. **Plugin PreToolUse hooks broken.** They are NOT broken — verified by `hooks/pre-branch-delete.sh` correctly firing TWICE during this session (blocked a `git branch -D` for an [open]-tracking branch). PreToolUse Bash dispatch is healthy.

## What we know about the bug shape

- The Stop event in Claude Code is **not invoking the plugin's `hooks/stop-reminder.sh`**, OR it IS invoking it but Claude isn't responding to the marker-required signal.
- It's NOT a "plugin hooks generally broken" issue — PreToolUse plugin hooks work fine (proven).
- It's NOT specific to repos with project-level hook configs (proven by agent-config).
- It IS plugin-wide (every repo affected).
- It started at some point in the last 8-10 days. Don't know exactly when.

## Suggested next step — debug instrumentation

This is the cheapest way to localize the bug. **Three lines of bash. Then run a multi-turn session in any repo and check the file.**

### Step 1: Instrument the hook

Edit `hooks/stop-reminder.sh` in this repo. After the shebang and comments, BEFORE the `set -euo pipefail` line, add:

```bash
# DEBUG: log every invocation to localize Stop-hook firing
mkdir -p "${HOME}/.cache/found-issues" 2>/dev/null
printf '%s pid=%s ppid=%s args=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "$PPID" "$*" \
  >> "${HOME}/.cache/found-issues/stop-debug.log" 2>/dev/null || true
```

The `printf` is unconditional. It writes even on opt-out paths. It captures pid + ppid so we can correlate with Claude Code's process tree if needed.

Commit this change to a branch like `debug/stop-hook-instrumentation` and DON'T merge yet — it's diagnostic only.

### Step 2: Reproduce

1. Start a NEW Claude Code session in **this repo** (or any repo with v1.2.0 plugin installed)
2. Do at least 3 substantive turns that include Bash or Write tool use. The Stop hook smart-fire requires substantive tool use in the most recent turn.
3. End the session normally (let Claude finish, don't `Ctrl-C`).

### Step 3: Inspect the debug log

```bash
cat ~/.cache/found-issues/stop-debug.log
```

### Decision tree based on output

**Case A: File doesn't exist OR is empty.**

→ **Stop hook is never being invoked by Claude Code.** Upstream bug.

Next steps:
1. Verify plugin hook registration: check `~/.claude/plugins/installed_plugins.json` for `found-issues@altdoug-plugins`, confirm path resolves to a dir containing `hooks/hooks.json`.
2. Read that `hooks/hooks.json` and confirm the Stop array still references `${CLAUDE_PLUGIN_ROOT}/hooks/stop-reminder.sh`.
3. Check Claude Code version: `claude --version`. The behavior may be version-specific.
4. File upstream issue at https://github.com/anthropics/claude-code/issues with:
   - Repro: any session with this plugin installed
   - Expected: Stop hook in plugin's hooks.json should fire on Stop event
   - Actual: hook never invoked; debug log empty
   - Compare: PreToolUse hook from same plugin fires correctly (e.g., `hooks/pre-branch-delete.sh`)
5. Update [`docs/found-issues.md`](../../found-issues.md) entry's status with the verdict.

**Case B: File fills with entries (one per Claude turn).**

→ **Hook is firing.** The bug is in how the hook surfaces the marker requirement to Claude (stderr/exit code semantics).

Next steps:
1. Read [`hooks/stop-reminder.sh`](../../../hooks/stop-reminder.sh) lines around 80-110 to see the marker-block logic.
2. Check whether the exit-2-with-stderr pattern is being followed correctly.
3. Try a Claude Code update — maybe the stderr surfacing protocol changed between versions.
4. Consider adding a minimal repro test: a script that exits 2 with stderr; verify Claude responds to it.

**Case C: File has SOME entries but inconsistent (some turns missing).**

→ **Smart-fire logic is too lenient.** Some turns are slipping past the substantive-tool-use check.

Next steps:
1. Review the awk-based "most recent assistant turn" extraction in [`hooks/stop-reminder.sh`](../../../hooks/stop-reminder.sh) lines 50-80.
2. The grep for `"name":"(Edit|Write|MultiEdit|Bash|NotebookEdit)"` may be missing newer tool names. Check Claude Code's current tool list.

## Key file paths

| File | Purpose |
|---|---|
| `hooks/stop-reminder.sh` | The hook itself. ~140 lines. Self-documented at top. |
| `hooks/hooks.json` | Plugin hook registry. Stop array declares stop-reminder.sh. |
| `docs/found-issues.md` | Where the [open] tracking entry lives (most recent line in this repo) |
| `~/.claude/plugins/installed_plugins.json` | User's plugin install metadata — confirms v1.2.0 |
| `~/.claude/plugins/cache/altdoug-plugins/found-issues/1.2.0/` | Installed plugin contents |
| `~/.claude/projects/*/...jsonl` | Session transcripts for diagnosis |

## Useful one-liners

```bash
# Count Stop-hook markers across recent transcripts
for t in $(fd -e jsonl . ~/.claude/projects --changed-within 24hours); do
  count=$(rg -c "found-issues-checked" "$t" 2>/dev/null || echo 0)
  size=$(wc -c < "$t")
  printf '%s\t%s\t%s\n' "$count" "$size" "$t"
done | sort -k1,1n | head -20

# Find largest recent transcript in a given repo
fd -e jsonl . ~/.claude/projects/-Users-diogosilvasena-Documents-projects-orchard \
  --changed-within 7days | xargs ls -S 2>/dev/null | head -1

# Confirm hook is registered
jq '.hooks.Stop' /Users/diogosilvasena/.claude/plugins/cache/altdoug-plugins/found-issues/1.2.0/hooks/hooks.json

# Manually invoke the hook with a synthetic Stop event (to confirm it works in isolation)
echo '{"transcript_path":"/tmp/empty.jsonl"}' \
  | bash /Users/diogosilvasena/.claude/plugins/cache/altdoug-plugins/found-issues/1.2.0/hooks/stop-reminder.sh
echo "exit: $?"
```

## What to do AFTER fixing

1. Update [`docs/found-issues.md`](../../found-issues.md) entry's `[open]` → `[fixed]` with the PR annotation
2. Delete this handoff doc OR move it to a "resolved" subdir for historical reference
3. Consider adding a bats test that asserts the Stop hook fires correctly in a synthetic session — would have caught this earlier

## Loose threads worth noting (lower priority)

1. PostToolUse hooks (`post-pr-create.sh`, `post-git-commit.sh`) MAY also not be firing. Not verified directly today, but if the operator hasn't been getting prompts to `/found-issues:annotate-pr` after `gh pr create` runs in those repos, that's the same root cause.

2. The pre-existing `[deferred]` entry in `docs/found-issues.md` about `cmd_install_statusline` render-target awareness is a SEPARATE bug — don't conflate.

3. Several local branches accumulated state today (`fix/setup-detect-custom-statusline` was merged + cleaned; `chore/sync-flips-and-stop-hook-log` is still local because the pre-branch-delete hook blocked cleanup). Harmless; user can `FOUND_ISSUES_PROMOTE_GUARD=off git branch -D <name>` from their shell.

---

**Pickup signal for next session:** if you're a fresh Claude reading this, your first command should be:

```bash
cat ~/.cache/found-issues/stop-debug.log 2>&1 | head -20
```

If you see entries → start at Case B above.
If you see "No such file" → start at Step 1 (instrument), Step 2 (repro), Step 3 (inspect).
