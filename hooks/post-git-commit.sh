#!/usr/bin/env bash
# post-git-commit.sh — PostToolUse hook on Bash
#
# Fires after every Bash invocation. If the command was `git commit`,
# scans the new HEAD commit's diff for files referenced by [open]
# entries and prompts Claude to run /found-issues:annotate-commit if any match.
#
# Especially load-bearing in `github-direct` mode where commits ARE
# the closure mechanism (no PR workflow).
#
# Hook event: PostToolUse (matcher: Bash)
# Exit code: 0 always (additive; never blocks).
# Stdout: markdown injected into Claude's context.

set -euo pipefail

input="$(cat)"

get_field() {
  local field="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$input" | jq -r "$field // empty" 2>/dev/null || true
  fi
}

tool_name="$(get_field '.tool_name')"
[[ "$tool_name" != "Bash" ]] && exit 0

command="$(get_field '.tool_input.command')"

# Match `git commit` (with -m, --amend, etc.) but not `git commit-tree` or merges
if [[ ! "$command" =~ (^|[^A-Za-z_])git[[:space:]]+commit($|[^-A-Za-z_]) ]]; then
  exit 0
fi

# Skip if the command failed (commit didn't happen)
exit_code="$(get_field '.tool_response.exit_code')"
if [[ -n "$exit_code" && "$exit_code" != "0" ]]; then
  exit 0
fi

# Locate CLI binary
FI_BIN="${FOUND_ISSUES_BIN:-found-issues}"
if ! command -v "$FI_BIN" >/dev/null 2>&1; then
  if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -x "$CLAUDE_PLUGIN_ROOT/bin/found-issues" ]]; then
    FI_BIN="$CLAUDE_PLUGIN_ROOT/bin/found-issues"
  else
    exit 0
  fi
fi

# Locate lib
if [[ -n "${FOUND_ISSUES_LIB_DIR:-}" ]]; then
  lib_dir="$FOUND_ISSUES_LIB_DIR"
elif [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
  lib_dir="$CLAUDE_PLUGIN_ROOT/lib"
else
  cli_dir="$(dirname "$(readlink -f "$FI_BIN" 2>/dev/null || echo "$FI_BIN")")"
  lib_dir="$cli_dir/../lib"
fi

if [[ -f "$lib_dir/parse-entries.sh" ]]; then
  # shellcheck source=../lib/parse-entries.sh
  source "$lib_dir/parse-entries.sh"
else
  exit 0
fi

# Must be in a git repo
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  exit 0
fi

# Find issues file
issues_file="$(fi_find_issues_file 2>/dev/null || true)"
[[ -z "$issues_file" || ! -f "$issues_file" ]] && exit 0

# Get HEAD commit info
short_sha="$(git rev-parse --short=7 HEAD 2>/dev/null || true)"
[[ -z "$short_sha" ]] && exit 0

# Files touched by HEAD
touched_files="$(git show --name-only --format= HEAD 2>/dev/null | grep -v '^$' || true)"
[[ -z "$touched_files" ]] && exit 0

# Find matching [open] entries (excluding ones already annotated with this short SHA)
already_annotated_pattern="\\(commit: $short_sha\\)"

matching=""
while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue
  if [[ "$entry" =~ $already_annotated_pattern ]]; then
    continue
  fi

  e_data="$(fi_parse_entry "$entry" 2>/dev/null || true)"
  [[ -z "$e_data" ]] && continue
  e_path="$(printf '%s' "$e_data" | grep '^path=' | head -1 | cut -d= -f2-)"
  [[ -z "$e_path" ]] && continue

  while IFS= read -r tf; do
    [[ -z "$tf" ]] && continue
    if [[ "$tf" == "$e_path" || "$tf" == */"$e_path" || "$e_path" == */"$tf" ]]; then
      matching+="$entry"$'\n'
      break
    fi
  done <<< "$touched_files"
done < <(fi_entries "$issues_file" open 2>/dev/null)

if [[ -z "$matching" ]]; then
  exit 0
fi

cat <<EOF
## found-issues — commit $short_sha touches files referenced by [open] entries

$matching
If your commit addresses any of these, run \`/found-issues:annotate-commit\` now
(defaults to HEAD; pass a different SHA if needed).

When the commit lands on the default branch (or already has, for direct
pushes), \`/found-issues:sync\` will auto-flip these to [fixed].
EOF
