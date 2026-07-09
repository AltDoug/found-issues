#!/usr/bin/env bash
# pre-branch-delete.sh — PreToolUse hook on Bash
#
# Hard-blocks branch deletions if the branch has [open] found-issues entries
# whose dedup key (path:line:symptom) does not appear in the default branch's
# version of the file. Reason: deleting a branch with unpromoted entries
# silently loses them — the whole point of /found-issues:promote is to
# prevent that.
#
# Matching: dedup key, not full-line equality. An entry that was merged via
# PR and then flipped from [open] to [fixed] on main (with annotations
# appended) is still considered "promoted" — its dedup key is on main even
# though the verbatim line is not. v1.0.5 and earlier used grep -Fxq full-
# line matching and false-positive-blocked deletion of merged-via-PR
# feature branches.
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

# Allow inline env-prefix opt-out. Documented escape hatch in
# docs/configuration.md advertises `FOUND_ISSUES_PROMOTE_GUARD=off git
# branch -D foo`, but inside Claude Code the hook subprocess never inherits
# per-command env from the command string — the prefix only takes effect
# when bash runs the inner git command. Parse the prefix here so the
# documented bypass works as advertised.
if [[ "$command" =~ ^[[:space:]]*FOUND_ISSUES_PROMOTE_GUARD=off[[:space:]] ]]; then
  exit 0
fi

# === Extract candidate branch names from the command ===

branches=()

# Patterns 1+2 tokenize the argument stream instead of position-matching:
# git accepts the delete flag anywhere relative to the other args
# (git branch --delete NAME, git push --delete REMOTE NAME,
# git push REMOTE -d NAME, ...), and the earlier fixed-order regexes let
# all three of those forms through unguarded. Glob expansion is disabled
# around the unquoted word-splits so a `*` in the command can't expand
# against the cwd.

# Pattern 1: git branch with -d/-D/--delete anywhere; first non-flag
# argument after "branch" is the branch name.
if [[ "$command" =~ git[[:space:]]+branch[[:space:]]+([^\|\;\&]*) ]]; then
  branch_args="${BASH_REMATCH[1]}"
  has_delete_flag=0
  target=""
  set -f
  for tok in $branch_args; do
    case "$tok" in
      -d|-D|--delete) has_delete_flag=1 ;;
      -*) : ;;
      *) [[ -z "$target" ]] && target="$tok" ;;
    esac
  done
  set +f
  if (( has_delete_flag == 1 )) && [[ -n "$target" ]]; then
    branches+=("$target")
  fi
fi

# Pattern 2: git push with -d/--delete anywhere; the branch is the second
# non-flag argument after "push" (the first is the remote).
if [[ "$command" =~ git[[:space:]]+push[[:space:]]+([^\|\;\&]*) ]]; then
  push_args="${BASH_REMATCH[1]}"
  has_delete_flag=0
  remote_tok=""
  branch_tok=""
  set -f
  for tok in $push_args; do
    case "$tok" in
      -d|--delete) has_delete_flag=1 ;;
      -*) : ;;
      *)
        if [[ -z "$remote_tok" ]]; then
          remote_tok="$tok"
        elif [[ -z "$branch_tok" ]]; then
          branch_tok="$tok"
        fi
        ;;
    esac
  done
  set +f
  if (( has_delete_flag == 1 )) && [[ -n "$branch_tok" ]]; then
    branches+=("$branch_tok")
  fi
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

# Short-circuit when the default branch does not track the issues file at
# all. The guard's contract — "promote entries to the default branch
# before deleting" — is incoherent in that regime: there is no canonical
# file on main to promote into. Surfaces today when a repo transitions
# the issues file from tracked to per-developer-local (gitignored), and
# old feature branches still carry the tracked file. Without this
# short-circuit the hook compares branch-tracked content to an empty
# main keyset and false-positive-blocks every delete.
if ! git cat-file -e "origin/$default_branch:$rel_path" 2>/dev/null \
    && ! git cat-file -e "$default_branch:$rel_path" 2>/dev/null; then
  {
    echo "found-issues: $default_branch does not track $rel_path; promote-guard skipped."
    echo "Entries are local-only in this repo and are not lost by branch deletion."
  } >&2
  exit 0
fi

# Source dedup-key helpers. Both libs are needed: parse-entries.sh for
# fi_parse_entry, canonicalize.sh for fi_dedup_key{,_abstract}.
if [[ -n "${FOUND_ISSUES_LIB_DIR:-}" ]]; then
  lib_dir="$FOUND_ISSUES_LIB_DIR"
elif [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
  lib_dir="$CLAUDE_PLUGIN_ROOT/lib"
else
  cli_dir="$(dirname "$(readlink -f "${FOUND_ISSUES_BIN:-found-issues}" 2>/dev/null || command -v "${FOUND_ISSUES_BIN:-found-issues}" 2>/dev/null || echo "")")"
  lib_dir="$cli_dir/../lib"
fi
if [[ -f "$lib_dir/parse-entries.sh" && -f "$lib_dir/canonicalize.sh" ]]; then
  # shellcheck source=../lib/parse-entries.sh
  source "$lib_dir/parse-entries.sh"
  # shellcheck source=../lib/canonicalize.sh
  source "$lib_dir/canonicalize.sh"
else
  # Lib missing — can't compute dedup keys safely. Fail open (allow delete)
  # rather than fall back to line-equality, which was the bug we're fixing.
  exit 0
fi

# Compute the dedup key for a single entry line. Mirrors cmd_log's branching
# (path:line, path-only, or abstract). Echoes empty on parse failure.
fi_dedup_key_for_line() {
  local line="$1"
  local data path line_num symptom
  data="$(fi_parse_entry "$line" 2>/dev/null)" || return 1
  path="$(printf '%s' "$data" | grep '^path=' | head -1 | cut -d= -f2-)"
  line_num="$(printf '%s' "$data" | grep '^line=' | head -1 | cut -d= -f2-)"
  symptom="$(printf '%s' "$data" | grep '^symptom=' | head -1 | cut -d= -f2-)"
  if [[ -n "$line_num" ]]; then
    fi_dedup_key "$path" "$line_num" "$symptom"
  elif [[ "$path" == */* || "$path" == *.* ]]; then
    fi_dedup_key "$path" "" "$symptom"
  else
    fi_dedup_key_abstract "$symptom"
  fi
}

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

  # Build a newline-delimited set of dedup keys from main's entries across
  # ALL statuses (open / deferred / fixed). The key insight: a branch entry
  # that was promoted is findable in main regardless of whether main has
  # since flipped its status or appended (PR:..)/(fixed:..) annotations.
  main_keyset=""
  if [[ -n "$main_content" ]]; then
    while IFS= read -r m_line; do
      if [[ "$m_line" =~ ^-[[:space:]]+\[(open|deferred|fixed)\] ]]; then
        m_key="$(fi_dedup_key_for_line "$m_line" 2>/dev/null || true)"
        [[ -n "$m_key" ]] && main_keyset+="${m_key}"$'\n'
      fi
    done <<< "$main_content"
  fi

  # Find branch [open] entries whose dedup key is not in main's keyset.
  branch_unpromoted=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^-[[:space:]]+\[open\] ]]; then
      b_key="$(fi_dedup_key_for_line "$line" 2>/dev/null || true)"
      if [[ -z "$b_key" ]]; then
        # Parse failed — treat as unpromoted (safer than silently allowing).
        branch_unpromoted+="$line"$'\n'
      elif ! printf '%s' "$main_keyset" | grep -Fxq -- "$b_key"; then
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
