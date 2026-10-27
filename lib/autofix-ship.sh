#!/usr/bin/env bash
# autofix-ship.sh — turn a verified worktree into a self-merging PR
# (spec 2026-10-03 §5 step 6; audit prompt-9: the (PR:) annotation is
# committed onto the PR branch so it reaches the default branch).
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
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

# The ledger a worktree annotates, relative to <wt>; rc 1 when it has none.
# 3.10.1 (#164): the docs ledger in whatever case it is spelled. The spelling
# git tracks at HEAD wins (a case-insensitive volume answers -f to any case,
# but `git add` matches the tracked spelling only), then fi_docs_ledger, then
# the local-mode .found-issues.md. Only paths INSIDE the worktree.
fi_af_wt_ledger() {
  local wt="$1" l
  if l="$(fi_docs_ledger_at_ref HEAD "$wt")"; then
    printf '%s' "$l"; return 0
  fi
  if l="$(fi_docs_ledger "$wt")"; then
    printf '%s' "${l#"$wt"/}"; return 0
  fi
  if [[ -f "$wt/.found-issues.md" ]]; then
    printf '%s' ".found-issues.md"; return 0
  fi
  return 1
}

# The fixer must not change the ledger, and a headless child's SessionStart
# sync may have (Review Focus 3). Put every ledger file back to <ref> — the
# fixed list, not just the files that still exist, or a deleted ledger
# would ship as a deletion. 3.10.0: the list adds the docs ledger as it is
# spelled in the worktree or at <ref> (a recased ledger the fixer deleted is
# only at <ref>), found case-insensitively like fi_docs_ledger. 3.10.2 (#164):
# the same for the archive, in the spelling git tracks. A literal default that
# is not tracked at <ref> but is the SAME FILE as a tracked recased one (a
# case-insensitive volume) is left to that tracked spelling: `rm` would delete
# the tracked file and the next `git add -A` would stage the deletion.
fi_af_reset_ledger() {
  local wt="$1" ref="$2" p t seen=$'\n' docs lp lt
  local -a paths=(docs/found-issues.md docs/found-issues-archive.md .found-issues.md)
  local -a tracked=()
  if docs="$(fi_docs_ledger "$wt")"; then
    paths[${#paths[@]}]="${docs#"$wt"/}"
  fi
  if docs="$(fi_docs_archive "$wt")"; then
    paths[${#paths[@]}]="${docs#"$wt"/}"
  fi
  if docs="$(fi_docs_ledger_at_ref "$ref" "$wt")"; then
    paths[${#paths[@]}]="$docs"; tracked[${#tracked[@]}]="$docs"
  fi
  if docs="$(fi_docs_archive_at_ref "$ref" "$wt")"; then
    paths[${#paths[@]}]="$docs"; tracked[${#tracked[@]}]="$docs"
  fi
  for p in "${paths[@]}"; do
    [[ "$seen" == *$'\n'"$p"$'\n'* ]] && continue
    seen+="$p"$'\n'
    if git -C "$wt" cat-file -e "$ref:$p" 2>/dev/null; then
      git -C "$wt" checkout -q "$ref" -- "$p" 2>/dev/null || true
    else
      lp="$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')"
      if (( ${#tracked[@]} )); then
        for t in "${tracked[@]}"; do
          lt="$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')"
          [[ "$lp" == "$lt" && "$wt/$p" -ef "$wt/$t" ]] && continue 2
        done
      fi
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
# 3.9.2: so does FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS. fi_af_child has read the
# watchdog limit already; `fix ship` sets it for its gate, and inherited it
# overrides the limit this repo's own readiness/watchdog tests compute.
# (fi_af_child drops CLAUDE_PROJECT_DIR for every child, this one included.)
# 3.9.3: and it runs on the caller's PATH (FI_AF_CALLER_PATH when a fixer
# called us from inside a child). fi_af_child puts the plugin bin first for
# the engine; in an auto-fix of found-issues itself that made any test finding
# found-issues via PATH run the installed CLI, not the worktree's.
fi_af_run_tests() {
  fi_af_child "$3" "$3.err" "$1" bash -c "unset FOUND_ISSUES_AUTOFIX_CHILD FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS FI_AF_CALLER_PATH; PATH=$(printf '%q' "${FI_AF_CALLER_PATH:-$PATH}"); $2" || return $?
}

# 3.4.3: a red suite after a change is re-run once before it counts. A flaky
# test (kh2-midgar: a shared build lock) failed a good fix, fed the next
# attempt unrelated failures and tagged the entry autofix-failed. A watchdog
# kill is not re-run; the first log is kept as <log>.first.log.
fi_af_tests_pass() {
  local wt="$1" cmd="$2" log="$3" first rc=0
  # 3.9.0: when the last run started, so a re-run is timed on its own.
  FI_AF_LAST_RUN_START="$(date +%s)"
  fi_af_run_tests "$wt" "$cmd" "$log" || rc=$?
  (( rc == 0 )) && return 0
  [[ -z "${FI_AF_CHILD_TIMEDOUT:-}" ]] || return "$rc"
  first="$(fi_af_test_failures "$log" | head -n 1)"
  mv -f "$log" "${log%.log}.first.log" 2>/dev/null || true
  fi_af_log "$AFI_id" "tests failed (${first:-exit $rc}); re-running once"
  FI_AF_LAST_RUN_START="$(date +%s)"
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
    /^(FAILED |--- FAIL: |FAIL )/ { print; n++; next }
    /^[ \t]*(×|✕|✗) / { print; n++ }
  ' "$1" 2>/dev/null || true
}

# The names of the failing tests in a test log, one per line, sorted and
# unique: TAP "not ok" (number and "# ..." directive dropped), pytest FAILED
# (" - message" dropped), go "--- FAIL:" (timing dropped), jest FAIL lines,
# and the indented "× name 12ms" / "✕ name (12 ms)" lines of vitest and jest
# (the timing dropped: cosmo's vitest prints no FAIL line at all).
# Read from the whole log, not the 80-line fi_af_test_failures excerpt, so a
# long run's later failures still count when two runs are compared.
fi_af_test_failed_names() {
  awk '
    /^not ok / { s = $0; sub(/^not ok [0-9]* */, "", s); sub(/ # .*$/, "", s); print s; next }
    /^FAILED / { s = $0; sub(/^FAILED /, "", s); sub(/ - .*$/, "", s); print s; next }
    /^--- FAIL: / { s = $0; sub(/^--- FAIL: /, "", s); sub(/ \([0-9.]+s\)$/, "", s); print s; next }
    /^FAIL / { s = $0; sub(/^FAIL /, "", s); print s; next }
    /^[ \t]*(×|✕|✗) / {
      s = $0; sub(/^[ \t]*(×|✕|✗) /, "", s); sub(/ \(?[0-9.]+ ?m?s\)?$/, "", s); print s
    }
  ' "$1" 2>/dev/null | LC_ALL=C sort -u
}

# Ledger lib/autofix-queue.sh:694: rc 0 when two red runs of one suite failed
# disjoint sets of named tests, so the suite is flaky rather than red. Either
# run naming no failed test (an unparsed runner, a crash) is not flaky.
fi_af_runs_flaky() { # <first log> <second log>
  local a b
  a="$(fi_af_test_failed_names "$1")"
  b="$(fi_af_test_failed_names "$2")"
  [[ -n "$a" && -n "$b" ]] || return 1
  [[ -z "$(LC_ALL=C comm -12 <(printf '%s\n' "$a") <(printf '%s\n' "$b"))" ]]
}

# What a fixer reads after a run: the failing tests, then the last <n> lines.
fi_af_test_report() {
  local f
  f="$(fi_af_test_failures "$1")"
  [[ -n "$f" ]] && printf 'Failing tests:\n%s\n\n' "$f"
  printf 'Last lines:\n'
  tail -n "${2:-30}" "$1" 2>/dev/null || true
}

# "N planned, X ok, Y not ok[, Z skipped]" for a TAP log (bats), summed over
# every plan when the test command runs bats more than once; nothing for
# other runners. The verdict line fix ship prints and a PR body quotes
# (ledger lib/fix-plumbing.sh:113).
fi_af_tap_summary() {
  awk '
    /^1\.\.[0-9]+[[:space:]]*$/ { sub(/^1\.\./, ""); planned += $0; plans++; next }
    /^not ok / { nok++; next }
    /^ok / { if ($0 ~ /# [Ss][Kk][Ii][Pp]/) skip++; else ok++ }
    END {
      if (!plans) exit
      printf "%d planned, %d ok, %d not ok", planned, ok, nok
      if (skip) printf ", %d skipped", skip
    }' "$1" 2>/dev/null
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
  # a day) must not hold the caller's fd 3, which bats waits on for EOF.
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
    wl="$(fi_af_wt_ledger "$wt")" || wl=""
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
#
# A guard outlives the wait for checks: the conflict it exists for appears
# when ANOTHER fix PR merges, which can be hours after this one was armed
# (that PR's CI may run long). It therefore polls for
# FOUND_ISSUES_AUTOFIX_GUARD_POLLS (default 288 = 24 h at the default
# 300 s guard sleep), not for the merge-when-green window of ..._MERGE_POLLS.
# A guard sleeps FOUND_ISSUES_AUTOFIX_GUARD_SLEEP (default five merge sleeps,
# 300 s): one per armed PR polls gh all day, so a slower look keeps 20-30
# open fix PRs at about 12 calls an hour each, not 60.
#
# 3.10.8 (ledger lib/autofix-ship.sh:511): a failed check re-runs the head's
# failed Actions runs once per head (_fi_af_mwg_rerun), after two red reads
# of that head in a row (a read just after a push can still be the old head);
# up to 3 red reads before the re-run shows as pending are not a second
# failure.
fi_af_merge_when_green() {
  local n="$1" slug="${2:-}" guard="${3:-0}" i v st ck mg br hr nones=0 polls="${FOUND_ISSUES_AUTOFIX_MERGE_POLLS:-60}" pause="${FOUND_ISSUES_AUTOFIX_MERGE_SLEEP:-60}"
  if (( guard )); then
    polls="${FOUND_ISSUES_AUTOFIX_GUARD_POLLS:-288}"
    [[ "$polls" =~ ^[0-9]+$ ]] && (( 10#$polls >= 1 )) || polls=288
    [[ "$pause" =~ ^[0-9]+$ ]] || pause=60
    pause="${FOUND_ISSUES_AUTOFIX_GUARD_SLEEP:-$(( 5 * 10#$pause ))}"
    [[ "$pause" =~ ^[0-9]+$ ]] || pause=300
  fi
  local jqf='[.state, ([.statusCheckRollup[]? | (.conclusion // .state // "")] | if length == 0 then "none" elif any(. == "FAILURE" or . == "ERROR" or . == "CANCELLED" or . == "TIMED_OUT" or . == "ACTION_REQUIRED" or . == "STARTUP_FAILURE") then "fail" elif all(. == "SUCCESS" or . == "SKIPPED" or . == "NEUTRAL") then "green" else "pending" end), (.mergeable // ""), (.baseRefName // ""), (.headRefName // ""), (.headRefOid // "")] | join("|")'
  local ho rr_sha="" rr_wait=0 red_sha=""
  [[ -n "$slug" ]] || slug="$(fi_repo_id 2>/dev/null || true)"
  [[ -n "$slug" ]] || { fi_err "autofix: merge-when-green needs a GitHub repo (--repo owner/name)"; return 1; }
  FI_AF_MWG_FIXES=0
  for (( i = 0; i < polls; i++ )); do
    v="$(gh pr view "$n" --repo "$slug" --json state,statusCheckRollup,mergeable,baseRefName,headRefName,headRefOid --jq "$jqf" 2>/dev/null || true)"
    IFS='|' read -r st ck mg br hr ho <<<"$v" || true
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
      "OPEN fail")
        # Ledger :511 — the head's failed runs are re-run once per head;
        # GitHub can still show the old red for a few reads after that.
        if [[ "$ho" == "$rr_sha" ]] && (( rr_wait > 0 )); then
          rr_wait=$((rr_wait - 1)); sleep "$pause"; continue
        fi
        # Only a head read red twice in a row: the first read after a push
        # can still be the previous head (live e2e, fi-rerun-e2e #2).
        if [[ "$ho" != "$rr_sha" ]] && _fi_af_mwg_rerun_on; then
          if [[ "$ho" != "$red_sha" ]]; then red_sha="$ho"; sleep "$pause"; continue; fi
          if _fi_af_mwg_rerun "$n" "$slug" "$ho"; then rr_sha="$ho" rr_wait=3; sleep "$pause"; continue; fi
        fi
        # The armed auto-merge outlives a failed check (a re-run can still
        # turn it green), so the guard keeps watching for a conflict.
        (( guard )) && { sleep "$pause"; continue; }
        [[ -n "$ho" && "$ho" == "$rr_sha" ]] && { fi_err "autofix: PR #$n checks failed again after a re-run — not merging"; return 1; }
        fi_err "autofix: PR #$n checks failed — not merging"; return 1 ;;
      "OPEN pending") nones=0 rr_wait=0 red_sha="" ;;
      *) nones=0 red_sha="" ;;
    esac
    sleep "$pause"
  done
  fi_err "autofix: PR #$n still pending after $polls checks — not merging"
  return 1
}

FI_AF_MWG_FIXES=0 FI_AF_MWG_ERR="" FI_AF_GUARD_LOCK=""

# One guard per repo+PR. A ship retry that re-arms auto-merge spawns another
# guard, and two guards racing _fi_af_mwg_unconflict make one push fail. The
# lock is a symlink whose target is the guard's pid (ln -s is atomic, so no
# window with a lock and no pid). A lock whose pid is dead, or alive but not a
# merge-when-green process (pid reuse), is stale and replaced.
# rc 0 = this process holds the lock; rc 1 = a live guard already holds it.
_fi_af_guard_lock() {
  local n="$1" slug="${2:-}" dir pid cmd try
  [[ -n "$slug" ]] || slug="$(fi_repo_id 2>/dev/null || true)"
  FI_AF_GUARD_LOCK=""
  [[ -n "$slug" ]] || return 0   # merge-when-green names the missing repo
  fi_af_root
  dir="$FI_AF_ROOT/guards"
  mkdir -p "$dir" 2>/dev/null || return 0
  slug="$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')"
  FI_AF_GUARD_LOCK="$dir/${slug//\//__}#$n.lock"
  for try in 1 2; do
    ln -s "$$" "$FI_AF_GUARD_LOCK" 2>/dev/null && return 0
    pid="$(readlink "$FI_AF_GUARD_LOCK" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ && "$pid" != "$$" ]] && kill -0 "$pid" 2>/dev/null; then
      cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
      if [[ "$cmd" == *merge-when-green* ]]; then
        FI_AF_GUARD_LOCK=""
        printf 'PR #%s is already guarded by pid %s\n' "$n" "$pid"
        return 1
      fi
    fi
    rm -f "$FI_AF_GUARD_LOCK"
  done
  FI_AF_GUARD_LOCK=""
  return 0
}

_fi_af_guard_unlock() {
  [[ -n "$FI_AF_GUARD_LOCK" && "$(readlink "$FI_AF_GUARD_LOCK" 2>/dev/null || true)" == "$$" ]] && rm -f "$FI_AF_GUARD_LOCK"
  FI_AF_GUARD_LOCK=""
  return 0
}

# Squash-merge <N>; a refusal's message is kept in FI_AF_MWG_ERR.
_fi_af_mwg_merge() {
  local n="$1" slug="$2"
  if FI_AF_MWG_ERR="$(gh pr merge "$n" --squash --repo "$slug" 2>&1 >/dev/null)"; then
    printf 'merged PR #%s\n' "$n"; return 0
  fi
  [[ -z "$FI_AF_MWG_ERR" ]] || printf '%s\n' "$FI_AF_MWG_ERR" >&2
  return 1
}

# Re-run the failed GitHub Actions runs of head <sha> (ledger :511: a one-off
# CI infrastructure failure stranded sayciao#320). rc 0 = at least one run
# was re-run; rc 1 = switched off (FOUND_ISSUES_AUTOFIX_RERUN_CHECKS=off), no
# head sha, nothing to re-run (a check that is not an Actions run), or gh
# refused every re-run.
_fi_af_mwg_rerun_on() {
  case "${FOUND_ISSUES_AUTOFIX_RERUN_CHECKS:-}" in off|0|false|no) return 1 ;; esac
  return 0
}

_fi_af_mwg_rerun() {
  local n="$1" slug="$2" sha="$3" ids id ok=""
  _fi_af_mwg_rerun_on || return 1
  [[ "$sha" =~ ^[0-9a-f]+$ ]] || return 1
  ids="$(gh run list --repo "$slug" --commit "$sha" --limit 50 --json databaseId,conclusion \
    --jq '.[] | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "cancelled" or .conclusion == "startup_failure") | .databaseId' 2>/dev/null || true)"
  for id in $ids; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    gh run rerun "$id" --failed --repo "$slug" >/dev/null 2>&1 && ok+=" $id"
  done
  [[ -n "$ok" ]] || return 1
  printf 'PR #%s: checks failed; re-running its failed runs once (%s)\n' "$n" "${ok# }"
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
# force; a PR retargeted after a squash merge is instead rebuilt and
# force-pushed with a lease, _fi_af_mwg_squashed). Only ledger conflicts are resolved: the code then merges exactly as
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
    local sq=0
    _fi_af_mwg_squashed "$n" "$slug" "$tmp/wt" "$base" "$head" || sq=$?
    if (( sq == 1 )); then
      _fi_af_mwg_update "$n" "$slug" "$tmp/wt" "$base" "$head" || rc=$?
    elif (( sq )); then
      rc=1
    fi
    git -C "$root" worktree remove --force "$tmp/wt" >/dev/null 2>&1 || true
  else
    fi_err "autofix: PR #$n has merge conflicts and a worktree of $head could not be made — not merging"; rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

# 3.10.1 (#164): the docs ledger may be spelled Docs/Found-Issues.md; the
# archive beside it is always lowercase-named.
_fi_af_is_ledger() {
  case "$1" in
    [Dd][Oo][Cc][Ss]/[Ff][Oo][Uu][Nn][Dd]-[Ii][Ss][Ss][Uu][Ee][Ss].[Mm][Dd]) return 0 ;;
    [Dd][Oo][Cc][Ss]/found-issues-archive.md|.found-issues.md) return 0 ;;
  esac
  return 1
}

# 3.10.7 (ledger lib/autofix-ship.sh:656): GitHub retargets a fix PR to the
# default branch when the session branch it was cut from merges and is
# deleted. After a squash merge the PR still carries that branch's commits,
# so merging the base in conflicts with more than the PR's own annotation.
# Then the PR's own change since it was cut (the merge base of the merged
# PR's head and this PR's head) is rebuilt as one commit on the base, the
# ledger as _fi_af_mwg_ledger resolves it, the repo's test command run on
# it (twice before it counts as red), and force-pushed with a lease.
# rc 0 = rebuilt and pushed; rc 1 = not that case (the ordinary merge
# applies); rc 2 = that case, but it needs a person.
_fi_af_mwg_squashed() {
  local n="$1" slug="$2" wt="$3" base="$4" head="$5" ev old m oid cut was why f lrc subj cmd
  local ann="(PR: $slug#$n)" code=() ledgers=() tlog="${3%/*}/rebuild-tests.log"
  local q='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){timelineItems(itemTypes:[AUTOMATIC_BASE_CHANGE_SUCCEEDED_EVENT],last:1){nodes{... on AutomaticBaseChangeSucceededEvent{oldBase newBase}}}}}}'
  ev="$(gh api graphql -f query="$q" -f o="${slug%%/*}" -f r="${slug#*/}" -F n="$n" \
    --jq '.data.repository.pullRequest.timelineItems.nodes[-1] // {} | "\(.oldBase // "")|\(.newBase // "")"' 2>/dev/null || true)"
  old="${ev%%|*}"
  [[ -n "$old" && "$old" != "$base" && "${ev#*|}" == "$base" ]] || return 1
  # Only the PR that merged that branch into this base (a reused name or a
  # fork's branch of the same name is another PR).
  m="$(gh pr list --repo "$slug" --head "$old" --base "$base" --state merged --limit 1 --json number,headRefOid,baseRefName \
    --jq '.[0] // {} | "\(.number // "")|\(.headRefOid // "")|\(.baseRefName // "")"' 2>/dev/null || true)"
  [[ "${m##*|}" == "$base" ]] || return 1
  m="${m%|*}" oid="${m#*|}" m="${m%%|*}"
  [[ "$m" =~ ^[0-9]+$ && "$oid" =~ ^[0-9a-f]{40}$ ]] || return 1
  # The deleted branch's head survives as refs/pull/<M>/head.
  git -C "$wt" fetch -q origin "refs/pull/$m/head" >/dev/null 2>&1 || return 1
  [[ "$(git -C "$wt" rev-parse FETCH_HEAD 2>/dev/null)" == "$oid" ]] || return 1
  cut="$(git -C "$wt" merge-base "$oid" HEAD 2>/dev/null)" || return 1
  # A merge that kept the branch's commits needs nothing here.
  git -C "$wt" merge-base --is-ancestor "$cut" "refs/remotes/origin/$base" && return 1
  why="autofix: PR #$n: its landing branch $old was squash-merged into $base (PR #$m)"
  was="$(git -C "$wt" rev-parse HEAD)"
  # NUL-separated and rename-free: a quoted path or a rename's old side
  # would otherwise drop out of the rebuilt diff.
  while IFS= read -r -d '' f || [[ -n "$f" ]]; do
    [[ -n "$f" ]] || continue
    if _fi_af_is_ledger "$f"; then ledgers+=("$f"); else code+=("$f"); fi
  done < <(git -C "$wt" diff -z --no-renames --name-only "$cut" "$was")
  if ! git -C "$wt" checkout -q --detach "refs/remotes/origin/$base" >/dev/null 2>&1; then
    fi_err "$why, and checking out $base failed — not merging"; return 2
  fi
  if (( ${#code[@]} )) && ! git -C "$wt" --literal-pathspecs diff --binary --no-renames "$cut" "$was" -- "${code[@]}" \
       | git -C "$wt" apply -q --3way --index >/dev/null 2>&1; then
    fi_err "$why, and its fix does not apply on $base; it needs a person — not merging"; return 2
  fi
  for f in "${ledgers[@]+"${ledgers[@]}"}"; do
    lrc=0; _fi_af_mwg_ledger "$wt" "$f" "$cut" "$ann" "$was" HEAD || lrc=$?
    if (( lrc == 2 )); then
      fi_err "$why, and an entry it annotates in $f changed on $base, so $ann cannot be carried over; it needs a person — not merging"; return 2
    elif (( lrc )); then
      fi_err "$why, and it changes $f by more than its own annotation $ann; it needs a person — not merging"; return 2
    fi
  done
  if git -C "$wt" diff --cached --quiet; then
    fi_err "$why, and its change is already on $base — not merging"; return 2
  fi
  # The subject of the PR's first own commit: the fix, not its annotation.
  subj=""; IFS= read -r subj < <(git -C "$wt" log --reverse --no-merges --format=%s "$cut..$was") || true
  if ! git -C "$wt" commit -q -m "${subj:-fix} (rebuilt on $base after #$m was squash-merged)" >/dev/null 2>&1; then
    fi_err "$why, and the rebuilt commit was refused — not merging"; return 2
  fi
  # The rebuilt tree was never tested (the fix was verified on the old
  # branch), and a repo without checks would merge it on the next poll.
  if ! cmd="$(fi_af_test_command "$wt")"; then
    fi_err "$why, and no test command is set to check the rebuild; it needs a person — not merging"; return 2
  fi
  if ! fi_af_run_tests "$wt" "$cmd" "$tlog" && ! fi_af_run_tests "$wt" "$cmd" "$tlog"; then
    fi_err "$why, and the tests fail on the rebuild; it needs a person — not merging"; return 2
  fi
  if ! git -C "$wt" push -q --force-with-lease="refs/heads/$head:$was" origin "HEAD:refs/heads/$head" >/dev/null 2>&1; then
    fi_err "$why, and pushing its rebuilt change failed — not merging"; return 2
  fi
  printf 'PR #%s: its landing branch %s was squash-merged into %s (PR #%s); rebuilt its own change on %s, waiting for checks again\n' "$n" "$old" "$base" "$m" "$base"
}

_fi_af_mwg_update() {
  local n="$1" slug="$2" wt="$3" base="$4" head="$5" files f bad="" mb out lrc=0
  local ann="(PR: $slug#$n)"
  if ! out="$(git -C "$wt" merge -q --no-edit "refs/remotes/origin/$base" 2>&1)"; then
    files="$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null || true)"
    while IFS= read -r f || [[ -n "$f" ]]; do
      [[ -z "$f" ]] || _fi_af_is_ledger "$f" || bad="${bad:+$bad, }$f"
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
# <ours> and <theirs> default to HEAD and MERGE_HEAD; a squash rebuild passes
# the PR head and the base it checked out.
_fi_af_mwg_ledger() {
  local wt="$1" p="$2" mb="$3" ann="$4" oref="${5:-HEAD}" tref="${6:-MERGE_HEAD}" ours line cr keys=$'\n' want=0 got=0 tmpf
  [[ -n "$mb" ]] || return 1
  git -C "$wt" cat-file -e "$mb:$p" 2>/dev/null || return 1
  git -C "$wt" cat-file -e "$tref:$p" 2>/dev/null || return 2
  ours="$(git -C "$wt" show "$oref:$p" 2>/dev/null)" || return 1
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
  done < <(git -C "$wt" show "$tref:$p" 2>/dev/null) >"$tmpf"
  if (( got < want )); then rm -f "$tmpf"; return 2; fi
  cat "$tmpf" >"$wt/$p" && rm -f "$tmpf"
  git -C "$wt" add -- "$p"
}
