#!/usr/bin/env bash
# promote.sh — the promote subcommand — carry [open] entries to the default branch
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Extracted verbatim from bin/found-issues in v2.2.9 — the final step of the
# tracked §12 split, which closes the loc-validator entry and removes the
# loc-override marker from the CLI header.
#
# Functions:
#   fi_promote_apply [...]
#   cmd_promote [...]

# === Subcommand: promote ===
#
# Lists [open] entries on current branch that are not yet on the default branch.
# Does NOT auto-edit the default branch — prints entries for the user/agent
# to consolidate manually (consistent with "no direct push to main").

# Copy [open] entries from <source-branch>'s ledger into the current branch's
# ledger, verbatim and serialized. Backs `promote --apply --from <branch>`.
#
# Runs on the TARGET branch (freshly cut from the default branch), reading the
# source with `git show`, because by step 5 of the promote workflow the operator
# has already left the source branch behind.
#
# Entries are copied VERBATIM rather than re-logged: `log` would stamp today's
# date, resetting entry age and corrupting the stale-entry counts that drive
# the statusline and the sync nudges.
#
#   $1 target ledger path, $2 repo-relative ledger path, $3 source branch
# Exits: 0 applied (or nothing to apply), 2 usage / unreadable source.
fi_promote_apply() {
  local file="$1" rel_path="$2" from_branch="$3"

  if [[ -z "$from_branch" ]]; then
    fi_err "promote --apply: missing --from <source-branch>"
    fi_err "Usage: found-issues promote --apply --from <source-branch>"
    return 2
  fi

  local source_content
  if ! source_content="$(git show "$from_branch:$rel_path" 2>/dev/null)"; then
    fi_err "promote --apply: cannot read $rel_path on branch \"$from_branch\""
    fi_err "Check the branch name exists and carries a ledger at that path."
    return 2
  fi

  # Guarantee a trailing newline before appending, or the first copied entry
  # would be glued onto the target's last line.
  if [[ -s "$file" ]] && [[ -n "$(tail -c 1 "$file")" ]]; then
    printf '\n' >> "$file"
  fi

  local tmp added=0 line
  tmp="$(mktemp -t fi-promote.XXXXXX)"
  cat "$file" > "$tmp"
  while IFS= read -r line; do
    # [open] only: [fixed] entries are already resolved history, and a
    # [deferred] entry carries defer-cycle state that belongs to its branch.
    [[ "$line" =~ ^-\ \[open\] ]] || continue
    # -F -x: exact whole-line match. Substring matching here is the cmd_archive
    # data-loss bug in reverse — a prefix entry would be silently skipped.
    #
    # Checked against $tmp, not $file: $tmp starts as a copy of the target and
    # accumulates this run's additions, so a source ledger carrying the same
    # line twice collapses to one instead of copying both.
    grep -Fxq -- "$line" "$tmp" && continue
    printf '%s\n' "$line" >> "$tmp"
    added=$(( added + 1 ))
  done <<< "$source_content"
  mv "$tmp" "$file"

  if (( added == 0 )); then
    printf 'promote: nothing to apply — every [open] entry on %s is already here.\n' "$from_branch"
  elif (( added == 1 )); then
    printf 'Applied 1 entry from %s.\n' "$from_branch"
  else
    printf 'Applied %d entries from %s.\n' "$added" "$from_branch"
  fi
  cmd_status plain
}

cmd_promote() {
  local apply=0 from_branch=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply)   apply=1; shift ;;
      --from)    from_branch="${2:-}"; shift 2 || break ;;
      -h|--help)
        printf 'Usage: found-issues promote                              List branch-only [open] entries\n'
        printf '       found-issues promote --apply --from <branch>      Copy them onto the current branch\n'
        return 0
        ;;
      *) shift ;;
    esac
  done

  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    fi_err "promote: not in a git repo"
    return 1
  fi

  local current_branch default_branch
  current_branch="$(git branch --show-current 2>/dev/null || true)"
  default_branch="$(fi_resolve_default_branch)"

  if [[ -z "$current_branch" ]]; then
    fi_err "promote: detached HEAD; check out a branch first"
    return 1
  fi
  if [[ "$current_branch" == "$default_branch" ]]; then
    fi_err "promote: already on $default_branch — nothing to promote"
    return 1
  fi

  local file
  file="$(fi_find_issues_file)" || {
    fi_err "promote: no found-issues.md found on this branch"
    return 1
  }

  # Get default branch's version of the file (if any).
  # Use `pwd -P` (physical, resolves symlinks) on BOTH paths so /var vs
  # /private/var on macOS doesn't break the prefix subtraction.
  local repo_root file_dir_real repo_real rel_dir rel_path main_content
  repo_root="$(git rev-parse --show-toplevel)"
  file_dir_real="$(cd "$(dirname "$file")" 2>/dev/null && pwd -P)"
  repo_real="$(cd "$repo_root" 2>/dev/null && pwd -P)"
  rel_dir="${file_dir_real#"$repo_real"}"
  rel_dir="${rel_dir#/}"
  if [[ -n "$rel_dir" ]]; then
    rel_path="$rel_dir/$(basename "$file")"
  else
    rel_path="$(basename "$file")"
  fi
  if (( apply == 1 )); then
    fi_promote_apply "$file" "$rel_path" "$from_branch"
    return $?
  fi

  main_content="$(git show "origin/$default_branch:$rel_path" 2>/dev/null \
    || git show "$default_branch:$rel_path" 2>/dev/null \
    || true)"

  # Get [open] entries on current branch that don't appear verbatim on main
  local needs_promotion=0
  printf 'Entries on %s not yet on %s:\n\n' "$current_branch" "$default_branch"

  local line
  # Final-partial-line guard (READ-LOOP GUARD, top of file). Listing only, but
  # the entry most likely to need promoting is the one just appended — exactly
  # the one an unguarded loop omits.
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^-\ \[open\] ]]; then
      if [[ -z "$main_content" ]] || ! printf '%s' "$main_content" | grep -Fxq -- "$line"; then
        printf '%s\n' "$line"
        needs_promotion=$((needs_promotion + 1))
      fi
    fi
  done <"$file"

  if [[ "$needs_promotion" -eq 0 ]]; then
    printf '(none — branch is in sync with %s for [open] entries)\n' "$default_branch"
    return 0
  fi

  local subj_verb
  if [[ "$needs_promotion" -eq 1 ]]; then
    subj_verb="entry needs"
  else
    subj_verb="entries need"
  fi
  printf '\n%d %s promotion. To consolidate:\n' "$needs_promotion" "$subj_verb"
  printf '  1. Open a PR from %s to %s with these entries added to %s\n' \
    "$current_branch" "$default_branch" "$rel_path"
  printf '  2. After merge, the pre-branch-delete hook will allow deletion of %s\n' \
    "$current_branch"
}

