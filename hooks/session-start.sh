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

# First-run onboarding hint — prepends a single italicized tip to the user's
# next response, then never fires again. This replaces the silent removal in
# v0.1.5 (users couldn't discover /found-issues:setup) and the verbose
# directive in v0.1.4 (hijacked first response as a paragraph block).
#
# Trade-off: still goes via "directive to Claude" because SessionStart stdout
# is context, not user UI. The directive is now a single italic line — visible
# enough to discover the setup command, light enough to not derail what the
# user actually asked.
ONBOARD_DIR="$HOME/.claude/found-issues"
ONBOARD_MARKER="$ONBOARD_DIR/.onboarded"
if [[ ! -f "$ONBOARD_MARKER" ]]; then
  mkdir -p "$ONBOARD_DIR"
  cat <<'EOF'
[found-issues setup hint — fires only on first session ever, never again]

Prepend this single italicized line to the very top of your next reply, then continue with whatever the user asked:

> _found-issues plugin is now active. Run `/found-issues:setup` for orientation + optional integrations (statusline counter, `/fi` alias, pre-commit hook)._

Do not paraphrase or expand. One line, then the user's actual task.

EOF
  touch "$ONBOARD_MARKER"
fi

# Broken-statusline self-heal nudge — fires at most once per day per machine.
# Detects pre-v0.1.7 handwritten snippets and v1.0.0/1.0.1 marker-bracketed
# segments that lack cwd handling (both render the counter empty silently).
# Emits a one-line directive to Claude pointing at the migration command.
#
# Why only once per day: the cost of breakage is high (silent broken counter
# for real users), the cost of a one-line nudge is low. Re-checking each
# session also means: if the user ignores it once, they get reminded daily
# until they fix it OR uninstall.
mkdir -p "$ONBOARD_DIR" 2>/dev/null || true
STATUSLINE_NUDGE_MARKER="$ONBOARD_DIR/.statusline-nudge-$(date +%Y-%m-%d 2>/dev/null || echo today)"
if [[ ! -f "$STATUSLINE_NUDGE_MARKER" ]] && [[ -f "$HOME/.claude/statusline.sh" ]]; then
  # Inline classifier (matches fi_statusline_state in the CLI). Kept in sync
  # by tests/cli-statusline.bats:"session-start hook detects broken state".
  STATUSLINE_FILE="$HOME/.claude/statusline.sh"
  STATUSLINE_START_MARKER="# === found-issues plugin segment ==="
  STATUSLINE_END_MARKER="# === end found-issues plugin segment ==="
  has_marker=0; marker_block_fixed=0; has_legacy=0
  if grep -Fq "$STATUSLINE_START_MARKER" "$STATUSLINE_FILE" 2>/dev/null; then
    has_marker=1
    if awk -v start="$STATUSLINE_START_MARKER" -v endm="$STATUSLINE_END_MARKER" '
        $0 == start { in_block = 1; next }
        $0 == endm { in_block = 0; next }
        in_block { print }
      ' "$STATUSLINE_FILE" 2>/dev/null | grep -Fq '__FI_DIR'; then
      marker_block_fixed=1
    fi
  fi
  if awk -v start="$STATUSLINE_START_MARKER" -v endm="$STATUSLINE_END_MARKER" '
      $0 == start { in_block = 1; next }
      $0 == endm { in_block = 0; next }
      !in_block && /found-issues[[:space:]]+status[[:space:]]+--format[=[:space:]]+segment/ { found = 1 }
      END { exit (found ? 0 : 1) }
    ' "$STATUSLINE_FILE" 2>/dev/null; then
    has_legacy=1
  fi

  # Broken if: marker present without cwd handling, OR handwritten legacy line outside markers.
  if (( (has_marker == 1 && marker_block_fixed == 0) || has_legacy == 1 )); then
    # All three broken states resolve via plain `install-statusline` as of
    # v1.0.4 — auto-migrate is the default for legacy snippets too.
    fix_cmd='found-issues install-statusline'
    if [[ "$has_legacy" -eq 1 && "$has_marker" -eq 0 ]]; then
      kind='pre-v0.1.7 handwritten snippet'
    elif [[ "$has_legacy" -eq 1 && "$has_marker" -eq 1 ]]; then
      kind='conflicting handwritten + marker block'
    else
      kind='v1.0.0/1.0.1 marker block missing cwd handling'
    fi
    cat <<EOF
[found-issues self-heal nudge — fires at most once per day until fixed]

Detected a broken statusline integration in ~/.claude/statusline.sh
($kind). The counter is rendering empty silently. Run \`found-issues doctor-statusline\`
to inspect, then \`$fix_cmd\` to fix.

Prepend this single italicized line to the very top of your next reply, then continue with whatever the user asked:

> _found-issues counter is silently broken in your statusline. Fix: \`$fix_cmd\` (or \`found-issues doctor-statusline\` to inspect first)._

Do not paraphrase. One line, then the user's actual task.

EOF
    touch "$STATUSLINE_NUDGE_MARKER" 2>/dev/null || true
  fi
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
