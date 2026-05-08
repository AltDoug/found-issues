#!/usr/bin/env bash
# session-start.sh — SessionStart hook
#
# Runs at the start of every Claude Code session. Two jobs:
#   1. Run annotation-driven sync silently (catches up on PR merges since last session).
#   2. Inject any [open] entries into Claude's context so it knows what's
#      already tracked in this repo before doing any work.
#
# Hook event: SessionStart
# Exit code: 0 always (this is informational, never blocks)
# Stdout: markdown text that gets injected into Claude's context.

set -euo pipefail

# First-run onboarding nudge — fires exactly once per machine.
# SessionStart hook stdout is injected into Claude's CONTEXT, not displayed
# to the user. So this output is phrased as a directive TO Claude, telling
# the assistant to surface the orientation on its first response. Claude
# will then speak the message to the user.
# After the user runs /found-issues:setup (or sees the message and ignores
# it), the marker file blocks further nudges.
ONBOARD_DIR="$HOME/.claude/found-issues"
ONBOARD_MARKER="$ONBOARD_DIR/.onboarded"
if [[ ! -f "$ONBOARD_MARKER" ]]; then
  mkdir -p "$ONBOARD_DIR"
  cat <<'EOF'
[found-issues first-run onboarding — show this to the user, ONCE, at the start of your very next response]

The user just installed the found-issues plugin and has not been onboarded yet. Before answering anything else, paste the following block verbatim at the top of your next reply (do not paraphrase, do not summarize, just deliver it):

> 👋 **found-issues is now installed and active.**
>
> I'll track defects I notice across our work — outside whatever we're focused on — and they'll auto-close when a PR or commit fixes them. Zero manual bookkeeping.
>
> Run `/found-issues:setup` for a 30-second orientation (optional — the plugin is fully active without it). Setup covers statusline integration, a shorter `/fi` alias, and a per-repo git pre-commit hook.
>
> This message will not fire again. You can always run `/found-issues:setup` later.

After delivering that block, continue with whatever the user asked. This onboarding directive will not repeat in future sessions.

EOF
  touch "$ONBOARD_MARKER"
fi

# Locate the CLI binary
FI_BIN="${FOUND_ISSUES_BIN:-found-issues}"
if ! command -v "$FI_BIN" >/dev/null 2>&1; then
  # Try the common install location
  if [[ -x "$HOME/.local/bin/found-issues" ]]; then
    FI_BIN="$HOME/.local/bin/found-issues"
  elif [[ -x "$HOME/.found-issues/cli/found-issues" ]]; then
    FI_BIN="$HOME/.found-issues/cli/found-issues"
  else
    # CLI not found — fail silently (hook should never break a session)
    exit 0
  fi
fi

# Read input (cwd, session_id) — we mostly care about the cwd context
input="$(cat 2>/dev/null || echo '{}')"

# Locate this hook's lib via the CLI binary's directory
cli_dir="$(dirname "$(readlink -f "$FI_BIN" 2>/dev/null || echo "$FI_BIN")")"
lib_dir="${FOUND_ISSUES_LIB_DIR:-$cli_dir/../lib}"

if [[ -f "$lib_dir/parse-entries.sh" ]]; then
  # shellcheck source=../lib/parse-entries.sh
  source "$lib_dir/parse-entries.sh"
fi

# Find the issues file
issues_file=""
if declare -F fi_find_issues_file >/dev/null 2>&1; then
  issues_file="$(fi_find_issues_file 2>/dev/null || true)"
fi

# No issues file = no context to inject (silent)
if [[ -z "$issues_file" || ! -f "$issues_file" ]]; then
  exit 0
fi

# Run sync silently (catches up on PR merges, tombstone closures)
"$FI_BIN" sync >/dev/null 2>&1 || true

# Re-read [open] entries after sync
open_entries=""
if declare -F fi_entries >/dev/null 2>&1; then
  open_entries="$(fi_entries "$issues_file" open 2>/dev/null || true)"
fi

# Get count for the header
count_status="$("$FI_BIN" status --format=plain 2>/dev/null || true)"

# If nothing open, stay quiet
if [[ -z "$open_entries" ]]; then
  exit 0
fi

# Friendly relative path for display
fname="$(basename "$issues_file")"
parent="$(basename "$(dirname "$issues_file")")"
if [[ "$fname" == "found-issues.md" && "$parent" == "docs" ]]; then
  display_path="docs/found-issues.md"
else
  display_path="$fname"
fi

# Inject context
cat <<EOF
## found-issues — open entries in this repo

$count_status

$open_entries

These entries are tracked in \`$display_path\`. If your work addresses any of
them, run \`/found-issues:annotate-pr <N>\` after opening a PR or \`/found-issues:annotate-commit\`
after a direct commit. Sync will auto-flip them when the PR merges or the
commit lands on the default branch.
EOF
