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
#   fi_af_claims_under <day-file> <limit>
#   fi_af_repo_cfg [<dir>] / fi_af_origin_ok [<dir>]
#   fi_af_find_entry [<ledger>]
#   fi_af_eligible
#   fi_af_worktree_add / fi_af_worktree_remove [drop]
#   fi_af_base_tests <id>
#   fi_af_retire <id> <outcome> <text>
#   fi_af_reap
#   fi_af_claim <id>
#   fi_af_ledger_tag <kind> <text> / fi_af_ledger_resolve
#   _fi_af_ledger_outcome <outcome> <text>
#   _fi_af_ledger_swap <ledger> <old-line> <new-line>
#   fi_af_finish <id> <outcome> <text>
#   fi_af_requeue <id> <why>

# shellcheck disable=SC2034  # AFI_* are read by the other autofix libs

AFI_id="" AFI_kind="" AFI_root="" AFI_slug="" AFI_loc="" AFI_key="" AFI_entry=""
AFI_engine="" AFI_queued="" AFI_crashes="0" AFI_pid="" AFI_wt="" AFI_branch=""
AFI_base="" AFI_result="" AFI_pr="" AFI_cost="" AFI_tokens="" AFI_base_sha="" FI_AF_ID=""
AFI_launcher="" AFI_launched="" AFI_attempts="0" AFI_verdict="" AFI_verdict_reason="" AFI_verdict_tree=""
AFI_head="" AFI_cur="0" AFI_fixed="0" AFI_cpgid="" AFI_finished=""
AFI_base_why="" AFI_waiting="" AFI_wait_since="" AFI_wait_next="" AFI_ship_tries="0" AFI_cont="" AFI_skip_files="" AFI_more="" AFI_chain_cost="" AFI_chain_tokens="" AFI_outages="0" AFI_pstart="" AFI_wt_retries="0"

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
  AFI_head="" AFI_cur="0" AFI_fixed="0" AFI_cpgid="" AFI_finished=""
  AFI_base_why="" AFI_waiting="" AFI_wait_since="" AFI_wait_next="" AFI_ship_tries="0" AFI_cont="" AFI_skip_files="" AFI_more="" AFI_chain_cost="" AFI_chain_tokens="" AFI_outages="0" AFI_pstart="" AFI_wt_retries="0"
  [[ -f "$1" ]] || return 1
  local line k
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}"
    case "$k" in
      id|kind|root|slug|loc|key|entry|engine|queued|crashes|pid|wt|branch|base|result|pr|cost|tokens|base_sha|launcher|launched|attempts|verdict|verdict_reason|verdict_tree|head|cur|fixed|cpgid|finished|base_why|waiting|wait_since|wait_next|ship_tries|cont|skip_files|more|chain_cost|chain_tokens|outages|pstart|wt_retries)
        printf -v "AFI_$k" '%s' "${line#*=}" ;;
    esac
  done <"$1"
  # wt comes from a file: anything but one of our own fi- worktrees under the
  # item's root (a hand-edited or forged item) would aim reset, add -A and
  # rm -rf at that path. Refuse the item rather than trust it.
  if [[ -n "$AFI_wt" ]] && [[ -z "$AFI_root" || "$AFI_wt" != "$AFI_root"/.claude/worktrees/fi-* || "$AFI_wt" == *..* ]]; then
    AFI_wt=""; return 1
  fi
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
  mv "$tmp" "$path" || return 1
  # A pid is only an identity together with its start time: the OS reuses
  # pids, and an unrelated process must not look like the run that died.
  if [[ "$key" == pid ]]; then
    if [[ "$val" =~ ^[1-9][0-9]*$ ]]; then
      _fi_af_pstart "$val"
      fi_af_item_set "$path" pstart "$FI_AF_PSTART"
    else
      fi_af_item_set "$path" pstart ""
    fi
  fi
  return 0
}

# Start time of <pid> in FI_AF_PSTART: epoch seconds when date can parse ps's
# lstart (BSD -j -f, else GNU -d), else the lstart text; "" when ps cannot
# say (Git Bash: callers then fall back to the pid alone). ps runs in the C
# locale and UTC, so a reader with another TZ or locale reads the same value.
_fi_af_pstart() {
  local s e
  FI_AF_PSTART=""
  [[ "$1" =~ ^[1-9][0-9]*$ ]] || return 0
  s="$(LC_ALL=C TZ=UTC0 ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//' || true)"
  s="${s//$'\n'/ }"
  [[ -n "$s" ]] || return 0
  e="$(LC_ALL=C TZ=UTC0 date -j -f '%a %b %d %T %Y' "$s" +%s 2>/dev/null \
       || LC_ALL=C TZ=UTC0 date -d "$s" +%s 2>/dev/null || true)"
  if [[ "$e" =~ ^[0-9]+$ ]]; then FI_AF_PSTART="$e"; else FI_AF_PSTART="$s"; fi
}

# rc 0 when the start time read now matches <recorded>: unknown on either
# side counts as a match (the pid alone decides), and two epochs may differ
# by 2 s (procps that derives boot time from uptime jitters by a second).
_fi_af_pstart_same() {
  local now="$1" rec="$2" d
  [[ -n "$now" && -n "$rec" ]] || return 0
  if [[ "$now" =~ ^[0-9]+$ && "$rec" =~ ^[0-9]+$ ]]; then
    d=$(( now - rec )); (( d < 0 )) && d=$(( -d ))
    (( d <= 2 ))
  else
    [[ "$now" == "$rec" ]]
  fi
}

# rc 0 when <pid> is alive and, if a start time was recorded and ps can read
# one now, still the same process.
_fi_af_pid_alive() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$1" 2>/dev/null || return 1
  [[ -n "${2:-}" ]] || return 0
  _fi_af_pstart "$1"
  _fi_af_pstart_same "$FI_AF_PSTART" "$2"
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
  fi_af_inflight_check "$key" && return 0
  # 3.6.0: an item with no test command can only end stale after its claim.
  if ! fi_af_test_command "$root" >/dev/null 2>&1; then
    printf 'Auto-fix: not queued, no test command (set found-issues.autofix.testCommand)\n'
    return 0
  fi
  for f in "$FI_AF_ST"/queue/* "$FI_AF_ST"/running/*; do
    [[ -f "$f" ]] || continue
    fi_af_item_read "$f" || true
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
# to a dead run and is broken by rename, so only one breaker wins. So is a
# lock whose owner is a running A item with a dead pid (SIGKILL, sleep): it
# would otherwise block the reap for the full hour.
fi_af_lock() {
  local id="$1" lock="$FI_AF_ST/lock" now age mt owner="" opid="" opstart="" brk owner2="" mt2
  brk="$lock.break"
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$id" >"$lock/owner"; return 0
  fi
  [[ -f "$lock/owner" ]] && { IFS= read -r owner <"$lock/owner" || true; }
  if [[ -n "$owner" ]]; then
    opid="$(_fi_af_field "$FI_AF_ST/running/$owner" pid)" || opid=""
    opstart="$(_fi_af_field "$FI_AF_ST/running/$owner" pstart)" || opstart=""
  fi
  mt="$(fi_file_mtime "$lock")"
  if [[ ! "$opid" =~ ^[1-9][0-9]*$ ]] || _fi_af_pid_alive "$opid" "$opstart"; then
    if (( mt == 0 )); then
      # stat failed (the lock vanished since the mkdir): not evidence of age.
      # Retake it if it is gone, else leave whoever holds it alone.
      mkdir "$lock" 2>/dev/null || return 1
      printf '%s\n' "$id" >"$lock/owner"; return 0
    fi
    now="$(date +%s)"
    age=$(( now - mt ))
    (( age >= ${FOUND_ISSUES_AUTOFIX_LOCK_STALE:-3600} )) || return 1
  fi
  # Breaking is serialized: of two contenders that both judged the owner dead
  # only the one holding the break mutex proceeds, and it re-reads the owner
  # (and the lock's age) first, so a lock another contender already broke and
  # retook is never moved away from its new holder.
  if ! mkdir "$brk" 2>/dev/null; then
    # A mutex left by a contender that died inside the break: drop it.
    mt2="$(fi_file_mtime "$brk")"
    if (( mt2 > 0 )) && (( $(date +%s) - mt2 >= 60 )); then rm -rf "$brk"; fi
    return 1
  fi
  [[ -f "$lock/owner" ]] && { IFS= read -r owner2 <"$lock/owner" || true; }
  mt2="$(fi_file_mtime "$lock")"
  if [[ "$owner2" != "$owner" || "$mt2" != "$mt" ]]; then
    rmdir "$brk" 2>/dev/null || true
    return 1
  fi
  mv "$lock" "$lock.stale.$$" 2>/dev/null || { rmdir "$brk" 2>/dev/null || true; return 1; }
  rm -rf "$lock.stale.$$"
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$id" >"$lock/owner"
    rmdir "$brk" 2>/dev/null || true
    return 0
  fi
  rmdir "$brk" 2>/dev/null || true
  return 1
}

fi_af_unlock() {
  local lock="$FI_AF_ST/lock" owner=""
  [[ -f "$lock/owner" ]] && IFS= read -r owner <"$lock/owner"
  [[ "$owner" == "$1" ]] && rm -rf "$lock"
  return 0
}

# Spec §7: claims per repo per day, one line per claim. <file> holds the
# claims (the day's .spot or .sweep file); 0 while there are fewer than
# <limit>. Shared by fi_af_cap_ok and the Stop fallback (fi_afh_stop), so
# the two count one way; no fork.
fi_af_claims_under() {
  local n=0 line
  if [[ -f "$1" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do n=$((n + 1)); done <"$1"
  fi
  (( n < $2 ))
}

fi_af_cap_ok() {
  fi_af_claims_under "$FI_AF_ST/day/$(fi_today).$1" "$2"
}

# The per-repo gate of <dir> (default .) in ONE git call: sets FI_AF_RC_ON
# to true or "" (found-issues.autofix, read the way git config --type=bool
# does: true/yes/on, a bare key, any nonzero integer) and FI_AF_RC_CAP (the
# spot cap, found-issues.autofix.dailyFixes; 5 unless a positive integer, as
# fi_af_int, minus its warning). Shared by fi_af_enabled and the Stop
# fallback, which would otherwise carry two copies of these reads.
FI_AF_RC_ON="" FI_AF_RC_CAP=5
fi_af_repo_cfg() {
  local line key val on
  FI_AF_RC_ON="" FI_AF_RC_CAP=5
  while IFS= read -r line; do
    key="${line%% *}" val="" on=""
    [[ "$line" == *" "* ]] && val="${line#* }" || on=true
    case "$key" in
      found-issues.autofix)
        case "$val" in
          [Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn]) on=true ;;
        esac
        [[ "$val" =~ ^[0-9]+$ ]] && (( 10#$val != 0 )) && on=true
        FI_AF_RC_ON="$on" ;;
      found-issues.autofix.dailyfixes)
        if [[ "$val" =~ ^[0-9]+$ ]] && (( 10#$val >= 1 )); then FI_AF_RC_CAP="$((10#$val))"
        else FI_AF_RC_CAP=5; fi ;;
    esac
  done < <(git -C "${1:-.}" config --get-regexp '^found-issues\.autofix(\.dailyfixes)?$' 2>/dev/null || true)
}

# 0 when origin of <dir> (default .) is a GitHub repo (v3 is GitHub-PR-mode
# only, spec §2): fi_repo_id's own rule, run in <dir>.
fi_af_origin_ok() {
  if [[ -z "${1:-}" || "$1" == "." ]]; then fi_repo_id >/dev/null 2>&1; return; fi
  ( cd "$1" 2>/dev/null && fi_repo_id >/dev/null 2>&1 )
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

# 3.3.1: ship skips the source ledger annotation when the PR lands on the
# checkout's own branch, so the local entry still looks unfixed. It leaves
# an in-flight record instead (key, PR, epoch seconds); a record younger than
# 14 days keeps the entry from being fixed again, an older one is dropped.
fi_af_inflight_file() {
  local ck
  read -r ck _ < <(printf '%s' "$1" | cksum)
  FI_AF_INFLIGHT_FILE="$FI_AF_ST/inflight/$ck"
}

fi_af_inflight_mark() {
  fi_af_inflight_file "$1"
  mkdir -p "$FI_AF_ST/inflight" 2>/dev/null || return 1
  printf 'key=%s\npr=%s\nts=%s\n' "$1" "$2" "$(date +%s)" >"$FI_AF_INFLIGHT_FILE"
}

# rc 0 and FI_AF_INFLIGHT_PR set when <key> has a fresh record.
fi_af_inflight_check() {
  local ts
  FI_AF_INFLIGHT_PR=""
  fi_af_inflight_file "$1"
  [[ -f "$FI_AF_INFLIGHT_FILE" ]] || return 1
  ts="$(_fi_af_field "$FI_AF_INFLIGHT_FILE" ts)" || ts=""
  if [[ "$ts" =~ ^[0-9]+$ ]] && (( $(date +%s) - ts < 14 * 86400 )); then
    FI_AF_INFLIGHT_PR="$(_fi_af_field "$FI_AF_INFLIGHT_FILE" pr)" || FI_AF_INFLIGHT_PR=""
    return 0
  fi
  rm -f "$FI_AF_INFLIGHT_FILE"
  return 1
}

# Spec §5.1: still [open], fixable now, no fix reference, never failed.
fi_af_eligible() {
  FI_AF_WHY=""
  fi_af_find_entry || { FI_AF_WHY="entry is no longer [open]"; return 1; }
  if fi_af_inflight_check "$AFI_key"; then
    FI_AF_WHY="fix in flight in PR #$FI_AF_INFLIGHT_PR"; return 1
  fi
  fi_parse_entry_vars "$FI_AF_ENTRY"
  if [[ -n "$FE_prs$FE_prs_auto$FE_commits$FE_commits_auto" ]]; then
    FI_AF_WHY="entry already has a fix reference"; return 1
  fi
  if [[ -n "$FE_autofix_failed" ]]; then
    FI_AF_WHY="auto-fix failed before: $FE_autofix_failed"; return 1
  fi
  local fixable=""
  case "$FE_fixtag" in small|medium) fixable=1 ;; esac
  [[ -n "$FE_decided" && -z "$FE_decide" ]] && fixable=1
  if [[ -z "$fixable" ]]; then
    FI_AF_WHY="entry is not fixable now (fix: ${FE_fixtag:-none})"; return 1
  fi
  # Last: it is network I/O, and its key compare re-parses FE_*.
  if fi_af_open_pr_fixing; then
    FI_AF_WHY="fix in flight in PR #$FI_AF_DUP_PR"; return 1
  fi
  return 0
}

# 3.6.0: three agent-config auto-fix PRs were closed as duplicates of PRs an
# interactive session opened for the same entries. An open PR that is not
# auto-fix's own, touches the ledger, and annotates this item's entry (same
# dedup key) with (PR: ...) already fixes it. FI_AF_PR_SCANNED="" forces a
# fresh scan (ship re-checks after a long fixer run). Sets FI_AF_DUP_PR.
FI_AF_PR_SCAN="" FI_AF_PR_SCANNED="" FI_AF_DUP_PR=""
fi_af_open_pr_fixing() {
  local n line
  FI_AF_DUP_PR=""
  [[ -n "${AFI_loc:-}" && -n "${AFI_key:-}" && -n "${AFI_slug:-}" ]] || return 1
  if [[ -z "$FI_AF_PR_SCANNED" ]]; then
    FI_AF_PR_SCANNED=1 FI_AF_PR_SCAN=""
    while IFS= read -r n || [[ -n "$n" ]]; do
      [[ "$n" =~ ^[0-9]+$ ]] || continue
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "+- ["* && "$line" == *"(PR: "* ]] || continue
        FI_AF_PR_SCAN+="$n"$'\t'"${line#+}"$'\n'
      done < <(gh pr diff "$n" --repo "$AFI_slug" 2>/dev/null || true)
    done < <(gh pr list --repo "$AFI_slug" --state open --limit 100 --json number,headRefName,files \
      --jq '.[] | select(.headRefName | startswith("fi/") | not)
                | select([.files[]?.path] | any(test("found-issues(-archive)?\\.md$")))
                | .number' 2>/dev/null || true)
  fi
  while IFS=$'\t' read -r n line || [[ -n "$n" ]]; do
    [[ "$line" == *" $AFI_loc "* ]] || continue
    fi_entry_dedup_key_v "$line" "$AFI_root" || continue
    [[ "$FI_KEY" == "$AFI_key" ]] || continue
    FI_AF_DUP_PR="$n"; return 0
  done <<<"$FI_AF_PR_SCAN"
  return 1
}

# 3.6.0: the entry fixed on origin/<base> while the run worked (agent-config
# #592 shipped after #587 had already fixed and closed its entry). Only a
# [fixed] line, or an [open] one with a PR/commit reference, counts; a
# deferral meanwhile does not. Sets FI_AF_WHY; rc 0 = fixed elsewhere.
fi_af_fixed_elsewhere() {
  local p line
  FI_AF_PR_SCANNED=""
  if fi_af_open_pr_fixing; then
    FI_AF_WHY="fix in flight in PR #$FI_AF_DUP_PR"; return 0
  fi
  git -C "$AFI_root" fetch -q origin "$AFI_base" >/dev/null 2>&1 || return 1
  for p in docs/found-issues.md docs/found-issues-archive.md .found-issues.md; do
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" == "- ["* && "$line" == *" $AFI_loc "* ]] || continue
      fi_entry_dedup_key_v "$line" "$AFI_root" || continue
      [[ "$FI_KEY" == "$AFI_key" ]] || continue
      fi_parse_entry_vars "$line" || continue
      if [[ "$line" == "- [fixed]"* || ( "$line" == "- [open]"* && -n "$FE_prs$FE_commits" ) ]]; then
        FI_AF_WHY="fixed on $AFI_base meanwhile"; return 0
      fi
    done < <(git -C "$AFI_root" show "origin/$AFI_base:$p" 2>/dev/null || true)
  done
  return 1
}

# 3.2.0 (spec section 1): the branch a fix starts from and lands into is the
# one the session works on, never assumed to be the default branch. Sets
# AFI_base and AFI_base_why; every fallback is the default branch.
fi_af_landing_branch() {
  local def cur up b n best="" bestn="" base rc
  def="$(cd "$AFI_root" && fi_resolve_default_branch)"
  AFI_base="$def"
  cur="$(git -C "$AFI_root" symbolic-ref -q --short HEAD 2>/dev/null || true)"
  if [[ -z "$cur" ]]; then AFI_base_why="detached"; return 0; fi
  if [[ "$cur" == "$def" ]]; then AFI_base_why="default branch"; return 0; fi
  up="$(git -C "$AFI_root" config --get "branch.$cur.merge" 2>/dev/null || true)"
  up="${up#refs/heads/}"
  if [[ -n "$up" ]]; then
    # ls-remote, not origin/<up>: a branch deleted on GitHub keeps its stale
    # remote-tracking ref until someone prunes.
    # Only exit 2 is "no such branch"; any other failure (network, auth) says
    # nothing about the branch, so the tracked one stays the base.
    rc=0
    git -C "$AFI_root" ls-remote --exit-code --heads origin "$up" >/dev/null 2>&1 || rc=$?
    if (( rc == 0 )); then
      AFI_base="$up" AFI_base_why="tracks origin/$up"; return 0
    elif (( rc != 2 )); then
      AFI_base="$up" AFI_base_why="tracks origin/$up (ls-remote failed)"; return 0
    fi
    base="$(cd "$AFI_root" && gh pr list --repo "${AFI_slug:-$(fi_repo_id 2>/dev/null)}" --head "$up" --state merged --limit 1 \
      --json baseRefName --jq '.[0].baseRefName // ""' 2>/dev/null || true)"
    if [[ -n "$base" ]]; then
      rc=0
      git -C "$AFI_root" ls-remote --exit-code --heads origin "$base" >/dev/null 2>&1 || rc=$?
      if (( rc == 0 )); then
        AFI_base="$base" AFI_base_why="$up merged into $base"; return 0
      elif (( rc != 2 )); then
        AFI_base="$base" AFI_base_why="$up merged into $base (ls-remote failed)"; return 0
      fi
    fi
    AFI_base_why="$up gone, base unknown"; return 0
  fi
  git -C "$AFI_root" fetch -q origin 2>/dev/null || true
  while IFS= read -r b || [[ -n "$b" ]]; do
    b="${b#origin/}"
    [[ -n "$b" && "$b" != HEAD && "$b" != fi/* ]] || continue
    # A failed ls-remote (not exit 2) keeps the candidate: the local ref decides.
    rc=0
    git -C "$AFI_root" ls-remote --exit-code --heads origin "$b" >/dev/null 2>&1 || rc=$?
    (( rc == 2 )) && continue
    git -C "$AFI_root" merge-base "origin/$b" HEAD >/dev/null 2>&1 || continue
    n="$(git -C "$AFI_root" rev-list --count "origin/$b..HEAD" 2>/dev/null)" || continue
    if [[ -z "$bestn" ]] || (( n < bestn )) || { (( n == bestn )) && [[ "$b" == "$def" ]]; }; then
      best="$b" bestn="$n"
    fi
  done < <(git -C "$AFI_root" for-each-ref --format='%(refname:short)' refs/remotes/origin 2>/dev/null)
  if [[ -z "$best" ]]; then AFI_base_why="no pushed ancestor"; return 0; fi
  # A tie keeps the default branch: only a strictly nearer branch wins.
  if [[ "$best" != "$def" ]] && [[ "$(git -C "$AFI_root" rev-list --count "origin/$def..HEAD" 2>/dev/null)" == "$bestn" ]]; then
    AFI_base_why="nearest pushed ancestor $def"; return 0
  fi
  AFI_base="$best" AFI_base_why="nearest pushed ancestor $best"
}

fi_af_worktree_add() {
  local s base
  [[ -n "$AFI_base" ]] || fi_af_landing_branch
  base="$AFI_base"
  git -C "$AFI_root" fetch -q origin "$base" 2>/dev/null || { FI_AF_WHY="git fetch failed"; return 1; }
  if [[ "$AFI_kind" == "sweep" ]]; then
    # Phase 4 ruling 5: unique per run (the spec's per-day <n> collided).
    AFI_branch="fi/sweep/${AFI_id%%-*}-${AFI_id##*-}"
    AFI_wt="$AFI_root/.claude/worktrees/fi-sweep-$AFI_id"
  else
    s="${AFI_loc//[^A-Za-z0-9]/-}"
    s="${s:0:40}"
    AFI_branch="fi/autofix/$s-$AFI_id"
    AFI_wt="$AFI_root/.claude/worktrees/fi-autofix-$AFI_id"
  fi
  mkdir -p "$AFI_root/.claude/worktrees"
  git -C "$AFI_root" worktree add -q -b "$AFI_branch" "$AFI_wt" "origin/$base" >/dev/null 2>&1 \
    || { FI_AF_WHY="git worktree add failed"; return 1; }
  # origin/<base> is shared with the source checkout and moves with every
  # fetch there; the run diffs and resets against this commit instead.
  AFI_base_sha="$(git -C "$AFI_wt" rev-parse HEAD 2>/dev/null || true)"
  fi_af_copy_worktree_files
  return 0
}

# 3.4.1 (ledger lib/autofix-queue.sh:313): a fresh worktree lacks the repo's
# gitignored local files (a tools/config.local.toml its tests read), so the
# suite failed at base and the item retired stale. found-issues.autofix.
# worktreeFiles lists repo-relative paths (spaces and/or commas) to copy in.
# Only a path the fix worktree ignores is copied, so it can never reach a fix
# commit. Every problem is a run-log line: the step never fails the run.
fi_af_copy_worktree_files() {
  local list p src main line dest
  local -a paths
  list="$(git -C "$AFI_root" config --get found-issues.autofix.worktreeFiles 2>/dev/null || true)"
  [[ -n "$list" ]] || return 0
  list="$(printf '%s' "$list" | tr ',' ' ')"
  # A linked worktree is the usual source checkout; its main worktree is the
  # fallback for a file only the main one holds.
  main=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "worktree "* ]]; then main="${line#worktree }"; break; fi
  done < <(git -C "$AFI_root" worktree list --porcelain 2>/dev/null)
  read -r -a paths <<<"$list" || true
  for p in ${paths[@]+"${paths[@]}"}; do
    if [[ -z "$p" || "$p" == /* || "$p" == \\* || "$p" =~ ^[A-Za-z]: ]]; then
      fi_af_log "$AFI_id" "worktreeFiles: $p rejected (must be a path inside the repo)"; continue
    fi
    dest="/${p//\\//}/"
    if [[ "$dest" == */../* ]]; then
      fi_af_log "$AFI_id" "worktreeFiles: $p rejected (must be a path inside the repo)"; continue
    fi
    src="$AFI_root/$p"
    if [[ ! -f "$src" && -n "$main" && "$main" != "$AFI_root" && -f "$main/$p" ]]; then src="$main/$p"; fi
    if [[ ! -f "$src" ]]; then
      fi_af_log "$AFI_id" "worktreeFiles: $p not found in $AFI_root — not copied"; continue
    fi
    if ! git -C "$AFI_wt" check-ignore -q -- "$p" >/dev/null 2>&1; then
      fi_af_log "$AFI_id" "worktreeFiles: $p is not gitignored — not copied"; continue
    fi
    if mkdir -p "$(dirname "$AFI_wt/$p")" 2>/dev/null && cp -p "$src" "$AFI_wt/$p" 2>/dev/null; then
      fi_af_log "$AFI_id" "worktreeFiles: copied $p"
    else
      fi_af_log "$AFI_id" "worktreeFiles: $p could not be copied"
    fi
  done
  return 0
}

# 3.2.1 (ledger lib/autofix-sweep.sh:387): once a sweep's ship has failed,
# its branch alone holds the verified commits, so only a shipped sweep
# (<drop>) deletes it; a requeue, crash, cancel or final failure keeps it.
fi_af_worktree_remove() {
  [[ -n "$AFI_wt" && -n "$AFI_root" ]] || return 0
  git -C "$AFI_root" worktree remove --force "$AFI_wt" >/dev/null 2>&1 || rm -rf "$AFI_wt"
  git -C "$AFI_root" worktree prune >/dev/null 2>&1 || true
  [[ "${AFI_ship_tries:-0}" =~ ^[1-9] && "${1:-}" != drop ]] && return 0
  if [[ -n "$AFI_branch" ]]; then
    git -C "$AFI_root" branch -D "$AFI_branch" >/dev/null 2>&1 || true
  fi
}

# 3.2.1 (ledger lib/autofix.sh:127): run the repo's tests once in the fresh
# worktree. A suite already red at base fails every attempt whatever the fix
# changes, so the run ends stale before any engine starts. rc 1 = red at
# base; rc 0 = green, or no test command (the run reports that itself). The
# worktree is reset after, so nothing the tests left reaches a fixer's diff.
fi_af_base_tests() {
  local id="$1" t rc=0 log="$FI_AF_RUNS/$1.base-tests.log" red="$FI_AF_ST/base-red" key=""
  FI_AF_BASE_WHY=""
  t="$(fi_af_test_command "$AFI_wt" 2>/dev/null)" || return 0
  # 3.6.0: a base found red is remembered by commit and test command, so the
  # next item on the same base retires without running the suite again.
  [[ -n "${AFI_base_sha:-}" ]] && key="$AFI_base_sha $t"
  if [[ -n "$key" && -f "$red" && "$(cat "$red" 2>/dev/null)" == "$key" ]]; then
    FI_AF_BASE_WHY="tests fail at base"
    fi_af_log "$id" "tests fail at base: known red at ${AFI_base_sha:0:7} ($t), not re-run"
    return 1
  fi
  # A red base is re-run once (fi_af_tests_pass): a flake is not red.
  fi_af_tests_pass "$AFI_wt" "$t" "$log" || rc=$?
  git -C "$AFI_wt" reset -q --hard "${AFI_base_sha:-HEAD}" >/dev/null 2>&1 || true
  git -C "$AFI_wt" clean -qfd >/dev/null 2>&1 || true
  if (( rc == 0 )); then rm -f "$red"; return 0; fi
  # 3.4.2: the watchdog firing is not a red suite (ledger :341).
  if [[ -n "${FI_AF_CHILD_TIMEDOUT:-}" ]]; then
    local secs="$FI_AF_CHILD_TIMEDOUT" took
    took="${secs}s"; (( secs % 60 == 0 )) && took="$(( secs / 60 )) min"
    FI_AF_BASE_WHY="base tests timed out after $took (raise found-issues.autofix.runTimeoutMin)"
    fi_af_log "$id" "$FI_AF_BASE_WHY ($t)"
    return 1
  fi
  FI_AF_BASE_WHY="tests fail at base"
  [[ -z "$key" ]] || printf '%s' "$key" >"$red" 2>/dev/null || true
  fi_af_log "$id" "tests fail at base (exit $rc, $t):"
  fi_af_test_report "$log" 20 >>"$FI_AF_RUNS/$id.log" 2>/dev/null || true
  return 1
}

# Move an item (queued or running) to done/ with a result, no ledger write.
fi_af_retire() {
  local id="$1" outcome="$2" text="$3" f="$FI_AF_ST/running/$1"
  [[ -f "$f" ]] || f="$FI_AF_ST/queue/$id"
  [[ -f "$f" ]] || return 1
  fi_af_item_set "$f" result "$outcome: $text"
  fi_af_item_set "$f" finished "$(date +%s)"
  mv "$f" "$FI_AF_ST/done/$id"
  fi_af_seg_write "$(_fi_af_field "$FI_AF_ST/done/$id" root)"
  fi_af_stuck_update "$(_fi_af_field "$FI_AF_ST/done/$id" root)" "$outcome" "$text" "$id"
  fi_af_unlock "$id"
  fi_af_log "$id" "$outcome: $text"
}

# A re-queued item re-claims as a fresh run: the dead run's attempts and
# verdict must not count against the next one.
_fi_af_clear_attempts() {
  fi_af_item_set "$1" attempts 0
  fi_af_item_set "$1" verdict ""
  fi_af_item_set "$1" verdict_reason ""
  fi_af_item_set "$1" verdict_tree ""
}

# Spec §8: a running item whose process is gone crashed. Requeue it once;
# the second crash fails it.
fi_af_reap() {
  local f
  for f in "$FI_AF_ST"/running/*; do
    [[ -f "$f" ]] || continue
    if ! fi_af_item_read "$f"; then
      # A refused item (forged worktree path) is retired untouched.
      fi_af_item_set "$f" result "failed: refused: worktree path outside its fi- worktrees"
      mv "$f" "$FI_AF_ST/done/${f##*/}"
      fi_af_seg_write "$(_fi_af_field "$FI_AF_ST/done/${f##*/}" root)"
      continue
    fi
    if [[ -n "$AFI_pid" ]] && _fi_af_pid_alive "$AFI_pid" "$AFI_pstart"; then continue; fi
    fi_af_worktree_remove
    if (( ${AFI_crashes:-0} < 1 )); then
      fi_af_item_set "$f" crashes 1
      fi_af_item_set "$f" pid ""
      # The dead run's PR number would make cancel refuse the re-run.
      fi_af_item_set "$f" pr ""
      # Back in the queue: the landing branch resolves fresh at re-claim and
      # B's attempt count and verdict start over, except for a ship retry,
      # whose kept branch was cut from this base and whose approved tree the
      # ship re-checks.
      if [[ ! "${AFI_ship_tries:-0}" =~ ^[1-9] ]]; then
        fi_af_item_set "$f" base ""
        fi_af_item_set "$f" base_why ""
        _fi_af_clear_attempts "$f"
      fi
      fi_af_unlock "$AFI_id"
      mv "$f" "$FI_AF_ST/queue/$AFI_id"
      fi_af_seg_write "$AFI_root"
      fi_af_log "$AFI_id" "requeued after a crash"
    else
      fi_af_finish "$AFI_id" failed "crashed"
    fi
  done
}

# The file an entry cites, relative to the root; rc 1 when the entry cites no
# file that exists in the root checkout (an abstract topic, with or without a
# slash, or a path that exists nowhere), so there is nothing to wait on.
_fi_af_entry_file() {
  fi_parse_entry_vars "$AFI_entry" 2>/dev/null || return 1
  [[ -n "$FE_path" ]] || return 1
  [[ -e "$AFI_root/$FE_path" ]] || return 1
  printf '%s' "$FE_path"
}

# Spec decision 5: a cited file is busy in the session's root checkout when it
# has uncommitted changes (staged or not) or commits not yet pushed. "Pushed"
# is the branch's own upstream ref when it exists (live or stale: a
# squash-merged branch's own commits are not unpushed), else origin/<base>.
# Never a diff against origin/<base> itself: a checkout merely behind origin
# differs from it without holding any work of its own. rc 0 = busy.
_fi_af_file_busy() {
  local p="$1" cur up pushed
  [[ -n "$(git -C "$AFI_root" diff --name-only HEAD -- "$p" 2>/dev/null)" ]] && return 0
  pushed="origin/$AFI_base"
  cur="$(git -C "$AFI_root" symbolic-ref -q --short HEAD 2>/dev/null || true)"
  if [[ -n "$cur" ]]; then
    up="$(git -C "$AFI_root" config --get "branch.$cur.merge" 2>/dev/null || true)"
    up="${up#refs/heads/}"
    if [[ -n "$up" ]] && git -C "$AFI_root" show-ref --verify --quiet "refs/remotes/origin/$up"; then
      pushed="origin/$up"
    fi
  fi
  [[ -n "$(git -C "$AFI_root" rev-list -1 "$pushed..HEAD" -- "$p" 2>/dev/null)" ]]
}

# Spec section 2: rc 0 = go; rc 8 = wait (item stays queued); rc 5 = waited
# too long. The file must be on the landing branch's remote and untouched
# locally, or a fix cut from origin/<base> would not match what the session sees.
_fi_af_wait_check() {
  local q="$1" p why now since
  p="$(_fi_af_entry_file)" || return 0
  # An offline claim waits like any other wait: no daily slot, no failed tag,
  # and it counts toward the wait maximum.
  if ! git -C "$AFI_root" fetch -q origin "$AFI_base" 2>/dev/null; then
    why="git fetch failed"
  elif ! git -C "$AFI_root" cat-file -e "origin/$AFI_base:$p" 2>/dev/null; then
    why="$p not on origin/$AFI_base"
  elif _fi_af_file_busy "$p"; then
    why="$p busy in $AFI_root"
  else
    return 0
  fi
  now="$(date +%s)"
  since="$AFI_wait_since"; [[ "$since" =~ ^[0-9]+$ ]] || since="$now"
  if (( now - since > ${FOUND_ISSUES_AUTOFIX_WAIT_MAX:-259200} )); then
    FI_AF_WHY="$why"; return 5
  fi
  fi_af_item_set "$q" waiting "$why"
  fi_af_item_set "$q" wait_since "$since"
  fi_af_item_set "$q" wait_next "$(( now + ${FOUND_ISSUES_AUTOFIX_WAIT_RECHECK:-900} ))"
  FI_AF_WHY="$why"
  return 8
}

# Spec §5.1. Lock first, so of two claimers exactly one sees the queue file.
fi_af_claim() {
  local id="$1" q="$FI_AF_ST/queue/$1" r="$FI_AF_ST/running/$1"
  fi_af_lock "$id" || { [[ -f "$q" ]] || return 1; return 4; }
  # Reap only while holding the lock: unlocked, a reaper could take a
  # half-claimed item (no pid yet) for a crash and unlock a live run.
  fi_af_reap
  if ! fi_af_item_read "$q"; then fi_af_unlock "$id"; return 1; fi
  if [[ "$AFI_kind" == "sweep" ]]; then fi_af_sweep_claim "$id"; return; fi
  # A cancel may have moved the queue file away meanwhile: then the retire
  # finds nothing and the lock is still ours to drop.
  if ! fi_af_eligible; then fi_af_retire "$id" stale "$FI_AF_WHY" || fi_af_unlock "$id"; return 5; fi
  if ! fi_af_cap_ok spot "$(fi_af_int dailyFixes 5)"; then fi_af_unlock "$id"; return 3; fi
  # Resolve the landing branch now so the wait check and the worktree cut
  # (fi_af_worktree_add reuses AFI_base) look at the same branch.
  fi_af_landing_branch
  local wrc=0
  _fi_af_wait_check "$q" || wrc=$?
  case $wrc in
    5) fi_af_retire "$id" stale "$FI_AF_WHY" || fi_af_unlock "$id"; return 5 ;;
    8) fi_af_unlock "$id"; fi_af_log "$id" "waiting: $FI_AF_WHY"; return 8 ;;
  esac
  # Move to running/ FIRST, then stamp the running file: fi_af_item_set on the
  # queue file checks it and later mv's its tmp copy over it, so a cancel that
  # moved the item away in between would have the stamp recreate queue/<id>
  # and ship an item cancel reported as cancelled. A lost mv means exactly
  # that cancel won.
  mv "$q" "$r" || { fi_af_unlock "$id"; return 1; }
  # The wait is over: clear its clock too, or the next wait of a requeued
  # item would start from this one's wait_since and retire stale at once.
  fi_af_item_set "$r" waiting ""
  fi_af_item_set "$r" wait_since ""
  fi_af_item_set "$r" wait_next ""
  # Launcher A's run passes its own long-lived pid. A standalone claim is an
  # in-session fixer (launcher B): its claim process exits at once, so there
  # is no pid to record. The repo lock, refreshed by every B-side call, is
  # what keeps the item from being reaped (ledger lib/autofix-queue.sh:263).
  fi_af_item_set "$r" pid "${FI_AF_PID:-}"
  if [[ -n "${FI_AF_PID:-}" ]]; then fi_af_item_set "$r" launcher A; else fi_af_item_set "$r" launcher B; fi
  fi_af_seg_write "$AFI_root"
  if ! fi_af_worktree_add; then
    # A fetch or worktree failure is usually transient (network, a busy
    # index): give the item back to the queue, at most 3 times in a row, and
    # fail it as before only after that. A requeue spends no daily slot.
    local tries
    tries="$(_fi_af_field "$r" wt_retries)" || tries=0
    [[ "$tries" =~ ^[0-9]+$ ]] || tries=0
    if (( tries < 3 )); then
      local why="$FI_AF_WHY"
      fi_af_item_set "$r" wt_retries "$(( tries + 1 ))"
      # Spaced like a wait (the drain and the Stop hook skip it until
      # wait_next), so three retries outlast a short outage.
      fi_af_item_set "$r" waiting "$why"
      fi_af_item_set "$r" wait_next "$(( $(date +%s) + ${FOUND_ISSUES_AUTOFIX_WAIT_RECHECK:-900} ))"
      fi_af_worktree_remove
      fi_af_requeue "$id" "$why; retry $(( tries + 1 )) of 3"
      FI_AF_WHY="$why; requeued, retry $(( tries + 1 )) of 3"
      return 8
    fi
    fi_af_cap_take spot "$id"
    fi_af_finish "$id" failed "$FI_AF_WHY"
    return 6
  fi
  fi_af_cap_take spot "$id"
  fi_af_item_set "$r" wt_retries ""
  fi_af_item_set "$r" wt "$AFI_wt"
  fi_af_item_set "$r" branch "$AFI_branch"
  fi_af_item_set "$r" base "$AFI_base"
  fi_af_item_set "$r" base_why "$AFI_base_why"
  fi_af_item_set "$r" base_sha "$AFI_base_sha"
  fi_af_log "$id" "claimed: $AFI_wt ($AFI_branch from origin/$AFI_base: $AFI_base_why)"
  if ! fi_af_base_tests "$id"; then
    FI_AF_WHY="${FI_AF_BASE_WHY:-tests fail at base}"
    fi_af_finish "$id" stale "$FI_AF_WHY"
    return 5
  fi
}

# Give a claimed item back to the queue untouched (an engine outage): no
# ledger tag and no attempt counted, so the next trigger retries it.
fi_af_requeue() {
  local id="$1" r="$FI_AF_ST/running/$1"
  fi_af_item_read "$r" || return 1
  fi_af_worktree_remove
  fi_af_item_set "$r" pid ""
  fi_af_item_set "$r" pr ""
  # A queued item resolves its landing branch fresh at its next claim and
  # starts B's attempt count and verdict over; a ship retry keeps the base
  # its kept branch was cut from and the approved tree the ship re-checks.
  if [[ ! "${AFI_ship_tries:-0}" =~ ^[1-9] ]]; then
    fi_af_item_set "$r" base ""
    fi_af_item_set "$r" base_why ""
    _fi_af_clear_attempts "$r"
  fi
  mv "$r" "$FI_AF_ST/queue/$id"
  fi_af_seg_write "$AFI_root"
  fi_af_unlock "$id"
  fi_af_log "$id" "requeued: $2"
}

# Retag the entry in the source checkout's ledger.
fi_af_ledger_tag() {
  fi_af_find_entry || return 1
  fi_tag_resolve "$1" "$2" "" "" || return 2
  fi_tag_apply "$FI_AF_LEDGER" "$FI_AF_ENTRY" "$FI_TAG_KIND" "$FI_TAG_VALUE" >/dev/null
}

# Replace the first line equal to <old> with <new>, serialized like every
# ledger write: 0 written, 1 line gone, 3 ledger changed underneath.
_fi_af_ledger_swap() {
  local file="$1" old="$2" new="$3" snapshot tmp line done_one=0
  snapshot="$(fi_ledger_snapshot "$file")"
  tmp="$(fi_ledger_tmp "$file")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if (( ! done_one )) && [[ "$line" == "$old" ]]; then
      printf '%s\n' "$new" >>"$tmp"; done_one=1
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$file"
  (( done_one )) || { rm -f "$tmp"; return 1; }
  fi_ledger_replace "$file" "$tmp" "$snapshot"
}

# Already fixed at origin: close it the way `resolve` does.
fi_af_ledger_resolve() {
  fi_af_find_entry || return 1
  _fi_af_ledger_swap "$FI_AF_LEDGER" "$FI_AF_ENTRY" \
    "- [fixed]${FI_AF_ENTRY#- \[open\]} (verified: ai) (fixed: $(fi_today))"
}

# The ledger side of an outcome for the loaded entry (AFI_key): resolve,
# retag or nothing. rc 2 for an unknown outcome.
_fi_af_ledger_outcome() {
  case "$1" in
    already-fixed) fi_af_ledger_resolve ;;
    decide|manual) fi_af_ledger_tag "$1" "$2" ;;
    failed)        fi_af_ledger_tag autofix-failed "$2" ;;
    shipped|stale|skipped) return 0 ;;
    *) fi_err "autofix: unknown outcome $1"; return 2 ;;
  esac
}

# Spec §5 steps 2, 4 and 7: end an item with an outcome. The ledger write is
# best effort — the item always leaves running/, so it never wedges the lock.
# A sweep item has no entry of its own (phase 4 ruling 7): its entries were
# settled one by one.
fi_af_finish() {
  local id="$1" outcome="$2" text="$3" f="$FI_AF_ST/running/$1" rc=0
  [[ -f "$f" ]] || f="$FI_AF_ST/queue/$id"
  fi_af_item_read "$f" || { fi_err "autofix: no queued or running item $id"; return 1; }
  text="${text//$'\n'/ }"
  text="${text:0:160}"
  case "$outcome" in
    already-fixed|decide|manual|failed|shipped|stale) ;;
    *) fi_err "autofix: unknown outcome $outcome"; return 2 ;;
  esac
  if [[ "$AFI_kind" != "sweep" ]]; then
    _fi_af_ledger_outcome "$outcome" "$text" || rc=$?
  fi
  (( rc == 0 )) || fi_af_log "$id" "ledger not updated for $outcome (rc $rc)"
  if [[ "$outcome" == shipped ]]; then fi_af_worktree_remove drop; else fi_af_worktree_remove; fi
  fi_af_retire "$id" "$outcome" "$text"
}
