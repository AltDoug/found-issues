---
feature: First-run setup
also-called: /found-issues:setup, fi-setup, onboarding
sources:
  - commands/setup.md
  - codex-skills/fi-setup/SKILL.md
proven: never
---

## What it is

A guided walkthrough: what the plugin does, then optional statusline, git pre-commit hook, `/fi` shortcut and auto-fix opt-in.

## Parts

| What you see | What it does | Handle |
|---|---|---|
| `found-issues is now active.` | The introduction | `commands/setup.md` |
| Optional 1 to 4 | Statusline, pre-commit hook, short alias, auto-fix | the commands in statusline.md, format-guard.md, alias-and-uninstall.md, autofix-settings.md |

## How to get to it

`/found-issues:setup` in a session, `$fi-setup` in Codex.

## Driving it

No harness: it is prose a model follows with a person answering. Drive the CLI calls it makes through the feature files listed under Parts. After editing the prose, run `bats tests/setup-autofix-disclosure.bats tests/setup-custom-statusline-flow.bats`.

## What proves it works

In a real session: each offered option ends in the state its own feature file describes.

## Gotchas

Never driven: it needs Claude Code or Codex with the plugin loaded and a person answering the questions.
