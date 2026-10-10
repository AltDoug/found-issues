#!/usr/bin/env bash
# unannotate.sh — strip one annotation marker from one [open] entry
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   cmd_unannotate <match> <ref>
#   fi_unannotate_line <line> <ref>      result in FI_UNANN_LINE / FI_UNANN_MARKER

# === Subcommand: unannotate ===
#
# Usage: found-issues unannotate <match> <ref>
#
# The one supported way to undo a mis-annotation: a (PR: ...) or (commit: ...)
# that arms sync's closer on the wrong entry, or a hook suggestion
# ((PR-auto: ...) / (commit-auto: ...)) the operator rejects. Before this verb
# the only remedy was editing the ledger by hand, which loses writes under
# concurrent sessions.
#
# <match>  selects ONE [open] entry (case-insensitive substring of the whole
#          line, like resolve/defer): a path:line or a symptom fragment.
# <ref>    a PR (`#N`, `N` or `org/repo#N`) or a commit sha (any prefix of 4+
#          hex characters, in either direction).
#
# Strips exactly one marker from the entry's annotation tail, together with
# the one space that separated it; everything else stays byte-identical.
#
# Exits:
#   0 success
#   1 no matching [open] entry, or the entry carries no such marker
#   2 usage error, or an ambiguous <match> / <ref>
#   3 the match is a [fixed] entry (closures are not reversible)

fi_unannotate_usage() {
  printf 'Usage: found-issues unannotate <match> <ref>\n'
  printf '       <match>  selects one [open] entry (path:line or a symptom fragment)\n'
  printf '       <ref>    a PR (#N, N or org/repo#N) or a commit sha (prefix ok)\n'
  printf 'Strips one (PR:), (PR-auto:), (commit:) or (commit-auto:) marker.\n'
}

# fi_unannotate_ref_matches <kind> <value> <ref-kind> <ref> — 0 when the marker
# (kind PR|commit, value as written in the ledger) is the one <ref> names.
# <ref-kind> is pr (#N / N / org/repo#N), commit (hex) or num (digits, which
# could be either).
_fi_unann_matches() {
  local kind="$1" value="$2" rkind="$3" ref="$4"
  if [[ "$kind" == "PR" ]]; then
    [[ "$rkind" == "commit" ]] && return 1
    if [[ "$ref" == */* ]]; then
      [[ "$value" == "$ref" ]]
      return $?
    fi
    local n="${ref#\#}"
    [[ "${value##*#}" == "$n" ]]
    return $?
  fi
  # commit marker
  [[ "$rkind" == "pr" ]] && return 1
  local lv lr
  lv="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  lr="$(printf '%s' "$ref" | tr '[:upper:]' '[:lower:]')"
  (( ${#lr} >= 4 )) || return 1
  [[ "$lv" == "$lr"* || "$lr" == "$lv"* ]]
}

# fi_unannotate_line <line> <ref> — remove the one marker <ref> names from the
# entry's annotation tail. Returns 0 and sets FI_UNANN_LINE / FI_UNANN_MARKER;
# 1 when no marker matches; 2 when several different markers match.
fi_unannotate_line() {
  local line="$1" ref="$2"
  FI_UNANN_LINE="" FI_UNANN_MARKER=""

  local rkind
  if [[ "$ref" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+$ || "$ref" =~ ^#[0-9]+$ ]]; then
    rkind="pr"
  elif [[ "$ref" =~ ^[0-9]+$ ]]; then
    rkind="num"
  else
    rkind="commit"
  fi

  fi_annotation_tail_v "$line"
  local tail="$FI_ANN_TAIL"
  [[ -n "$tail" ]] || return 1
  local head="${line%"$tail"}"

  # Walk the tail group by group, collecting the markers that match.
  local re_marker='\((PR|PR-auto|commit|commit-auto): ([^)]*)\)'
  local rest="$tail" kind value marker pre
  local -a found=()
  while [[ "$rest" =~ $re_marker ]]; do
    marker="${BASH_REMATCH[0]}"
    kind="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    pre="${rest%%"$marker"*}"
    rest="${rest#"$pre$marker"}"
    if _fi_unann_matches "${kind%%-*}" "$value" "$rkind" "$ref"; then
      found+=("$marker")
    fi
  done
  (( ${#found[@]} > 0 )) || return 1

  # Several markers are fine only when they are the same text (a duplicate);
  # different ones need a more specific ref.
  local m
  for m in "${found[@]}"; do
    if [[ "$m" != "${found[0]}" ]]; then
      FI_UNANN_MARKER="${found[*]}"
      return 2
    fi
  done
  marker="${found[0]}"

  # Cut the first occurrence inside the tail, plus the one space before it.
  local before="${tail%%"$marker"*}"
  local after="${tail#"$before$marker"}"
  local combined="$head$before"
  if [[ "$combined" == *" " ]]; then
    combined="${combined% }"
  fi
  FI_UNANN_LINE="$combined$after"
  FI_UNANN_MARKER="$marker"
  return 0
}

cmd_unannotate() {
  local match="" ref="" npos=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) fi_unannotate_usage; return 0 ;;
      -*) fi_unknown_arg unannotate "$1"; fi_unannotate_usage >&2; return 2 ;;
      *)
        if (( npos == 0 )); then match="$1"
        elif (( npos == 1 )); then ref="$1"
        else fi_unknown_arg unannotate "$1"; return 2
        fi
        npos=$((npos + 1))
        shift
        ;;
    esac
  done

  if [[ -z "$match" || -z "$ref" ]]; then
    fi_err "unannotate: needs <match> and <ref>"
    fi_unannotate_usage >&2
    return 2
  fi
  if ! [[ "$ref" =~ ^([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)?#[0-9]+$ \
       || "$ref" =~ ^[0-9]+$ || "$ref" =~ ^[0-9a-fA-F]{4,40}$ ]]; then
    fi_err "unannotate: <ref> must be a PR (#N, N, org/repo#N) or a commit sha (4+ hex), got: $ref"
    return 2
  fi

  local file
  file="$(fi_resolve_issues_file)"

  local matches=() entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    fi_icontains "$entry" "$match" && matches+=("$entry")
  done < <(fi_entries "$file" open 2>/dev/null || true)

  if (( ${#matches[@]} == 0 )); then
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      if fi_icontains "$entry" "$match"; then
        fi_err "unannotate: that entry is already [fixed]; closures are not reversible."
        return 3
      fi
    done < <(fi_entries "$file" fixed 2>/dev/null || true)
    fi_err "unannotate: no [open] entries match \"$match\""
    return 1
  fi

  if (( ${#matches[@]} > 1 )); then
    fi_err "unannotate: ambiguous match — ${#matches[@]} [open] entries match \"$match\":"
    local m
    for m in "${matches[@]}"; do fi_err "  $m"; done
    fi_err "Use a more specific match."
    return 2
  fi

  local target="${matches[0]}" rc=0
  fi_unannotate_line "$target" "$ref" || rc=$?
  if (( rc == 1 )); then
    fi_err "unannotate: the entry has no (PR:), (PR-auto:), (commit:) or (commit-auto:) marker matching \"$ref\""
    return 1
  elif (( rc == 2 )); then
    fi_err "unannotate: \"$ref\" matches several markers: $FI_UNANN_MARKER"
    fi_err "Give the full org/repo#N or a longer sha."
    return 2
  fi
  local new_line="$FI_UNANN_LINE" marker="$FI_UNANN_MARKER"

  local tmp replaced=0 line
  tmp="$(fi_ledger_tmp "$file")"
  # Final-partial-line guard — see the READ-LOOP GUARD block in bin/found-issues.
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$target" ]] && (( replaced == 0 )); then
      replaced=1
      printf '%s\n' "$new_line" >>"$tmp"
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$file"
  fi_ledger_replace "$file" "$tmp"

  printf 'Unannotated 1 entry. Removed %s\n' "$marker"
  cmd_status plain
}
