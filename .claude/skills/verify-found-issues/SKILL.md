---
name: verify-found-issues
description: "Launch, check, drive and prove found-issues (a bash CLI, agent hooks and statusline shims) in throwaway sandboxes. Use when verifying or running a change to bin, lib or hooks in found-issues, or asked what one of its commands, hooks or features is called."
---

# Verify found-issues

The surface is the command line `bin/found-issues`, the hook scripts in `hooks/` (JSON on stdin) and, for statusline work, the **generated shim executed with Claude Code's stdin**. Passing tests is CI's job. Verifying means running this checkout against a real scratch repo and reading what it printed and wrote.

**This plugin is installed and live for every session on the maintainer's machines. These rules come before any drive:**

- Never run the checkout against a real project's ledger, this repo's `docs/found-issues.md` included. Drive only through `scripts/fi-sandbox.sh`.
- Never write any `docs/found-issues.md` by hand to record a defect. It is written by the CLI only (`/found-issues:log`). Fixture ledgers inside a sandbox are fine.
- Never touch `~/.claude/` or the installed plugin. `found-issues uninstall`, `install-statusline`, `install-fi-alias` and `install-codex-hooks` write under `HOME`: sandbox only.
- Auto-fix bills a real account in the background and its PRs merge themselves. Keep `FOUND_ISSUES_AUTOFIX=off` in every command; the sandbox forces it.
- The bare command `found-issues` on your own PATH is the **installed** plugin, not your change. So is the CLI a hook finds from PATH when `FOUND_ISSUES_BIN` is unset.
- `CLAUDE_PROJECT_DIR` makes `list` and `status` read that project's ledger whatever the current folder is, and `CLAUDE_PLUGIN_ROOT` makes the checkout's CLI load the installed `lib/`. The sandbox starts from an empty environment for this reason.

## Launch

There is no server and nothing to build. "Launching" is making a sandbox: a temp `HOME`, a scratch git repo, and this checkout's `bin/` first on PATH. Run from the repo root of the checkout you want to prove.

```bash
export FOUND_ISSUES_AUTOFIX=off
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh
eval "$($F new my-check)"          # sets SB and EVIDENCE
echo "SB=$SB EVIDENCE=$EVIDENCE"   # print them: your next shell call will not remember them
$F doctor "$SB"
```

- **Each agent shell call is a new shell.** Either chain a whole drive in one call, or set `F=...` and `SB=<the path you printed>` again at the top of the next one.
- `new` takes `--github` (adds a fake `github.com/fi-sandbox/demo` origin, for PR paths and the hard-blocking guards) or `--local` (no git at all). Without either: a git repo with no remote.
- Usable = `doctor` ends with `DOCTOR: ok`.
- The scratch repo holds `src/app.sh` (4 lines) and `src/util.py` (`return a / b` on line 2, `return items[0]` on line 6), committed on `main`. It has no ledger until you log something.
- Sandboxes are independent, so drives can run side by side, each with its own slug.

## Doctor

```bash
$F doctor          # the checkout: tools, bin/ holds only found-issues, version matches plugin.json
$F doctor "$SB"    # plus: the sandbox runs THIS checkout, gh is the mock, claude and codex are refused,
                   # HOME is inside the sandbox, auto-fix off, no CLAUDE_/CODEX_/XDG_ variables, remote fake
```

Read-only. Run it before the first drive and after any result that surprises you. `bin/ is clean` matters because subagents sometimes leave shims such as `bin/awk` there, which shadow the real tool for anything that puts `bin/` on PATH. The line `found-issues on YOUR PATH` is information only: it names the installed plugin the sandbox deliberately does not use.

## Drive

**1. A CLI command.** One quoted argument, run by `bash -c` inside the scratch repo, with `$SB`, `$REPO`, `$FI_ROOT` and `$EVIDENCE` set. Single-quote it when it uses those variables. Each call is a fresh shell, so `export` does not carry over: set variables in the same string.

```bash
$F run "$SB" "found-issues log 'src/util.py:2 — divide has no zero check'"
$F run "$SB" 'found-issues status --format=plain'
```

The separator in an entry is ` — ` (an em dash with spaces), not a hyphen. The recorded exit code is the exit code of the whole string, so after a pipe it is the **last** program's: measure a CLI exit code with no pipe after it.

**2. A hook.** `hook` pipes a JSON payload to `hooks/NAME.sh` in the checkout, from inside the scratch repo. Put switches the hook reads at fire time before the name. `__REPO__`, `__SB__` and `__HEAD__` (the scratch repo's current short sha) are filled in.

```bash
$F hook "$SB" FOUND_ISSUES_STOP_REMINDER=block stop-reminder '{"session_id":"s1","transcript_path":"__SB__/transcript.jsonl"}'
```

Payload shapes that work are in each hook's feature file. A `VAR=value` before the name may hold tabs and newlines, so `gh` mock values work there too (commit-pr-hook.md).

**Silence is ambiguous.** A rejected payload, an off switch, an already-handled event and the merge route's successful background sync all print nothing and exit 0. Judge by the ledger, `gh-calls.log` and state files, and run a control that should differ.

**3. A generated script** (statusline shims, Codex shims): install it with the CLI into the sandbox, then execute the file with the stdin its host would send. See `features/statusline.md` and `features/codex-install.md`.

**GitHub** is the repo's own mock, `tests/bin-shims/gh`, linked into the sandbox. By default `gh auth status` succeeds, `gh pr list` returns `[]` and `gh pr view` fails. Feed it with `GH_MOCK_*` variables set inside the `run` string; the header of the mock lists them, and `features/sync.md` and `features/annotate.md` have working rows. Every call is logged to `$SB/gh-calls.log`. Network git is blocked (`GIT_ALLOW_PROTOCOL=file`).

**What the sandbox pins, and why:** `FOUND_ISSUES_BIN` and `FOUND_ISSUES_LIB_DIR` point hooks and statusline shims at this checkout (a shim looks for the CLI in `FOUND_ISSUES_BIN`, then PATH, then the installed plugin cache). `FOUND_ISSUES_SEGMENT_AUTOSYNC=off` stops a statusline render from starting a background sync that races the sandbox's removal. A harness of your own needs all three.

**Fixture ledgers** may be written by hand inside a sandbox, at `docs/found-issues.md` or at the root as `.found-issues.md` (the local-mode name, also read in a git repo that has no `docs/` ledger).

**Dates in hand-written fixtures** must be today's (`$(date +%Y-%m-%d)`): a hard-coded date crosses the 30-day stale limit and changes the label (`1 issue` becomes `1 other · 1 stale`).

**An old revision** is driven from a worktree of it. Never `git show REV:bin/found-issues > file`: the binary loads `../lib/*.sh` next to itself and dies silently.

## Evidence

Everything goes to `.verify/evidence/YYYY-MM-DD-slug/` in the repo root (ignored by git). `new` creates it and never reuses a folder: a second run of one slug gets `-2`. `new` prints the path (`sandbox ready: SB=... EVIDENCE=...`), also under `eval`. Your evidence is the folder yours printed, not another with the same slug.

- `transcript.txt`: first line names the checkout, commit and number of uncommitted product files; then every `run` and `hook` with stdout, stderr and `[exit N]`.
- `$F snap "$SB" LABEL` copies the ledger, the archive, the scratch repo's `git status`, log and branches, and the `gh` call log. Snap before and after the step you are proving.
- Files you write to `$EVIDENCE` from inside a `run` (shim output) are kept too.

Proof is the real command or hook, its output **and** its side effect (the ledger line, the hooks file, the shim's rendered bytes). Include one failing input and its exit code. A call to an internal `fi_` function proves nothing a user gets. The `gh` mock is a stand-in for GitHub: say so in the report. Colored statusline output is read through `cat -v`.

## Cleanup

```bash
$F rm "$SB"
```

It deletes that sandbox only (it refuses a folder it did not make), never the evidence. It waits up to 10 s for processes whose working folder is the sandbox (a background `sync`; found with `lsof`) or whose command line names it, then refuses and lists them. It never stops them: wait, then run it again. Remove only sandboxes **you** made: others under the temp folder may belong to a live session. Run `rm` after failed attempts too.

## Helpers

| Helper | Call |
|---|---|
| `scripts/fi-sandbox.sh` | `new SLUG [--github or --local]`, `doctor [SB]`, `run SB 'cmd'`, `hook SB [VAR=x] NAME 'json'`, `snap SB LABEL`, `rm SB`, `help` |
| `tests/bin-shims/gh` (the repo's) | linked into every sandbox; driven with `GH_MOCK_*` |
| `tests/helpers.bash`, `tests/autofix-helpers.bash` (the repo's) | fixtures for the bats suite, including auto-fix with stand-in engines |

The test suite is not this kit's proof, but when you need it: `bats --jobs 8 tests/` (needs bats-core and GNU parallel; one file: `bats tests/canonicalize.bats`). On a machine that also hosts CI runners, a full run slows them, so run the files you need.

## Features

Open `features/README.md`, find the feature by the command or the words used for it, open its file and follow **Driving it**. For a diff: `python3 ~/.claude/skills/verification-kit/scripts/kit_check.py .claude/skills/verify-found-issues --for-diff origin/main` (fetch first; a local `main` that is rarely pulled lists hundreds of files).

## Not driveable here

- **Slash commands and Codex skills** (`commands/*.md`, `codex-skills/`, `agents/`): they are instructions a model follows inside Claude Code or Codex. The CLI calls they make are driveable; the model's judgement (AI verification in sync, triage in fix, the setup walkthrough) is not.
- **Hooks as the host fires them.** `hook` proves what a script does with a payload of the shape written here. It does not prove that Claude Code or Codex registers it (`hooks/hooks.json`), sends that payload, or shows the output to the model. That needs a real session with the plugin loaded.
- **Real GitHub:** PR creation, merge state, mode detection from real PR history. The mock answers instead.
- **Auto-fix runs:** they need a paid engine and a real GitHub repo, and verification keeps auto-fix off.
- **The statusline inside Claude Code**, the trust review for Codex hooks (`/hooks`), Linux, and Windows with Git Bash.

## Keeping this kit true

- You drove a feature and it works: set `proven:` in its file to today's date.
- The kit was wrong or out of date: fix it in the same pull request as your change.
- You added a user-facing feature: add its file and its line in `features/README.md`.
- Check the kit with `python3 ~/.claude/skills/verification-kit/scripts/kit_check.py <this folder>`.
