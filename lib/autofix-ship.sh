#!/usr/bin/env bash
# autofix-ship.sh — turn a verified worktree into a self-merging PR
# (spec 2026-10-03 §5 step 6; audit prompt-9: the (PR:) annotation is
# committed onto the PR branch so it reaches the default branch).
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   fi_af_ledger_paths <wt>
#   fi_af_reset_ledger <wt> <base>
#   fi_af_diff <wt> <base>
#   fi_af_run_tests <wt> <cmd> <log>
#   fi_af_tests_pass <wt> <cmd> <log>
#   fi_af_test_failures <log>
#   fi_af_test_report <log> [n]
#   fi_af_annotate_ledger <ledger|""> <annotation>
#   fi_af_spawn <cwd> <found-issues args...>
#   fi_af_ship
#   _fi_af_publish <title> <body-file> <key-loc-rows-file>
#   fi_af_merge_when_green <N>
#   _fi_af_mwg_unconflict <N> <slug> <base> <head>

# shellcheck disable=SC2154  # AFI_*/FE_* come from autofix-queue.sh / parse-entries.sh

FI_AF_PR="" FI_AF_MERGE="" FI_AF_TESTCMD="" FI_AF_VERDICT_REASON=""
FI_SELF="${FI_BIN_DIR:-}/found-issues"

# The worktree's own ledger files, relative. Only paths INSIDE the worktree:
# fi_find_issues_file would walk up into the source checkout when the
# worktree has none (Review Focus 2).
fi_af_ledger_paths() {
  local p
  for p in docs/found-issues.md docs/found-issues-archive.md .found-issues.md; do
    [[ -f "$1/$p" ]] && printf '%s\n' "$p"
  done
  return 0
}

# The fixer must not change the ledger, and a headless child's SessionStart
# sync may have (Review Focus 3). Put every ledger file back to <ref> — the
# fixed list, not just the files that still exist, or a deleted ledger
# would ship as a deletion.
fi_af_reset_ledger() {
  local wt="$1" ref="$2" p
  for p in docs/found-issues.md docs/found-issues-archive.md .found-issues.md; do
    if git -C "$wt" cat-file -e "$ref:$p" 2>/dev/null; then
      git -C "$wt" checkout -q "$ref" -- "$p" 2>/dev/null || true
    else
      rm -f "$wt/$p"
    fi
  done
}

# 3.5.1: a fixer on Git for Windows can rewrite lines it never meant to touch
# with CRLF; kh2-midgar's verifier rejected otherwise good fixes three times
# for an LF->CRLF rewrite of an unrelated test block. Strip CR from each
# changed text file whose <ref> blob has none. Files that had CR at <ref>,
# new files and binary files are left as they are, and so is a checkout git
# itself converts to CRLF (core.autocrlf=true, eol=crlf): its add normalizes.
fi_af_restore_eol() {
  local wt="$1" ref="$2" add _ f tmp
  [[ "$(git -C "$wt" config --get core.autocrlf 2>/dev/null)" != true ]] || return 0
  while IFS=$'\t' read -r add _ f || [[ -n "$f" ]]; do
    [[ "$add" != "-" && -f "$wt/$f" ]] || continue
    git -C "$wt" cat-file -e "$ref:$f" 2>/dev/null || continue
    [[ "$(git -C "$wt" check-attr eol -- "$f" 2>/dev/null)" != *": eol: crlf" ]] || continue
    grep -q $'\r' "$wt/$f" || continue
    git -C "$wt" cat-file -p "$ref:$f" | grep -q $'\r' && continue
    tmp="$wt/$f.fi-eol.$$"
    # cat > keeps the file's mode (an executable stays executable).
    tr -d '\r' < "$wt/$f" > "$tmp" && cat "$tmp" > "$wt/$f"
    rm -f "$tmp"
  done < <(git -C "$wt" diff --numstat "$ref" 2>/dev/null)
}

# <ref> is the claim-time commit (base_sha), never the moving origin/<base>.
fi_af_diff() {
  fi_af_reset_ledger "$1" "$2"
  fi_af_restore_eol "$1" "$2"
  git -C "$1" add -A >/dev/null 2>&1 || true
  git -C "$1" diff --cached "$2"
}

# The test command is the repo's suite, not part of the fixer: it runs
# without the child marker fi_af_child sets, as a developer would run it.
# Inherited, the marker turned every interactive-path session-start test in
# this repo red, so every auto-fix of found-issues itself failed (3.0.2).
fi_af_run_tests() {
  fi_af_child "$3" "$3.err" "$1" bash -c "unset FOUND_ISSUES_AUTOFIX_CHILD; $2" || return $?
}

# 3.4.3: a red suite after a change is re-run once before it counts. A flaky
# test (kh2-midgar: a shared build lock) failed a good fix, fed the next
# attempt unrelated failures and tagged the entry autofix-failed. A watchdog
# kill is not re-run; the first log is kept as <log>.first.log.
fi_af_tests_pass() {
  local wt="$1" cmd="$2" log="$3" first rc=0
  fi_af_run_tests "$wt" "$cmd" "$log" || rc=$?
  (( rc == 0 )) && return 0
  [[ -z "${FI_AF_CHILD_TIMEDOUT:-}" ]] || return "$rc"
  first="$(fi_af_test_failures "$log" | head -n 1)"
  mv -f "$log" "${log%.log}.first.log" 2>/dev/null || true
  fi_af_log "$AFI_id" "tests failed (${first:-exit $rc}); re-running once"
  fi_af_run_tests "$wt" "$cmd" "$log" || return $?
  fi_af_log "$AFI_id" "tests passed on the re-run: the first failure was flaky"
}

# The failing tests in a test log, at most 80 lines: TAP "not ok" lines with
# their "#" diagnostics, and the failure lines of pytest, go test and jest.
# A tail alone hid them: a full bats run printed its failures hundreds of
# lines above the last 30.
fi_af_test_failures() {
  awk '
    n >= 80 { exit }
    /^not ok / { print; n++; tap = 1; next }
    tap && /^#/ { print; n++; next }
    { tap = 0 }
    /^(FAILED |--- FAIL: |FAIL )/ { print; n++ }
  ' "$1" 2>/dev/null || true
}

# What a fixer reads after a run: the failing tests, then the last <n> lines.
fi_af_test_report() {
  local f
  f="$(fi_af_test_failures "$1")"
  [[ -n "$f" ]] && printf 'Failing tests:\n%s\n\n' "$f"
  printf 'Last lines:\n'
  tail -n "${2:-30}" "$1" 2>/dev/null || true
}

# Append a closing annotation to THIS item's entry (matched by dedup key) in
# <ledger> ("" = the source checkout's). `annotate-pr --pick <loc>` matches
# by location, so with two entries on one line it tags the wrong one or both.
fi_af_annotate_ledger() {
  # Batch 3: rc 3 = the ledger changed between the snapshot and the write;
  # the entry is re-found and the write tried again (three attempts).
  local try rc=0
  for try in 1 2 3; do
    rc=0
    _fi_af_annotate_ledger_once "$1" "$2" || rc=$?
    (( rc == 3 )) || return "$rc"
  done
  return "$rc"
}

_fi_af_annotate_ledger_once() {
  fi_af_find_entry "$1" || return 1
  local new="$FI_AF_ENTRY $2" snapshot tmp line done_one=0
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

fi_af_spawn() {
  local cwd="$1"
  shift
  # 3>&-: a watcher that outlives its caller (the merge guard polls for up to
  # an hour) must not hold the caller's fd 3, which bats waits on for EOF.
  ( cd "$cwd" && nohup "$FI_SELF" "$@" </dev/null >>"$FI_AF_RUNS/spawn.log" 2>&1 3>&- & )
}

# 3.3.0: a Codex run's PR body names the model each role ran on.
_fi_af_pr_models() {
  [[ "${AFI_engine:-}" == codex ]] || return 0
  printf ' \xe2\x80\x94 codex models: fixer %s, verifier %s' \
    "$(fi_af_codex_margs fixer; printf '%s' "$FI_AF_MDESC")" "$(fi_af_codex_margs verifier; printf '%s' "$FI_AF_MDESC")"
}

_fi_af_pr_body() {
  local tlog="$1"
  printf 'Unattended fix by found-issues auto-fix (launcher %s, engine %s).\n\n' "${AFI_launcher:-A}" "${AFI_engine:-?}"
  printf 'Issue:\n\n    %s\n\n' "$AFI_entry"
  printf 'Tests: `%s` passed. Last lines:\n\n' "$FI_AF_TESTCMD"
  tail -n 15 "$tlog" 2>/dev/null | sed 's/^/    /'
  printf '\nVerifier: approved — %s\n' "${FI_AF_VERDICT_REASON:-n/a}"
  printf 'Run cost: $%s (claude), %s tokens (codex)' "${FI_AF_COST:-0}" "${FI_AF_TOKENS:-0}"
  _fi_af_pr_models
  printf '\n\n'
  printf 'This PR merges itself when its checks pass (found-issues auto-fix policy).\n'
}

fi_af_ship() {
  local wt="$AFI_wt" runlog="$FI_AF_RUNS/$AFI_id.log"
  local ref="${AFI_base_sha:-origin/$AFI_base}"
  local tlog="$FI_AF_RUNS/$AFI_id.ship-tests.log" bodyf="$FI_AF_RUNS/$AFI_id.pr-body.md" frag
  # shellcheck disable=SC2034  # FI_AF_SHIP_STALE is read by lib/autofix.sh
  FI_AF_PR="" FI_AF_MERGE="none" FI_AF_WHY="" FI_AF_SHIP_STALE=""
  # 3.6.0: rc 3 = fixed elsewhere meanwhile; the caller retires it stale.
  # Not on a ship retry: this item's own PR may already annotate the base.
  if [[ ! "${AFI_ship_tries:-0}" =~ ^[1-9] ]] && fi_af_fixed_elsewhere; then
    FI_AF_SHIP_STALE=1; return 3
  fi
  [[ -n "$FI_AF_TESTCMD" ]] || FI_AF_TESTCMD="$(fi_af_test_command "$wt")" || { FI_AF_WHY="no test command"; return 1; }
  fi_af_reset_ledger "$wt" "$ref"
  fi_af_tests_pass "$wt" "$FI_AF_TESTCMD" "$tlog" || { FI_AF_WHY="tests fail at ship"; return 1; }
  git -C "$wt" add -A
  if git -C "$wt" diff --cached --quiet "$ref"; then FI_AF_WHY="nothing to ship"; return 1; fi
  # Fail closed: an approval with no recorded tree (a write that failed, or
  # an item file edited by hand) never ships.
  [[ -n "${AFI_verdict_tree:-}" ]] || { FI_AF_WHY="no verifier-approved tree recorded (run: found-issues autofix verify $AFI_id)"; return 1; }
  if [[ "$(git -C "$wt" write-tree 2>/dev/null)" != "$AFI_verdict_tree" ]]; then
    FI_AF_WHY="the change differs from what the verifier approved (did the tests leave files?)"; return 1
  fi
  fi_parse_entry_vars "$AFI_entry" || true
  frag="${FE_symptom:-$AFI_loc}"
  frag="${frag:0:60}"
  git -C "$wt" commit -q -m "fix: $frag (found-issues $AFI_loc)" >>"$runlog" 2>&1 \
    || { FI_AF_WHY="git commit refused (a commit hook?)"; return 1; }
  _fi_af_pr_body "$tlog" >"$bodyf"
  printf '%s\t%s\n' "$AFI_key" "$AFI_loc" >"$FI_AF_RUNS/$AFI_id.publish"
  _fi_af_publish "fix: $frag" "$bodyf" "$FI_AF_RUNS/$AFI_id.publish"
}

# 3.4.2 (ledger lib/autofix-ship.sh:179): the landing branch can be deleted
# after the claim (the session's branch merged mid-run). Then the item's own
# commits (cut point = the item's recorded base_sha) are replayed onto the
# branch it merged into, the tests re-run there, and the item records the new
# base and the rebased tree as the approved one (the verifier's diff on the
# new base; a ship retry compares against it). Exit 2 from ls-remote is "no
# such branch"; any other failure leaves the base alone for push and pr
# create to report. A failed retarget leaves the branch where it was.
_fi_af_retarget() {
  local old="$AFI_base" runlog="$FI_AF_RUNS/$AFI_id.log" rc=0 new cut was r="$FI_AF_ST/running/$AFI_id"
  FI_AF_RETARGETED=""
  git -C "$AFI_wt" ls-remote --exit-code origin "refs/heads/$old" >/dev/null 2>&1 || rc=$?
  (( rc == 2 )) || return 0
  if ! new="$(cd "$AFI_wt" && gh pr list --repo "$AFI_slug" --head "$old" --state merged --limit 1 \
    --json baseRefName --jq '.[0].baseRefName // ""' 2>>"$runlog")"; then
    FI_AF_WHY="landing branch $old was deleted on origin; could not look up where landing branch $old merged (gh pr list failed)"; return 1
  fi
  if [[ -z "$new" || "$new" == "$old" ]] \
     || ! git -C "$AFI_wt" fetch -q origin "+refs/heads/$new:refs/remotes/origin/$new" >>"$runlog" 2>&1; then
    FI_AF_WHY="landing branch $old was deleted on origin and its merge target is unknown"; return 1
  fi
  cut="${AFI_base_sha:-}"
  [[ -n "$cut" ]] || { FI_AF_WHY="landing branch $old was deleted on origin (merged into $new); no recorded cut point to rebase from"; return 1; }
  was="$(git -C "$AFI_wt" rev-parse HEAD)"
  if ! git -C "$AFI_wt" rebase -q --onto "origin/$new" "$cut" "$AFI_branch" >>"$runlog" 2>&1; then
    git -C "$AFI_wt" rebase --abort >/dev/null 2>&1 || true
    FI_AF_WHY="landing branch $old was deleted on origin (merged into $new) and the fix does not rebase onto origin/$new"; return 1
  fi
  if [[ "$(git -C "$AFI_wt" rev-parse HEAD)" == "$(git -C "$AFI_wt" rev-parse "origin/$new")" ]]; then
    git -C "$AFI_wt" reset -q --hard "$was" >/dev/null 2>&1 || true
    FI_AF_WHY="landing branch $old was deleted on origin (merged into $new); the fix is already on $new"; return 1
  fi
  if ! fi_af_tests_pass "$AFI_wt" "$FI_AF_TESTCMD" "$FI_AF_RUNS/$AFI_id.retarget-tests.log"; then
    git -C "$AFI_wt" reset -q --hard "$was" >/dev/null 2>&1 || true
    FI_AF_WHY="landing branch $old was deleted on origin (merged into $new); tests fail after rebasing onto origin/$new"; return 1
  fi
  git -C "$AFI_wt" reset -q --hard HEAD >/dev/null 2>&1 || true
  git -C "$AFI_wt" clean -qfd >/dev/null 2>&1 || true
  AFI_base="$new" AFI_base_why="$old merged into $new"
  AFI_base_sha="$(git -C "$AFI_wt" rev-parse "origin/$new")"
  AFI_head="$(git -C "$AFI_wt" rev-parse HEAD)"
  AFI_verdict_tree="$(git -C "$AFI_wt" rev-parse 'HEAD^{tree}')"
  fi_af_item_set "$r" base "$AFI_base"
  fi_af_item_set "$r" base_why "$AFI_base_why"
  fi_af_item_set "$r" base_sha "$AFI_base_sha"
  fi_af_item_set "$r" verdict_tree "$AFI_verdict_tree"
  [[ "${AFI_kind:-}" == sweep ]] && fi_af_item_set "$r" head "$AFI_head"
  FI_AF_RETARGETED=1
  fi_af_log "$AFI_id" "landing branch $old is gone on origin (merged into $new): rebased onto origin/$new"
}

# Shared by a spot ship and a sweep ship: push the branch, open the PR,
# annotate every <key>\t<loc> row on the PR branch's ledger (one commit, so
# the annotation reaches the default branch, prompt-9) and in the source
# ledger (where sync closes it on merge), then arm auto-merge.
_fi_af_publish() {
  local title="$1" bodyf="$2" rows="$3" wt="$AFI_wt" br="$AFI_branch" base
  local runlog="$FI_AF_RUNS/$AFI_id.log" url="" p wl="" ann key loc n=0 msg force=""
  local keep_key="$AFI_key" keep_loc="$AFI_loc"
  _fi_af_retarget || return 1
  base="$AFI_base"
  [[ "$FI_AF_RETARGETED" == 1 ]] && force="--force-with-lease"
  git -C "$wt" push -q $force -u origin "$br" >>"$runlog" 2>&1 || { FI_AF_WHY="git push failed"; return 1; }
  # A ship retry (3.2.1) may follow a try whose PR was opened after all.
  if [[ "${AFI_ship_tries:-0}" =~ ^[1-9] ]]; then
    p="$(cd "$wt" && gh pr list --repo "$AFI_slug" --head "$br" --state open --json number --jq '.[0].number // ""' 2>>"$runlog" || true)"
    [[ "$p" =~ ^[0-9]+$ ]] && url="https://github.com/$AFI_slug/pull/$p"
  fi
  [[ -n "$url" ]] || url="$(cd "$wt" && gh pr create --repo "$AFI_slug" --base "$base" --head "$br" --title "$title" --body-file "$bodyf" 2>>"$runlog")" \
    || { FI_AF_WHY="gh pr create failed"; return 1; }
  FI_AF_PR="${url##*/}"
  [[ "$FI_AF_PR" =~ ^[0-9]+$ ]] || { FI_AF_WHY="no PR number in: $url"; return 1; }
  # On the item at once, so a cancel from now on sees the open PR (review I4).
  fi_af_item_set "$FI_AF_ST/running/$AFI_id" pr "$FI_AF_PR" || true
  fi_af_log "$AFI_id" "opened PR #$FI_AF_PR"

  ann="(PR: $AFI_slug#$FI_AF_PR)"
  # The PR branch's ledger, when origin already has the entry (prompt-9). A
  # continuation batch leaves it alone: batch PRs are cut from the same base
  # and adjacent-line annotations would conflict once the first merges (spec
  # section 9); the source ledger below is where sync closes the entry.
  if _fi_af_sweep_is_cont; then
    fi_af_log "$AFI_id" "PR-branch ledger annotation skipped for a continuation batch"
  else
    for p in docs/found-issues.md .found-issues.md; do
      [[ -f "$wt/$p" ]] && { wl="$p"; break; }
    done
  fi
  local annotated=$'\n' pushed=0 cur
  while IFS=$'\t' read -r key loc || [[ -n "$key" ]]; do
    [[ -n "$key" ]] || continue
    AFI_key="$key" AFI_loc="$loc"
    if [[ -n "$wl" ]] && fi_af_annotate_ledger "$wt/$wl" "$ann"; then
      n=$((n + 1)); msg="annotate $loc with PR $FI_AF_PR"; annotated+="$key"$'\n'
    fi
  done <"$rows"
  if (( n > 0 )); then
    (( n == 1 )) || msg="annotate $n entries with PR $FI_AF_PR"
    git -C "$wt" add -- "$wl"
    if git -C "$wt" commit -q -m "docs(found-issues): $msg" >>"$runlog" 2>&1; then
      if git -C "$wt" push -q origin "$br" >>"$runlog" 2>&1; then pushed=1; else fi_af_log "$AFI_id" "ledger annotation push failed"; fi
    fi
  fi
  # The source checkout's ledger, where sync will close the entry on merge. A
  # PR that lands on the branch this checkout is on already carries the
  # annotation, and an uncommitted copy here would abort the user's next
  # plain git pull (3.3.1). Anywhere else (a continuation batch, an entry
  # origin never saw, another branch) the source ledger is annotated.
  cur="$(git -C "$AFI_root" symbolic-ref -q --short HEAD 2>/dev/null || true)"
  while IFS=$'\t' read -r key loc || [[ -n "$key" ]]; do
    [[ -n "$key" ]] || continue
    AFI_key="$key" AFI_loc="$loc"
    if (( pushed )) && [[ -n "$cur" && "$cur" == "$base" && "$annotated" == *$'\n'"$key"$'\n'* ]]; then
      fi_af_log "$AFI_id" "source ledger annotation skipped for $loc: the PR lands on $base, this checkout's branch, and carries it"
      fi_af_inflight_mark "$key" "$FI_AF_PR" || fi_af_log "$AFI_id" "in-flight record failed for $loc"
      continue
    fi
    fi_af_annotate_ledger "" "$ann" || fi_af_log "$AFI_id" "source ledger annotation failed for $loc"
  done <"$rows"
  AFI_key="$keep_key" AFI_loc="$keep_loc"

  if ( cd "$wt" && gh pr merge "$FI_AF_PR" --auto --squash --repo "$AFI_slug" ) >>"$runlog" 2>&1; then
    FI_AF_MERGE="auto"
    # Batch 4 (ledger lib/autofix-ship.sh:329): GitHub never fires an armed
    # auto-merge on a CONFLICTING PR, so two fix PRs cut from one base leave
    # the second open for good. A guard watcher resolves a ledger-only
    # conflict (3.6.1) and leaves once the PR merges; it never merges itself,
    # so it cannot fight the armed auto-merge.
    fi_af_spawn "$AFI_root" autofix merge-when-green "$FI_AF_PR" --repo "$AFI_slug" --guard
  else
    fi_af_spawn "$AFI_root" autofix merge-when-green "$FI_AF_PR" --repo "$AFI_slug"
    FI_AF_MERGE="merge-when-green"
  fi
  fi_af_log "$AFI_id" "merge: $FI_AF_MERGE"
}

# gh runs with --repo <origin slug>: without it gh prefers an `upstream`
# remote, so a fork would get its PR merged on the upstream project.
# "No checks" must hold on two looks a poll apart: right after a push the
# new head has no checks YET, and merging then skips CI (spec §5.6 means a
# repo with no checks at all).
#
# 3.6.1 (ledger lib/autofix-ship.sh:231): a PR that conflicts with its base
# only in the ledger (fix PRs cut from one base annotate adjacent entries) is
# brought up to date by _fi_af_mwg_unconflict, then waited on again; it used
# to give up with "merging PR #N failed" and nothing retried.
#
# Batch 4: with guard=1 (merge-when-green <N> --guard) the watch is only a
# conflict guard for a PR whose auto-merge is armed: it never calls gh pr
# merge, so it cannot race the armed auto-merge, and it returns 0 as soon as
# the PR is MERGED or CLOSED.
fi_af_merge_when_green() {
  local n="$1" slug="${2:-}" guard="${3:-0}" i v st ck mg br hr nones=0 polls="${FOUND_ISSUES_AUTOFIX_MERGE_POLLS:-60}" pause="${FOUND_ISSUES_AUTOFIX_MERGE_SLEEP:-60}"
  local jqf='[.state, ([.statusCheckRollup[]? | (.conclusion // .state // "")] | if length == 0 then "none" elif any(. == "FAILURE" or . == "ERROR" or . == "CANCELLED" or . == "TIMED_OUT" or . == "ACTION_REQUIRED" or . == "STARTUP_FAILURE") then "fail" elif all(. == "SUCCESS" or . == "SKIPPED" or . == "NEUTRAL") then "green" else "pending" end), (.mergeable // ""), (.baseRefName // ""), (.headRefName // "")] | join("|")'
  [[ -n "$slug" ]] || slug="$(fi_repo_id 2>/dev/null || true)"
  [[ -n "$slug" ]] || { fi_err "autofix: merge-when-green needs a GitHub repo (--repo owner/name)"; return 1; }
  FI_AF_MWG_FIXES=0
  for (( i = 0; i < polls; i++ )); do
    v="$(gh pr view "$n" --repo "$slug" --json state,statusCheckRollup,mergeable,baseRefName,headRefName --jq "$jqf" 2>/dev/null || true)"
    IFS='|' read -r st ck mg br hr <<<"$v" || true
    if [[ "$st" == OPEN && "$mg" == CONFLICTING ]]; then
      _fi_af_mwg_unconflict "$n" "$slug" "$br" "$hr" || return 1
      nones=0; sleep "$pause"; continue
    fi
    case "$st $ck" in
      MERGED*|CLOSED*) printf 'PR #%s is already %s\n' "$n" "$st"; return 0 ;;
      "OPEN none")
        nones=$((nones + 1))
        if (( nones >= 2 && ! guard )); then
          _fi_af_mwg_merge "$n" "$slug" && return 0
          _fi_af_mwg_refused "$n" "$slug" "$br" "$hr" || return 1
          nones=0
        fi ;;
      "OPEN green")
        (( guard )) && { sleep "$pause"; continue; }
        _fi_af_mwg_merge "$n" "$slug" && return 0
        _fi_af_mwg_refused "$n" "$slug" "$br" "$hr" || return 1 ;;
      "OPEN fail") fi_err "autofix: PR #$n checks failed — not merging"; return 1 ;;
      *) nones=0 ;;
    esac
    sleep "$pause"
  done
  fi_err "autofix: PR #$n still pending after $polls checks — not merging"
  return 1
}

FI_AF_MWG_FIXES=0 FI_AF_MWG_ERR=""

# Squash-merge <N>; a refusal's message is kept in FI_AF_MWG_ERR.
_fi_af_mwg_merge() {
  local n="$1" slug="$2"
  if FI_AF_MWG_ERR="$(gh pr merge "$n" --squash --repo "$slug" 2>&1 >/dev/null)"; then
    printf 'merged PR #%s\n' "$n"; return 0
  fi
  [[ -z "$FI_AF_MWG_ERR" ]] || printf '%s\n' "$FI_AF_MWG_ERR" >&2
  return 1
}

# After a refused merge: GitHub computes mergeable lazily, so a PR it called
# UNKNOWN can still be refused for conflicts — by the API ("Pull Request has
# merge conflicts") or by gh itself ("is not mergeable: the merge commit
# cannot be cleanly created"). Those are resolved like a CONFLICTING PR
# (rc 0 = keep waiting); any other refusal ends the watch.
_fi_af_mwg_refused() {
  local n="$1" slug="$2" br="$3" hr="$4"
  if [[ "$FI_AF_MWG_ERR" == *"merge conflict"* || "$FI_AF_MWG_ERR" == *"cannot be cleanly created"* ]]; then
    _fi_af_mwg_unconflict "$n" "$slug" "$br" "$hr" && return 0
    return 1
  fi
  fi_err "autofix: merging PR #$n failed"
  return 1
}

# Merge origin/<base> into the PR branch <head> in a throwaway worktree of
# the checkout merge-when-green runs in, and push it (a merge commit, so no
# force). Only ledger conflicts are resolved: the code then merges exactly as
# GitHub would have merged a PR that did not conflict, and the PR's checks
# run again on the new head before it merges. A head that already contains
# its base is GitHub's stale mergeable value, not a conflict: nothing is
# done and nothing is counted. At most 3 updates per watch.
_fi_af_mwg_unconflict() {
  local n="$1" slug="$2" base="$3" head="$4" root tmp rc=0 own
  if [[ -z "$base" || -z "$head" ]]; then
    fi_err "autofix: PR #$n has merge conflicts and gh did not name its branches — not merging"; return 1
  fi
  if ! root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    fi_err "autofix: PR #$n has merge conflicts; run merge-when-green inside a checkout of $slug to resolve them"; return 1
  fi
  own="$(cd "$root" && fi_repo_id 2>/dev/null || true)"
  if [[ "$(printf '%s' "$own" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')" ]]; then
    fi_err "autofix: PR #$n has merge conflicts, but this checkout's origin is ${own:-not a GitHub repo}, not $slug — not merging"; return 1
  fi
  if ! git -C "$root" fetch -q origin "+refs/heads/$head:refs/remotes/origin/$head" "+refs/heads/$base:refs/remotes/origin/$base" >/dev/null 2>&1; then
    fi_err "autofix: PR #$n has merge conflicts and fetching $head and $base failed — not merging"; return 1
  fi
  git -C "$root" merge-base --is-ancestor "refs/remotes/origin/$base" "refs/remotes/origin/$head" 2>/dev/null && return 0
  FI_AF_MWG_FIXES=$((FI_AF_MWG_FIXES + 1))
  if (( FI_AF_MWG_FIXES > 3 )); then
    fi_err "autofix: PR #$n still conflicts with $base after 3 updates — not merging"; return 1
  fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/fi-mwg.XXXXXX")" || { fi_err "autofix: PR #$n: no temp dir — not merging"; return 1; }
  if git -C "$root" worktree add -q --detach "$tmp/wt" "refs/remotes/origin/$head" >/dev/null 2>&1; then
    _fi_af_mwg_update "$n" "$slug" "$tmp/wt" "$base" "$head" || rc=$?
    git -C "$root" worktree remove --force "$tmp/wt" >/dev/null 2>&1 || true
  else
    fi_err "autofix: PR #$n has merge conflicts and a worktree of $head could not be made — not merging"; rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

_fi_af_mwg_update() {
  local n="$1" slug="$2" wt="$3" base="$4" head="$5" files f bad="" mb out lrc=0
  local ann="(PR: $slug#$n)"
  if ! out="$(git -C "$wt" merge -q --no-edit "refs/remotes/origin/$base" 2>&1)"; then
    files="$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null || true)"
    while IFS= read -r f || [[ -n "$f" ]]; do
      case "$f" in
        "") ;;
        docs/found-issues.md|docs/found-issues-archive.md|.found-issues.md) ;;
        *) bad="${bad:+$bad, }$f" ;;
      esac
    done <<<"$files"
    if [[ -z "$files" ]]; then
      git -C "$wt" merge --abort >/dev/null 2>&1 || true
      fi_err "autofix: PR #$n: git could not merge $base into $head: ${out##*$'\n'} — not merging"; return 1
    fi
    if [[ -n "$bad" ]]; then
      git -C "$wt" merge --abort >/dev/null 2>&1 || true
      fi_err "autofix: PR #$n conflicts with $base outside the ledger ($bad) — not merging"; return 1
    fi
    mb="$(git -C "$wt" merge-base HEAD MERGE_HEAD 2>/dev/null || true)"
    while IFS= read -r f || [[ -n "$f" ]]; do
      [[ -n "$f" ]] || continue
      lrc=0; _fi_af_mwg_ledger "$wt" "$f" "$mb" "$ann" || lrc=$?
      if (( lrc )); then
        git -C "$wt" merge --abort >/dev/null 2>&1 || true
        if (( lrc == 2 )); then
          fi_err "autofix: PR #$n: an entry it annotates in $f changed on $base, so $ann cannot be carried over; its conflict needs a person — not merging"
        else
          fi_err "autofix: PR #$n changes $f by more than its own annotation $ann, so its conflict with $base needs a person — not merging"
        fi
        return 1
      fi
    done <<<"$files"
    if ! out="$(git -C "$wt" commit -q --no-edit 2>&1)"; then
      git -C "$wt" merge --abort >/dev/null 2>&1 || true
      fi_err "autofix: PR #$n: the merge commit of $base was refused: ${out##*$'\n'} — not merging"; return 1
    fi
  fi
  if ! git -C "$wt" push -q origin "HEAD:refs/heads/$head" >/dev/null 2>&1; then
    fi_err "autofix: PR #$n: pushing $base merged into $head failed — not merging"; return 1
  fi
  printf 'PR #%s: merged %s into %s (the only conflict was the ledger; both sides kept), waiting for checks again\n' "$n" "$base" "$head"
}

# Resolve the conflicted ledger <p>: the base's version, with this PR's
# annotation re-added to each entry the PR annotated (matched by dedup key).
# Refused with rc 1 unless the PR's own change to <p> since the merge base is
# exactly that annotation, the only ledger change an auto-fix PR makes; rc 2
# when an entry it annotated is no longer on the base under the same key
# (re-anchored, reworded, archived), so the annotation would be dropped.
_fi_af_mwg_ledger() {
  local wt="$1" p="$2" mb="$3" ann="$4" ours line cr keys=$'\n' want=0 got=0 tmpf
  [[ -n "$mb" ]] || return 1
  git -C "$wt" cat-file -e "$mb:$p" 2>/dev/null || return 1
  git -C "$wt" cat-file -e "MERGE_HEAD:$p" 2>/dev/null || return 2
  ours="$(git -C "$wt" show "HEAD:$p" 2>/dev/null)" || return 1
  [[ "${ours//" $ann"/}" == "$(git -C "$wt" show "$mb:$p")" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *" $ann"* ]] || continue
    line="${line%$'\r'}"
    fi_entry_dedup_key_v "${line//" $ann"/}" "$wt" || continue
    keys+="$FI_KEY"$'\n'; want=$((want + 1))
  done <<<"$ours"
  # Line by line from git, so the base's bytes (trailing blank lines, a
  # missing final newline aside) are what the merge commit keeps.
  tmpf="$wt/$p.fi-mwg.$$"
  while IFS= read -r line || [[ -n "$line" ]]; do
    cr=""
    [[ "$line" == *$'\r' ]] && { cr=$'\r'; line="${line%$'\r'}"; }
    if [[ "$line" == "- ["* ]] && fi_entry_dedup_key_v "${line//" $ann"/}" "$wt" \
       && [[ "$keys" == *$'\n'"$FI_KEY"$'\n'* ]]; then
      [[ "$line" == *" $ann"* ]] || line="$line $ann"
      got=$((got + 1))
    fi
    printf '%s%s\n' "$line" "$cr"
  done < <(git -C "$wt" show "MERGE_HEAD:$p" 2>/dev/null) >"$tmpf"
  if (( got < want )); then rm -f "$tmpf"; return 2; fi
  cat "$tmpf" >"$wt/$p" && rm -f "$tmpf"
  git -C "$wt" add -- "$p"
}
