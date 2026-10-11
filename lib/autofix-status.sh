#!/usr/bin/env bash
# autofix-status.sh — v3 auto-fix visibility and control: cancel, status,
# the statusline state file, the SessionStart summary and the doctor section
# (spec 2026-10-03 §8; phase 5 plan rulings 1-6, 9).
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   fi_af_cancel <id>
#   fi_af_status
#   fi_af_seg_write <root> / fi_af_seg_refresh
#   fi_af_stuck_update <root> <outcome> <text> <id> / fi_af_stuck_line
#   fi_af_summary [--peek]
#   fi_af_doctor <pass> <warn> <fail> <gh-user>

# shellcheck disable=SC2154  # AFI_*/FI_AF_* come from autofix-queue.sh / autofix-config.sh

# A pid we may signal: alive, running `found-issues ... autofix run`, and the
# very process the item recorded. Any live autofix run matches the command, so
# the start time stamped with the pid (fi_af_item_set) is what ties it to THIS
# item's state dir: a run from another state dir, or a pid the OS reused, has a
# different start time. Where ps cannot print a start time (Git Bash) the
# command match alone decides.
_fi_af_is_run_pid() {
  local cmd
  [[ "$1" =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null || return 1
  cmd="$(ps -o command= -p "$1" 2>/dev/null || true)"
  [[ "$cmd" == *found-issues*"autofix run"* ]] || return 1
  _fi_af_pstart "$1"
  _fi_af_pstart_same "$FI_AF_PSTART" "${2:-}"
}

# Phase 5 ruling 6: retire a queued or running item as cancelled, stopping
# an A run and its engine child first. No ledger write.
fi_af_cancel() {
  local id="$1" r="$FI_AF_ST/running/$1" q="$FI_AF_ST/queue/$1" d="$FI_AF_ST/done/$1" n=0 how owner=""
  if [[ -f "$d" ]]; then fi_err "autofix: $id already finished"; return 1; fi
  # One atomic move out of the queue (review I6): a claim that wins the race
  # has moved the item to running/, which the branch below handles; never a
  # running-first retire that would unlock the claimer's live run.
  if [[ -f "$q" ]] && mv "$q" "$d" 2>/dev/null; then
    how="by autofix cancel while queued"
    fi_af_item_set "$d" result "cancelled: $how" || true
    fi_af_item_set "$d" finished "$(date +%s)" || true
    fi_af_log "$id" "cancelled: $how"
    printf 'Cancelled %s (it was queued).\n' "$id"
    # A ship retry's verified commits live only on its kept branch (3.2.1).
    if [[ "$(_fi_af_field "$d" ship_tries)" =~ ^[1-9] ]]; then
      printf 'Its fixes stay on branch %s (delete it with git branch -D when no longer wanted).\n' "$(_fi_af_field "$d" branch)"
    fi
    return 0
  fi
  [[ -f "$r" ]] || { fi_err "autofix: no queued or running item $id"; return 1; }
  fi_af_item_read "$r" || true
  # A PR that is open is already arming or armed to merge itself (review I4).
  if [[ -n "$AFI_pr" ]]; then
    fi_err "autofix: $id already opened PR #$AFI_pr, which merges itself; to stop it: gh pr close $AFI_pr --repo $AFI_slug"
    return 1
  fi
  how="by autofix cancel (in-session fixer)"
  # Signal only the run that owns this item now (review I3): a drain that
  # moved on to another item keeps the same pid but owns the lock under
  # that item's id.
  [[ -f "$FI_AF_ST/lock/owner" ]] && { IFS= read -r owner <"$FI_AF_ST/lock/owner" || true; }
  if [[ "$owner" == "$id" ]]; then
    if _fi_af_is_run_pid "$AFI_pid" "$AFI_pstart"; then
      how="by autofix cancel (background run $AFI_pid stopped)"
      kill -TERM "$AFI_pid" 2>/dev/null || true
      while kill -0 "$AFI_pid" 2>/dev/null && (( n < 40 )); do sleep 0.25; n=$((n + 1)); done
      kill -KILL "$AFI_pid" 2>/dev/null || true
    fi
    if [[ "$AFI_cpgid" =~ ^[0-9]+$ ]]; then
      kill -TERM -- "-$AFI_cpgid" 2>/dev/null || true
    fi
  fi
  # The run may have finished the item while it was stopping.
  if [[ ! -f "$r" ]]; then fi_err "autofix: $id already finished"; return 1; fi
  fi_af_item_read "$r" || true
  fi_af_worktree_remove
  if [[ -n "$AFI_pr" ]]; then
    how="$how; PR #$AFI_pr was already open"
    fi_err "autofix: PR #$AFI_pr was opened before the run stopped; to stop it: gh pr close $AFI_pr --repo $AFI_slug"
  fi
  fi_af_retire "$id" cancelled "$how"
  printf 'Cancelled %s.\n' "$id"
}

FI_AF_PRNUM=""
# The PR number of the loaded item: its pr field, else "PR #N" in its result.
_fi_af_pr_num() {
  FI_AF_PRNUM="$AFI_pr"
  if [[ -z "$FI_AF_PRNUM" && "$AFI_result" =~ PR\ \#([0-9]+) ]]; then FI_AF_PRNUM="${BASH_REMATCH[1]}"; fi
  return 0
}

_fi_af_count_lines() {
  local n=0 line
  if [[ -f "$1" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do n=$((n + 1)); done <"$1"
  fi
  printf '%s' "$n"
}

# 3.3.0: the location column; a continuation batch of a sweep says which.
_fi_af_loc_label() {
  if [[ "${AFI_kind:-}" == "sweep" && "${AFI_cont:-}" =~ ^[0-9]+$ ]] && (( 10#$AFI_cont >= 2 )); then
    printf 'sweep (batch %s)' "$((10#$AFI_cont))"
  else
    printf '%s' "${AFI_loc:-sweep}"
  fi
}

# 3.3.0: a Codex item's tokens, against its cap when one is set. A
# continuation's cap covers the whole chain, so its row shows the chain's
# total (the batches before it plus its own) marked "(chain)"; the sums of
# what was spent (spent today, the summary) stay on each item's own tokens.
_fi_af_tokens_row() {
  local cap own="${AFI_tokens:-0}" total chain=""
  [[ "${AFI_engine:-}" == codex ]] || return 0
  [[ "$own" =~ ^[0-9]+$ ]] || own=0
  total="$own"
  if [[ "${AFI_chain_tokens:-}" =~ ^[0-9]+$ ]]; then
    total=$(( AFI_chain_tokens + own )) chain=" (chain)"
  fi
  (( total > 0 )) || return 0
  cap="$(fi_af_token_cap)"
  printf '      %s%s tokens%s\n' "$total" "${cap:+/$cap}" "$chain"
}

# Spec §8: queue, running, today's counts against caps, decisions waiting,
# recent results with PR links and cost.
fi_af_status() {
  local f n dir label count today midnight spent=0.00 file
  if fi_af_enabled; then printf 'Auto-fix: on (%s)\n' "$FI_AF_SLUG"
  else printf 'Auto-fix: off — %s\n' "$FI_AF_WHY"; fi
  # A run that died (SIGKILL, sleep) is reaped here too, so status and the
  # statusline stop calling it running. Never steals a live lock.
  if fi_af_lock "status-$$"; then fi_af_reap; fi_af_unlock "status-$$"; fi
  fi_af_seg_refresh
  today="$(fi_today)"
  printf 'Today: %s/%s spot fixes\n' "$(_fi_af_count_lines "$FI_AF_ST/day/$today.spot")" "$(fi_af_int dailyFixes 5)"
  printf 'Today: %s/%s sweeps\n' "$(_fi_af_count_lines "$FI_AF_ST/day/$today.sweep")" "$(fi_af_int dailySweeps 1)"
  [[ -e "$FI_AF_ST/day/$today.capped" ]] && printf 'Capped for today: queued items wait for tomorrow.\n'
  for dir in running queue; do
    count=0
    for f in "$FI_AF_ST/$dir"/*; do [[ -f "$f" ]] && count=$((count + 1)); done
    label="Queued"; [[ "$dir" == running ]] && label="Running"
    printf '%s (%s)\n' "$label" "$count"
    for f in "$FI_AF_ST/$dir"/*; do
      [[ -f "$f" ]] || continue
      fi_af_item_read "$f" || true
      if [[ "$dir" == running ]]; then
        printf '  %s  %s  %s (launcher %s)\n' "$AFI_id" "${AFI_kind:-spot}" "$(_fi_af_loc_label)" "${AFI_launcher:-?}"
        if [[ -n "$AFI_base" ]]; then printf '      into %s (%s)\n' "$AFI_base" "${AFI_base_why:-?}"; fi
        _fi_af_tokens_row
      else
        printf '  %s  %s  %s\n' "$AFI_id" "${AFI_kind:-spot}" "$(_fi_af_loc_label)"
        if [[ -n "$AFI_waiting" ]]; then printf '      waiting: %s\n' "$AFI_waiting"; fi
      fi
      if [[ -n "$AFI_rescued" ]]; then printf '      commits kept on local branch %s\n' "$AFI_rescued"; fi
    done
  done
  file="$(fi_find_issues_file "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" 2>/dev/null || true)"
  if [[ -n "$file" ]]; then
    n="$(fi_count_decide "$file")"
    (( n > 0 )) && printf 'Decisions waiting: %s — answer with found-issues decide\n' "$n"
  fi
  # BSD date fills unspecified fields from the current time: pass midnight.
  midnight="$(date -j -f '%Y-%m-%d %H:%M:%S' "$today 00:00:00" +%s 2>/dev/null \
    || date -d "$today" +%s 2>/dev/null || echo 0)"
  printf 'Recent:\n'
  local -a rows=()
  for f in "$FI_AF_ST"/done/*; do
    [[ -f "$f" ]] || continue
    fi_af_item_read "$f" || true
    [[ "$AFI_finished" =~ ^[0-9]+$ ]] || AFI_finished=0
    rows+=("$AFI_finished $f")
    if (( AFI_finished >= midnight )) && [[ "$AFI_cost" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      spent="$(awk -v a="$spent" -v b="$AFI_cost" 'BEGIN { printf "%.2f", a + b }')"
    fi
  done
  if (( ${#rows[@]} > 0 )); then
    # Newest first by finished stamp (items from before phase 5 sort as 0).
    while IFS= read -r f || [[ -n "$f" ]]; do
      fi_af_item_read "${f#* }" || true
      printf '  %s  %s — %s\n' "$AFI_id" "$(_fi_af_loc_label)" "$AFI_result"
      if [[ -n "$AFI_base" ]]; then printf '      into %s (%s)\n' "$AFI_base" "${AFI_base_why:-?}"; fi
      # A crashed run's unshipped commits (ledger lib/autofix-queue.sh:583).
      if [[ -n "$AFI_rescued" ]]; then printf '      commits kept on local branch %s\n' "$AFI_rescued"; fi
      _fi_af_tokens_row
      _fi_af_pr_num
      if [[ -n "$FI_AF_PRNUM" ]]; then
        printf '      https://github.com/%s/pull/%s' "${AFI_slug:-$FI_AF_SLUG}" "$FI_AF_PRNUM"
        [[ -n "$AFI_cost" && "$AFI_cost" != 0 ]] && printf '  ($%s)' "$AFI_cost"
        printf '\n'
      fi
    done < <(printf '%s\n' "${rows[@]}" | sort -rn | head -n 5)
  fi
  printf 'Spent today: $%s (Claude Code estimate; Codex runs report $0)\n' "$spent"
  return 0
}

# Phase 5 ruling 1: the statusline reads runs in progress from one small
# file per repo root, written here on every move in or out of running/.
# The name is the physical root (git's toplevel), sanitized like the
# segment cache's; lib/segment-cache.sh reads it with builtins only.
fi_af_seg_write() {
  local root="$1" f n=0 name dir
  [[ -n "$root" && -n "$FI_AF_ST" ]] || return 0
  fi_af_root
  for f in "$FI_AF_ST"/running/*; do
    [[ -f "$f" ]] || continue
    [[ "$(_fi_af_field "$f" root 2>/dev/null)" == "$root" ]] && n=$((n + 1))
  done
  fi_af_root_key "$root"; name="$FI_AF_KEY"
  dir="$FI_AF_ROOT/seg"
  if (( n == 0 )); then rm -f "$dir/$name" 2>/dev/null; return 0; fi
  mkdir -p "$dir" 2>/dev/null || return 0
  if printf '%s\n' "$n" >"$dir/$name.$$" 2>/dev/null; then
    mv -f "$dir/$name.$$" "$dir/$name" 2>/dev/null || rm -f "$dir/$name.$$"
  fi
  return 0
}

# 3.8.0 (ledger lib/autofix-queue.sh:345): when every item retires "stale:
# tests fail at base" day after day, nothing outside `autofix status` said
# auto-fix was stuck. The streak per repo (keyed by its main worktree, so
# linked worktrees share it; consecutive items retired that
# way; only a green base resets it) lives in autofix/stuck/<root>: line 1 the
# count, line 2 the first failing test names, line 3 the epoch of the last
# base failure, line 4 the repo root (3.8.1, for the --global clear). Written at retire time so the statusline (lib/segment-cache.sh,
# which owns FI_AF_STUCK_AFTER, the key and the reader) and SessionStart only
# read a tiny file. It also clears when the base is found green, when
# auto-fix is switched off, and once its last failure is a week old.
fi_af_stuck_update() {
  local root="$1" outcome="$2" text="$3" id="$4" dir f n=0 names="" fresh="" line p count=0
  [[ -n "$root" ]] || return 0
  fi_af_root
  dir="$FI_AF_ROOT/stuck"
  fi_af_stuck_key "$root"
  f="$dir/$FI_AF_KEY"
  # Only a base found green ends the streak (fi_af_base_tests clears it):
  # a cancel, a prune or a no-longer-eligible retire says nothing about the
  # base, so it neither counts nor resets.
  [[ "$outcome" == stale && "$text" == "tests fail at base" ]] || return 0
  if fi_af_stuck_read "$f"; then
    n="$FI_AF_STUCK_N" names="$FI_AF_STUCK_NAMES"
    # A streak whose last failure is over a week old has aged out: start again.
    if [[ "$FI_AF_STUCK_TS" =~ ^[0-9]+$ ]]; then
      fi_af_now
      (( FI_AF_NOW - 10#$FI_AF_STUCK_TS <= FI_AF_STUCK_MAX_AGE )) || { n=0; names=""; }
    fi
  fi
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  n=$((10#$n + 1))
  # Names come from this item's own base-test log; a base known red from an
  # earlier item has no new log, so the names already recorded stay.
  if [[ -n "${FI_AF_RUNS:-}" && -f "$FI_AF_RUNS/$id.base-tests.log" ]] && declare -F fi_af_test_failures >/dev/null; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        "not ok "*) p="${line#not ok }"; p="${p#[0-9]* }" ;;
        "FAILED "*) p="${line#FAILED }" ;;
        "--- FAIL: "*) p="${line#--- FAIL: }" ;;
        "FAIL "*) p="${line#FAIL }" ;;
        *) continue ;;
      esac
      p="${p//[^A-Za-z0-9 ._:\/#()-]/}"
      p="${p:0:60}"
      [[ -n "$p" ]] || continue
      fresh+="${fresh:+, }$p"
      count=$((count + 1))
      (( count < 3 )) || break
    done < <(fi_af_test_failures "$FI_AF_RUNS/$id.base-tests.log" 2>/dev/null)
    [[ -z "$fresh" ]] || names="$fresh"
  fi
  mkdir -p "$dir" 2>/dev/null || return 0
  fi_af_now
  if printf '%s\n%s\n%s\n%s\n' "$n" "$names" "$FI_AF_NOW" "${FI_AF_STUCK_ROOT:-$root}" >"$f.$$" 2>/dev/null; then
    mv -f "$f.$$" "$f" 2>/dev/null || rm -f "$f.$$"
  fi
  return 0
}

# Drop the stuck marker of one repo root, or of every repo (no argument).
# --global (config autofix false --global) keeps the marker of a repo whose
# own setting still turns auto-fix on there (ledger lib/autofix-config.sh:409),
# or whose config git cannot read; a file whose repo is gone, or from before
# 3.8.1 (no root line), is dropped.
fi_af_stuck_clear() {
  local f r
  fi_af_root
  if [[ "${1:-}" == --global ]]; then
    for f in "$FI_AF_ROOT"/stuck/*; do
      [[ -f "$f" ]] || continue
      r=""
      { IFS= read -r _; IFS= read -r _; IFS= read -r _; IFS= read -r r; } <"$f" 2>/dev/null || true
      if [[ -n "$r" && -d "$r" ]]; then
        # Config that cannot be read (safe.directory, a moved .git) keeps it.
        git -C "$r" rev-parse --git-dir >/dev/null 2>&1 || continue
        fi_af_repo_cfg "$r"
        [[ "$FI_AF_RC_ON" == true ]] && continue
      fi
      rm -f "$f" 2>/dev/null
    done
  elif [[ -n "${1:-}" ]]; then
    fi_af_stuck_key "$1"
    rm -f "$FI_AF_ROOT/stuck/$FI_AF_KEY" 2>/dev/null
  else
    rm -f "$FI_AF_ROOT"/stuck/* 2>/dev/null
  fi
  return 0
}

# The SessionStart line for a repo whose auto-fix is stuck (empty otherwise).
# Fixed text plus bash-sanitized test names: no model text reaches it.
fi_af_stuck_line() {
  local root s
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  fi_af_root
  fi_af_stuck_key "$root"
  fi_af_stuck_active "$FI_AF_ROOT/stuck/$FI_AF_KEY" || return 0
  s="Auto-fix is STUCK in this repo: the last $((10#$FI_AF_STUCK_N)) items all retired with tests failing at base, so nothing is being fixed."
  [[ -n "$FI_AF_STUCK_NAMES" ]] && s+=" First failing: $FI_AF_STUCK_NAMES."
  s+=" Fix the base suite; if its tests read gitignored local files, list them in git config found-issues.autofix.worktreeFiles. Details: found-issues autofix status."
  printf '%s\n' "$s"
}

# Recount this repo's roots: drop their files, rewrite those still running.
fi_af_seg_refresh() {
  local f root
  fi_af_root
  for f in "$FI_AF_ST"/done/* "$FI_AF_ST"/queue/* "$FI_AF_ST"/running/*; do
    [[ -f "$f" ]] || continue
    root="$(_fi_af_field "$f" root 2>/dev/null || true)"
    if [[ -n "$root" ]]; then fi_af_root_key "$root"; rm -f "$FI_AF_ROOT/seg/$FI_AF_KEY" 2>/dev/null; fi
  done
  for f in "$FI_AF_ST"/running/*; do
    [[ -f "$f" ]] && fi_af_seg_write "$(_fi_af_field "$f" root 2>/dev/null || true)"
  done
  return 0
}

# Phase 5 rulings 3-4: what finished since the last interactive session, for
# SessionStart. The stamp moves BEFORE printing, so two sessions starting
# together show it once. The stamp is the newest `finished` value seen, plus
# the ids shown in that second (seen.ids), so an item finishing mid-scan still
# shows next time, once. A done file whose mtime is over 60 s older than the
# stamp is skipped unread (an item's file is written at or after its finished
# time, and done/ only grows); one stat call covers every file. Failure reasons keep only the
# bash-authored prefix (text before the first ':' or '('): model text never
# reaches the line.
fi_af_summary() {
  local peek="${1:-}" seen=0 f fixed=0 failed=0 prs="" reasons="" r cost=0 dec=0 file s newest n
  local seen_ids="" newest_ids="" id mt="" line m stuck=""
  local -a files=() scan=()
  # An empty or newline-less stamp makes read return 1: that is not an error.
  [[ -f "$FI_AF_ST/seen" ]] && { IFS= read -r seen <"$FI_AF_ST/seen" || true; }
  [[ "$seen" =~ ^[0-9]+$ ]] || seen=0
  # Ids already shown whose finished second equals the stamp: an item stamped
  # in that same second but moved to done/ after the scan still shows once.
  [[ -f "$FI_AF_ST/seen.ids" ]] && { IFS= read -r seen_ids <"$FI_AF_ST/seen.ids" || true; }
  newest="$seen"
  for f in "$FI_AF_ST"/done/*; do [[ -f "$f" ]] && files+=("$f"); done
  (( ${#files[@]} > 0 )) || return 0
  # One stat for every file (GNU form first, BSD second); without a usable
  # answer every file is read, as before.
  mt="$(stat -c '%Y %n' -- "${files[@]}" 2>/dev/null || true)"
  [[ "$mt" =~ ^[0-9]+\  ]] || mt="$(stat -f '%m %N' -- "${files[@]}" 2>/dev/null || true)"
  if [[ "$mt" =~ ^[0-9]+\  ]]; then
    while IFS= read -r line; do
      m="${line%% *}"
      [[ "$m" =~ ^[0-9]+$ ]] && (( m + 60 >= seen )) && scan+=("${line#* }")
    done <<< "$mt"
  else
    scan=("${files[@]}")
  fi
  for f in ${scan[@]+"${scan[@]}"}; do
    [[ -f "$f" ]] || continue
    fi_af_item_read "$f" || true
    [[ "$AFI_finished" =~ ^[0-9]+$ ]] || continue
    id="${f##*/}"
    (( AFI_finished >= seen )) || continue
    (( AFI_finished == seen )) && [[ " $seen_ids " == *" $id "* ]] && continue
    case "$AFI_result" in
      shipped:*)
        n=1
        # A sweep ships several fixes in one PR; AFI_fixed holds its count.
        if [[ "$AFI_kind" == sweep && "$AFI_fixed" =~ ^[0-9]+$ ]] && (( AFI_fixed > 0 )); then n="$AFI_fixed"; fi
        fixed=$((fixed + n)); _fi_af_pr_num
        [[ -n "$FI_AF_PRNUM" ]] && prs+="${prs:+, }#$FI_AF_PRNUM" ;;
      failed:*)
        failed=$((failed + 1))
        r="${AFI_result#failed: }"; r="${r%%:*}"; r="${r%%(*}"
        r="${r//[^A-Za-z0-9 ._-]/}"; r="${r:0:40}"
        while [[ "$r" == *" " ]]; do r="${r% }"; done
        # Only reasons bash writes (review I5): `autofix release --failed`
        # stores a fixer's own words, which must not reach the directive.
        case "$r" in
          "verifier rejected"|"tests fail after 2 attempts"|"no change after 2 attempts"|ship|commit|crashed|\
          "run budget spent"|"no claude on PATH"|"no codex on PATH"|"no claude or codex on PATH"|\
          "git fetch failed"|"git worktree add failed") ;;
          *) r="see autofix status" ;;
        esac
        [[ -n "$r" && "; $reasons; " != *"; $r; "* ]] && reasons+="${reasons:+; }$r" ;;
      *) continue ;;
    esac
    if (( AFI_finished > newest )); then newest="$AFI_finished"; newest_ids="$id"
    elif (( AFI_finished == newest )); then newest_ids+="${newest_ids:+ }$id"; fi
    [[ "$AFI_cost" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
      && cost="$(awk -v a="$cost" -v b="$AFI_cost" 'BEGIN { printf "%.2f", a + b }')"
  done
  stuck="$(fi_af_stuck_line)"
  if (( fixed + failed == 0 )); then
    [[ -n "$stuck" ]] && printf '%s\n' "$stuck"
    return 0
  fi
  if [[ "$peek" != --peek ]]; then
    # Still at the old stamp: keep the ids already shown in that second.
    (( newest == seen )) && newest_ids="${seen_ids}${seen_ids:+${newest_ids:+ }}${newest_ids}"
    printf '%s\n' "$newest" >"$FI_AF_ST/seen" 2>/dev/null || true
    printf '%s\n' "$newest_ids" >"$FI_AF_ST/seen.ids" 2>/dev/null || true
  fi
  file="$(fi_find_issues_file "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" 2>/dev/null || true)"
  [[ -n "$file" ]] && dec="$(fi_count_decide "$file")"
  s="Since last session: fixed $fixed"
  [[ -n "$prs" ]] && s+=" (PR $prs)"
  (( failed > 0 )) && s+=", $failed failed${reasons:+ ($reasons)}"
  if (( dec == 1 )); then s+=", 1 decision waiting"; elif (( dec > 1 )); then s+=", $dec decisions waiting"; fi
  [[ "$cost" != 0 && "$cost" != 0.00 ]] && s+=" — \$$cost spent"
  printf '%s.\n' "$s"
  [[ -z "$stuck" ]] || printf '%s\n' "$stuck"
}

# 3.3.0: the dollar cap doctor reports is the value fi_af_budget accepts, not
# the raw setting: a set value the engine ignores ("3usd") is called out.
# $1 = run | sweep.
_fi_af_doctor_budget() {
  local key=runBudget raw v
  [[ "$1" == sweep ]] && key=sweepBudget
  raw="$(fi_af_cfg "$key" "")"
  if [[ -z "$raw" ]]; then printf 'no dollar cap per %s' "$1"; return 0; fi
  if [[ "$1" == sweep ]]; then v="$(AFI_kind=sweep fi_af_budget 2>/dev/null)"; else v="$(AFI_kind="" fi_af_budget 2>/dev/null)"; fi
  if [[ -n "$v" ]]; then printf '$%s per %s' "$v" "$1"; return 0; fi
  printf "invalid %s '%s' (ignored: no dollar cap)" "$key" "$raw"
}

# Phase 5 ruling 9: auto-fix readiness at a glance, on or off (spec §8).
fi_af_doctor() {
  local p="$1" w="$2" x="$3" gh_user="$4" e v rb sb rt st r
  git rev-parse --show-toplevel >/dev/null 2>&1 || return 0
  printf '== Auto-fix ==\n'
  if fi_af_enabled; then
    fi_cfg_show_line autofix
    printf '%s Auto-fix: on (found-issues.autofix=true, %s)\n' "$p" "$FI_CFG_SRC"
  else
    printf '%s Auto-fix: off — %s\n' "$w" "$FI_AF_WHY"
    printf '   Turn on: found-issues config autofix true (read the disclosure in /found-issues:setup first)\n'
  fi
  fi_cfg_show_line autofix.testCommand
  if [[ "$FI_CFG_SRC" == none ]]; then
    printf '%s No test command — set one: found-issues config autofix.testCommand "<cmd>"\n' "$x"
  else
    printf '%s Test command: %s (%s)\n' "$p" "$FI_CFG_VAL" "$FI_CFG_SRC"
  fi
  fi_cfg_show_line autofix.worktreeFiles
  [[ -z "$FI_CFG_VAL" ]] || printf '%s Local files copied into fix worktrees: %s (%s)\n' "$p" "$FI_CFG_VAL" "$FI_CFG_SRC"
  if [[ -n "$gh_user" ]]; then printf '%s gh authenticated as %s\n' "$p" "$gh_user"
  else printf '%s gh not authenticated — auto-fix cannot open PRs\n' "$x"; fi
  for e in claude codex; do
    if command -v "$e" >/dev/null 2>&1; then
      v="$("$e" --version 2>/dev/null | head -n 1 || true)"
      printf '%s %s: %s (%s)\n' "$p" "$e" "$(command -v "$e")" "${v:-version unknown}"
    else
      printf '%s %s not on PATH\n' "$w" "$e"
    fi
  done
  e="$(fi_af_engine 2>/dev/null || true)"
  printf '   Engine: %s -> %s\n' "$(fi_af_cfg engine auto)" "${e:-none available}"
  if [[ "$e" == claude ]] && ! fi_af_sandbox_available; then
    printf '%s No Claude sandbox runtime (macOS sandbox-exec, or bubblewrap + socat on Linux): the fixer'"'"'s test command runs unsandboxed\n' "$w"
  fi
  printf '   Codex models: fixer %s, verifier %s, classifier %s\n' \
    "$(fi_af_codex_desc fixer)" "$(fi_af_codex_desc verifier)" "$(fi_af_codex_desc classifier)"
  for r in fixer verifier classifier; do
    fi_af_codex_margs "$r"
    [[ -z "$FI_AF_MWARN" ]] || printf '%s %s\n' "$w" "$FI_AF_MWARN"
  done
  fi_af_root
  if [[ -s "$FI_AF_ROOT/codex-model-error" ]]; then
    printf '%s Last Codex run failed on its model: %s\n' "$w" "$(head -n 1 "$FI_AF_ROOT/codex-model-error")"
    printf '   Fix: found-issues config autofix.codexModel <model> (or inherit); same for autofix.codexVerifierModel\n'
  fi
  rb="$(_fi_af_doctor_budget run)" sb="$(_fi_af_doctor_budget sweep)"
  rt="$(fi_af_cap_int codexRunTokens)" st="$(fi_af_cap_int codexSweepTokens)"
  [[ -n "$rt" ]] && rt="$rt Codex tokens per run" || rt="no token cap per run"
  [[ -n "$st" ]] && st="$st per sweep" || st="no token cap per sweep"
  printf '   Caps: %s spot fixes/day, %s sweep(s)/day (at %s fixable, %s fixes per PR), %s, %s, %s, %s, %s min per run\n' \
    "$(fi_af_int dailyFixes 5)" "$(fi_af_int dailySweeps 1)" "$(fi_af_int sweepThreshold 5)" \
    "$(fi_af_sweep_batch)" "$rb" "$sb" "$rt" "$st" "$(fi_af_int runTimeoutMin 20)"
  printf '   Fix PRs merge themselves once checks pass. Stop: found-issues autofix off\n\n'
}
