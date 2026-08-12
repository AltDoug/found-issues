#!/usr/bin/env bash
# annotate-commands.sh — the annotate-pr and annotate-commit subcommands
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Extracted verbatim from bin/found-issues in v2.2.9 — the final step of the
# tracked §12 split, which closes the loc-validator entry and removes the
# loc-override marker from the CLI header.
#
# Functions:
#   cmd_annotate_pr [...]
#   cmd_annotate_commit [...]

# === Subcommand: annotate-pr ===
#
# Usage: found-issues annotate-pr <PR-number> [--pick <loc>[,<loc>...]] [--all]
#
# Scans the PR's diff for files referenced by [open] entries and appends
# (PR: org/repo#N) to matching entries. File-level matching alone
# over-annotates — a PR touching a hot file (one with many open entries)
# would tag every entry on that file, and sync would false-flip them all to
# [fixed] on merge (hit in production 2026-07-09: 12 tagged, 3 actually
# fixed). So:
#   - a touched file cited by exactly ONE entry auto-annotates (unambiguous)
#   - a touched file cited by SEVERAL entries annotates none of them; the
#     candidates are listed for symptom-level selection via --pick
#   - --pick <path:line>[,...] annotates exactly the selected entries
#     (locations as printed in the candidate list; bare path for line-less
#     entries). Picked entries need not cite a touched file — a fix can land
#     in a different file than the symptom.
#   - --all restores annotate-everything-matching for PRs that genuinely
#     address every listed entry.

cmd_annotate_pr() {
  local pr_num=""
  local annotate_all="no"
  local hook_auto="no"
  local picks_nl=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)
        annotate_all="yes"
        ;;
      --hook-auto)
        hook_auto="yes"
        ;;
      --pick)
        shift
        if [[ -z "${1:-}" ]]; then
          fi_err "annotate-pr: --pick requires a comma-separated list of entry locations"
          return 2
        fi
        picks_nl+="$(fi_split_picks "$1")"$'\n'
        ;;
      --pick=*)
        picks_nl+="$(fi_split_picks "${1#--pick=}")"$'\n'
        ;;
      -*)
        fi_err "annotate-pr: unknown flag: $1"
        fi_err "Usage: found-issues annotate-pr <PR-number> [--pick <path:line>[,<path:line>...]] [--all]"
        return 2
        ;;
      *)
        if [[ -n "$pr_num" ]]; then
          fi_err "Usage: found-issues annotate-pr <PR-number> [--pick <path:line>[,<path:line>...]] [--all]"
          return 2
        fi
        pr_num="$1"
        ;;
    esac
    shift
  done

  if [[ -z "$pr_num" ]]; then
    fi_err "Usage: found-issues annotate-pr <PR-number> [--pick <path:line>[,<path:line>...]] [--all]"
    return 2
  fi
  local ref_repo="" _ref_re='^([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)#([0-9]+)$'
  if [[ "$pr_num" =~ $_ref_re ]]; then
    # Cross-repo ref (e.g. an upstream plugin fix for a consumer-ledger
    # entry). Sync already reads org/repo#N annotations; this makes them
    # producible. --pick is mandatory: file-level auto-matching compares
    # the PR's touched files against THIS repo's entry paths, which is
    # meaningless when the PR lives in another repo's tree.
    ref_repo="${BASH_REMATCH[1]}"
    pr_num="${BASH_REMATCH[2]}"
    if [[ -z "$picks_nl" ]]; then
      fi_err "annotate-pr: cross-repo ref $ref_repo#$pr_num requires --pick <path:line>[,...]"
      return 2
    fi
  elif ! [[ "$pr_num" =~ ^[0-9]+$ ]]; then
    fi_err "annotate-pr: PR argument must be numeric or org/repo#N, got: $pr_num"
    return 2
  fi

  local repo_id
  if [[ -n "$ref_repo" ]]; then
    repo_id="$ref_repo"
  elif ! repo_id="$(fi_repo_id)"; then
    fi_err "annotate-pr: not in a GitHub repo"
    return 1
  fi

  if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
    fi_err "annotate-pr: gh CLI not available or not authenticated"
    return 1
  fi

  # Verify PR exists (in the ref's repo when cross-repo)
  if [[ -n "$ref_repo" ]]; then
    if ! gh pr view "$pr_num" --repo "$ref_repo" --json number >/dev/null 2>&1; then
      fi_err "annotate-pr: PR #$pr_num not found in $repo_id"
      return 1
    fi
  elif ! gh pr view "$pr_num" --json number >/dev/null 2>&1; then
    fi_err "annotate-pr: PR #$pr_num not found in $repo_id"
    return 1
  fi

  local file
  file="$(fi_find_issues_file)" || {
    fi_err "annotate-pr: no found-issues.md found in this repo"
    return 1
  }

  local annotation="(PR: $repo_id#$pr_num)"

  # --pick runs BEFORE (and without) the touched-files fetch: selection is
  # judgment-driven and independent of file matching (a fix can land in a
  # different file than the symptom), and a transient gh failure must not
  # silently drop the requested annotations.
  if [[ -n "$picks_nl" ]]; then
    fi_annotate_apply_picks "$file" "$annotation" "$picks_nl" \
      "annotate-pr" "found-issues annotate-pr ${ref_repo:+$ref_repo#}$pr_num"
    return $?
  fi

  # Get list of files touched by the PR
  local touched_files
  touched_files="$(gh pr view "$pr_num" --json files --jq '.files[].path' 2>/dev/null || true)"

  if [[ -z "$touched_files" ]]; then
    printf 'annotate-pr: PR #%s touches no files (or fetch failed). Nothing to do.\n' "$pr_num"
    return 0
  fi

  local old_ranges=""
  if [[ "$hook_auto" == "yes" ]]; then
    old_ranges="$(gh pr diff "$pr_num" 2>/dev/null | fi_diff_old_ranges || true)"
  fi

  fi_annotate_auto "$file" "$annotation" "$touched_files" "$annotate_all" \
    "annotate-pr" "found-issues annotate-pr $pr_num" "PR #$pr_num" \
    "$hook_auto" "$old_ranges" || return $?
}

# === Subcommand: annotate-commit ===
#
# Usage: found-issues annotate-commit [<sha>]  (default HEAD)
#
# Scans the commit's diff for files referenced by [open] entries,
# appends (commit: <short-sha>) to each matching entry.

cmd_annotate_commit() {
  local target=""
  local annotate_all="no"
  local hook_auto="no"
  local picks_nl=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)
        annotate_all="yes"
        ;;
      --hook-auto)
        hook_auto="yes"
        ;;
      --pick)
        shift
        if [[ -z "${1:-}" ]]; then
          fi_err "annotate-commit: --pick requires a comma-separated list of entry locations"
          return 2
        fi
        picks_nl+="$(fi_split_picks "$1")"$'\n'
        ;;
      --pick=*)
        picks_nl+="$(fi_split_picks "${1#--pick=}")"$'\n'
        ;;
      -*)
        fi_err "annotate-commit: unknown flag: $1"
        fi_err "Usage: found-issues annotate-commit [<sha>] [--pick <path:line>[,<path:line>...]] [--all]"
        return 2
        ;;
      *)
        if [[ -n "$target" ]]; then
          fi_err "Usage: found-issues annotate-commit [<sha>] [--pick <path:line>[,<path:line>...]] [--all]"
          return 2
        fi
        target="$1"
        ;;
    esac
    shift
  done
  [[ -z "$target" ]] && target="HEAD"

  local full_sha short_sha
  full_sha="$(git rev-parse --verify "$target" 2>/dev/null || true)"
  if [[ -z "$full_sha" ]]; then
    fi_err "annotate-commit: not a valid commit: $target"
    return 1
  fi
  short_sha="$(git rev-parse --short=7 "$full_sha")"

  local file
  file="$(fi_find_issues_file)" || {
    fi_err "annotate-commit: no found-issues.md found"
    return 1
  }

  local annotation="(commit: $short_sha)"

  # --pick is independent of the commit's file list — same rationale as
  # annotate-pr (selection is judgment-driven; a fix can land in a
  # different file than the symptom).
  if [[ -n "$picks_nl" ]]; then
    fi_annotate_apply_picks "$file" "$annotation" "$picks_nl" \
      "annotate-commit" "found-issues annotate-commit $target"
    return $?
  fi

  # Files touched by the commit
  local touched_files
  touched_files="$(git show --name-only --format= "$full_sha" 2>/dev/null | grep -v '^$' || true)"

  if [[ -z "$touched_files" ]]; then
    printf 'annotate-commit: commit %s touches no files. Nothing to do.\n' "$short_sha"
    return 0
  fi

  local old_ranges=""
  if [[ "$hook_auto" == "yes" ]]; then
    old_ranges="$(git show --format= "$full_sha" | fi_diff_old_ranges || true)"
  fi

  fi_annotate_auto "$file" "$annotation" "$touched_files" "$annotate_all" \
    "annotate-commit" "found-issues annotate-commit $target" "commit $short_sha" \
    "$hook_auto" "$old_ranges" || return $?
}

