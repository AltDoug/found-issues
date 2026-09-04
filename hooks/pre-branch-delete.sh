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

# Strip quoted string content from the command before pattern-matching, so
# a deletion verb that appears only INSIDE a string literal — e.g. `printf
# 'git branch -D old' | pbcopy` for an operator handoff — reads as inert
# text, not a command actually being executed. Also stops that same false
# match from collaterally blocking unrelated steps chained in the same
# Bash tool call. Same technique as hooks/stop-reminder.sh's
# bash_turn_mutates(): drop single-quoted spans first, then double-quoted
# spans (respecting backslash-escaped inner quotes).
_fi_command_unquoted="$(printf '%s' "$command" \
  | sed "s/'[^']*'//g" \
  | sed -E 's/"([^"\\]|\\.)*"//g')"

# Patterns 1+2 tokenize each simple-command segment instead of position-
# matching the whole string. Three reasons, all observed bypasses:
#   - git accepts the delete flag anywhere relative to the other args
#     (git branch --delete NAME, git push --delete REMOTE NAME, ...)
#   - deletes may name SEVERAL branches (git branch -D b1 b2)
#   - compound commands hide the delete in a later segment
#     (git push origin main && git push origin --delete feature-x)
# Glob expansion is disabled around the unquoted word-splits so a `*` in
# the command can't expand against the cwd. Tokens are trimmed to the
# branch-name charset so shell syntax fragments ("foo)") don't obscure the
# real name.
_fi_segments="$(printf '%s' "$_fi_command_unquoted" | tr '|;&' '\n')"
while IFS= read -r seg_cmd; do
  [[ -z "${seg_cmd//[[:space:]]/}" ]] && continue

  # Pattern 1: git branch with -d/-D/--delete anywhere; EVERY non-flag
  # argument after "branch" is a branch name.
  if [[ "$seg_cmd" =~ git[[:space:]]+branch[[:space:]]+(.*) ]]; then
    branch_args="${BASH_REMATCH[1]}"
    has_delete_flag=0
    targets=()
    set -f
    for tok in $branch_args; do
      case "$tok" in
        -d|-D|--delete) has_delete_flag=1 ;;
        -*) : ;;
        *)
          tok="${tok%%[^A-Za-z0-9._/-]*}"
          [[ -n "$tok" ]] && targets+=("$tok")
          ;;
      esac
    done
    set +f
    if (( has_delete_flag == 1 && ${#targets[@]} > 0 )); then
      branches+=("${targets[@]}")
    fi
  fi

  # Pattern 2: git push with -d/--delete anywhere; every non-flag argument
  # after the remote (the first positional) is a branch name. If an unknown
  # value-taking flag swallows the remote slot, extra tokens are checked
  # harmlessly (nothing tracks an issues file at that ref) and the real
  # branch is still in the list.
  if [[ "$seg_cmd" =~ git[[:space:]]+push[[:space:]]+(.*) ]]; then
    push_args="${BASH_REMATCH[1]}"
    has_delete_flag=0
    positionals=()
    set -f
    for tok in $push_args; do
      case "$tok" in
        -d|--delete) has_delete_flag=1 ;;
        -*) : ;;
        *)
          tok="${tok%%[^A-Za-z0-9._/-]*}"
          [[ -n "$tok" ]] && positionals+=("$tok")
          ;;
      esac
    done
    set +f
    if (( has_delete_flag == 1 && ${#positionals[@]} > 1 )); then
      branches+=("${positionals[@]:1}")
    fi
  fi
done <<<"$_fi_segments"

# Pattern 3: git push <remote> :<name>  (old-style delete)
if [[ "$_fi_command_unquoted" =~ git[[:space:]]+push[[:space:]]+[A-Za-z0-9._/-]+[[:space:]]+:([A-Za-z0-9._/-]+) ]]; then
  branches+=("${BASH_REMATCH[1]}")
fi

# Pattern 4: gh api ... DELETE ... refs/heads/<name>
if [[ "$_fi_command_unquoted" =~ gh[[:space:]]+api[[:space:]].*DELETE.*refs/heads/([A-Za-z0-9._/-]+) ]]; then
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
  # LC_ALL=C: $data's symptom= line carries the entry's raw symptom text,
  # which routinely contains em-dashes (CONTRIBUTING.md's own house style).
  # Under a UTF-8 locale, BSD grep on macOS dies with "illegal byte
  # sequence" scanning that multi-byte content even when matching an
  # ASCII-only anchor like ^path=; GNU grep on Linux is exposed to the
  # equivalent multibyte failure. Byte-mode grep is safe here since every
  # pattern below is plain ASCII. Same fix as elsewhere in hooks/ + lib/
  # (see CHANGELOG's stop-reminder/session-start LC_ALL=C entries).
  data="$(fi_parse_entry "$line" 2>/dev/null)" || return 1
  path="$(printf '%s' "$data" | LC_ALL=C grep '^path=' | head -1 | cut -d= -f2-)"
  line_num="$(printf '%s' "$data" | LC_ALL=C grep '^line=' | head -1 | cut -d= -f2-)"
  symptom="$(printf '%s' "$data" | LC_ALL=C grep '^symptom=' | head -1 | cut -d= -f2-)"
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

  # Also read the archive file on the default branch. cmd_archive
  # (lib/archive.sh) moves closed [fixed] entries out of the working
  # ledger into found-issues-archive.md (sibling of $rel_path) to keep it
  # lean — an entry that was promoted via PR, flipped to [fixed], and later
  # archived disappears from main_content entirely even though it was
  # genuinely promoted. Without unioning the archive in, its dedup key
  # vanishes from main_keyset and a fully-merged branch reads as "not yet
  # promoted". Mirrors archive.sh's own path derivation: same directory as
  # the tracked issues file, basename always "found-issues-archive.md"
  # (non-dot-prefixed even when the source is the ".found-issues.md"
  # fallback — archive.sh never dot-prefixes the archive file).
  archive_rel_dir="${rel_path%/*}"
  if [[ "$archive_rel_dir" == "$rel_path" ]]; then
    archive_rel_path="found-issues-archive.md"
  else
    archive_rel_path="$archive_rel_dir/found-issues-archive.md"
  fi
  archive_content="$(git show "origin/$default_branch:$archive_rel_path" 2>/dev/null \
    || git show "$default_branch:$archive_rel_path" 2>/dev/null \
    || true)"

  # Build a newline-delimited set of dedup keys from main's entries (working
  # ledger + archive) across ALL statuses (open / deferred / fixed). The key
  # insight: a branch entry that was promoted is findable on main regardless
  # of whether main has since flipped its status, appended
  # (PR:..)/(fixed:..) annotations, or archived it out of the working file.
  main_keyset=""
  _fi_main_and_archive="$main_content"$'\n'"$archive_content"
  if [[ -n "$_fi_main_and_archive" ]]; then
    while IFS= read -r m_line; do
      if [[ "$m_line" =~ ^-[[:space:]]+\[(open|deferred|fixed)\] ]]; then
        m_key="$(fi_dedup_key_for_line "$m_line" 2>/dev/null || true)"
        [[ -n "$m_key" ]] && main_keyset+="${m_key}"$'\n'
      fi
    done <<< "$_fi_main_and_archive"
  fi

  # Find branch [open] entries whose dedup key is not in main's keyset.
  branch_unpromoted=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^-[[:space:]]+\[open\] ]]; then
      b_key="$(fi_dedup_key_for_line "$line" 2>/dev/null || true)"
      if [[ -z "$b_key" ]]; then
        # Parse failed — treat as unpromoted (safer than silently allowing).
        branch_unpromoted+="$line"$'\n'
      # LC_ALL=C: dedup keys retain the symptom's raw bytes (canonicalize.sh
      # lowercases/collapses whitespace but never strips non-ASCII), so an
      # em-dash-bearing key hits the same BSD/GNU grep multibyte failure as
      # above.
      elif ! printf '%s' "$main_keyset" | LC_ALL=C grep -Fxq -- "$b_key"; then
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
