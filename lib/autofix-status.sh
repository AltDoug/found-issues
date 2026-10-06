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
#   fi_af_summary [--peek]
#   fi_af_doctor <pass> <warn> <fail> <gh-user>

# shellcheck disable=SC2154  # AFI_*/FI_AF_* come from autofix-queue.sh / autofix-config.sh

# A pid we may signal: alive and running `found-issues … autofix run`.
_fi_af_is_run_pid() {
  local cmd
  [[ "$1" =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null || return 1
  cmd="$(ps -o command= -p "$1" 2>/dev/null || true)"
  [[ "$cmd" == *found-issues*"autofix run"* ]]
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
    if _fi_af_is_run_pid "$AFI_pid"; then
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
        printf '  %s  %s  %s (launcher %s)\n' "$AFI_id" "${AFI_kind:-spot}" "${AFI_loc:-sweep}" "${AFI_launcher:-?}"
        if [[ -n "$AFI_base" ]]; then printf '      into %s (%s)\n' "$AFI_base" "${AFI_base_why:-?}"; fi
      else
        printf '  %s  %s  %s\n' "$AFI_id" "${AFI_kind:-spot}" "${AFI_loc:-sweep}"
        if [[ -n "$AFI_waiting" ]]; then printf '      waiting: %s\n' "$AFI_waiting"; fi
      fi
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
      printf '  %s  %s — %s\n' "$AFI_id" "${AFI_loc:-sweep}" "$AFI_result"
      if [[ -n "$AFI_base" ]]; then printf '      into %s (%s)\n' "$AFI_base" "${AFI_base_why:-?}"; fi
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
  name="${root//[^A-Za-z0-9._-]/_}"
  dir="$FI_AF_ROOT/seg"
  if (( n == 0 )); then rm -f "$dir/$name" 2>/dev/null; return 0; fi
  mkdir -p "$dir" 2>/dev/null || return 0
  if printf '%s\n' "$n" >"$dir/$name.$$" 2>/dev/null; then
    mv -f "$dir/$name.$$" "$dir/$name" 2>/dev/null || rm -f "$dir/$name.$$"
  fi
  return 0
}

# Recount this repo's roots: drop their files, rewrite those still running.
fi_af_seg_refresh() {
  local f root
  fi_af_root
  for f in "$FI_AF_ST"/done/* "$FI_AF_ST"/queue/* "$FI_AF_ST"/running/*; do
    [[ -f "$f" ]] || continue
    root="$(_fi_af_field "$f" root 2>/dev/null || true)"
    [[ -n "$root" ]] && rm -f "$FI_AF_ROOT/seg/${root//[^A-Za-z0-9._-]/_}" 2>/dev/null
  done
  for f in "$FI_AF_ST"/running/*; do
    [[ -f "$f" ]] && fi_af_seg_write "$(_fi_af_field "$f" root 2>/dev/null || true)"
  done
  return 0
}

# Phase 5 rulings 3-4: what finished since the last interactive session, for
# SessionStart. The stamp moves BEFORE printing, so two sessions starting
# together show it once. Failure reasons keep only the bash-authored prefix
# (text before the first ':' or '('): model text never reaches the line.
fi_af_summary() {
  local peek="${1:-}" seen=0 f fixed=0 failed=0 prs="" reasons="" r cost=0 dec=0 file s
  [[ -f "$FI_AF_ST/seen" ]] && IFS= read -r seen <"$FI_AF_ST/seen"
  [[ "$seen" =~ ^[0-9]+$ ]] || seen=0
  for f in "$FI_AF_ST"/done/*; do
    [[ -f "$f" ]] || continue
    fi_af_item_read "$f" || true
    [[ "$AFI_finished" =~ ^[0-9]+$ ]] || continue
    (( AFI_finished > seen )) || continue
    case "$AFI_result" in
      shipped:*)
        fixed=$((fixed + 1)); _fi_af_pr_num
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
    [[ "$AFI_cost" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
      && cost="$(awk -v a="$cost" -v b="$AFI_cost" 'BEGIN { printf "%.2f", a + b }')"
  done
  (( fixed + failed > 0 )) || return 0
  [[ "$peek" == --peek ]] || printf '%s\n' "$(date +%s)" >"$FI_AF_ST/seen" 2>/dev/null || true
  file="$(fi_find_issues_file "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" 2>/dev/null || true)"
  [[ -n "$file" ]] && dec="$(fi_count_decide "$file")"
  s="Since last session: fixed $fixed"
  [[ -n "$prs" ]] && s+=" (PR $prs)"
  (( failed > 0 )) && s+=", $failed failed${reasons:+ ($reasons)}"
  if (( dec == 1 )); then s+=", 1 decision waiting"; elif (( dec > 1 )); then s+=", $dec decisions waiting"; fi
  [[ "$cost" != 0 && "$cost" != 0.00 ]] && s+=" — \$$cost spent"
  printf '%s.\n' "$s"
}

# Phase 5 ruling 9: auto-fix readiness at a glance, on or off (spec §8).
fi_af_doctor() {
  local p="$1" w="$2" x="$3" gh_user="$4" e v rb sb
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
  rb="$(fi_af_cfg runBudget "")" sb="$(fi_af_cfg sweepBudget "")"
  [[ -n "$rb" ]] && rb="\$$rb per run" || rb="no dollar cap per run"
  [[ -n "$sb" ]] && sb="\$$sb per sweep" || sb="no dollar cap per sweep"
  printf '   Caps: %s spot fixes/day, %s sweep(s)/day (at %s fixable, up to %s entries), %s, %s, %s min per run\n' \
    "$(fi_af_int dailyFixes 5)" "$(fi_af_int dailySweeps 1)" "$(fi_af_int sweepThreshold 5)" \
    "$(fi_af_int sweepMax 8)" "$rb" "$sb" "$(fi_af_int runTimeoutMin 20)"
  printf '   Fix PRs merge themselves once checks pass. Stop: found-issues autofix off\n\n'
}
