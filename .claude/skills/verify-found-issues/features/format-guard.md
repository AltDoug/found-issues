---
feature: Ledger format guard
also-called: format-enforcer, format violations, pre-commit
sources:
  - hooks/format-enforcer.sh
  - hooks/pre-commit.sh
proven-with: hand-built hook payloads (no Claude Code or Codex)
proven: 2026-11-27
---

## What it is

Rejects malformed ledger lines: in the agent's file edits (hard block on GitHub repos, warning in plain git) and, if installed, at `git commit`.

## Parts

| What you see | What it does | Drive it by |
|---|---|---|
| `found-issues format violations in found-issues.md:` and exit 2 | Blocks the Write or Edit (GitHub modes) | a Write payload for `docs/found-issues.md` in a `--github` sandbox |
| The same text as `additionalContext`, exit 0 | Plain git: warns only | the same payload in a plain sandbox |
| `found-issues: pre-commit format violations` and exit 1 | The optional git hook | copy `hooks/pre-commit.sh` to `.git/hooks/pre-commit` |
| Silence | Switches | `FOUND_ISSUES_FORMAT_ENFORCER=off` before the hook name; `FOUND_ISSUES_PRE_COMMIT=off` for the git hook |

## How to get to it

It fires before the agent's Write, Edit or MultiEdit; the git hook is offered by `/found-issues:setup`.

## Driving it

The agent-side guard on a GitHub repo: block, switch off, and a good line.

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new format-guard --github)"; trap '$F rm "$SB"' EXIT
$F registered "$SB" PreToolUse format-enforcer Write
BAD='{"tool_name":"Write","cwd":"__REPO__","tool_input":{"file_path":"__REPO__/docs/found-issues.md","content":"# found-issues\n\n- [open] 2026-11-27 src/util.py:2 - hyphen not em dash\n"}}'
$F hook "$SB" format-enforcer "$BAD" || true
$F rc "$SB" 2
$F has "$SB" "separator must be ' — '"
$F hook "$SB" FOUND_ISSUES_FORMAT_ENFORCER=off format-enforcer "$BAD"
$F silent "$SB"
$F hook "$SB" format-enforcer '{"tool_name":"Write","cwd":"__REPO__","tool_input":{"file_path":"__REPO__/docs/found-issues.md","content":"# found-issues\n\n- [open] 2026-11-27 src/util.py:2 — good line\n"}}'
$F silent "$SB"
```

Plain git, no GitHub remote: the same bad line only warns.

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new format-warn)"; trap '$F rm "$SB"' EXIT
$F hook "$SB" format-enforcer '{"tool_name":"Write","cwd":"__REPO__","tool_input":{"file_path":"__REPO__/docs/found-issues.md","content":"# found-issues\n\n- [open] 2026-11-27 src/util.py:2 - hyphen not em dash\n"}}'
$F rc "$SB" 0
$F has "$SB" 'additionalContext'
$F has "$SB" 'separator must be'
```

The git hook: a bad ledger cannot be committed, a good one can.

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new pre-commit)"; trap '$F rm "$SB"' EXIT
$F run "$SB" 'cp "$FI_ROOT/hooks/pre-commit.sh" .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit && mkdir -p docs && printf "# found-issues\n\n- [open] 2026-11-27 src/util.py:2 - bad separator\n" > docs/found-issues.md && git add docs && git commit -qm bad' || true
$F rc "$SB" 1
$F has "$SB" 'pre-commit format violations'
$F run "$SB" 'git log --format=%s -1'
$F is "$SB" 'init'
$F run "$SB" 'printf "# found-issues\n\n- [open] 2026-11-27 src/util.py:2 — good line\n" > docs/found-issues.md && git add docs && git commit -qm good && git log --format=%s -1'
$F has "$SB" 'good'
```

## What proves it works

- `--github`: exit 2 with `separator must be ' — '`; the switch and a well-formed line pass silently.
- Plain git: exit 0 with the same text inside `hookSpecificOutput.additionalContext`.
- Git hook: the bad commit exits 1 and no commit appears; the good one lands.

## Gotchas

- Only files named like the ledger are checked.
- Not driven: Edit and MultiEdit payloads, Codex `apply_patch`, and `FOUND_ISSUES_PRE_COMMIT=off`. The `hooks.json` line is read, not fired.
