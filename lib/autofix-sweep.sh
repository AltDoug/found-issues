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
    q="$(_fi_af_field "$f" queued)" || continue
    [[ "${q:0:10}" < "$today" ]] || continue
    id="${f##*/}"
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
  fi_af_sweep_pending && return 0
  fi_af_cap_ok sweep "$(fi_af_int dailySweeps 1)" || return 0
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
  engine="$(fi_af_engine 2>/dev/null || true)"
  fi_af_new_id
  fi_af_item_write "$FI_AF_ST/queue/$FI_AF_ID" "id=$FI_AF_ID" "kind=sweep" \
    "root=$root" "slug=$slug" "loc=sweep" "engine=$engine" \
    "queued=$(date +%Y-%m-%dT%H:%M:%S)" "crashes=0"
  printf 'AUTOFIX-SWEEP-DUE %s\n' "$FI_AF_ID"
}

# Spec §6 steps 1-3 at claim time (lock held, queue item read): cap, the
# fresh worktree, the classify/wake pass, then the ordered entry list.
# A sweep requeued today (crash, switch-off, outage) already holds today's
# cap. A sweep over the cap retires stale rather than returning rc 3: rc 3
# writes the day's capped marker, which would stop spot fixes too.
fi_af_sweep_claim() {
  local id="$1" q="$FI_AF_ST/queue/$1" r="$FI_AF_ST/running/$1" file n=0 line capped=0
  [[ "$(_fi_af_field "$q" cap_day)" == "$(fi_today)" ]] && capped=1
  if (( ! capped )) && ! fi_af_cap_ok sweep "$(fi_af_int dailySweeps 1)"; then
    FI_AF_WHY="today's sweep cap is reached; the next trigger queues a new sweep"
    fi_af_retire "$id" stale "$FI_AF_WHY" || fi_af_unlock "$id"; return 5
  fi
  fi_af_item_set "$q" pid "${FI_AF_PID:-}"
  if [[ -n "${FI_AF_PID:-}" ]]; then fi_af_item_set "$q" launcher A; else fi_af_item_set "$q" launcher B; fi
  (( capped )) || fi_af_item_set "$q" cap_day "$(fi_today)"
  mv "$q" "$r" || { fi_af_unlock "$id"; return 1; }
  fi_af_seg_write "$AFI_root"
  if ! fi_af_worktree_add; then fi_af_finish "$id" failed "$FI_AF_WHY"; return 6; fi
  fi_af_item_set "$r" wt "$AFI_wt"
  fi_af_item_set "$r" branch "$AFI_branch"
  # No test command at origin/<base>: retire before the day's slot is spent
  # and before the classifier runs.
  if ! fi_af_test_command "$AFI_wt" >/dev/null 2>&1; then
    fi_af_finish "$id" stale "no test command"; return 5
  fi
  (( capped )) || fi_af_cap_take sweep "$id"
  fi_af_item_set "$r" base "$AFI_base"
  fi_af_item_set "$r" base_why "$AFI_base_why"
  fi_af_item_set "$r" base_sha "$AFI_base_sha"
  fi_af_item_set "$r" head "$AFI_base_sha"
  fi_af_item_set "$r" cur 1
  fi_af_item_set "$r" fixed 0
  AFI_head="$AFI_base_sha" AFI_cur=1 AFI_fixed=0
  mkdir -p "$FI_AF_ST/sweeps"
  file="$(fi_find_issues_file "$AFI_root" 2>/dev/null)" || file=""
  if [[ -n "$file" && -f "$file" ]]; then
    if declare -F fi_af_classify >/dev/null; then fi_af_classify "$file" "$id" || true; fi
    fi_af_sweep_candidates "$file" "$AFI_root" "$(fi_af_int sweepMax 8)" >"$FI_AF_ST/sweeps/$id.entries"
  else
    : >"$FI_AF_ST/sweeps/$id.entries"
  fi
  : >"$FI_AF_ST/sweeps/$id.outcomes"
  while IFS= read -r line || [[ -n "$line" ]]; do n=$((n + 1)); done <"$FI_AF_ST/sweeps/$id.entries"
  if (( n == 0 )); then fi_af_finish "$id" stale "nothing fixable now"; return 5; fi
  fi_af_log "$id" "claimed sweep: $n entries in $AFI_wt ($AFI_branch from origin/$AFI_base)"
}

# Entry number AFI_cur of the sweep, with its base pinned to the last good
# commit, so diff, reset and the verifier see only this entry's change.
fi_af_sweep_load() {
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

# The verifier approved FI_AF_TREE: commit exactly that tree as this entry's
# one commit (spec §6 step 4).
fi_af_sweep_commit() {
  local id="$1" r="$FI_AF_ST/running/$1" frag
  FI_AF_WHY=""
  fi_af_reset_ledger "$AFI_wt" "$AFI_head"
  git -C "$AFI_wt" add -A >/dev/null 2>&1 || true
  if [[ -z "$FI_AF_TREE" || "$(git -C "$AFI_wt" write-tree 2>/dev/null)" != "$FI_AF_TREE" ]]; then
    FI_AF_WHY="the change differs from what the verifier approved"; return 1
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
  local id="$1" outcome="$2" text="$3" rc=0
  text="${text//$'\n'/ }"
  text="${text:0:160}"
  git -C "$AFI_wt" reset -q --hard "$AFI_head" >/dev/null 2>&1 || true
  git -C "$AFI_wt" clean -qfd >/dev/null 2>&1 || true
  _fi_af_ledger_outcome "$outcome" "$text" || rc=$?
  (( rc == 0 )) || fi_af_log "$id" "ledger not updated for $AFI_loc $outcome (rc $rc)"
  _fi_af_sweep_record "$outcome" "$text"
  fi_af_log "$id" "sweep: $AFI_loc $outcome: $text"
  _fi_af_sweep_advance
}

# Launcher A for a claimed sweep: each entry through the shared fix loop,
# then one PR (spec §6 steps 4-5). A budget stop or an engine outage leaves
# the current entry untouched and ships what is committed (ruling 7).
_fi_af_run_sweep() {
  local id="$1" engine_opt="$2" r="$FI_AF_ST/running/$1" engine
  fi_af_item_read "$r" || return 0
  FI_AF_COST="${AFI_cost:-0}" FI_AF_TOKENS="${AFI_tokens:-0}"
  if ! FI_AF_TESTCMD="$(fi_af_test_command "$AFI_wt")"; then
    fi_af_finish "$id" stale "no test command"; return 0
  fi
  if ! engine="$(fi_af_engine "${engine_opt:-$AFI_engine}")" || ! command -v "$engine" >/dev/null 2>&1; then
    fi_af_finish "$id" failed "no ${engine:-claude or codex} on PATH"; return 0
  fi
  AFI_engine="$engine"
  while fi_af_sweep_load "$id"; do
    fi_af_enabled || break
    _fi_af_fix_loop "$id" "$engine"
    fi_af_item_set "$r" cost "$FI_AF_COST"
    fi_af_item_set "$r" tokens "$FI_AF_TOKENS"
    case "$FI_AF_OUTCOME" in
      outage)
        fi_af_log "$id" "sweep: engine error: $FI_AF_OUTCOME_TEXT"
        _fi_af_reset_wt; break ;;
      approved)
        fi_af_sweep_commit "$id" || fi_af_sweep_settle "$id" failed "commit: $FI_AF_WHY" ;;
      failed)
        if [[ "$FI_AF_OUTCOME_TEXT" == "run budget spent"* ]]; then
          fi_af_log "$id" "sweep: $FI_AF_OUTCOME_TEXT"
          _fi_af_reset_wt; break
        fi
        fi_af_sweep_settle "$id" failed "$FI_AF_OUTCOME_TEXT" ;;
      *) fi_af_sweep_settle "$id" "$FI_AF_OUTCOME" "$FI_AF_OUTCOME_TEXT" ;;
    esac
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
  for k in fixed already-fixed decide manual failed; do
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
    fi_af_finish "$id" shipped "PR #$FI_AF_PR, $AFI_fixed fixed, merge $FI_AF_MERGE, \$${FI_AF_COST:-0}"
    return 0
  fi
  fi_af_finish "$id" failed "ship: $FI_AF_WHY"
  return 1
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
  printf '\nRun cost: $%s (claude), %s tokens (codex)\n\n' "${FI_AF_COST:-0}" "${FI_AF_TOKENS:-0}"
  printf 'This PR merges itself when its checks pass (found-issues auto-fix policy).\n'
}

# The commits exist; ship re-runs the tests at head and refuses any tree
# other than head's (plan Review Focus 3), then publishes one PR. An entry
# left half-done (verify exit 3, 6 or 7) is dropped first: only committed,
# approved entries ship, and a failed ship would delete their branch.
fi_af_sweep_ship() {
  local wt="$AFI_wt" tlog="$FI_AF_RUNS/$AFI_id.ship-tests.log" bodyf="$FI_AF_RUNS/$AFI_id.pr-body.md"
  local rows="$FI_AF_RUNS/$AFI_id.publish" loc out key text
  FI_AF_PR="" FI_AF_MERGE="none" FI_AF_WHY=""
  [[ -n "$FI_AF_TESTCMD" ]] || { FI_AF_WHY="no test command"; return 1; }
  git -C "$wt" reset -q --hard "$AFI_head" >/dev/null 2>&1 || true
  git -C "$wt" clean -qfd >/dev/null 2>&1 || true
  fi_af_run_tests "$wt" "$FI_AF_TESTCMD" "$tlog" || { FI_AF_WHY="tests fail at ship"; return 1; }
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
  _fi_af_publish "fix: found-issues sweep ($AFI_fixed entries)" "$bodyf" "$rows"
}
