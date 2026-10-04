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
#   fi_af_lock <id> / fi_af_unlock <id>
#   fi_af_cap_ok <kind> <limit> / fi_af_cap_take <kind> <id>
#   fi_af_find_entry [<ledger>]
#   fi_af_eligible
#   fi_af_worktree_add / fi_af_worktree_remove
#   fi_af_retire <id> <outcome> <text>
#   fi_af_reap
#   fi_af_claim <id>
#   fi_af_ledger_tag <kind> <text> / fi_af_ledger_resolve
#   fi_af_finish <id> <outcome> <text>
#   fi_af_requeue <id> <why>

# shellcheck disable=SC2034  # AFI_* are read by the other autofix libs

AFI_id="" AFI_kind="" AFI_root="" AFI_slug="" AFI_loc="" AFI_key="" AFI_entry=""
AFI_engine="" AFI_queued="" AFI_crashes="0" AFI_pid="" AFI_wt="" AFI_branch=""
AFI_base="" AFI_result="" AFI_pr="" AFI_cost="" AFI_tokens="" AFI_base_sha="" FI_AF_ID=""
AFI_launcher="" AFI_launched="" AFI_attempts="0" AFI_verdict="" AFI_verdict_reason="" AFI_verdict_tree=""
AFI_head="" AFI_cur="0" AFI_fixed="0"

fi_af_item_write() {
  local path="$1" tmp
  shift
  tmp="$path.tmp.$$"
  printf '%s\n' "$@" >"$tmp" && mv "$tmp" "$path"
}

fi_af_item_read() {
  AFI_id="" AFI_kind="" AFI_root="" AFI_slug="" AFI_loc="" AFI_key="" AFI_entry=""
  AFI_engine="" AFI_queued="" AFI_crashes="0" AFI_pid="" AFI_wt="" AFI_branch=""
  AFI_base="" AFI_result="" AFI_pr="" AFI_cost="" AFI_tokens="" AFI_base_sha=""
  AFI_launcher="" AFI_launched="" AFI_attempts="0" AFI_verdict="" AFI_verdict_reason="" AFI_verdict_tree=""
  AFI_head="" AFI_cur="0" AFI_fixed="0"
  [[ -f "$1" ]] || return 1
  local line k
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}"
    case "$k" in
      id|kind|root|slug|loc|key|entry|engine|queued|crashes|pid|wt|branch|base|result|pr|cost|tokens|base_sha|launcher|launched|attempts|verdict|verdict_reason|verdict_tree|head|cur|fixed)
        printf -v "AFI_$k" '%s' "${line#*=}" ;;
    esac
  done <"$1"
}

fi_af_item_set() {
  local path="$1" key="$2" val="$3" line tmp found=0
  # The hooks stamp items without the repo lock: a claimer may move the
  # file away at any moment. Give up rather than recreate a stub.
  [[ -f "$path" ]] || return 1
  tmp="$path.tmp.$$"
  : >"$tmp" || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "${line%%=*}" == "$key" ]]; then
      printf '%s=%s\n' "$key" "$val" >>"$tmp"; found=1
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$path" || { rm -f "$tmp"; return 1; }
  (( found )) || printf '%s=%s\n' "$key" "$val" >>"$tmp"
  [[ -f "$path" ]] || { rm -f "$tmp"; return 1; }
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

FI_AF_ENTRY="" FI_AF_LEDGER=""

# Spec §5.1: one fixer per repo at a time. mkdir is the atomic test-and-set;
# a lock older than 60 min (FOUND_ISSUES_AUTOFIX_LOCK_STALE seconds) belonged
# to a dead run and is broken by rename, so only one breaker wins.
fi_af_lock() {
  local id="$1" lock="$FI_AF_ST/lock" now age
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$id" >"$lock/owner"; return 0
  fi
  now="$(date +%s)"
  age=$(( now - $(fi_file_mtime "$lock") ))
  (( age >= ${FOUND_ISSUES_AUTOFIX_LOCK_STALE:-3600} )) || return 1
  mv "$lock" "$lock.stale.$$" 2>/dev/null || return 1
  rm -rf "$lock.stale.$$"
  mkdir "$lock" 2>/dev/null || return 1
  printf '%s\n' "$id" >"$lock/owner"
}

fi_af_unlock() {
  local lock="$FI_AF_ST/lock" owner=""
  [[ -f "$lock/owner" ]] && IFS= read -r owner <"$lock/owner"
  [[ "$owner" == "$1" ]] && rm -rf "$lock"
  return 0
}

# Spec §7: claims per repo per day, one line per claim.
fi_af_cap_ok() {
  local f="$FI_AF_ST/day/$(fi_today).$1" n=0 line
  if [[ -f "$f" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do n=$((n + 1)); done <"$f"
  fi
  (( n < $2 ))
}

fi_af_cap_take() {
  printf '%s\n' "$2" >>"$FI_AF_ST/day/$(fi_today).$1"
}

# The entry this item is about, re-found by dedup key (relative path, line,
# symptom — annotations and tags may have changed since it was queued) in
# the source checkout's ledger, or in <ledger> when given (ship uses the
# worktree's own ledger).
fi_af_find_entry() {
  local file="${1:-}" entry
  FI_AF_ENTRY=""
  [[ -n "$file" ]] || file="$(fi_find_issues_file "$AFI_root")" || return 1
  [[ -f "$file" ]] || return 1
  FI_AF_LEDGER="$file"
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    fi_entry_dedup_key_v "$entry" "$AFI_root" || continue
    if [[ "$FI_KEY" == "$AFI_key" ]]; then FI_AF_ENTRY="$entry"; return 0; fi
  done < <(fi_entries "$file" open 2>/dev/null || true)
  return 1
}

# Spec §5.1: still [open], fixable now, no fix reference, never failed.
fi_af_eligible() {
  FI_AF_WHY=""
  fi_af_find_entry || { FI_AF_WHY="entry is no longer [open]"; return 1; }
  fi_parse_entry_vars "$FI_AF_ENTRY"
  if [[ -n "$FE_prs$FE_prs_auto$FE_commits$FE_commits_auto" ]]; then
    FI_AF_WHY="entry already has a fix reference"; return 1
  fi
  if [[ -n "$FE_autofix_failed" ]]; then
    FI_AF_WHY="auto-fix failed before: $FE_autofix_failed"; return 1
  fi
  case "$FE_fixtag" in small|medium) return 0 ;; esac
  [[ -n "$FE_decided" && -z "$FE_decide" ]] && return 0
  FI_AF_WHY="entry is not fixable now (fix: ${FE_fixtag:-none})"
  return 1
}

fi_af_worktree_add() {
  local s base
  base="$(cd "$AFI_root" && fi_resolve_default_branch)"
  git -C "$AFI_root" fetch -q origin "$base" 2>/dev/null || { FI_AF_WHY="git fetch failed"; return 1; }
  s="${AFI_loc//[^A-Za-z0-9]/-}"
  s="${s:0:40}"
  AFI_base="$base"
  AFI_branch="fi/autofix/$s-$AFI_id"
  AFI_wt="$AFI_root/.claude/worktrees/fi-autofix-$AFI_id"
  mkdir -p "$AFI_root/.claude/worktrees"
  git -C "$AFI_root" worktree add -q -b "$AFI_branch" "$AFI_wt" "origin/$base" >/dev/null 2>&1 \
    || { FI_AF_WHY="git worktree add failed"; return 1; }
  # origin/<base> is shared with the source checkout and moves with every
  # fetch there; the run diffs and resets against this commit instead.
  AFI_base_sha="$(git -C "$AFI_wt" rev-parse HEAD 2>/dev/null || true)"
}

fi_af_worktree_remove() {
  [[ -n "$AFI_wt" && -n "$AFI_root" ]] || return 0
  git -C "$AFI_root" worktree remove --force "$AFI_wt" >/dev/null 2>&1 || rm -rf "$AFI_wt"
  git -C "$AFI_root" worktree prune >/dev/null 2>&1 || true
  if [[ -n "$AFI_branch" ]]; then
    git -C "$AFI_root" branch -D "$AFI_branch" >/dev/null 2>&1 || true
  fi
}

# Move an item (queued or running) to done/ with a result, no ledger write.
fi_af_retire() {
  local id="$1" outcome="$2" text="$3" f="$FI_AF_ST/running/$1"
  [[ -f "$f" ]] || f="$FI_AF_ST/queue/$id"
  [[ -f "$f" ]] || return 1
  fi_af_item_set "$f" result "$outcome: $text"
  mv "$f" "$FI_AF_ST/done/$id"
  fi_af_unlock "$id"
  fi_af_log "$id" "$outcome: $text"
}

# Spec §8: a running item whose process is gone crashed. Requeue it once;
# the second crash fails it.
fi_af_reap() {
  local f
  for f in "$FI_AF_ST"/running/*; do
    [[ -f "$f" ]] || continue
    fi_af_item_read "$f"
    if [[ -n "$AFI_pid" ]] && kill -0 "$AFI_pid" 2>/dev/null; then continue; fi
    fi_af_worktree_remove
    if (( ${AFI_crashes:-0} < 1 )); then
      fi_af_item_set "$f" crashes 1
      fi_af_item_set "$f" pid ""
      fi_af_unlock "$AFI_id"
      mv "$f" "$FI_AF_ST/queue/$AFI_id"
      fi_af_log "$AFI_id" "requeued after a crash"
    else
      fi_af_finish "$AFI_id" failed "crashed"
    fi
  done
}

# Spec §5.1. Lock first, so of two claimers exactly one sees the queue file.
fi_af_claim() {
  local id="$1" q="$FI_AF_ST/queue/$1" r="$FI_AF_ST/running/$1"
  fi_af_lock "$id" || { [[ -f "$q" ]] || return 1; return 4; }
  # Reap only while holding the lock: unlocked, a reaper could take a
  # half-claimed item (no pid yet) for a crash and unlock a live run.
  fi_af_reap
  if ! fi_af_item_read "$q"; then fi_af_unlock "$id"; return 1; fi
  if ! fi_af_eligible; then fi_af_retire "$id" stale "$FI_AF_WHY"; return 5; fi
  if ! fi_af_cap_ok spot "$(fi_af_int dailyFixes 5)"; then fi_af_unlock "$id"; return 3; fi
  # Launcher A's run passes its own long-lived pid. A standalone claim is an
  # in-session fixer (launcher B): its claim process exits at once, so there
  # is no pid to record. The repo lock, refreshed by every B-side call, is
  # what keeps the item from being reaped (ledger lib/autofix-queue.sh:263).
  fi_af_item_set "$q" pid "${FI_AF_PID:-}"
  if [[ -n "${FI_AF_PID:-}" ]]; then fi_af_item_set "$q" launcher A; else fi_af_item_set "$q" launcher B; fi
  mv "$q" "$r" || { fi_af_unlock "$id"; return 1; }
  fi_af_cap_take spot "$id"
  if ! fi_af_worktree_add; then
    fi_af_finish "$id" failed "$FI_AF_WHY"
    return 6
  fi
  fi_af_item_set "$r" wt "$AFI_wt"
  fi_af_item_set "$r" branch "$AFI_branch"
  fi_af_item_set "$r" base "$AFI_base"
  fi_af_item_set "$r" base_sha "$AFI_base_sha"
  fi_af_log "$id" "claimed: $AFI_wt ($AFI_branch from origin/$AFI_base)"
}

# Give a claimed item back to the queue untouched (an engine outage): no
# ledger tag and no attempt counted, so the next trigger retries it.
fi_af_requeue() {
  local id="$1" r="$FI_AF_ST/running/$1"
  fi_af_item_read "$r" || return 1
  fi_af_worktree_remove
  fi_af_item_set "$r" pid ""
  mv "$r" "$FI_AF_ST/queue/$id"
  fi_af_unlock "$id"
  fi_af_log "$id" "requeued: $2"
}

# Retag the entry in the source checkout's ledger.
fi_af_ledger_tag() {
  fi_af_find_entry || return 1
  fi_tag_resolve "$1" "$2" "" "" || return 2
  fi_tag_apply "$FI_AF_LEDGER" "$FI_AF_ENTRY" "$FI_TAG_KIND" "$FI_TAG_VALUE" >/dev/null
}

# Already fixed at origin: close it the way `resolve` does.
fi_af_ledger_resolve() {
  fi_af_find_entry || return 1
  local new="- [fixed]${FI_AF_ENTRY#- \[open\]} (verified: ai) (fixed: $(fi_today))"
  local snapshot tmp line done_one=0
  snapshot="$(fi_ledger_snapshot "$FI_AF_LEDGER")"
  tmp="$(fi_ledger_tmp "$FI_AF_LEDGER")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( ! done_one )) && [[ "$line" == "$FI_AF_ENTRY" ]]; then
      printf '%s\n' "$new" >>"$tmp"; done_one=1
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$FI_AF_LEDGER"
  fi_ledger_replace "$FI_AF_LEDGER" "$tmp" "$snapshot"
}

# Spec §5 steps 2, 4 and 7: end an item with an outcome. The ledger write is
# best effort — the item always leaves running/, so it never wedges the lock.
fi_af_finish() {
  local id="$1" outcome="$2" text="$3" f="$FI_AF_ST/running/$1" rc=0
  [[ -f "$f" ]] || f="$FI_AF_ST/queue/$id"
  fi_af_item_read "$f" || { fi_err "autofix: no queued or running item $id"; return 1; }
  text="${text//$'\n'/ }"
  text="${text:0:160}"
  case "$outcome" in
    already-fixed) fi_af_ledger_resolve || rc=$? ;;
    decide|manual) fi_af_ledger_tag "$outcome" "$text" || rc=$? ;;
    failed)        fi_af_ledger_tag autofix-failed "$text" || rc=$? ;;
    shipped|stale) ;;
    *) fi_err "autofix: unknown outcome $outcome"; return 2 ;;
  esac
  (( rc == 0 )) || fi_af_log "$id" "ledger not updated for $outcome (rc $rc)"
  fi_af_worktree_remove
  fi_af_retire "$id" "$outcome" "$text"
}
