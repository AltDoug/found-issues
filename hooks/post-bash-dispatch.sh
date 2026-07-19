#!/usr/bin/env bash
# post-bash-dispatch.sh — the plugin's single PostToolUse(Bash) hook.
#
# Routes on the executed command:
#   gh pr create            → auto-annotate line-matched entries (--hook-auto);
#                             surface candidates needing model judgment
#   git commit               → same, against HEAD (--hook-auto)
#   gh pr merge|close|reopen → background `found-issues sync` (statusline
#                             freshness; moved verbatim from post-pr-state.sh)
#
# Replaces post-pr-create.sh, post-git-commit.sh, post-pr-state.sh (v2.0.0):
# one process + one jq parse per Bash call instead of three.
#
# Exit code: 0 always (additive; never blocks).
# Output: via fi_emit_post_context (plain text on Claude, JSON on Codex).
# Opt-outs: FOUND_ISSUES_AUTO_ANNOTATE=off (prompt-only legacy behavior —
#           old post-pr-create/post-git-commit scan+prompt, verbatim below),
#           FOUND_ISSUES_POST_PR_STATE=off (skip merge-route sync).

set -euo pipefail

input="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0

get_field() {
  printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null || true
}

tool_name="$(get_field '.tool_name')"
[[ "$tool_name" != "Bash" ]] && exit 0
cmd="$(get_field '.tool_input.command')"
[[ -z "$cmd" ]] && exit 0

# --- shared resolution (same chain as the retired hooks) ---
__fi_hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
FI_BIN="${FOUND_ISSUES_BIN:-found-issues}"
if ! command -v "$FI_BIN" >/dev/null 2>&1; then
  if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -x "$CLAUDE_PLUGIN_ROOT/bin/found-issues" ]]; then
    FI_BIN="$CLAUDE_PLUGIN_ROOT/bin/found-issues"
  elif [[ -x "$__fi_hook_dir/../bin/found-issues" ]]; then
    FI_BIN="$__fi_hook_dir/../bin/found-issues"
  else
    exit 0
  fi
fi
lib_dir="${FOUND_ISSUES_LIB_DIR:-$__fi_hook_dir/../lib}"
[[ -f "$lib_dir/harness.sh" ]] && source "$lib_dir/harness.sh"

# ============ legacy fallback prompts (FOUND_ISSUES_AUTO_ANNOTATE=off) =====
# Moved verbatim from the retired post-pr-create.sh / post-git-commit.sh
# matching-scan + prompt bodies (same silent-exit guards, same
# lib/parse-entries.sh sourcing). Only the variable plumbing changed
# (pr_num arrives as $1 / commit defaults to HEAD, since the shared block
# above already resolved FI_BIN/lib_dir and the caller already extracted
# pr_num) and output goes through fi_emit_post_context (Codex-safe JSON)
# instead of bare `cat`. Bash requires function definitions before use, so
# these sit above the routing blocks that call them.

legacy_pr_prompt() {
  local pr_num="$1"

  if [[ -f "$lib_dir/parse-entries.sh" ]]; then
    # shellcheck source=../lib/parse-entries.sh
    source "$lib_dir/parse-entries.sh"
  else
    exit 0
  fi

  local issues_file
  issues_file="$(fi_find_issues_file 2>/dev/null || true)"
  [[ -z "$issues_file" || ! -f "$issues_file" ]] && exit 0

  if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
    exit 0
  fi

  local touched_files
  touched_files="$(gh pr view "$pr_num" --json files --jq '.files[].path' 2>/dev/null || true)"
  [[ -z "$touched_files" ]] && exit 0

  local repo_id
  repo_id="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)"
  local already_annotated_pattern="\\(PR: $repo_id#$pr_num\\)"

  local matching="" entry e_data e_path tf
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

  fi_emit_post_context "## found-issues — PR #$pr_num touches files referenced by [open] entries

$matching
If your PR addresses any of these, run \`/found-issues:annotate-pr $pr_num\` now.
The format-enforcer hook will block bare \`PR #$pr_num\` references — only
the canonical \`(PR: $repo_id#$pr_num)\` annotation is accepted."
}

legacy_commit_prompt() {
  if [[ -f "$lib_dir/parse-entries.sh" ]]; then
    # shellcheck source=../lib/parse-entries.sh
    source "$lib_dir/parse-entries.sh"
  else
    exit 0
  fi

  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    exit 0
  fi

  local issues_file
  issues_file="$(fi_find_issues_file 2>/dev/null || true)"
  [[ -z "$issues_file" || ! -f "$issues_file" ]] && exit 0

  local short_sha
  short_sha="$(git rev-parse --short=7 HEAD 2>/dev/null || true)"
  [[ -z "$short_sha" ]] && exit 0

  local touched_files
  touched_files="$(git show --name-only --format= HEAD 2>/dev/null | grep -v '^$' || true)"
  [[ -z "$touched_files" ]] && exit 0

  local already_annotated_pattern="\\(commit: $short_sha\\)"

  local matching="" entry e_data e_path tf
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

  fi_emit_post_context "## found-issues — commit $short_sha touches files referenced by [open] entries

$matching
If your commit addresses any of these, run \`/found-issues:annotate-commit\` now
(defaults to HEAD; pass a different SHA if needed).

When the commit lands on the default branch (or already has, for direct
pushes), \`/found-issues:sync\` will auto-flip these to [fixed]."
}

# ============ route: gh pr merge/close/reopen → background sync ============
if [[ "$cmd" =~ (^|[[:space:];|&])gh[[:space:]]+pr[[:space:]]+(merge|close|reopen)([[:space:]]|$) ]]; then
  if [[ "${FOUND_ISSUES_POST_PR_STATE:-on}" != "off" ]]; then
    if [[ -n "${FOUND_ISSUES_AUTOSYNC_CMD:-}" ]]; then
      ( bash -c "$FOUND_ISSUES_AUTOSYNC_CMD" >/dev/null 2>&1 & ) >/dev/null 2>&1
    else
      ( "$FI_BIN" sync >/dev/null 2>&1 & ) >/dev/null 2>&1
    fi
  fi
  exit 0
fi

# ============ route: gh pr create → annotate ============
if [[ "$cmd" == *"gh pr create"* ]]; then
  stdout="$(get_field '.tool_response.stdout')"
  pr_num=""
  if [[ "$stdout" =~ /pull/([0-9]+) ]]; then
    pr_num="${BASH_REMATCH[1]}"
  fi
  [[ -z "$pr_num" ]] && exit 0

  if [[ "${FOUND_ISSUES_AUTO_ANNOTATE:-on}" == "off" ]]; then
    legacy_pr_prompt "$pr_num"
    exit 0
  fi

  out="$("$FI_BIN" annotate-pr "$pr_num" --hook-auto 2>/dev/null)" && rc=0 || rc=$?
  if [[ "$rc" -eq 0 && "$out" == *"Annotated"* ]]; then
    fi_emit_post_context "found-issues: PR #$pr_num auto-annotated — ${out%%$'\n'*} (line-matched by the PR diff). Entries updated in the ledger; no action needed unless one looks wrong."
  elif [[ "$rc" -eq 3 ]]; then
    fi_emit_post_context "## found-issues — PR #$pr_num needs annotation judgment

$out

Compare each candidate's symptom against what the PR actually changes, then run:
  found-issues annotate-pr $pr_num --pick <path:line>[,...]
(or --all only if the PR genuinely addresses every candidate). Entries the PR does not fix must NOT be annotated — they would false-flip to [fixed] on merge."
  fi
  exit 0
fi

# ============ route: git commit → annotate ============
if [[ "$cmd" =~ (^|[^A-Za-z_])git[[:space:]]+commit($|[^-A-Za-z_]) ]]; then
  exit_code="$(get_field '.tool_response.exit_code')"
  [[ -n "$exit_code" && "$exit_code" != "0" ]] && exit 0
  git rev-parse --git-dir >/dev/null 2>&1 || exit 0

  if [[ "${FOUND_ISSUES_AUTO_ANNOTATE:-on}" == "off" ]]; then
    legacy_commit_prompt
    exit 0
  fi

  out="$("$FI_BIN" annotate-commit HEAD --hook-auto 2>/dev/null)" && rc=0 || rc=$?
  if [[ "$rc" -eq 0 && "$out" == *"Annotated"* ]]; then
    fi_emit_post_context "found-issues: ${out%%$'\n'*} (line-matched by the commit diff)."
  elif [[ "$rc" -eq 3 ]]; then
    fi_emit_post_context "## found-issues — commit needs annotation judgment

$out

If this commit addresses any candidate, run the printed --pick command; otherwise ignore."
  fi
  exit 0
fi

exit 0
