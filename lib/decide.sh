#!/usr/bin/env bash
# decide.sh — decide — the v3 decision queue (spec 2026-10-03 §3.4)
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   cmd_decide [...]

# shellcheck disable=SC2154  # cross-file globals: FE_* are set by fi_parse_entry_vars (parse-entries.sh)

# Lists [open] entries tagged (decide: <question>), critical first, or
# records an answer as (decided: <answer>) — which turns the entry fixable.
# Exits: 0 ok, 1 no match, 2 usage/ambiguous, 3 entry has no open question.
cmd_decide() {
  local match="" answer="" count_only=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --answer) fi_need_value decide --answer $# "${2:-}" || return 2
                answer="$2"; shift 2 ;;
      --answer=*) answer="${1#--answer=}"; shift ;;
      --count) count_only=1; shift ;;
      -h|--help)
        printf 'Usage: found-issues decide                            List open questions (critical first)\n'
        printf '       found-issues decide --count                    Print how many are waiting\n'
        printf '       found-issues decide <match> --answer "<text>"  Record the answer\n'
        return 0 ;;
      -*) fi_unknown_arg decide "$1"; return 2 ;;
      *) [[ -z "$match" ]] || { fi_unknown_arg decide "$1"; return 2; }
         match="$1"; shift ;;
    esac
  done

  local file entry
  file="$(fi_resolve_issues_file)"

  if [[ -z "$match" ]]; then
    [[ -z "$answer" ]] || { fi_err "decide: --answer needs a <match>"; return 2; }
    local crit="" rest="" n=0 loc
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      fi_parse_entry_vars "$entry" || continue
      [[ -n "$FE_decide" ]] || continue
      n=$((n + 1))
      loc="$(fi_entry_loc "$entry" 2>/dev/null || printf '%s' "$FE_path")"
      if [[ "$FE_critical" == "yes" ]]; then
        crit+="[!] $loc — $FE_decide"$'\n'
      else
        rest+="$loc — $FE_decide"$'\n'
      fi
    done < <(fi_entries "$file" open 2>/dev/null || true)
    if (( count_only )); then printf '%s\n' "$n"; return 0; fi
    if (( n == 0 )); then printf 'No decisions waiting.\n'; return 0; fi
    local i=0 l
    while IFS= read -r l; do
      [[ -z "$l" ]] && continue
      i=$((i + 1)); printf '%d. %s\n' "$i" "$l"
    done <<< "${crit}${rest}"
    return 0
  fi

  [[ -n "$answer" ]] || { fi_err "decide: missing --answer \"<text>\""; return 2; }
  local -a matches=()
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    fi_icontains "$entry" "$match" && matches+=("$entry")
  done < <(fi_entries "$file" open 2>/dev/null || true)
  (( ${#matches[@]} > 0 )) || { fi_err "decide: no [open] entry matches \"$match\""; return 1; }
  if (( ${#matches[@]} > 1 )); then
    fi_err "decide: ambiguous — ${#matches[@]} entries match \"$match\":"
    local m
    for m in "${matches[@]}"; do fi_err "  $m"; done
    return 2
  fi
  fi_parse_entry_vars "${matches[0]}"
  [[ -n "$FE_decide" ]] || { fi_err "decide: that entry has no open question"; return 3; }
  fi_tag_resolve decided "$answer" "" "" || return 2
  local rc=0
  fi_tag_apply "$file" "${matches[0]}" decided "$FI_TAG_VALUE" || rc=$?
  (( rc == 0 )) || { fi_err "decide: the ledger changed while writing — re-run"; return 1; }
  fi_af_sweep_check || true
}
