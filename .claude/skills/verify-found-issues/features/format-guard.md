---
feature: Ledger format guard
also-called: format enforcer, format violations, pre-commit hook
sources:
  - hooks/format-enforcer.sh
  - hooks/pre-commit.sh
  - lib/detect-mode.sh
proven: 2026-11-27
---

## What it is

Rejects malformed ledger lines: in the agent's file edits (hard block on GitHub repos, warning in plain git) and, if installed, at `git commit`.

## Parts

| What you see | What it does | Handle |
|---|---|---|
| `found-issues format violations in found-issues.md:` and exit 2 | Blocks the Write or Edit (GitHub modes) | `hooks/format-enforcer.sh` |
| Same text as `additionalContext`, exit 0 | Plain git mode: warns only | `hooks/format-enforcer.sh` |
| `found-issues: pre-commit format violations` and exit 1 | The optional git hook, copied to `.git/hooks/pre-commit` | `hooks/pre-commit.sh` |
| `FOUND_ISSUES_FORMAT_ENFORCER=off`, `FOUND_ISSUES_PRE_COMMIT=off` | Switches | both scripts |

## How to get to it

It fires before the agent's Write, Edit or MultiEdit; the git hook is offered by `/found-issues:setup`.

## Driving it

Enforcer (use `--github` for the block, a plain sandbox for the warning):

Run the whole block as one shell call:

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new format-guard --github)"
BAD='{"tool_name":"Write","cwd":"__REPO__","tool_input":{"file_path":"__REPO__/docs/found-issues.md","content":"# found-issues\n\n- [open] 2026-11-27 src/util.py:2 - hyphen not em dash\n"}}'
$F hook "$SB" format-enforcer "$BAD" || true                              # exit 2
$F hook "$SB" FOUND_ISSUES_FORMAT_ENFORCER=off format-enforcer "$BAD"     # exit 0, silent
$F rm "$SB"
```

Git hook:

Run the whole block as one shell call:

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new pre-commit)"
$F run "$SB" 'cp "$FI_ROOT/hooks/pre-commit.sh" .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit && mkdir -p docs && printf "# found-issues\n\n- [open] 2026-11-27 src/util.py:2 - bad separator\n" > docs/found-issues.md && git add docs && git commit -qm bad' || true   # exit 1
$F rm "$SB"
```

## What proves it works

- `--github`: exit 2 with the offending line and `separator must be ' — '`. A well-formed line exits 0 with no output.
- Plain git sandbox: exit 0 with the same text inside `hookSpecificOutput.additionalContext`.
- Git hook: the commit fails with exit 1.

## Gotchas

Only files named like the ledger are checked. Not driven in the proving run: Edit and MultiEdit payloads and Codex `apply_patch`.
