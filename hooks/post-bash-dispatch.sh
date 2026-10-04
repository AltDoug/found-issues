#!/usr/bin/env bash
# post-bash-dispatch.sh — the plugin's single PostToolUse(Bash) hook.
#
# Routes on the executed command:
#   gh pr create            → record line-matched entries as SUGGESTIONS
#                             ((PR-auto: ...), never closing — see fi_auto_form
#                             in lib/annotate.sh); surface candidates needing
#                             model judgment
#   git commit               → same, against HEAD (--hook-auto)
#   gh pr merge|close|reopen → background `found-issues sync` (statusline
#                             freshness; moved verbatim from post-pr-state.sh)
#
# All three routes are non-exclusive and evaluated independently — a single
# Bash call can legitimately satisfy more than one (e.g. `git commit -m x &&
# gh pr create`, or `gh pr create ... && gh pr merge N --auto`), so the
# pr-create and git-commit routes append their context text to an
# accumulator instead of emitting immediately, and the merge/close/reopen
# route no longer exits early either. The routes are evaluated in this
# fixed order: pr-create, then git-commit, then merge/close/reopen LAST.
# The merge route spawns a detached background `found-issues sync`;
# running it after the two synchronous annotation routes means sync sees
# the annotations they just wrote instead of racing them — both sides do
# an atomic tmp-file-then-mv rewrite of the same ledger file, so a
# concurrent sync could otherwise read a stale copy or clobber the
# annotation update. The accumulator is emitted via fi_emit_post_context
# exactly ONCE at the end: on Codex the hook's stdout must be a single JSON
# object, so two emissions would be invalid.
#
# Replaces post-pr-create.sh, post-git-commit.sh, post-pr-state.sh (v2.0.0):
# one process + one jq parse per Bash call instead of three.
#
# Exit code: 0 always (additive; never blocks).
# Output: via fi_emit_post_context (hookSpecificOutput JSON on both harnesses).
# Opt-outs: FOUND_ISSUES_AUTO_ANNOTATE=off (prompt-only legacy behavior —
#           old post-pr-create/post-git-commit scan+prompt, verbatim below),
#           FOUND_ISSUES_POST_PR_STATE=off (skip merge-route sync).

set -euo pipefail

IFS= read -r -d '' input || true

# Zero-fork relevance gate (lib/hook-gate.sh): every route below needs
# "commit", or "gh" plus one of its four verbs, in the command — or an
# AUTOFIX-QUEUED marker anywhere in the payload (it lives in tool_response,
# not the command; a plain substring test, zero forks). Anything else exits
# here, before any jq/$(...). A missing lib or an untrustworthy gate falls
# through to the full path.
__fi_hook_dir="${BASH_SOURCE[0]%/*}"
[[ "$__fi_hook_dir" == "${BASH_SOURCE[0]}" ]] && __fi_hook_dir=.
# shellcheck source=../lib/hook-gate.sh
if [[ -f "$__fi_hook_dir/../lib/hook-gate.sh" ]] \
    && source "$__fi_hook_dir/../lib/hook-gate.sh" && fi_gate_text "$input"; then
  fi_gate_has commit \
    || { fi_gate_has gh && fi_gate_has create merge close reopen; } \
    || [[ "$input" == *AUTOFIX-QUEUED* ]] \
    || exit 0
fi

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

# Fail-open: harness.sh may be missing (broken install, stripped plugin dir).
# The routes below call fi_emit_post_context unconditionally, so without this
# fallback a missing harness.sh would exit 127 with stderr noise — violating
# this hook's own "Exit code: 0 always" contract. Plain-text output matches
# legacy (pre-harness) Claude-only behavior.
if ! declare -F fi_emit_post_context >/dev/null 2>&1; then
  fi_emit_post_context() { printf '%s\n' "${1:-}"; }
fi

# ============ legacy fallback prompts (FOUND_ISSUES_AUTO_ANNOTATE=off) =====
# Moved verbatim from the retired post-pr-create.sh / post-git-commit.sh
# matching-scan + prompt bodies (same silent-exit guards, same
# lib/parse-entries.sh sourcing). Only the variable plumbing changed
# (pr_num arrives as $1 / commit defaults to HEAD, since the shared block
# above already resolved FI_BIN/lib_dir and the caller already extracted
# pr_num). Guard clauses `return` (not `exit`) and the prompt body is
# printed on stdout rather than emitted directly: callers capture it via
# command substitution and append it to the shared accumulator, which goes
# through fi_emit_post_context (Codex-safe JSON) exactly once at the very
# end of the script. Bash requires function definitions before use, so
# these sit above the routing blocks that call them.

legacy_pr_prompt() {
  local pr_num="$1"

  if [[ -f "$lib_dir/parse-entries.sh" ]]; then
    # shellcheck source=../lib/parse-entries.sh
    source "$lib_dir/parse-entries.sh"
  else
    return 0
  fi

  local issues_file
  issues_file="$(fi_find_issues_file 2>/dev/null || true)"
  [[ -z "$issues_file" || ! -f "$issues_file" ]] && return 0

  if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
    return 0
  fi

  local touched_files
  touched_files="$(gh pr view "$pr_num" --json files --jq '.files[].path' 2>/dev/null || true)"
  [[ -z "$touched_files" ]] && return 0

  local repo_id
  repo_id="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)"
  local already_annotated_pattern="\\(PR: $repo_id#$pr_num\\)"

  local matching="" entry e_path tf
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    if [[ "$entry" =~ $already_annotated_pattern ]]; then
      continue
    fi

    fi_parse_entry_vars "$entry" || continue
    e_path="$FE_path"
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
    return 0
  fi

  printf '%s' "## found-issues — PR #$pr_num touches files referenced by [open] entries

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
    return 0
  fi

  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    return 0
  fi

  local issues_file
  issues_file="$(fi_find_issues_file 2>/dev/null || true)"
  [[ -z "$issues_file" || ! -f "$issues_file" ]] && return 0

  local short_sha
  short_sha="$(git rev-parse --short=7 HEAD 2>/dev/null || true)"
  [[ -z "$short_sha" ]] && return 0

  local touched_files
  touched_files="$(git show --name-only --format= HEAD 2>/dev/null | grep -v '^$' || true)"
  [[ -z "$touched_files" ]] && return 0

  local already_annotated_pattern="\\(commit: $short_sha\\)"

  local matching="" entry e_path tf
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    if [[ "$entry" =~ $already_annotated_pattern ]]; then
      continue
    fi

    fi_parse_entry_vars "$entry" || continue
    e_path="$FE_path"
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
    return 0
  fi

  printf '%s' "## found-issues — commit $short_sha touches files referenced by [open] entries

$matching
If your commit fixes any of these, run
\`/found-issues:annotate-commit $short_sha --pick <path:line>\` now for exactly
those entries (without --pick it only writes a non-closing suggestion).

When the commit lands on the default branch (or already has, for direct
pushes), \`/found-issues:sync\` will auto-flip these to [fixed]."
}

# Accumulator for pr-create / git-commit route output. Both routes below
# are evaluated independently (non-exclusive) and append here instead of
# emitting immediately; a single fi_emit_post_context call at the bottom of
# the script flushes it exactly once. See header comment for why. (The
# merge/close/reopen route, last below, never appends to this — it produces
# no ctx text of its own.)
ctx=""

# ============ route: gh pr create → annotate ============
# Anchored the same way as the merge/close/reopen matcher below (rather than
# a bare substring match) so a commit message that merely mentions the words
# "gh pr create" doesn't behave differently here than it does anywhere else
# — the /pull/N stdout guard below is still the main false-positive gate.
if [[ "$cmd" =~ (^|[[:space:];|&])gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$) ]]; then
  stdout="$(get_field '.tool_response.stdout')"
  pr_num=""
  if [[ "$stdout" =~ /pull/([0-9]+) ]]; then
    pr_num="${BASH_REMATCH[1]}"
  fi

  if [[ -n "$pr_num" ]]; then
    if [[ "${FOUND_ISSUES_AUTO_ANNOTATE:-on}" == "off" ]]; then
      legacy_out="$(legacy_pr_prompt "$pr_num")"
      [[ -n "$legacy_out" ]] && ctx+="$legacy_out"$'\n\n'
    else
      out="$("$FI_BIN" annotate-pr "$pr_num" --hook-auto 2>/dev/null)" && rc=0 || rc=$?
      if [[ "$rc" -eq 0 && "$out" == *"Suggested"* ]]; then
        ctx+="## found-issues — PR #$pr_num produced annotation SUGGESTIONS

$out

These are (PR-auto: ...) tokens: recorded but NOT closing. A line-match means
the PR touched the defect's location, not that it fixed the defect. Confirm the
ones it genuinely fixes with the --pick command above; leave the rest alone."$'\n\n'
      elif [[ "$rc" -eq 3 ]]; then
        ctx+="## found-issues — PR #$pr_num needs annotation judgment

$out

Compare each candidate's symptom against what the PR actually changes, then run:
  found-issues annotate-pr $pr_num --pick <path:line>[,...]
(or --all only if the PR genuinely addresses every candidate). Entries the PR does not fix must NOT be annotated — they would false-flip to [fixed] on merge."
        ctx+=$'\n\n'
      fi
    fi
  fi
fi

# ============ route: git commit → annotate ============
# Evaluated independently of the pr-create route above (not `elif`/exit) so
# a chained `git commit -m x && gh pr create` runs both, and so a plain
# commit whose message happens to mention "gh pr create" still gets its
# own commit-annotation pass.
if [[ "$cmd" =~ (^|[^A-Za-z_])git[[:space:]]+commit($|[^-A-Za-z_]) ]]; then
  exit_code="$(get_field '.tool_response.exit_code')"
  if [[ ( -z "$exit_code" || "$exit_code" == "0" ) ]] && git rev-parse --git-dir >/dev/null 2>&1; then
    if [[ "${FOUND_ISSUES_AUTO_ANNOTATE:-on}" == "off" ]]; then
      legacy_out="$(legacy_commit_prompt)"
      [[ -n "$legacy_out" ]] && ctx+="$legacy_out"$'\n\n'
    else
      out="$("$FI_BIN" annotate-commit HEAD --hook-auto 2>/dev/null)" && rc=0 || rc=$?
      if [[ "$rc" -eq 0 && "$out" == *"Suggested"* ]]; then
        ctx+="## found-issues — this commit produced annotation SUGGESTIONS

$out

These are (commit-auto: ...) tokens: recorded but NOT closing. A line-match means
the commit touched the defect's location, not that it fixed the defect. Confirm
the ones it genuinely fixes with the --pick command above; leave the rest alone."$'\n\n'
      elif [[ "$rc" -eq 3 ]]; then
        ctx+="## found-issues — commit needs annotation judgment

$out

If this commit addresses any candidate, run the printed --pick command; otherwise ignore."
        ctx+=$'\n\n'
      fi
    fi
  fi
fi

# ============ route: AUTOFIX-QUEUED → launcher A or B (v3 spec §4.2) ============
# The marker comes from `found-issues log` OUTPUT. Only ids whose item is
# still in queue/ count, so re-printed old markers (a cat of a log) do
# nothing. A gets one detached `autofix run` (it drains the queue); B gets
# one nudge per id. Inside a subagent (agent_id) or a fixer child nothing
# launches; the main session's Stop fallback picks those up.
if [[ "$input" == *AUTOFIX-QUEUED* && -f "$lib_dir/autofix-queue.sh" && -f "$lib_dir/autofix-hook.sh" ]]; then
  # shellcheck source=../lib/autofix-queue.sh
  source "$lib_dir/autofix-queue.sh"
  # shellcheck source=../lib/autofix-hook.sh
  source "$lib_dir/autofix-hook.sh"
  fi_afh_ids "$(printf '%s' "$input" | jq -r '.tool_response | if type == "string" then . else tostring end' 2>/dev/null || true)"
  if (( ${#FI_AFH_IDS[@]} > 0 )); then
    __fi_harness="$(fi_detect_harness 2>/dev/null || printf claude)"
    fi_afh_launcher "$__fi_harness" "$(get_field '.permission_mode')" "$(get_field '.agent_id')"
    if [[ "$FI_AFH_LAUNCHER" != none ]]; then
      fi_afh_now
      __fi_first=""
      for __fi_id in "${FI_AFH_IDS[@]}"; do
        fi_afh_item "$__fi_id" || continue
        fi_afh_mark "$FI_AFH_ITEM" "$FI_AFH_LAUNCHER" "$FI_AFH_NOW" || continue
        if [[ "$FI_AFH_LAUNCHER" == B ]]; then
          ctx+="$(fi_afh_context_b "$__fi_id")"$'\n\n'
        elif [[ -z "$__fi_first" ]]; then
          __fi_first="$FI_AFH_ITEM"
        fi
      done
      if [[ -n "$__fi_first" ]]; then fi_afh_launch_a "$__fi_first" "$__fi_harness" "$FI_BIN" || true; fi
    fi
  fi
fi

# ============ route: gh pr merge/close/reopen → background sync ============
# Evaluated LAST and non-exclusively (no early exit): this route produces no
# ctx text of its own, so ordering it after the pr-create/git-commit routes
# above doesn't change what gets emitted — it only changes WHEN the
# background sync spawn happens relative to those two synchronous routes.
# That ordering matters: `found-issues annotate-pr`/`annotate-commit` above
# run to completion (writing docs/found-issues.md) before this script
# continues, so by the time this route spawns the detached background
# `found-issues sync`, sync sees the freshly written annotations instead of
# racing them — both sides do an atomic tmp-file-then-mv rewrite of the
# same ledger file, so a concurrent sync could otherwise read a stale copy
# or clobber the annotation update. Previously this route exited early
# (its own `exit 0`) on the theory that it never produces annotation
# output so it "can't shadow" the routes below it — true for output, but
# it also meant a chained `git commit -m fix && gh pr merge 7` or
# `gh pr create ... && gh pr merge N --auto` never reached the annotation
# routes at all, since they sat below this one's exit. Moving this route
# last and dropping its exit fixes that.
if [[ "$cmd" =~ (^|[[:space:];|&])gh[[:space:]]+pr[[:space:]]+(merge|close|reopen)([[:space:]]|$) ]]; then
  if [[ "${FOUND_ISSUES_POST_PR_STATE:-on}" != "off" ]]; then
    if [[ -n "${FOUND_ISSUES_AUTOSYNC_CMD:-}" ]]; then
      ( bash -c "$FOUND_ISSUES_AUTOSYNC_CMD" >/dev/null 2>&1 & ) >/dev/null 2>&1
    else
      # No auto-archive in an unattended sync — see hooks/session-start.sh.
      ( FOUND_ISSUES_AUTO_ARCHIVE=off "$FI_BIN" sync >/dev/null 2>&1 & ) >/dev/null 2>&1
    fi
  fi
fi

[[ -n "$ctx" ]] && fi_emit_post_context "$ctx"
exit 0
