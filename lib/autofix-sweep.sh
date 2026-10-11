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
#   fi_af_sweep_check (untagged entries count toward the threshold)
#   fi_af_sweep_claim <id>
#   fi_af_sweep_load <id>
#   fi_af_sweep_commit <id> / fi_af_sweep_settle <id> <outcome> <text>
#   _fi_af_run_sweep <id> <engine>
#   fi_af_sweep_finish <id> / fi_af_sweep_ship
#
# 3.3.0 (spec section 9): a sweep takes every fixable entry and ships one PR
# per sweepBatch fixes. A full batch closes at a file boundary and queues a
# continuation item (cont, skip_files, cap_day, carried cost/tokens) for the rest.

# shellcheck disable=SC2034,SC2154  # AFI_*/FE_* are shared with autofix-queue.sh / parse-entries.sh

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
    fi_af_inflight_check "$FI_KEY" && continue
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

# A sweep still waiting in queue/ from an earlier day never got launched (its
# root's session never stopped, or the root is gone) and would block every
# later sweep: retire it as stale so the next check queues a fresh one.
_fi_af_sweep_retire_stale() {
  local f q id today
  today="$(fi_today)"
  for f in "$FI_AF_ST"/queue/*; do
    [[ -f "$f" ]] || continue
    [[ "$(_fi_af_field "$f" kind)" == "sweep" ]] || continue
    id="${f##*/}"
    # A ship retry holds verified commits: it gets 3 days to be launched,
    # then retires (its branch kept and named) so it cannot block sweeps.
    if [[ "$(_fi_af_field "$f" ship_tries)" =~ ^[1-9] ]]; then
      q="$(fi_file_mtime "$f" 2>/dev/null)" || q=""
      [[ "$q" =~ ^[0-9]+$ ]] || continue
      (( $(date +%s) - q > ${FOUND_ISSUES_AUTOFIX_WAIT_MAX:-259200} )) || continue
      fi_af_retire "$id" stale "ship retry never launched; branch $(_fi_af_field "$f" branch) kept" || true
      continue
    fi
    q="$(_fi_af_field "$f" queued)" || continue
    [[ "${q:0:10}" < "$today" ]] || continue
    fi_af_retire "$id" stale "queued ${q:0:10} and never launched" || true
  done
}

# Spec §4.1: after log, tag, decide or sync wrote the ledger. One sweep at
# a time and dailySweeps a day; due at sweepThreshold candidates or on one
# critical (fix: medium). Never fails its caller. Never inside a fixer
# child: its cwd is the fixer's worktree, so the sweep would get that root
# (and burn the day's cap on a worktree about to vanish); the main
# session's next ledger write checks the source ledger instead.
# [open] entries the classify pass would take (_fi_af_classify_list's rule)
# and has not been shown before: one it left untagged waits for a human tag.
_fi_af_untagged_count() {
  local entry c=0 seen="$FI_AF_ST/classify-offered"
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    fi_parse_entry_vars "$entry" || continue
    [[ -z "$FE_fixtag$FE_decide$FE_decided$FE_manual$FE_autofix_failed$FE_prs$FE_prs_auto$FE_commits$FE_commits_auto" ]] || continue
    if [[ -s "$seen" ]] && fi_entry_dedup_key_v "$entry" "$2" && grep -Fqx -- "$FI_KEY" "$seen"; then
      continue
    fi
    c=$((c + 1))
  done < <(fi_entries "$1" open 2>/dev/null || true)
  printf '%s' "$c"
}

fi_af_sweep_check() {
  local slug root file entry n=0 crit=0 engine
  [[ "${FOUND_ISSUES_AUTOFIX_CHILD:-}" == "1" ]] && return 0
  fi_af_enabled || return 0
  slug="$(fi_repo_id 2>/dev/null)" || return 0
  fi_repo_root_cached
  root="$FI_REPO_ROOT"
  [[ -n "$root" ]] || return 0
  file="$(fi_find_issues_file "$root" 2>/dev/null)" || return 0
  [[ -f "$file" ]] || return 0
  fi_af_dirs "$slug"
  _fi_af_sweep_retire_stale
  fi_af_test_command "$root" >/dev/null 2>&1 || return 0
  fi_af_sweep_pending && return 0
  fi_af_cap_ok sweep "$(fi_af_int dailySweeps 1)" || return 0
  # A sweep that retired for want of a test command on the landing branch
  # (the root checkout may have one) is not queued again the same day.
  fi_af_cap_ok sweep-notest 1 || return 0
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    [[ -n "$entry" ]] || continue
    n=$((n + 1))
    fi_parse_entry_vars "$entry"
    [[ "$FE_critical" == "yes" && "$FE_fixtag" == "medium" ]] && crit=1
  done < <(fi_af_sweep_candidates "$file" "$root" 1000)
  # Untagged entries count too: only a sweep's classify pass tags them, so
  # a backlog logged before tags existed could otherwise never reach the
  # threshold (ledger lib/autofix-sweep.sh:97).
  n=$((n + $(_fi_af_untagged_count "$file" "$root")))
  (( n > 0 )) || return 0
  (( crit || n >= $(fi_af_int sweepThreshold 5) )) || return 0
  engine="$(fi_af_engine_setting)"
  fi_af_new_id
  fi_af_item_write "$FI_AF_ST/queue/$FI_AF_ID" "id=$FI_AF_ID" "kind=sweep" \
    "root=$root" "slug=$slug" "loc=sweep" "engine=$engine" "engine_q=$engine" \
    "queued=$(date +%Y-%m-%dT%H:%M:%S)" "crashes=0"
  printf 'AUTOFIX-SWEEP-DUE %s\n' "$FI_AF_ID"
}

# Spec section 3: a sweep leaves out entries whose file is not on the landing
# branch yet or is busy in the sweep's root checkout; they stay eligible.
# Filters candidate lines on stdin; AFI_base is set by the worktree step.
# Batch 4 (ledger lib/autofix-sweep.sh:274): the claim holds the repo lock
# while this runs over up to 1000 candidates, so the git questions are asked
# once for all of them: one cat-file --batch-check for presence on
# origin/<base>, one diff and one log for the busy files.
_fi_af_sweep_ready() {
  local id="$1" entry p keep="${AFI_entry:-}" skip=":${AFI_skip_files:-}:" held=":${AFI_held_files:-}:"
  local i k n=0 line any=0
  local -a ents=() paths=() gone=() want=() spec=() ans=()
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    [[ -n "$entry" ]] || continue
    AFI_entry="$entry"
    p="$(_fi_af_entry_file)" || p=""
    ents[n]="$entry"; paths[n]="$p"; gone[n]=0; want[n]=""
    # An earlier batch's file is skipped before any git question is asked.
    if [[ -n "$p" && "$skip" != *":$p:"* ]]; then
      want[n]="origin/$AFI_base:$p"
      spec[${#spec[@]}]="${want[n]}"
    fi
    n=$((n + 1))
  done
  if (( ${#spec[@]} > 0 )); then
    # Positional: answer line k belongs to the k-th wanted path.
    while IFS= read -r line || [[ -n "$line" ]]; do ans[${#ans[@]}]="$line"; done \
      < <(printf '%s\n' "${spec[@]}" | git -C "$AFI_root" -c core.quotepath=off cat-file --batch-check 2>/dev/null || true)
    k=0
    for (( i = 0; i < n; i++ )); do
      [[ -n "${want[i]}" ]] || continue
      # No answer at all counts as missing, like a failed cat-file -e.
      if [[ -z "${ans[k]:-}" || "${ans[k]}" == *" missing" || "${ans[k]}" == *" ambiguous" ]]; then gone[i]=1; fi
      k=$((k + 1))
    done
    _fi_af_busy_set
  fi
  for (( i = 0; i < n; i++ )); do
    p="${paths[i]}"
    if [[ -n "$p" ]]; then
      fi_entry_loc_v "${ents[i]}" || true
      if [[ "$held" == *":$p:"* ]]; then
        fi_af_log "$id" "sweep: skip $FE_loc (held back: an earlier batch skipped an entry on this file)"; continue
      fi
      if [[ "$skip" == *":$p:"* ]]; then
        fi_af_log "$id" "sweep: skip $FE_loc (file in an earlier batch's PR)"; continue
      fi
      if (( gone[i] )); then
        fi_af_log "$id" "sweep: skip $FE_loc (not on origin/$AFI_base)"; continue
      fi
      if _fi_af_in_busy_set "$p"; then
        fi_af_log "$id" "sweep: skip $FE_loc (busy)"; continue
      fi
    fi
    printf '%s\n' "${ents[i]}"
  done
  AFI_entry="$keep"
}

# 3.2.1 (ledger lib/autofix-sweep.sh:387): a sweep whose ship failed comes
# back with its commits on the kept branch. No cap, no classify, no entries:
# re-attach a worktree to that branch, at the commit the sweep recorded, and
# go straight to ship (its cur is past the last entry).
_fi_af_sweep_claim_ship() {
  local id="$1" q="$FI_AF_ST/queue/$1" r="$FI_AF_ST/running/$1" at
  # mv first, then stamp running/ (as fi_af_claim): a stamp on queue/ races
  # a cancel and can recreate the item it retired.
  mv "$q" "$r" || { fi_af_unlock "$id"; return 1; }
  fi_af_item_set "$r" pid "${FI_AF_PID:-}"
  if [[ -n "${FI_AF_PID:-}" ]]; then fi_af_item_set "$r" launcher A; else fi_af_item_set "$r" launcher B; fi
  fi_af_item_set "$r" wait_next ""
  fi_af_seg_write "$AFI_root"
  [[ -n "$AFI_wt" ]] || AFI_wt="$AFI_root/.claude/worktrees/fi-sweep-$id"
  at="$(git -C "$AFI_root" rev-parse -q --verify "refs/heads/$AFI_branch" 2>/dev/null || true)"
  if [[ -z "$AFI_branch" || -z "$AFI_head" || -z "$AFI_base" || "$at" != "$AFI_head" ]]; then
    FI_AF_WHY="ship retry: branch ${AFI_branch:-?} is gone or moved"
    fi_af_finish "$id" failed "$FI_AF_WHY"; return 6
  fi
  mkdir -p "$AFI_root/.claude/worktrees"
  git -C "$AFI_root" worktree prune >/dev/null 2>&1 || true
  if ! git -C "$AFI_root" worktree add -q "$AFI_wt" "$AFI_branch" >/dev/null 2>&1; then
    FI_AF_WHY="ship retry: git worktree add failed"
    fi_af_finish "$id" failed "$FI_AF_WHY"; return 6
  fi
  fi_af_item_set "$r" wt "$AFI_wt"
  fi_af_log "$id" "claimed sweep for ship retry $AFI_ship_tries: $AFI_wt ($AFI_branch at $AFI_head)"
}

# Spec §6 steps 1-3 at claim time (lock held, queue item read): cap, the
# fresh worktree, the classify/wake pass, then the ordered entry list.
# A sweep requeued today (crash, switch-off, outage) already holds today's
# cap. A sweep over the cap retires stale rather than returning rc 3: rc 3
# writes the day's capped marker, which would stop spot fixes too.
fi_af_sweep_claim() {
  local id="$1" q="$FI_AF_ST/queue/$1" r="$FI_AF_ST/running/$1" file n=0 line capped=0 cont=0
  [[ "${AFI_cont:-}" =~ ^[0-9]+$ ]] && (( 10#$AFI_cont >= 2 )) && cont=1
  if [[ "${AFI_ship_tries:-0}" =~ ^[1-9] ]]; then _fi_af_sweep_claim_ship "$id"; return; fi
  [[ "$(_fi_af_field "$q" cap_day)" == "$(fi_today)" ]] && capped=1
  if (( ! capped )) && ! fi_af_cap_ok sweep "$(fi_af_int dailySweeps 1)"; then
    FI_AF_WHY="today's sweep cap is reached; the next trigger queues a new sweep"
    fi_af_retire "$id" stale "$FI_AF_WHY" || fi_af_unlock "$id"; return 5
  fi
  mv "$q" "$r" || { fi_af_unlock "$id"; return 1; }
  fi_af_item_set "$r" pid "${FI_AF_PID:-}"
  if [[ -n "${FI_AF_PID:-}" ]]; then fi_af_item_set "$r" launcher A; else fi_af_item_set "$r" launcher B; fi
  fi_af_seg_write "$AFI_root"
  if ! fi_af_worktree_add; then
    # Batch 4 (ledger lib/autofix-sweep.sh:246): a failed fetch waits like a
    # spot item's does, through the same bounded requeue.
    _fi_af_wt_fail_requeue "$id" && return 8
    fi_af_finish "$id" failed "$FI_AF_WHY"; return 6
  fi
  # The cut worked: a fetch-failure requeue's retry count and wait clock end
  # here (the spot claim clears them the same way, lib/autofix-queue.sh).
  fi_af_item_set "$r" wt_retries ""
  fi_af_item_set "$r" waiting ""
  fi_af_item_set "$r" wait_next ""
  fi_af_item_set "$r" wt "$AFI_wt"
  fi_af_item_set "$r" branch "$AFI_branch"
  # No test command at origin/<base>: retire before the day's slot is spent
  # and before the classifier runs.
  if ! fi_af_test_command "$AFI_wt" >/dev/null 2>&1; then
    FI_AF_WHY="no test command"
    # Not the sweep slot (nothing ran), but a day marker so fi_af_sweep_check
    # does not queue the same doomed sweep on every trigger.
    fi_af_cap_take sweep-notest "$id"
    fi_af_finish "$id" stale "$FI_AF_WHY"; return 5
  fi
  # Red at base: retire before the classifier spends anything. The day's
  # slot is spent, or every Stop would queue a new sweep and re-run the suite.
  if ! fi_af_base_tests "$id"; then
    (( capped )) || fi_af_cap_take sweep "$id"
    FI_AF_WHY="${FI_AF_BASE_WHY:-tests fail at base}"
    fi_af_finish "$id" stale "$FI_AF_WHY"; return 5
  fi
  fi_af_item_set "$r" base "$AFI_base"
  fi_af_item_set "$r" base_why "$AFI_base_why"
  fi_af_item_set "$r" base_sha "$AFI_base_sha"
  fi_af_item_set "$r" head "$AFI_base_sha"
  fi_af_item_set "$r" cur 1
  fi_af_item_set "$r" fixed 0
  fi_af_item_set "$r" more ""
  AFI_head="$AFI_base_sha" AFI_cur=1 AFI_fixed=0 AFI_more=""
  mkdir -p "$FI_AF_ST/sweeps"
  file="$(fi_find_issues_file "$AFI_root" 2>/dev/null)" || file=""
  if [[ -n "$file" && -f "$file" ]]; then
    # A continuation was classified with its first batch.
    if (( ! cont )) && declare -F fi_af_classify >/dev/null; then fi_af_classify "$file" "$id" || true; fi
    fi_af_sweep_candidates "$file" "$AFI_root" 1000 | _fi_af_sweep_ready "$id" \
      >"$FI_AF_ST/sweeps/$id.entries" || true
  else
    : >"$FI_AF_ST/sweeps/$id.entries"
  fi
  : >"$FI_AF_ST/sweeps/$id.outcomes"
  : >"$FI_AF_ST/sweeps/$id.held"
  while IFS= read -r line || [[ -n "$line" ]]; do n=$((n + 1)); done <"$FI_AF_ST/sweeps/$id.entries"
  if (( n == 0 )); then
    FI_AF_WHY="nothing fixable now"
    fi_af_finish "$id" stale "$FI_AF_WHY"; return 5
  fi
  # Spend the day's slot only now that the sweep has something to fix, like
  # the no-test-command retire above.
  if (( ! capped )); then
    fi_af_item_set "$r" cap_day "$(fi_today)"
    fi_af_cap_take sweep "$id"
  fi
  fi_af_log "$id" "claimed sweep: $n entries in $AFI_wt ($AFI_branch from origin/$AFI_base: $AFI_base_why)"
}

# Entry number AFI_cur of the sweep, with its base pinned to the last good
# commit, so diff, reset and the verifier see only this entry's change.
# rc 1 when the ledger still holds the current entry (AFI_key, any status) and
# it is no longer fixable now. An entry the ledger no longer lists is not
# judged: nothing says it was resolved rather than moved.
_fi_af_sweep_still_fixable() {
  local entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    fi_entry_dedup_key_v "$entry" "$AFI_root" || continue
    [[ "$FI_KEY" == "$AFI_key" ]] || continue
    fi_af_fixable_now "$entry"; return
  done < <(fi_entries "$1" all 2>/dev/null || true)
  return 0
}

fi_af_sweep_load() {
  local file
  while :; do
    _fi_af_sweep_load_one "$1" || return 1
    # Batch 3: the entry may have been retagged, resolved or annotated since
    # the claim listed it; one that is no longer fixable now is skipped.
    file="$(fi_find_issues_file "$AFI_root" 2>/dev/null)" || return 0
    [[ -f "$file" ]] || return 0
    _fi_af_sweep_still_fixable "$file" && return 0
    fi_af_sweep_settle "$1" skipped "no longer fixable: the entry changed since the sweep was claimed"
    [[ "${AFI_more:-}" == 1 ]] && return 1
  done
}

_fi_af_sweep_load_one() {
  local f="$FI_AF_ST/sweeps/$1.entries" i=0 line
  [[ "$AFI_cur" =~ ^[0-9]+$ && -f "$f" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    i=$((i + 1))
    (( i == AFI_cur )) || continue
    AFI_entry="$line"
    fi_entry_loc_v "$line" || return 1
    AFI_loc="$FE_loc"
    fi_entry_dedup_key_v "$line" "$AFI_root" || return 1
    AFI_key="$FI_KEY"
    AFI_base_sha="${AFI_head:-$AFI_base_sha}"
    return 0
  done <"$f"
  return 1
}

# One line per settled entry: <loc>\t<outcome>\t<dedup key>\t<text>. The key,
# not the location, names the entry: two entries can share one line.
_fi_af_sweep_record() {
  local text="${2//$'\t'/ }"
  printf '%s\t%s\t%s\t%s\n' "$AFI_loc" "$1" "$AFI_key" "${text//$'\n'/ }" >>"$FI_AF_ST/sweeps/$AFI_id.outcomes"
}

_fi_af_sweep_advance() {
  local r="$FI_AF_ST/running/$AFI_id"
  AFI_cur=$(( AFI_cur + 1 ))
  fi_af_item_set "$r" cur "$AFI_cur"
  fi_af_item_set "$r" attempts 0
  fi_af_item_set "$r" verdict ""
  AFI_attempts=0 AFI_verdict=""
}

# In a continuation batch: the first staged path of <wt> (against <ref>) that
# is in skip_files, on stdout; rc 1 when none (or not a continuation).
_fi_af_sweep_skip_hit() {
  local p
  _fi_af_sweep_is_cont && [[ -n "${AFI_skip_files:-}" ]] || return 1
  while IFS= read -r p || [[ -n "$p" ]]; do
    if [[ -n "$p" && ":$AFI_skip_files:" == *":$p:"* ]]; then printf '%s' "$p"; return 0; fi
  done < <(git -C "$1" -c core.quotepath=off diff --cached --name-only --no-renames "$2" 2>/dev/null)
  return 1
}

# The verifier approved FI_AF_TREE: commit exactly that tree as this entry's
# one commit (spec §6 step 4). rc 0 committed; rc 1 refused (the caller
# settles it failed); rc 2 dropped and already settled as skipped.
fi_af_sweep_commit() {
  local id="$1" r="$FI_AF_ST/running/$1" frag p
  FI_AF_WHY=""
  fi_af_reset_ledger "$AFI_wt" "$AFI_head"
  git -C "$AFI_wt" add -A >/dev/null 2>&1 || true
  if [[ -z "$FI_AF_TREE" || "$(git -C "$AFI_wt" write-tree 2>/dev/null)" != "$FI_AF_TREE" ]]; then
    FI_AF_WHY="the change differs from what the verifier approved"; return 1
  fi
  # A continuation batch is cut from origin/<base>, where an earlier batch's
  # PR may not be merged: a change to one of that chain's files would conflict
  # with it (spec section 9). The entry is dropped, not failed: it stays
  # eligible for the next sweep once those PRs have merged.
  if p="$(_fi_af_sweep_skip_hit "$AFI_wt" "$AFI_head")"; then
    FI_AF_WHY="touches $p (file in an earlier batch's PR)"
    fi_af_sweep_settle "$id" skipped-chain "$FI_AF_WHY"
    return 2
  fi
  fi_parse_entry_vars "$AFI_entry" || true
  frag="${FE_symptom:-$AFI_loc}"
  frag="${frag:0:60}"
  git -C "$AFI_wt" commit -q -m "fix: $frag (found-issues $AFI_loc)" >>"$FI_AF_RUNS/$id.log" 2>&1 \
    || { FI_AF_WHY="git commit refused (a commit hook?)"; return 1; }
  AFI_head="$(git -C "$AFI_wt" rev-parse HEAD)"
  AFI_fixed=$(( ${AFI_fixed:-0} + 1 ))
  AFI_verdict_tree="$(git -C "$AFI_wt" rev-parse 'HEAD^{tree}')"
  fi_af_item_set "$r" head "$AFI_head"
  fi_af_item_set "$r" fixed "$AFI_fixed"
  fi_af_item_set "$r" verdict_tree "$AFI_verdict_tree"
  _fi_af_sweep_record fixed "${FI_AF_VERDICT_REASON:-approved}"
  fi_af_log "$id" "sweep: committed $AFI_loc"
  _fi_af_sweep_advance
}

# Any outcome but fixed: drop this entry's change, record the outcome on the
# source ledger, move on (plan Review Focus 2).
fi_af_sweep_settle() {
  local id="$1" outcome="$2" text="$3" rc=0 chain=0
  # skipped-chain = skipped for touching a file of an earlier batch's PR. It is
  # recorded as plain "skipped"; its entry's file goes to the chain's held list
  # (a marker of its own, so the 160-char display text is never parsed).
  if [[ "$outcome" == skipped-chain ]]; then outcome=skipped chain=1; fi
  text="${text//$'\n'/ }"
  text="${text:0:160}"
  git -C "$AFI_wt" reset -q --hard "$AFI_head" >/dev/null 2>&1 || true
  git -C "$AFI_wt" clean -qfd >/dev/null 2>&1 || true
  _fi_af_ledger_outcome "$outcome" "$text" || rc=$?
  (( rc == 0 )) || fi_af_log "$id" "ledger not updated for $AFI_loc $outcome (rc $rc)"
  _fi_af_sweep_record "$outcome" "$text"
  (( ! chain )) || printf '%s\n' "${AFI_loc%%:*}" >>"$FI_AF_ST/sweeps/$AFI_id.held"
  fi_af_log "$id" "sweep: $AFI_loc $outcome: $text"
  _fi_af_sweep_advance
  # Whatever the last outcome was, a full batch closes at the first file
  # boundary; checking only after a commit let a settled entry carry the
  # batch past it.
  _fi_af_sweep_close_if_full "$id" "${AFI_engine:-}" || true
}

# Right after an entry settles or commits (AFI_cur already points at the
# next entry): the batch is full and the next entry cites another file, so
# the batch closes here. A file never straddles two PRs. rc 1 = keep going.
_fi_af_sweep_batch_closes() {
  local id="$1" f="$FI_AF_ST/sweeps/$1.entries" i=0 line next="" prev
  (( ${AFI_fixed:-0} >= $(fi_af_sweep_batch) )) || return 1
  fi_parse_entry_vars "$AFI_entry" 2>/dev/null || true
  prev="$FE_path"
  [[ "$AFI_cur" =~ ^[0-9]+$ && -f "$f" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    i=$((i + 1))
    (( i == AFI_cur )) && { next="$line"; break; }
  done <"$f"
  [[ -n "$next" ]] || return 1
  fi_parse_entry_vars "$next" 2>/dev/null || true
  [[ -n "$prev" && "$FE_path" == "$prev" ]] && return 1
  fi_af_log "$id" "sweep: batch $(_fi_af_sweep_batch_no) closes at $AFI_fixed fixes"
  return 0
}

# A full batch stops handing out entries: record that entries remain and keep
# the engine this batch resolved, so the chain never switches (spec section 9).
# Shared by launchers A and B. rc 0 = the batch closed.
_fi_af_sweep_close_if_full() {
  local id="$1" engine="$2" r="$FI_AF_ST/running/$1"
  _fi_af_sweep_batch_closes "$id" || return 1
  [[ -z "$engine" ]] || fi_af_item_set "$r" engine "$engine"
  fi_af_item_set "$r" more 1
  AFI_more=1
  return 0
}

# A chain's spend (spec section 9; ruling R10). A continuation carries the
# chain's running totals in chain_cost/chain_tokens, which seed the run so
# sweepBudget / codexSweepTokens cover the whole chain; the item's own cost
# and tokens record only this batch, so the status and summary sums stay true.
_fi_af_chain_seed() {
  if [[ -z "$AFI_chain_cost" ]]; then
    FI_AF_COST="${AFI_cost:-0}" FI_AF_TOKENS="${AFI_tokens:-0}"
    return 0
  fi
  FI_AF_COST="$(awk -v a="$AFI_chain_cost" -v b="${AFI_cost:-0}" 'BEGIN { printf "%.4f", a + b }')"
  FI_AF_TOKENS=$(( ${AFI_chain_tokens:-0} + ${AFI_tokens:-0} ))
}

_fi_af_own_cost() {
  if [[ -z "$AFI_chain_cost" ]]; then printf '%s' "${FI_AF_COST:-0}"; return 0; fi
  awk -v a="${FI_AF_COST:-0}" -v b="$AFI_chain_cost" 'BEGIN { d = a - b; if (d < 0) d = 0; printf "%.4f", d }'
}

_fi_af_own_tokens() {
  local d=$(( ${FI_AF_TOKENS:-0} - ${AFI_chain_tokens:-0} ))
  (( d < 0 )) && d=0
  printf '%s' "$d"
}

_fi_af_chain_save() {
  fi_af_item_set "$1" cost "$(_fi_af_own_cost)"
  fi_af_item_set "$1" tokens "$(_fi_af_own_tokens)"
}

# rc 0 when the loaded item is a continuation (batch 2 or later).
_fi_af_sweep_is_cont() {
  [[ "${AFI_cont:-}" =~ ^[0-9]+$ ]] && (( 10#$AFI_cont >= 2 ))
}

# This batch's number: 1 for the first, cont for a continuation.
_fi_af_sweep_batch_no() {
  if [[ "${AFI_cont:-}" =~ ^[0-9]+$ ]] && (( 10#$AFI_cont >= 2 )); then printf '%s' "$((10#$AFI_cont))"; else printf '1'; fi
}

# Launcher A for a claimed sweep: each entry through the shared fix loop,
# then one PR (spec §6 steps 4-5). A budget stop or an engine outage leaves
# the current entry untouched and ships what is committed (ruling 7).
_fi_af_run_sweep() {
  local id="$1" engine_opt="$2" r="$FI_AF_ST/running/$1" engine want rc
  fi_af_item_read "$r" || return 0
  _fi_af_chain_seed
  if ! FI_AF_TESTCMD="$(fi_af_test_command "$AFI_wt")"; then
    fi_af_finish "$id" stale "no test command"; return 0
  fi
  # A ship retry calls no engine: it must not fail for want of one.
  if [[ "${AFI_ship_tries:-0}" =~ ^[1-9] ]]; then
    engine="${AFI_engine:-${engine_opt:-claude}}"
  else
    # A chain never switches engines (spec section 9): a continuation keeps
    # the engine its first batch resolved, whatever launcher or harness runs
    # it; --engine only decides for a fresh sweep.
    want="${engine_opt:-$(fi_af_item_engine 2>/dev/null || true)}"
    if _fi_af_sweep_is_cont && [[ -n "$AFI_engine" ]]; then want="$AFI_engine"; fi
    if ! engine="$(fi_af_engine "$want")" || ! command -v "$engine" >/dev/null 2>&1; then
      fi_af_finish "$id" failed "no ${engine:-claude or codex} on PATH"; return 0
    fi
  fi
  AFI_engine="$engine"
  # The engine the sweep really ran on, for its PR body and the status row.
  fi_af_item_set "$r" engine "$engine"
  while fi_af_sweep_load "$id"; do
    fi_af_enabled || break
    _fi_af_fix_loop "$id" "$engine"
    _fi_af_chain_save "$r"
    case "$FI_AF_OUTCOME" in
      outage)
        fi_af_log "$id" "sweep: engine error: $FI_AF_OUTCOME_TEXT"
        _fi_af_reset_wt; break ;;
      approved)
        rc=0
        fi_af_sweep_commit "$id" || rc=$?
        case $rc in
          0) _fi_af_sweep_close_if_full "$id" "$engine" && break ;;
          2) ;;
          *) fi_af_sweep_settle "$id" failed "commit: $FI_AF_WHY" ;;
        esac ;;
      failed)
        if [[ "$FI_AF_OUTCOME_TEXT" == "run budget spent"* ]]; then
          fi_af_log "$id" "sweep: $FI_AF_OUTCOME_TEXT"
          _fi_af_reset_wt; break
        fi
        fi_af_sweep_settle "$id" failed "$FI_AF_OUTCOME_TEXT" ;;
      *) fi_af_sweep_settle "$id" "$FI_AF_OUTCOME" "$FI_AF_OUTCOME_TEXT" ;;
    esac
    # A settled entry can close a full batch too (fi_af_sweep_settle).
    [[ "${AFI_more:-}" == 1 ]] && break
  done
  # `autofix off` mid-sweep gives it back untouched, like B's verify and
  # ship (exit 8): nothing ships and nothing merges after the switch.
  if ! fi_af_enabled; then
    fi_af_requeue "$id" "switched off: $FI_AF_WHY"
    printf 'Auto-fix: switched off (%s); sweep %s is requeued.\n' "$FI_AF_WHY" "$id"
    return 0
  fi
  fi_af_sweep_finish "$id" || true
  return 0
}

# "2 fixed, 1 failed" from the outcomes file.
_fi_af_sweep_tally() {
  local f="$FI_AF_ST/sweeps/$1.outcomes" k c loc out key text t=""
  for k in fixed already-fixed decide manual failed skipped; do
    c=0
    if [[ -f "$f" ]]; then
      while IFS=$'\t' read -r loc out key text || [[ -n "$loc" ]]; do
        [[ "$out" == "$k" ]] && c=$((c + 1))
      done <"$f"
    fi
    (( c > 0 )) && t+="${t:+, }$c $k"
  done
  printf '%s' "${t:-no entries}"
}

# Ship when anything was committed, else end stale. rc 1 when ship failed.
fi_af_sweep_finish() {
  local id="$1" r="$FI_AF_ST/running/$1"
  fi_af_item_read "$r" || return 1
  if (( ${AFI_fixed:-0} == 0 )); then
    fi_af_finish "$id" stale "sweep fixed nothing ($(_fi_af_sweep_tally "$id"))"
    return 0
  fi
  [[ -n "$FI_AF_TESTCMD" ]] || FI_AF_TESTCMD="$(fi_af_test_command "$AFI_wt" 2>/dev/null || true)"
  if fi_af_sweep_ship; then
    fi_af_item_set "$r" pr "$FI_AF_PR"
    # Queue the rest BEFORE this item moves to done/, so fi_af_sweep_pending
    # never sees a gap in which a Stop hook could queue an unrelated sweep.
    if [[ "${AFI_more:-}" == 1 ]] && fi_af_enabled; then _fi_af_sweep_queue_next "$id"; fi
    fi_af_finish "$id" shipped "PR #$FI_AF_PR, $AFI_fixed fixed, merge $FI_AF_MERGE, \$$(_fi_af_own_cost)"
    return 0
  fi
  _fi_af_sweep_ship_failed "$id"
  return 1
}

# The continuation item: what fi_af_sweep_check writes, plus the chain state.
# skip_files holds every file an earlier batch of the chain changed (the
# paths its entries cite plus its whole diff): their PRs may not be merged
# yet, so a later batch cut from origin/<base> must not touch them. The item keeps this batch's base and resolved engine.
_fi_af_sweep_queue_next() {
  local id="$1" nxt skip="${AFI_skip_files:-}" held="${AFI_held_files:-}" loc out key text p
  nxt=$(( $(_fi_af_sweep_batch_no) + 1 ))
  while IFS=$'\t' read -r loc out key text || [[ -n "$loc" ]]; do
    [[ "$out" == "fixed" ]] || continue
    p="${loc%%:*}"
    [[ -n "$p" && ":$skip:" != *":$p:"* ]] && skip+="${skip:+:}$p"
  done <"$FI_AF_ST/sweeps/$id.outcomes"
  # An entry dropped for touching a chain file stays [open]: its own file
  # joins the skip set (so later batches skip its entries before paying a
  # fixer for them) and the held list (so the log says why).
  if [[ -f "$FI_AF_ST/sweeps/$id.held" ]]; then
    while IFS= read -r p || [[ -n "$p" ]]; do
      [[ -n "$p" && ":$held:" != *":$p:"* ]] && held+="${held:+:}$p"
      [[ -n "$p" && ":$skip:" != *":$p:"* ]] && skip+="${skip:+:}$p"
    done <"$FI_AF_ST/sweeps/$id.held"
  fi
  # Every file this batch changed, not just the ones its entries cite: a
  # fixer's test file or a shared helper conflicts with the batch's PR too.
  if [[ -n "${AFI_base_sha:-}" && -n "${AFI_head:-}" ]]; then
    while IFS= read -r p || [[ -n "$p" ]]; do
      [[ -n "$p" && ":$skip:" != *":$p:"* ]] && skip+="${skip:+:}$p"
    done < <(git -C "$AFI_root" -c core.quotepath=off diff --name-only --no-renames "$AFI_base_sha" "$AFI_head" 2>/dev/null)
  fi
  # A chain never switches engines: a batch that closed before any engine
  # call (launcher B, every entry settled) still names the one its harness
  # would run, never auto.
  local ce="$AFI_engine"
  case "$ce" in claude|codex) ;; *) ce="$(fi_af_item_engine 2>/dev/null || true)" ;; esac
  fi_af_new_id
  fi_af_item_write "$FI_AF_ST/queue/$FI_AF_ID" "id=$FI_AF_ID" "kind=sweep" \
    "root=$AFI_root" "slug=$AFI_slug" "loc=sweep" "engine=$ce" \
    "queued=$(date +%Y-%m-%dT%H:%M:%S)" "crashes=0" \
    "cont=$nxt" "cap_day=$(fi_today)" "chain_cost=${FI_AF_COST:-0}" "chain_tokens=${FI_AF_TOKENS:-0}" \
    "base=$AFI_base" "base_why=$AFI_base_why" "skip_files=$skip" "held_files=$held"
  fi_af_log "$id" "sweep: queued batch $nxt as $FI_AF_ID"
}

# 3.2.1 (ledger lib/autofix-sweep.sh:387): one transient push failure used to
# delete the branch and every verified commit on it. Keep the branch and
# requeue the sweep with its cur past the last entry, so the next run (after
# FOUND_ISSUES_AUTOFIX_SHIP_WAIT seconds) only ships. The
# FOUND_ISSUES_AUTOFIX_SHIP_TRIES-th failure (default 3) ends it failed,
# still keeping the branch, which the result names.
_fi_af_sweep_ship_failed() {
  local id="$1" r="$FI_AF_ST/running/$1" tries max n wait
  tries=$(( ${AFI_ship_tries:-0} + 1 ))
  max="${FOUND_ISSUES_AUTOFIX_SHIP_TRIES:-3}"
  [[ "$max" =~ ^[1-9][0-9]*$ ]] || max=3
  wait="${FOUND_ISSUES_AUTOFIX_SHIP_WAIT:-900}"
  [[ "$wait" =~ ^[0-9]+$ ]] || wait=900
  AFI_ship_tries="$tries"
  fi_af_item_set "$r" ship_tries "$tries"
  # Spec section 9: a batch whose ship fails queues no continuation, even if
  # a retry ships it; the rest waits for the next sweep.
  fi_af_item_set "$r" more ""
  AFI_more=""
  if (( tries >= max )); then
    fi_af_finish "$id" failed "ship: $FI_AF_WHY ($tries tries; branch $AFI_branch kept)"
    return 0
  fi
  n="$(_fi_af_count_lines "$FI_AF_ST/sweeps/$id.entries")"
  fi_af_item_set "$r" cur "$(( n + 1 ))"
  fi_af_item_set "$r" wait_next "$(( $(date +%s) + 10#$wait ))"
  fi_af_requeue "$id" "ship failed ($FI_AF_WHY); branch $AFI_branch kept, the next run retries ship"
}

_fi_af_sweep_pr_body() {
  local tlog="$1" loc out key text
  printf 'Unattended sweep by found-issues auto-fix (launcher %s, engine %s): %s.\n\n' \
    "${AFI_launcher:-A}" "${AFI_engine:-?}" "$(_fi_af_sweep_tally "$AFI_id")"
  printf '| Entry | Outcome | Note |\n|---|---|---|\n'
  while IFS=$'\t' read -r loc out key text || [[ -n "$loc" ]]; do
    printf '| `%s` | %s | %s |\n' "$loc" "$out" "${text//|/\\|}"
  done <"$FI_AF_ST/sweeps/$AFI_id.outcomes"
  printf '\nOne commit per fixed entry; the verifier approved each one.\n\n'
  printf 'Tests: `%s` passed. Last lines:\n\n' "$FI_AF_TESTCMD"
  tail -n 15 "$tlog" 2>/dev/null | sed 's/^/    /'
  printf '\nRun cost: $%s (claude), %s tokens (codex)' "$(_fi_af_own_cost)" "$(_fi_af_own_tokens)"
  _fi_af_pr_models
  printf '\n\n'
  printf 'This PR merges itself when its checks pass (found-issues auto-fix policy).\n'
}

# The commits exist; ship re-runs the tests at head and refuses any tree
# other than head's (plan Review Focus 3), then publishes one PR. An entry
# left half-done (verify exit 3, 6 or 7) is dropped first: only committed,
# approved entries ship; a failed ship keeps the branch and requeues (3.2.1).
fi_af_sweep_ship() {
  local wt="$AFI_wt" tlog="$FI_AF_RUNS/$AFI_id.ship-tests.log" bodyf="$FI_AF_RUNS/$AFI_id.pr-body.md"
  local rows="$FI_AF_RUNS/$AFI_id.publish" loc out key text
  FI_AF_PR="" FI_AF_MERGE="none" FI_AF_WHY=""
  [[ -n "$FI_AF_TESTCMD" ]] || { FI_AF_WHY="no test command"; return 1; }
  git -C "$wt" reset -q --hard "$AFI_head" >/dev/null 2>&1 || true
  git -C "$wt" clean -qfd >/dev/null 2>&1 || true
  fi_af_tests_pass "$wt" "$FI_AF_TESTCMD" "$tlog" || { FI_AF_WHY="tests fail at ship"; return 1; }
  fi_af_reset_ledger "$wt" "$AFI_head"
  git -C "$wt" add -A >/dev/null 2>&1 || true
  if [[ -z "$AFI_verdict_tree" || "$(git -C "$wt" write-tree 2>/dev/null)" != "$AFI_verdict_tree" ]]; then
    FI_AF_WHY="the tree differs from the approved commits (did the tests leave files?)"; return 1
  fi
  : >"$rows"
  while IFS=$'\t' read -r loc out key text || [[ -n "$loc" ]]; do
    [[ "$out" == "fixed" && -n "$key" ]] && printf '%s\t%s\n' "$key" "$loc" >>"$rows"
  done <"$FI_AF_ST/sweeps/$AFI_id.outcomes"
  _fi_af_sweep_pr_body "$tlog" >"$bodyf"
  local title="fix: found-issues sweep ($AFI_fixed entries)" bn
  bn="$(_fi_af_sweep_batch_no)"
  if [[ "${AFI_more:-}" == 1 ]] || (( bn >= 2 )); then
    title="fix: found-issues sweep ($AFI_fixed entries, batch $bn)"
  fi
  _fi_af_publish "$title" "$bodyf" "$rows"
}
