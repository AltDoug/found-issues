#!/usr/bin/env bash
# tag.sh — tag — set an entry's v3 fix tag (spec 2026-10-03 §3.5)
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   fi_tag_apply <file> <target-line> <kind> <value>
#   cmd_tag [...]

# The single file writer of tags (log and decide call it too). Exact-line
# match on the first occurrence, serialized like every other ledger write.
# Returns 0 written, 1 target line no longer present, 3 ledger changed.
fi_tag_apply() {
  local file="$1" target="$2" kind="$3" value="$4"
  fi_entry_retag "$target" "$kind" "$value" || return 2
  local new_line="$FI_RETAGGED" snapshot tmp line done_one=0
  snapshot="$(fi_ledger_snapshot "$file")"
  tmp="$(fi_ledger_tmp "$file")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( ! done_one )) && [[ "$line" == "$target" ]]; then
      printf '%s\n' "$new_line" >>"$tmp"; done_one=1
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$file"
  if (( ! done_one )); then rm -f "$tmp"; return 1; fi
  fi_ledger_replace "$file" "$tmp" "$snapshot" || return 3
  printf 'Tagged: %s\n' "$new_line"
}

cmd_tag() {
  local match="" kind="" value=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fix|--decide|--manual)
        fi_need_value tag "$1" $# "${2:-}" || return 2
        kind="${1#--}"; value="$2"; shift 2 ;;
      --fix=*|--decide=*|--manual=*)
        kind="${1%%=*}"; kind="${kind#--}"; value="${1#*=}"; shift ;;
      -h|--help)
        printf 'Usage: found-issues tag <match> --fix small|medium|large\n'
        printf '       found-issues tag <match> --decide "<question>"\n'
        printf '       found-issues tag <match> --manual "<why>"\n'
        printf 'Sets the one fix tag of the [open]/[deferred] entry matching <match>.\n'
        return 0 ;;
      -*) fi_unknown_arg tag "$1"; return 2 ;;
      *)
        [[ -z "$match" ]] || { fi_unknown_arg tag "$1"; return 2; }
        match="$1"; shift ;;
    esac
  done
  if [[ -z "$match" || -z "$kind" ]]; then
    fi_err "tag: need <match> and one of --fix / --decide / --manual (see: found-issues tag --help)"
    return 2
  fi

  local file
  file="$(fi_resolve_issues_file)"
  local -a matches=()
  local entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    [[ "$entry" =~ ^-\ \[(open|deferred)\] ]] || continue
    fi_icontains "$entry" "$match" && matches+=("$entry")
  done < <(fi_entries "$file" all 2>/dev/null || true)

  if (( ${#matches[@]} == 0 )); then
    fi_err "tag: no [open] or [deferred] entry matches \"$match\""
    return 1
  fi
  if (( ${#matches[@]} > 1 )); then
    fi_err "tag: ambiguous — ${#matches[@]} entries match \"$match\":"
    local m
    for m in "${matches[@]}"; do fi_err "  $m"; done
    return 2
  fi

  local target="${matches[0]}"
  fi_parse_entry_vars "$target" || return 1
  fi_repo_root_cached
  # An abstract topic has no file: checked as file-less, not as untracked.
  local tag_path=""
  [[ "$FE_path" == */* || "$FE_path" == *.* ]] && tag_path="$FE_path"
  fi_tag_resolve "$kind" "$value" "$tag_path" "$FI_REPO_ROOT" || return 2
  if [[ "$kind" == "fix" && "$FI_TAG_KIND" == "manual" ]]; then
    fi_err "tag: $FE_path is off-limits for auto-fix ($FI_TAG_VALUE) — tagged manual instead"
  fi
  local rc=0
  fi_tag_apply "$file" "$target" "$FI_TAG_KIND" "$FI_TAG_VALUE" || rc=$?
  case $rc in
    0) return 0 ;;
    3) fi_err "tag: the ledger changed while writing — re-run"; return 3 ;;
    *) fi_err "tag: the entry changed before it could be tagged — re-run"; return 1 ;;
  esac
}
