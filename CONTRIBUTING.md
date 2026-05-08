# Contributing to found-issues

Thanks for considering a contribution. The project is small enough that
most things can ship quickly if they fit the design.

## Quick start

1. **Fork** the repo and clone locally
2. **Branch** off `main`: `git checkout -b your-branch-name`
3. **Make changes** — see "What kinds of contributions are welcome" below
4. **Run tests**: `bats tests/` (install via `brew install bats-core` if needed)
5. **Open a PR** against `main` with a description of the change

## What kinds of contributions are welcome

**Bug fixes** — always welcome. Open a PR directly with a test reproducing the bug.

**Small features** — additions that fit the existing design. Examples
that would land quickly:

- New regex pattern in `lib/parse-entries.sh` for a new annotation form
- New error message in a hook
- Documentation improvements
- New tests for existing behavior
- Bash portability fixes

**Larger features** — please open an issue first. Examples:

- New slash commands
- New hook events
- New modes beyond the existing four
- Format spec extensions
- Per-repo configuration files

We'll discuss the design before you spend time implementing. Saves
everyone effort.

## What's NOT in scope

These have been considered and explicitly rejected:

- **Web UI / dashboard** — the file is the interface
- **Central server / cloud sync** — issues live in git, that's the point
- **Issue assignment / ownership / milestones** — use a real tracker for that
- **Auto-priority sorting beyond `[!]`** — order is observation order
- **Non-Claude-Code-first design** — we may eventually support other
  agents, but not at the cost of design clarity for Claude Code users

## Project structure

```
.claude-plugin/    Plugin manifests (plugin.json, marketplace.json)
bin/               CLI binary
commands/          Slash command markdown files
docs/              User-facing documentation
hooks/             Hook scripts + hooks.json registration
lib/               Shared bash libraries (sourced by CLI + hooks)
skills/            Auto-loading skills (rules)
tests/             bats-core test suite
```

## Coding conventions

**Bash**:

- `set -euo pipefail` at the top of every script
- Functions prefixed `fi_` to namespace
- Compatible with bash 3.2+ where reasonable; bash 5+ allowed for plugin
  hooks since Claude Code provides bash 5+
- Pure functions in `lib/`; side effects in `bin/`/`hooks/`
- Use `[[ "$x" =~ $pattern ]]` with `pattern` assigned to a variable
  (bash 5.3 chokes on inline patterns with `\)`)
- Cross-platform: BSD vs GNU sed/date/stat — test both branches in CI

**Markdown** (commands/skills/docs):

- Frontmatter required for slash commands and skills (see existing
  examples)
- Em-dash `—` (U+2014) for separators in entries; never hyphen
- ISO 8601 dates only

**JSON** (manifests, hooks.json):

- 2-space indent
- Validates via `jq empty` (CI checks this)

## Testing

The bats test suite is the primary safety net:

```bash
bats tests/                    # run all
bats tests/canonicalize.bats   # run one file
```

When adding code, add tests. Existing files in `tests/` are good
reference — they cover lib functions, CLI subcommands, and hooks.

CI runs the suite on every PR (Linux + macOS matrix). Both legs must be
green before merge.

## Commit messages

We follow Conventional Commits loosely:

- `feat: ...` — new feature
- `fix: ...` — bug fix
- `docs: ...` — documentation only
- `test: ...` — test changes only
- `chore: ...` — repo housekeeping (CI, deps, etc.)
- `refactor: ...` — code change without behavior change

The body should explain *why*. The diff explains *what*.

## PR conventions

- One topic per PR — easier to review, easier to revert
- Include a "Test plan" section in the PR body (existing PRs are
  reference)
- Don't squash-merge yourself; the maintainer will squash on merge
- Keep PRs focused; resist scope creep

## Security

If you find a security issue, please **don't** open a public issue.
Email the maintainer directly (find via [DougBTW's GitHub profile](https://github.com/DougBTW))
and we'll coordinate disclosure.

## License

By contributing, you agree your contributions are licensed under the
project's MIT License. See [LICENSE](LICENSE).

## Code of conduct

Be kind. Critique code, not people. Assume good intent. Disagree
explicitly and concretely if you must. Anyone behaving badly will be
removed without further discussion.
