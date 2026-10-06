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
AFI_base_why="" AFI_waiting="" AFI_wait_since="" AFI_wait_next="" AFI_ship_tries="0"

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
  AFI_base_why="" AFI_waiting="" AFI_wait_since="" AFI_wait_next="" AFI_ship_tries="0"
  [[ -f "$1" ]] || return 1
  local line k
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}"
    case "$k" in
      id|kind|root|slug|loc|key|entry|engine|queued|crashes|pid|wt|branch|base|result|pr|cost|tokens|base_sha|launcher|launched|attempts|verdict|verdict_reason|verdict_tree|head|cur|fixed|cpgid|finished|base_why|waiting|wait_since|wait_next|ship_tries)
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
  local id="$1" lock="$FI_AF_ST/lock" now age owner="" opid=""
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$id" >"$lock/owner"; return 0
  fi
  [[ -f "$lock/owner" ]] && { IFS= read -r owner <"$lock/owner" || true; }
  if [[ -n "$owner" ]]; then
    opid="$(_fi_af_field "$FI_AF_ST/running/$owner" pid)" || opid=""
  fi
  if [[ ! "$opid" =~ ^[1-9][0-9]*$ ]] || kill -0 "$opid" 2>/dev/null; then
    now="$(date +%s)"
    age=$(( now - $(fi_file_mtime "$lock") ))
    (( age >= ${FOUND_ISSUES_AUTOFIX_LOCK_STALE:-3600} )) || return 1
  fi
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

# 3.2.0 (spec section 1): the branch a fix starts from and lands into is the
# one the session works on, never assumed to be the default branch. Sets
# AFI_base and AFI_base_why; every fallback is the default branch.
fi_af_landing_branch() {
  local def cur up b n best="" bestn="" base
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
    if git -C "$AFI_root" ls-remote --exit-code --heads origin "$up" >/dev/null 2>&1; then
      AFI_base="$up" AFI_base_why="tracks origin/$up"; return 0
    fi
    base="$(cd "$AFI_root" && gh pr list --repo "${AFI_slug:-$(fi_repo_id 2>/dev/null)}" --head "$up" --state merged --limit 1 \
      --json baseRefName --jq '.[0].baseRefName // ""' 2>/dev/null || true)"
    if [[ -n "$base" ]] && git -C "$AFI_root" ls-remote --exit-code --heads origin "$base" >/dev/null 2>&1; then
      AFI_base="$base" AFI_base_why="$up merged into $base"; return 0
    fi
    AFI_base_why="$up gone, base unknown"; return 0
  fi
  git -C "$AFI_root" fetch -q origin 2>/dev/null || true
  while IFS= read -r b || [[ -n "$b" ]]; do
    b="${b#origin/}"
    [[ -n "$b" && "$b" != HEAD && "$b" != fi/* ]] || continue
    git -C "$AFI_root" ls-remote --exit-code --heads origin "$b" >/dev/null 2>&1 || continue
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
  local id="$1" t rc=0 log="$FI_AF_RUNS/$1.base-tests.log"
  t="$(fi_af_test_command "$AFI_wt" 2>/dev/null)" || return 0
  fi_af_run_tests "$AFI_wt" "$t" "$log" || rc=$?
  git -C "$AFI_wt" reset -q --hard "${AFI_base_sha:-HEAD}" >/dev/null 2>&1 || true
  git -C "$AFI_wt" clean -qfd >/dev/null 2>&1 || true
  (( rc == 0 )) && return 0
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
  fi_af_unlock "$id"
  fi_af_log "$id" "$outcome: $text"
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
    if [[ -n "$AFI_pid" ]] && kill -0 "$AFI_pid" 2>/dev/null; then continue; fi
    fi_af_worktree_remove
    if (( ${AFI_crashes:-0} < 1 )); then
      fi_af_item_set "$f" crashes 1
      fi_af_item_set "$f" pid ""
      # The dead run's PR number would make cancel refuse the re-run.
      fi_af_item_set "$f" pr ""
      # Back in the queue: the landing branch resolves fresh at re-claim,
      # except for a ship retry, whose kept branch was cut from this base.
      if [[ ! "${AFI_ship_tries:-0}" =~ ^[1-9] ]]; then
        fi_af_item_set "$f" base ""
        fi_af_item_set "$f" base_why ""
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
  git -C "$AFI_root" fetch -q origin "$AFI_base" 2>/dev/null || return 0
  if ! git -C "$AFI_root" cat-file -e "origin/$AFI_base:$p" 2>/dev/null; then
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
  # The wait is over: clear its clock too, or the next wait of a requeued
  # item would start from this one's wait_since and retire stale at once.
  fi_af_item_set "$q" waiting ""
  fi_af_item_set "$q" wait_since ""
  fi_af_item_set "$q" wait_next ""
  # Launcher A's run passes its own long-lived pid. A standalone claim is an
  # in-session fixer (launcher B): its claim process exits at once, so there
  # is no pid to record. The repo lock, refreshed by every B-side call, is
  # what keeps the item from being reaped (ledger lib/autofix-queue.sh:263).
  fi_af_item_set "$q" pid "${FI_AF_PID:-}"
  if [[ -n "${FI_AF_PID:-}" ]]; then fi_af_item_set "$q" launcher A; else fi_af_item_set "$q" launcher B; fi
  mv "$q" "$r" || { fi_af_unlock "$id"; return 1; }
  fi_af_seg_write "$AFI_root"
  fi_af_cap_take spot "$id"
  if ! fi_af_worktree_add; then
    fi_af_finish "$id" failed "$FI_AF_WHY"
    return 6
  fi
  fi_af_item_set "$r" wt "$AFI_wt"
  fi_af_item_set "$r" branch "$AFI_branch"
  fi_af_item_set "$r" base "$AFI_base"
  fi_af_item_set "$r" base_why "$AFI_base_why"
  fi_af_item_set "$r" base_sha "$AFI_base_sha"
  fi_af_log "$id" "claimed: $AFI_wt ($AFI_branch from origin/$AFI_base: $AFI_base_why)"
  if ! fi_af_base_tests "$id"; then
    FI_AF_WHY="tests fail at base"
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
  # A queued item resolves its landing branch fresh at its next claim; a
  # ship retry keeps the base its kept branch was cut from.
  if [[ ! "${AFI_ship_tries:-0}" =~ ^[1-9] ]]; then
    fi_af_item_set "$r" base ""
    fi_af_item_set "$r" base_why ""
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
    shipped|stale) return 0 ;;
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
