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

IFS= read -r -d '' input || true

# Zero-fork relevance gate (lib/hook-gate.sh): a command that cannot be a
# branch delete exits here, before any jq/sed/$(...). A missing lib or an
# untrustworthy gate falls through to the full path below.
__fi_hook_dir="${BASH_SOURCE[0]%/*}"
[[ "$__fi_hook_dir" == "${BASH_SOURCE[0]}" ]] && __fi_hook_dir=.
# shellcheck source=../lib/hook-gate.sh
if [[ -f "$__fi_hook_dir/../lib/hook-gate.sh" ]] \
    && source "$__fi_hook_dir/../lib/hook-gate.sh" && fi_gate_text "$input"; then
  # The full path below splits the command into shell words, which drops
  # quote characters but keeps what they quote (`bra''nch`, `-'d'` and
  # `"--delete"` are branch / -d / --delete). So between letters the gate
  # allows any run of quote characters (', escaped \") and escaped newlines.
  # Regexes, not ${var//'/} stripping: pattern substitution is quadratic in
  # bash and took ~4 s on a 70 KB heredoc. Necessary conditions:
  #   branch: "branch" + a dash run containing d/D (-d, -D, -df, --delete)
  #   push:   "push" + (a dash run containing d, or ":")
  #   gh api: "heads" (refs/heads) + "DELETE"
  _fi_g="('|\\\\\"|\\\\n)*"
  _fi_re_branch="b${_fi_g}r${_fi_g}a${_fi_g}n${_fi_g}c${_fi_g}h"
  _fi_re_push="p${_fi_g}u${_fi_g}s${_fi_g}h"
  _fi_re_heads="h${_fi_g}e${_fi_g}a${_fi_g}d${_fi_g}s"
  _fi_re_del="D${_fi_g}E${_fi_g}L${_fi_g}E${_fi_g}T${_fi_g}E"
  _fi_re_bdel="-(${_fi_g}[A-Za-z])*${_fi_g}[dD]"
  _fi_re_pdel="-(${_fi_g}[A-Za-z0-9])*${_fi_g}d"
  { [[ "$FI_GATE" =~ $_fi_re_branch && "$FI_GATE" =~ $_fi_re_bdel ]]; } \
    || { [[ "$FI_GATE" =~ $_fi_re_push ]] && { [[ "$FI_GATE" =~ $_fi_re_pdel ]] || [[ "$FI_GATE" == *:* ]]; }; } \
    || { [[ "$FI_GATE" =~ $_fi_re_heads && "$FI_GATE" =~ $_fi_re_del ]]; } \
    || exit 0
fi

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
#
# The command is split into shell WORDS the way bash would, before any
# matching (2026-10-03 audit, hook-2/3/4 and the pre-branch-delete.sh:92
# ledger entry). The previous approach deleted every quoted span and then
# regex-matched the remainder, which had three classes of bypass:
#   - a quoted operand or flag vanished with its quotes: `git branch -D "$b"`
#     and `git push origin "--delete" x` read as non-deletes;
#   - git global options between `git` and the verb (`git -C dir branch -D x`,
#     `git -c k=v ...`) defeated the `git branch` regexes;
#   - bundled short flags (`-df`, `-fd`) were not delete flags.
# Words keep quoted CONTENT and drop the quote characters, so a deletion
# command that only appears inside a string (`printf 'git branch -D x'`) is a
# single argument word and never reads as a command.

# fi_shell_words <command> — fills _fi_words with the command's words; a
# segment boundary (unquoted ; & | ( ) or newline) is the word $'\x1f'.
# Approximates bash: no expansion, $var/$(...) stay literal, a backslash
# outside single quotes escapes the next character.
_fi_sep=$'\x1f'
fi_shell_words() {
  # Walk one LINE at a time (quote state carries across lines): ${s:i:1}
  # copies the whole string it slices, so a character loop over the full
  # command was quadratic — a 70 KB heredoc took ~19 s. Byte mode keeps the
  # per-line slicing simple; multi-byte characters pass through unchanged.
  local LC_ALL=C
  local s n i c w="" have=0 q=""
  _fi_words=()
  while IFS= read -r s || [[ -n "$s" ]]; do
    s+=$'\n'
    n=${#s}
    i=0
    while (( i < n )); do
      c="${s:i:1}"
      if [[ "$q" == "'" ]]; then
        if [[ "$c" == "'" ]]; then q=""; else w+="$c"; fi
      elif [[ "$q" == '"' ]]; then
        if [[ "$c" == '"' ]]; then q=""
        elif [[ "$c" == '\' && $((i + 1)) -lt $n ]]; then
          i=$((i + 1)); [[ "${s:i:1}" != $'\n' ]] && w+="${s:i:1}"
        else w+="$c"; fi
      else
        case "$c" in
          "'"|'"') q="$c"; have=1 ;;
          '\') i=$((i + 1)); (( i < n )) && [[ "${s:i:1}" != $'\n' ]] && { w+="${s:i:1}"; have=1; } ;;
          ' '|$'\t')
            (( have )) && _fi_words+=("$w"); w=""; have=0 ;;
          ';'|'&'|'|'|'('|')'|$'\n')
            (( have )) && _fi_words+=("$w"); w=""; have=0
            _fi_words+=("$_fi_sep") ;;
          *) w+="$c"; have=1 ;;
        esac
      fi
      i=$((i + 1))
    done
  done <<<"$1"
  (( have )) && _fi_words+=("$w")
  _fi_words+=("$_fi_sep")
}

# Records found: "<git -C dir or .>\t<branch>". A branch of `$...` / `` `...` ``
# could not be resolved statically and is reported as such.
branches=()

fi_record_target() {
  local dir="$1" tok="$2"
  if [[ "$tok" == *'$'* || "$tok" == *'`'* ]]; then
    branches+=("$dir"$'\t'"$tok")
    return
  fi
  tok="${tok#refs/heads/}"
  tok="${tok%%[^A-Za-z0-9._/-]*}"
  [[ -n "$tok" ]] && branches+=("$dir"$'\t'"$tok")
}

# fi_scan_segment <words...> — one simple command.
fi_scan_segment() {
  local -a w=("$@")
  local n=${#w[@]} i=0 dir="." verb=""
  # gh api ... DELETE ... refs/heads/<name>
  if (( n >= 2 )) && [[ "${w[0]}" == "gh" && "${w[1]}" == "api" ]]; then
    local has_del=0 ref=""
    for (( i = 2; i < n; i++ )); do
      [[ "${w[$i]}" == "DELETE" || "${w[$i]}" == "--method=DELETE" || "${w[$i]}" == "-XDELETE" ]] && has_del=1
      [[ "${w[$i]}" == *refs/heads/* ]] && ref="${w[$i]##*refs/heads/}"
    done
    (( has_del )) && [[ -n "$ref" ]] && fi_record_target "." "$ref"
    return 0
  fi
  # Skip env assignments and wrappers to the git word.
  while (( i < n )); do
    case "${w[$i]}" in
      git|*/git) break ;;
      *=*|command|exec|sudo|env|nice|time|nohup) i=$((i + 1)) ;;
      do|then|else|elif|if|while|until|'!'|'{') i=$((i + 1)) ;;
      *) return 0 ;;
    esac
  done
  (( i < n )) || return 0
  i=$((i + 1))
  # git global options before the verb.
  while (( i < n )); do
    case "${w[$i]}" in
      -C) dir="${w[$((i + 1))]:-.}"; i=$((i + 2)) ;;
      -c|--git-dir|--work-tree|--namespace|--config-env|--exec-path|--super-prefix) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *) verb="${w[$i]}"; i=$((i + 1)); break ;;
    esac
  done
  local has_delete=0 opts_done=0 tok
  local -a operands=()
  case "$verb" in
    branch)
      for (( ; i < n; i++ )); do
        tok="${w[$i]}"
        if (( ! opts_done )); then
          case "$tok" in
            --) opts_done=1; continue ;;
            --delete) has_delete=1; continue ;;
            --*) continue ;;
            -*[dD]*) [[ "$tok" =~ ^-[A-Za-z]+$ ]] && has_delete=1; continue ;;
            -*) continue ;;
          esac
        fi
        operands+=("$tok")
      done
      if (( has_delete )); then
        for tok in ${operands[@]+"${operands[@]}"}; do fi_record_target "$dir" "$tok"; done
      fi
      ;;
    push)
      for (( ; i < n; i++ )); do
        tok="${w[$i]}"
        if (( ! opts_done )); then
          case "$tok" in
            --) opts_done=1; continue ;;
            --delete) has_delete=1; continue ;;
            --*) continue ;;
            -*d*) [[ "$tok" =~ ^-[A-Za-z0-9]+$ ]] && has_delete=1; continue ;;
            -*) continue ;;
          esac
        fi
        operands+=("$tok")
      done
      # operands[0] is the remote; the rest are refs. An old-style `:name`
      # refspec deletes even without --delete.
      local k
      for (( k = 1; k < ${#operands[@]}; k++ )); do
        tok="${operands[$k]}"
        tok="${tok#+}"
        if [[ "$tok" == :* ]]; then
          fi_record_target "$dir" "${tok#:}"
        elif (( has_delete )); then
          fi_record_target "$dir" "$tok"
        fi
      done
      ;;
  esac
  return 0
}

fi_shell_words "$command"
_fi_seg=()
for _fi_w in "${_fi_words[@]}"; do
  if [[ "$_fi_w" == "$_fi_sep" ]]; then
    (( ${#_fi_seg[@]} > 0 )) && fi_scan_segment "${_fi_seg[@]}"
    _fi_seg=()
  else
    _fi_seg+=("$_fi_w")
  fi
done

if [[ ${#branches[@]} -eq 0 ]]; then
  exit 0
fi

# Source dedup-key helpers. Both libs are needed: parse-entries.sh for
# fi_parse_entry, canonicalize.sh for fi_dedup_key{,_abstract}.
# The script-relative lib comes first after the explicit override: the
# PATH/readlink fallback resolved `found-issues` against the CWD under GNU
# readlink, and Codex hooks get no CLAUDE_PLUGIN_ROOT, so the guard silently
# allowed every delete there (2026-10-03 audit, hook-14).
lib_dir=""
for _fi_cand in "${FOUND_ISSUES_LIB_DIR:-}" "$__fi_hook_dir/../lib" \
    "${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/lib}"; do
  if [[ -n "$_fi_cand" && -f "$_fi_cand/parse-entries.sh" && -f "$_fi_cand/canonicalize.sh" ]]; then
    lib_dir="$_fi_cand"
    break
  fi
done
if [[ -z "$lib_dir" ]]; then
  # Lib missing — can't compute dedup keys safely. Fail open (allow delete)
  # rather than fall back to line-equality, but say so.
  echo "found-issues: promote-guard could not find its lib; branch delete NOT checked." >&2
  exit 0
fi
# shellcheck source=../lib/parse-entries.sh
source "$lib_dir/parse-entries.sh"
# shellcheck source=../lib/canonicalize.sh
source "$lib_dir/canonicalize.sh"

# Check each target, grouped by the directory git runs in (`git -C dir`).
problems=()
_fi_notes=""
_fi_orig_dir="$PWD"
_fi_dirs="$(for rec in "${branches[@]}"; do printf '%s\n' "${rec%%$'\t'*}"; done | awk '!seen[$0]++')"
while IFS= read -r _fi_dir; do
  [[ -z "$_fi_dir" ]] && continue
  cd "$_fi_orig_dir" && cd "$_fi_dir" 2>/dev/null || continue

  # Must be in a git repo
  git rev-parse --git-dir >/dev/null 2>&1 || continue

  # Determine default branch
  default_branch="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's|^refs/remotes/origin/||' || true)"
  if [[ -z "$default_branch" ]]; then
    # Same fallback order as fi_resolve_default_branch (audit cli-13).
    for _fi_b in main master trunk; do
      if git rev-parse --verify --quiet "refs/remotes/origin/$_fi_b" >/dev/null 2>&1 \
         || git rev-parse --verify --quiet "refs/heads/$_fi_b" >/dev/null 2>&1; then
        default_branch="$_fi_b"; break
      fi
    done
    [[ -z "$default_branch" ]] && default_branch="main"
  fi

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
    # Buffered, emitted once at the end: an advisory on stderr with exit 0
    # reaches nobody (see fi_emit_pre_context), and a mid-loop JSON write
    # could produce several objects.
    _fi_notes+="found-issues: $default_branch does not track $rel_path; promote-guard skipped."$'\n'
    _fi_notes+="Entries are local-only in this repo and are not lost by branch deletion."$'\n'
    continue
  fi

  # Main's dedup keys (ledger + archive) are the same for every branch in
  # this repo: built lazily, once, the first time a branch needs them. The
  # per-branch rebuild cost ~25 processes per main ledger line per branch
  # (audit hook-12); keys are now builtin (fi_entry_dedup_key_v).
  main_keyset="" _fi_keyset_built=0
  for rec in "${branches[@]}"; do
    [[ "${rec%%$'\t'*}" == "$_fi_dir" ]] || continue
    branch="${rec#*$'\t'}"
    # Skip if branch == default branch (deleting main is its own bad idea, not ours to enforce here)
    [[ "$branch" == "$default_branch" ]] && continue

    if [[ "$branch" == *'$'* || "$branch" == *'`'* ]]; then
      # A `for b in ...; git branch -D "$b"` loop: the name only exists once
      # bash runs the command, so nothing here can check it. Block; the
      # literal-name retry is cheap and checks every branch.
      problems+=("$branch"$'\t'"(branch name '$branch' is only known when the command runs — the guard cannot check it)"$'\n')
      continue
    fi

    # Get branch's version of the issues file
    branch_content="$(git show "$branch:$rel_path" 2>/dev/null \
      || git show "origin/$branch:$rel_path" 2>/dev/null \
      || true)"
    [[ -z "$branch_content" ]] && continue
    # Nothing [open] on the branch = nothing to lose.
    _fi_re_open=$'(^|\n)-[[:space:]]+\\[open\\]'
    [[ "$branch_content" =~ $_fi_re_open ]] || continue

    if (( ! _fi_keyset_built )); then
    _fi_keyset_built=1
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
    _fi_main_and_archive="$main_content"$'\n'"$archive_content"
    if [[ -n "$_fi_main_and_archive" ]]; then
      while IFS= read -r m_line; do
        if [[ "$m_line" =~ ^-[[:space:]]+\[(open|deferred|fixed)\] ]]; then
          fi_entry_dedup_key_v "$m_line" "$repo_root" && main_keyset+="$FI_KEY"$'\n'
        fi
      done <<< "$_fi_main_and_archive"
    fi
    fi

    # Find branch [open] entries whose dedup key is not in main's keyset.
    branch_unpromoted=""
    while IFS= read -r line; do
      if [[ "$line" =~ ^-[[:space:]]+\[open\] ]]; then
        if ! fi_entry_dedup_key_v "$line" "$repo_root"; then
          # Parse failed — treat as unpromoted (safer than silently allowing).
          branch_unpromoted+="$line"$'\n'
        elif [[ $'\n'"$main_keyset" != *$'\n'"$FI_KEY"$'\n'* ]]; then
          branch_unpromoted+="$line"$'\n'
        fi
      fi
    done <<< "$branch_content"

    if [[ -n "$branch_unpromoted" ]]; then
      problems+=("$branch"$'\t'"$branch_unpromoted")
    fi
  done
done <<<"$_fi_dirs"
cd "$_fi_orig_dir"

# Advisory notes: stdout additionalContext on a clean allow, plain stderr
# ahead of the block message otherwise (stderr is delivered on exit 2).
_fi_notes="${_fi_notes%$'\n'}"
if [[ ${#problems[@]} -eq 0 ]]; then
  if [[ -n "$_fi_notes" ]]; then
    if [[ -f "$lib_dir/harness.sh" ]]; then
      # shellcheck source=../lib/harness.sh
      source "$lib_dir/harness.sh"
      fi_emit_pre_context "$_fi_notes"
    else
      printf '%s\n' "$_fi_notes" >&2
    fi
  fi
  exit 0
fi
[[ -n "$_fi_notes" ]] && printf '%s\n' "$_fi_notes" >&2

# Block with detailed message. No bypass hint here: this text is what the
# agent reads, and naming the off switch made skipping the guard the cheapest
# way past it (audit prompt-6). The switch stays documented in
# docs/configuration.md for operators.
{
  echo "found-issues: branch deletion blocked"
  echo
  for prob in "${problems[@]}"; do
    branch="${prob%%$'\t'*}"
    entries="${prob#*$'\t'}"
    if [[ "$branch" == *'$'* || "$branch" == *'`'* ]]; then
      echo "Branch '$branch' cannot be checked before the command runs:"
    else
      echo "Branch '$branch' has [open] found-issues entries not yet promoted to '$default_branch':"
    fi
    echo
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      echo "  $entry"
    done <<< "$entries"
    echo
  done
  echo "Promote them first, then delete:"
  echo "  1. git checkout <branch> && found-issues promote          (review what would move)"
  echo "  2. git checkout -b promote/<branch> $default_branch && found-issues promote --apply --from <branch>"
  echo "  3. open a PR to '$default_branch', merge it, then re-run the delete"
  echo "Delete branches by literal name (not \$variables) so each one can be checked."
} >&2

exit 2
