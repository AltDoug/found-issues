#!/usr/bin/env bash
# post-pr-create.sh — PostToolUse hook on Bash
#
# Fires after every Bash invocation. If the command was `gh pr create`,
# extracts the new PR number from stdout, scans the PR's diff for files
# referenced by [open] entries, and surfaces a one-shot prompt to Claude
# telling it which entries it should annotate.
#
# This is the enforcement layer that makes /fi annotate-pr happen
# reliably — without it, Claude relies on memory of the rule.
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
stdout="$(get_field '.tool_response.stdout')"

# Only fire for gh pr create (and variants like `gh pr create --base main`)
if [[ "$command" != *"gh pr create"* ]]; then
  exit 0
fi

# Extract PR number from stdout (URL form: https://github.com/org/repo/pull/N)
pr_num=""
if [[ "$stdout" =~ /pull/([0-9]+) ]]; then
  pr_num="${BASH_REMATCH[1]}"
fi
[[ -z "$pr_num" ]] && exit 0

# Locate CLI + lib
FI_BIN="${FOUND_ISSUES_BIN:-found-issues}"
if ! command -v "$FI_BIN" >/dev/null 2>&1; then
  if [[ -x "$HOME/.local/bin/found-issues" ]]; then
    FI_BIN="$HOME/.local/bin/found-issues"
  elif [[ -x "$HOME/.found-issues/cli/found-issues" ]]; then
    FI_BIN="$HOME/.found-issues/cli/found-issues"
  else
    exit 0  # no CLI; nothing we can do
  fi
fi

cli_dir="$(dirname "$(readlink -f "$FI_BIN" 2>/dev/null || echo "$FI_BIN")")"
lib_dir="${FOUND_ISSUES_LIB_DIR:-$cli_dir/../lib}"

if [[ -f "$lib_dir/parse-entries.sh" ]]; then
  # shellcheck source=../lib/parse-entries.sh
  source "$lib_dir/parse-entries.sh"
else
  exit 0
fi

# Find issues file
issues_file="$(fi_find_issues_file 2>/dev/null || true)"
[[ -z "$issues_file" || ! -f "$issues_file" ]] && exit 0

# Get touched files in the PR
if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  exit 0
fi

touched_files="$(gh pr view "$pr_num" --json files --jq '.files[].path' 2>/dev/null || true)"
[[ -z "$touched_files" ]] && exit 0

# Find matching [open] entries (excluding ones already annotated for this PR)
repo_id="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)"
already_annotated_pattern="\\(PR: $repo_id#$pr_num\\)"

matching=""
while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue
  # Skip if already annotated for this PR
  if [[ "$entry" =~ $already_annotated_pattern ]]; then
    continue
  fi

  # Get path from entry
  e_data="$(fi_parse_entry "$entry" 2>/dev/null || true)"
  [[ -z "$e_data" ]] && continue
  e_path="$(printf '%s' "$e_data" | grep '^path=' | head -1 | cut -d= -f2-)"
  [[ -z "$e_path" ]] && continue

  # Match against touched files
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

# Surface to Claude
cat <<EOF
## found-issues — PR #$pr_num touches files referenced by [open] entries

$matching
If your PR addresses any of these, run \`/fi annotate-pr $pr_num\` now.
The format-enforcer hook will block bare \`PR #$pr_num\` references — only
the canonical \`(PR: $repo_id#$pr_num)\` annotation is accepted.
EOF
