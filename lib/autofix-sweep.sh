#!/usr/bin/env bash
# autofix-sweep.sh — v3 auto-sweep: which entries a sweep takes, when one is
# due, the sweep claim, per-entry progress, the launcher A loop and the one
# self-merging PR (spec 2026-10-03 §4.1, §6, §7; phase 4 plan rulings 1-7).
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# A sweep is a queue item with kind=sweep: it shares the repo lock, caps,
# reap, launcher selection and the Stop fallback with spot items.
#
# Functions:
#   fi_af_fixable_now <entry>
#   fi_af_sweep_candidates <ledger> <root> <max>
#   fi_af_sweep_pending
#   fi_af_sweep_check

# shellcheck disable=SC2154  # AFI_*/FE_* come from autofix-queue.sh / parse-entries.sh

FI_AF_SPOT_KEYS=""

# Spec §3.1/§5.1: still [open], (fix: small|medium) or answered, no fix
# reference or suggestion, never failed. Large, decide and manual wait.
fi_af_fixable_now() {
  fi_parse_entry_vars "$1" || return 1
  [[ "$FE_status" == "open" ]] || return 1
  [[ -z "$FE_prs$FE_prs_auto$FE_commits$FE_commits_auto$FE_autofix_failed" ]] || return 1
  case "$FE_fixtag" in small|medium) return 0 ;; esac
  [[ -n "$FE_decided" && -z "$FE_decide" ]]
}

# One value from an item file, builtin (fi_af_item_read would clobber AFI_*).
_fi_af_field() {
  local line
  [[ -f "$1" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "$2="* ]] && { printf '%s' "${line#*=}"; return 0; }
  done <"$1"
  return 1
}

# Dedup keys of spot items waiting or running: a sweep leaves those to their
# own fixer (plan Review Focus 1).
_fi_af_spot_keys() {
  local f k
  FI_AF_SPOT_KEYS=$'\n'
  for f in "$FI_AF_ST"/queue/* "$FI_AF_ST"/running/*; do
    [[ -f "$f" ]] || continue
    [[ "$(_fi_af_field "$f" kind)" == "spot" ]] || continue
    k="$(_fi_af_field "$f" key)" && FI_AF_SPOT_KEYS+="$k"$'\n'
  done
}

# Ruling 6 order: critical first; then file groups, each placed by its
# oldest entry; then oldest; then ledger order. awk computes each group's
# oldest date (bash 3.2 has no associative arrays).
fi_af_sweep_candidates() {
  local file="$1" root="$2" max="$3" entry crit path date n=0
  _fi_af_spot_keys
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    fi_af_fixable_now "$entry" || continue
    crit=1
    [[ "$FE_critical" == "yes" ]] && crit=0
    path="$FE_path" date="$FE_date"
    fi_entry_dedup_key_v "$entry" "$root" || continue
    [[ "$FI_AF_SPOT_KEYS" == *$'\n'"$FI_KEY"$'\n'* ]] && continue
    n=$((n + 1))
    printf '%s\t%s\t%s\t%05d\t%s\n' "$crit" "$path" "$date" "$n" "$entry"
  done < <(fi_entries "$file" open 2>/dev/null || true) \
    | awk -F'\t' '{ r[NR] = $0; k = $1 SUBSEP $2; if (!(k in g) || $3 < g[k]) g[k] = $3; c[NR] = $1; p[NR] = $2 }
        END { for (i = 1; i <= NR; i++) print c[i] "\t" g[c[i] SUBSEP p[i]] "\t" r[i] }' \
    | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2 -k4,4 -k5,5 -k6,6 \
    | head -n "$max" | cut -f7-
}

fi_af_sweep_pending() {
  local f
  for f in "$FI_AF_ST"/queue/* "$FI_AF_ST"/running/*; do
    [[ -f "$f" ]] || continue
    [[ "$(_fi_af_field "$f" kind)" == "sweep" ]] && return 0
  done
  return 1
}

# Spec §4.1: after log, tag, decide or sync wrote the ledger. One sweep at
# a time and dailySweeps a day; due at sweepThreshold candidates or on one
# critical (fix: medium). Never fails its caller.
fi_af_sweep_check() {
  local slug root file entry n=0 crit=0 engine
  fi_af_enabled || return 0
  slug="$(fi_repo_id 2>/dev/null)" || return 0
  fi_repo_root_cached
  root="$FI_REPO_ROOT"
  [[ -n "$root" ]] || return 0
  file="$(fi_find_issues_file "$root" 2>/dev/null)" || return 0
  [[ -f "$file" ]] || return 0
  fi_af_dirs "$slug"
  fi_af_sweep_pending && return 0
  fi_af_cap_ok sweep "$(fi_af_int dailySweeps 1)" || return 0
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    [[ -n "$entry" ]] || continue
    n=$((n + 1))
    fi_parse_entry_vars "$entry"
    [[ "$FE_critical" == "yes" && "$FE_fixtag" == "medium" ]] && crit=1
  done < <(fi_af_sweep_candidates "$file" "$root" 1000)
  (( n > 0 )) || return 0
  (( crit || n >= $(fi_af_int sweepThreshold 5) )) || return 0
  engine="$(fi_af_engine 2>/dev/null || true)"
  fi_af_new_id
  fi_af_item_write "$FI_AF_ST/queue/$FI_AF_ID" "id=$FI_AF_ID" "kind=sweep" \
    "root=$root" "slug=$slug" "loc=sweep" "engine=$engine" \
    "queued=$(date +%Y-%m-%dT%H:%M:%S)" "crashes=0"
  if [[ "${FOUND_ISSUES_AUTOFIX_CHILD:-}" == "1" ]]; then
    printf 'Auto-fix: sweep queued %s (inside a fixer; the main session launches it)\n' "$FI_AF_ID"
  else
    printf 'AUTOFIX-SWEEP-DUE %s\n' "$FI_AF_ID"
  fi
}
