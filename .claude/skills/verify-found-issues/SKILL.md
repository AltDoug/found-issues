---
name: verify-found-issues
description: "Launch, check, drive and prove found-issues (a bash CLI, agent hooks and statusline shims) in throwaway sandboxes. Use when verifying or running a change to bin, lib or hooks in found-issues, or asked what one of its commands, hooks or features is called."
---

# Verify found-issues

The surface is the command line `bin/found-issues`, the hook scripts in `hooks/` (JSON on stdin) and, for statusline work, the **generated shim executed with Claude Code's stdin**. Passing tests is CI's job. Verifying means running this checkout against a real scratch repo and reading what it printed and wrote.

## Never

This plugin may be installed and live in your own agent session. These rules come before any drive.

- **Never run the checkout against a real project's ledger**, this repo's `docs/found-issues.md` included: drives write, close and archive entries. Drive only through `scripts/fi-sandbox.sh`.
- **Never write any `docs/found-issues.md` by hand** to record a defect: the CLI owns the format (`/found-issues:log`). Fixture ledgers inside a sandbox are fine.
- **Never touch `~/.claude/` or the installed plugin.** `uninstall`, `install-statusline`, `install-fi-alias` and `install-codex-hooks` write under `HOME`: sandbox only.
- **Never turn auto-fix on or start its engine.** It bills a real account in the background and its PRs merge themselves. Keep `FOUND_ISSUES_AUTOFIX=off` in every command; the sandbox forces it and puts refusing stand-ins in place of `claude` and `codex`.
- **Never call real GitHub.** The sandbox's `gh` is the repo's mock, `tests/bin-shims/gh`.
- **Never trust the bare command `found-issues` on your own PATH:** it is the installed plugin, not your change. So is the CLI a hook finds on PATH when `FOUND_ISSUES_BIN` is unset.
- **Never drive from your own shell's environment.** `CLAUDE_PROJECT_DIR` makes `list` and `status` read that project's ledger whatever the current folder is, and `CLAUDE_PLUGIN_ROOT` makes the checkout's CLI load the installed `lib/`. The sandbox starts from an empty environment for this reason.
- **Do not paste the `git commit`, `gh pr create` or branch-delete steps of a drive as bare commands:** installed hooks read the text of your shell calls. Inside `fi-sandbox.sh run` or a payload they name sandbox things only; the checker's `--run` keeps them out of your command text altogether.

## Launch

There is no server and nothing to build. "Launching" is making a sandbox: a temp `HOME`, a scratch git repo, and this checkout's `bin/` first on PATH. Run from the repo root of the checkout you want to prove. `--keep` records the sandbox under its slug, so every later command, in any new shell, can name it:

```bash
.claude/skills/verify-found-issues/scripts/fi-sandbox.sh new my-check --keep
```

It prints `SB=` (the sandbox folder) and `EVIDENCE=` (where proof is kept). `new` also takes `--github` (adds a fake `github.com/fi-sandbox/demo` origin, for PR paths and the hard-blocking guards) or `--local` (no git at all). Without either: a git repo with no remote. A slug already kept is refused: pick your own.

Usable = this ends with `DOCTOR: ok`:

```bash
.claude/skills/verify-found-issues/scripts/fi-sandbox.sh doctor my-check
```

The scratch repo holds `src/app.sh` (4 lines) and `src/util.py` (`return a / b` on line 2, `return items[0]` on line 6), committed on `main`. It has no ledger until you log something. Sandboxes are independent, so drives can run side by side, each with its own slug.

A feature file's block does not use `--keep`: it holds the path in a variable for the length of that one block and removes the sandbox when the block ends, passed or failed. Every sandbox is made the same way, so `doctor` on one kept sandbox (above) vouches for the ones the blocks make: run it once before them, and again after a block fails.

## Doctor

Read-only. Run it before the first drive and after any result that surprises you. With no sandbox it checks the checkout alone (tools, bash 4 or later, `bin/` holds only `found-issues`, version matches `plugin.json`):

```bash
.claude/skills/verify-found-issues/scripts/fi-sandbox.sh doctor
```

With a sandbox name or path it also checks that the sandbox runs THIS checkout, `gh` is the mock, `claude` and `codex` are refused, `HOME` is inside the sandbox, auto-fix is off, no `CLAUDE_`, `CODEX_` or `XDG_` variables leaked in and the remote is fake or absent. It exits 1 with `DOCTOR: NOT worth driving` and a `FAIL` line naming what is wrong.

The `gh` line matters more than it looks: the sandbox's PATH also holds the folders of `jq` and `node`, where a real `gh` may live, so a sandbox whose mock link is gone would run the real one.

`bin/ is clean` matters because subagents sometimes leave shims such as `bin/awk` there, which shadow the real tool for anything that puts `bin/` on PATH. The line `found-issues on YOUR PATH` is information only: it names the installed plugin the sandbox deliberately does not use.

## Drive

Each line below works pasted alone, after Launch.

**1. A CLI command.** One quoted argument, run by `bash -c` inside the scratch repo, with `$SB`, `$REPO`, `$FI_ROOT` and `$EVIDENCE` set (single-quote the string to use them). Each call is a fresh shell, so `export` does not carry over: set variables in the same string.

```bash
.claude/skills/verify-found-issues/scripts/fi-sandbox.sh run my-check "found-issues log 'src/util.py:2 — divide has no zero check'"
.claude/skills/verify-found-issues/scripts/fi-sandbox.sh has my-check 'Logged: - [open] '
```

The separator in an entry is ` — ` (an em dash with spaces), not a hyphen. The recorded exit code is the exit code of the whole string, so after a pipe it is the **last** program's: measure a CLI exit code with no pipe after it.

**2. A hook.** `hook` pipes a JSON payload to `hooks/NAME.sh` in the checkout, from inside the scratch repo. Put switches the hook reads at fire time before the name. `__REPO__`, `__SB__` and `__HEAD__` (the scratch repo's current short sha) are filled in.

```bash
.claude/skills/verify-found-issues/scripts/fi-sandbox.sh hook my-check first-touch '{"session_id":"s1","cwd":"__REPO__","hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"__REPO__/src/util.py"}}'
.claude/skills/verify-found-issues/scripts/fi-sandbox.sh has my-check 'open entries for src/util.py'
```

Payload shapes that work are in each hook's feature file. A `VAR=value` before the name may hold tabs and newlines, so `gh` mock values work there too (`features/commit-pr-hook.md`). `hook` runs the script directly and never reads `hooks.json`, so a wrong matcher does not show: the feature blocks check the registration with `registered`.

**Silence is ambiguous.** A rejected payload, an off switch, an already-handled event and the merge route's successful background sync all print nothing and exit 0. Judge by the ledger, `gh-calls.log` and state files, and run a control that should differ.

**3. A generated script** (statusline shims, Codex shims): install it with the CLI into the sandbox, then execute the file with the stdin its host would send. See `features/statusline.md` and `features/codex-install.md`.

**Checking.** A step that only runs proves nothing. After each `run` or `hook`, assert on it. The checks read the last command's stdout and stderr (never the command line itself) or a file, given relative to the scratch repo or as an absolute path; each prints `check ok:` or `CHECK FAILED:` with what it found, and exits 1.

| Check | Passes when |
|---|---|
| `has SB 'text' [file]` / `lacks SB 'text' [file]` | the text is there / is not (a missing file fails both) |
| `match SB 'regex' [file]` | a line matches the extended regular expression |
| `count SB N 'text' [file]` | exactly N lines hold the text |
| `is SB 'whole output'` | the output is exactly that |
| `rc SB N` / `silent SB` | the exit code was N / exit 0 with no output |
| `exists SB file` / `executable SB file` / `gone SB file` | the file is there / can be run / is not there |
| `registered SB Event hook-name [Tool]` | `hooks/hooks.json` names the hook for that event and tool |

For a command meant to fail: `... run SB 'cmd' || true`, then `rc SB 2` and `has SB 'the message'`. A bare `|| true` passes whatever happens. In a block run with `set -e`, `! grep ...` and `a && b` never stop the block: use these checks, or `test`.

**GitHub** is the repo's own mock, linked into the sandbox. By default `gh auth status` succeeds, `gh pr list` returns `[]` and `gh pr view` fails. Feed it with `GH_MOCK_*` variables set inside the `run` string; the header of `tests/bin-shims/gh` lists them, and `features/sync.md` and `features/annotate.md` have working rows. Every call is logged to `gh-calls.log` in the sandbox folder. Network git is blocked (`GIT_ALLOW_PROTOCOL=file`).

**What the sandbox pins, and why:** `FOUND_ISSUES_BIN` and `FOUND_ISSUES_LIB_DIR` point hooks and statusline shims at this checkout (a shim looks for the CLI in `FOUND_ISSUES_BIN`, then PATH, then the installed plugin cache). `FOUND_ISSUES_SEGMENT_AUTOSYNC=off` stops a statusline render from starting a background sync that races the sandbox's removal. A harness of your own needs all three.

**Fixture ledgers** may be written by hand inside a sandbox, at `docs/found-issues.md` or at the root as `.found-issues.md` (the local-mode name, also read in a git repo that has no `docs/` ledger).

**Dates in hand-written fixtures** must be today's (`$(date +%Y-%m-%d)`) when the count's wording matters: a hard-coded date crosses the 30-day stale limit and changes the label (`1 issue` becomes `1 other · 1 stale`).

**An old revision** is driven from a worktree of it. Never `git show REV:bin/found-issues > file`: the binary loads `../lib/*.sh` next to itself and dies silently.

## Evidence

Everything goes to `.verify/evidence/YYYY-MM-DD-HHMMSS-slug/` in the repo root (ignored by git). `new` creates it and never reuses a folder: a second sandbox of one slug in the same second gets `-2`. `new` prints the path (`sandbox ready: SB=... EVIDENCE=...`), also under `eval`. Your evidence is the folder yours printed, not another with the same slug.

- `transcript.txt`: the first line names the checkout, commit and number of uncommitted product files; then every `run` and `hook` with its command line, stdout, stderr and `[exit N]`, and every check with its verdict.
- `.claude/skills/verify-found-issues/scripts/fi-sandbox.sh snap my-check after-log` copies the ledger, the archive, the scratch repo's `git status`, log and branches, and the `gh` call log under that label. Snap before and after the step you are proving.
- Files you write to `$EVIDENCE` from inside a `run` (shim output) are kept too.

Proof is the real command or hook, its output **and** its side effect (the ledger line, the hooks file, the shim's rendered bytes). The feature blocks carry their own checks and mostly a refusal or a control that should differ. In a drive of your own, snap before and after and include one failing input and its exit code. A call to an internal `fi_` function proves nothing a user gets. The `gh` mock is a stand-in for GitHub and the hook payloads are hand-built: say so in the report. Colored statusline output is read through `cat -v`.

## Cleanup

```bash
.claude/skills/verify-found-issues/scripts/fi-sandbox.sh rm my-check
```

It deletes that sandbox only (it refuses a folder it did not make), never the evidence, and frees the kept name. It waits up to 10 s for processes whose working folder is the sandbox (a background `sync`; found with `lsof`) or whose command line names it, then refuses, lists them and exits 1. It never stops them: wait, then run it again. Remove only sandboxes **you** made: others under the temp folder may belong to a live session. Run `rm` after failed attempts too; the feature blocks do it from an `EXIT` trap.

## Helpers

| Helper | Call |
|---|---|
| `scripts/fi-sandbox.sh` | `new SLUG [--github or --local] [--keep]`, `doctor [SB]`, `run SB 'cmd'`, `hook SB [VAR=x] NAME 'json'`, `snap SB LABEL`, `rm SB`, the checks `has`, `lacks`, `match`, `count`, `is`, `rc`, `silent`, `exists`, `executable`, `gone`, `registered`, and `help`. SB is the folder `new` printed, or the slug of a `--keep` sandbox |
| `tests/bin-shims/gh` (the repo's) | linked into every sandbox; driven with `GH_MOCK_*` |
| `tests/helpers.bash`, `tests/autofix-helpers.bash` (the repo's) | fixtures for the bats suite, including auto-fix with stand-in engines |

The test suite is not this kit's proof, but when you need it: `env -u CLAUDE_CODE_ENTRYPOINT FOUND_ISSUES_AUTOFIX=off bats tests/canonicalize.bats` for one file (needs bats-core), `bats --jobs 8 tests/` for all (needs GNU parallel too). Unset `CLAUDE_CODE_ENTRYPOINT` in an agent session: `tests/helpers.bash` does not, and the hook tests then fail for no product reason (`features/stop-reminder.md`). The `autofix-*` test files drive auto-fix with stand-in engines and expect it switchable; leave them, and the full suite, to CI unless your change is in auto-fix. On a machine that also hosts CI runners, a full run slows them, so run the files you need.

## Features

Open `features/README.md`, find the feature by its command or message, open its file and follow **Driving it**. With the `verification-kit` skill installed, its `scripts/kit_check.py` does the finding and the running: `kit_check.py .claude/skills/verify-found-issues --for-diff origin/main` names the features your change touches (fetch first; a local `main` that is rarely pulled lists hundreds of files), and `kit_check.py .claude/skills/verify-found-issues --run sync` runs one feature's blocks. Without it, copy a whole block into a script file outside the repo (a temp file) and run that file with `bash -eo pipefail` from the repo root; it must exit 0.

## Not driveable here

- **Slash commands and Codex skills** (`commands/*.md`, `codex-skills/`, `agents/`): they are instructions a model follows inside Claude Code or Codex. The CLI calls they make are driveable; the model's judgement (AI verification in sync, triage in fix, the setup walkthrough) is not.
- **Hooks as the host fires them.** `hook` proves what a script does with a payload of the shape written here. It does not prove that Claude Code or Codex loads the registration, sends that payload, or shows the output to the model. That needs a real session with the plugin loaded.
- **Real GitHub:** PR creation, merge state, mode detection from real PR history. The mock answers instead.
- **Auto-fix runs:** they need a paid engine and a real GitHub repo, and verification keeps auto-fix off.
- **The statusline inside Claude Code**, the trust review for Codex hooks (`/hooks`), Linux, and Windows with Git Bash. The kit has only been run on macOS, and CI does not run it.

## Keeping this kit true

- You drove a feature and it works: set `proven:` in its file to today's date.
- The kit was wrong or out of date: fix it in the same pull request as your change.
- You added a user-facing feature: add its file and its line in `features/README.md`.
- With the `verification-kit` skill installed, its `scripts/kit_check.py` checks this folder, and `--run <feature> --stamp` drives a feature and dates it. Without it, follow the three rules above by hand.
