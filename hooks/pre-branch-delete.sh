#!/usr/bin/env bash
# pre-branch-delete.sh — PreToolUse hook on Bash
#
# Hard-blocks branch deletions if the branch has [open] found-issues entries
# that aren't on the default branch. Reason: deleting a branch with
# unpromoted entries silently loses them — the whole point of /found-issues:promote
# is to prevent that.
#
# Patterns matched:
#   git branch -d <name>
#   git branch -D <name>
#   git push <remote> --delete <name>
#   git push <remote> :<name>
#   gh api ... DELETE ... refs/heads/<name>
#
# Hook event: PreToolUse (matcher: Bash)
# Exit codes:
#   0 — allow (no entries to lose, or not a delete operation)
#   2 — block (entries unpromoted); message to stderr

set -euo pipefail

# Allow opt-out
if [[ "${FOUND_ISSUES_PROMOTE_GUARD:-on}" == "off" ]]; then
  exit 0
fi

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
[[ -z "$command" ]] && exit 0

# === Extract candidate branch names from the command ===

branches=()

# Pattern 1: git branch -d / -D <name>
if [[ "$command" =~ git[[:space:]]+branch[[:space:]]+-[dD][[:space:]]+([A-Za-z0-9._/-]+) ]]; then
  branches+=("${BASH_REMATCH[1]}")
fi

# Pattern 2: git push <remote> --delete <name>
if [[ "$command" =~ git[[:space:]]+push[[:space:]]+[A-Za-z0-9._/-]+[[:space:]]+--delete[[:space:]]+([A-Za-z0-9._/-]+) ]]; then
  branches+=("${BASH_REMATCH[1]}")
fi

# Pattern 3: git push <remote> :<name>  (old-style delete)
if [[ "$command" =~ git[[:space:]]+push[[:space:]]+[A-Za-z0-9._/-]+[[:space:]]+:([A-Za-z0-9._/-]+) ]]; then
  branches+=("${BASH_REMATCH[1]}")
fi

# Pattern 4: gh api ... DELETE ... refs/heads/<name>
if [[ "$command" =~ gh[[:space:]]+api[[:space:]].*DELETE.*refs/heads/([A-Za-z0-9._/-]+) ]]; then
  branches+=("${BASH_REMATCH[1]}")
fi

if [[ ${#branches[@]} -eq 0 ]]; then
  exit 0
fi

# Must be in a git repo
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  exit 0
fi

# Determine default branch
default_branch="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
  | sed 's|^refs/remotes/origin/||' || true)"
[[ -z "$default_branch" ]] && default_branch="main"

# Path to the issues file inside the repo (relative)
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
rel_path="docs/found-issues.md"
[[ ! -f "$repo_root/$rel_path" ]] && rel_path=".found-issues.md"

# Check each branch for unpromoted [open] entries
problems=()
for branch in "${branches[@]}"; do
  # Skip if branch == default branch (deleting main is its own bad idea, not ours to enforce here)
  if [[ "$branch" == "$default_branch" ]]; then
    continue
  fi

  # Get branch's version of the issues file
  branch_content="$(git show "$branch:$rel_path" 2>/dev/null \
    || git show "origin/$branch:$rel_path" 2>/dev/null \
    || true)"
  [[ -z "$branch_content" ]] && continue

  # Get default branch's version
  main_content="$(git show "origin/$default_branch:$rel_path" 2>/dev/null \
    || git show "$default_branch:$rel_path" 2>/dev/null \
    || true)"

  # Find [open] entries on branch not on main
  branch_unpromoted=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^-[[:space:]]+\[open\] ]]; then
      if [[ -z "$main_content" ]] \
         || ! printf '%s' "$main_content" | grep -Fxq -- "$line"; then
        branch_unpromoted+="$line"$'\n'
      fi
    fi
  done <<< "$branch_content"

  if [[ -n "$branch_unpromoted" ]]; then
    problems+=("$branch"$'\t'"$branch_unpromoted")
  fi
done

if [[ ${#problems[@]} -eq 0 ]]; then
  exit 0
fi

# Block with detailed message
{
  echo "found-issues: branch deletion blocked"
  echo
  for prob in "${problems[@]}"; do
    branch="${prob%%$'\t'*}"
    entries="${prob#*$'\t'}"
    echo "Branch '$branch' has [open] found-issues entries not yet promoted to '$default_branch':"
    echo
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      echo "  $entry"
    done <<< "$entries"
    echo
  done
  echo "Run /found-issues:promote on the branch first, open a PR to '$default_branch',"
  echo "and re-attempt the delete after merge. This prevents silent loss of"
  echo "tracked observations when feature branches get pruned."
  echo
  echo "To skip this guard for this command only, set FOUND_ISSUES_PROMOTE_GUARD=off."
} >&2

exit 2
