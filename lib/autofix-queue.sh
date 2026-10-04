#!/usr/bin/env bash
# autofix-queue.sh — v3 auto-fix queue: items, lock, caps, crash reaping,
# claim and release (spec 2026-10-03 §4.1, §4.3-§4.4, §5 steps 1-2, §7, §8).
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Items are key=value files under $FI_AF_ST/{queue,running,done}/<id>. A
# directory move is the state change, so a crashed process can never leave
# an item in two states.
#
# Functions:
#   fi_af_item_write <path> key=value...
#   fi_af_item_read <path>
#   fi_af_item_set <path> <key> <value>
#   fi_af_new_id
#   fi_af_log <id> <text>
#   fi_af_queue_spot <entry-line>

# shellcheck disable=SC2034  # AFI_* are read by the other autofix libs

AFI_id="" AFI_kind="" AFI_root="" AFI_slug="" AFI_loc="" AFI_key="" AFI_entry=""
AFI_engine="" AFI_queued="" AFI_crashes="0" AFI_pid="" AFI_wt="" AFI_branch=""
AFI_base="" AFI_result="" AFI_pr="" AFI_cost="" FI_AF_ID=""

fi_af_item_write() {
  local path="$1" tmp
  shift
  tmp="$path.tmp.$$"
  printf '%s\n' "$@" >"$tmp" && mv "$tmp" "$path"
}

fi_af_item_read() {
  AFI_id="" AFI_kind="" AFI_root="" AFI_slug="" AFI_loc="" AFI_key="" AFI_entry=""
  AFI_engine="" AFI_queued="" AFI_crashes="0" AFI_pid="" AFI_wt="" AFI_branch=""
  AFI_base="" AFI_result="" AFI_pr="" AFI_cost=""
  [[ -f "$1" ]] || return 1
  local line k
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}"
    case "$k" in
      id|kind|root|slug|loc|key|entry|engine|queued|crashes|pid|wt|branch|base|result|pr|cost)
        printf -v "AFI_$k" '%s' "${line#*=}" ;;
    esac
  done <"$1"
}

fi_af_item_set() {
  local path="$1" key="$2" val="$3" line tmp found=0
  tmp="$path.tmp.$$"
  : >"$tmp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "${line%%=*}" == "$key" ]]; then
      printf '%s=%s\n' "$key" "$val" >>"$tmp"; found=1
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$path"
  (( found )) || printf '%s=%s\n' "$key" "$val" >>"$tmp"
  mv "$tmp" "$path"
}

# Sortable by queue time: the drain loop takes the oldest first.
fi_af_new_id() {
  printf -v FI_AF_ID '%s-%05d' "$(date +%Y%m%d-%H%M%S)" "$RANDOM"
}

fi_af_log() {
  printf '%s %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$2" >>"$FI_AF_RUNS/$1.log" 2>/dev/null || true
}

# Spec §4.1: called by log after it wrote or tagged a (fix: small) entry.
# Never fails the log call: every problem here just means "not queued".
fi_af_queue_spot() {
  local entry="$1" slug root key engine f
  fi_af_enabled || return 0
  slug="$(fi_repo_id 2>/dev/null)" || return 0
  fi_repo_root_cached
  root="$FI_REPO_ROOT"
  [[ -n "$root" ]] || return 0
  fi_entry_dedup_key_v "$entry" "$root" || return 0
  key="$FI_KEY"
  fi_entry_loc_v "$entry" || return 0
  fi_af_dirs "$slug" || return 0
  for f in "$FI_AF_ST"/queue/* "$FI_AF_ST"/running/*; do
    [[ -f "$f" ]] || continue
    fi_af_item_read "$f"
    if [[ "$AFI_key" == "$key" && "$AFI_root" == "$root" ]]; then
      printf 'Auto-fix: already queued (%s)\n' "$AFI_id"
      return 0
    fi
  done
  engine="$(fi_af_engine 2>/dev/null || true)"
  fi_af_new_id
  fi_af_item_write "$FI_AF_ST/queue/$FI_AF_ID" "id=$FI_AF_ID" "kind=spot" \
    "root=$root" "slug=$slug" "loc=$FE_loc" "key=$key" "entry=$entry" \
    "engine=$engine" "queued=$(date +%Y-%m-%dT%H:%M:%S)" "crashes=0"
  if [[ "${FOUND_ISSUES_AUTOFIX_CHILD:-}" == "1" ]]; then
    printf 'Auto-fix: queued %s (inside a fixer; the main session launches it)\n' "$FI_AF_ID"
  else
    printf 'AUTOFIX-QUEUED %s\n' "$FI_AF_ID"
  fi
}
