#!/usr/bin/env bash
# sync.sh — the sync subcommand — annotation-driven flip + tombstone close
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Extracted verbatim from bin/found-issues in v2.2.9 — the final step of the
# tracked §12 split, which closes the loc-validator entry and removes the
# loc-override marker from the CLI header.
#
# Functions:
#   cmd_sync [...]

# === Subcommand: sync ===
#
# Annotation-driven flip + tombstone close.
# Does NOT do AI verification — that lives in the /fi sync slash command.

# Usage text for `sync`. Kept next to the parser so the two cannot drift.
fi_sync_usage() {
  cat <<'EOF'
Usage: found-issues sync [--dry-run]

Flip [open] entries whose annotations have landed, and tombstone entries whose
file git confirms was removed, then auto-archive old [fixed] entries
(FOUND_ISSUES_AUTO_ARCHIVE=off skips that). Also runs automatically at
SessionStart, on statusline refresh and after `gh pr merge`; those unattended
runs never archive.

  --dry-run   Report what would change; write nothing.
  -h, --help  Show this help.

Closures are not reversible — there is no command that reopens a [fixed]
entry. Use --dry-run first when in doubt.
EOF
}

# fi_commit_touches_entry <sha> <path> [<renamed-from>] — 0 when the commit
# changed the entry's cited location, 1 when it did not. An annotation on its
# own only says "this commit is the fix" because somebody wrote it; the closer
# checks that the commit is at least ABOUT the file the entry cites (a stray
# --pick or a bare annotate-commit on the wrong HEAD used to close an entry
# for any commit on the default branch). A cited directory matches any file
# under it, a glob location matches by pattern, and the pre-rename path counts.
# Merge commits are diffed against each parent (-m), root commits against the
# empty tree (--root).
fi_commit_touches_entry() {
  local sha="$1" cited="$2" renamed_from="${3:-}"
  local files f c
  files="$(git -c core.quotepath=off diff-tree --no-commit-id --name-only -r -m --root "$sha" 2>/dev/null)" || return 1
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    for c in "$cited" "$renamed_from"; do
      [[ -n "$c" ]] || continue
      c="${c%/}"
      if [[ "$f" == "$c" || "$f" == "$c"/* ]]; then
        return 0
      fi
      if [[ "$c" == *[\*\?]* || "$c" == *\[*\]* ]]; then
        # shellcheck disable=SC2053
        [[ "$f" == $c ]] && return 0
      fi
    done
  done <<<"$files"
  return 1
}

# fi_sq <text> — single-quote text for a shell command line shown to the operator.
fi_sq() {
  local t="$1" q="'\\''"
  printf "'%s'" "${t//\'/$q}"
}

cmd_sync() {
  # Unknown flags used to be ignored entirely: `sync --help` parsed nothing and
  # ran a full mutating pass, so reaching for help performed irreversible
  # closures (issue #151). Mutating subcommands must refuse what they do not
  # understand rather than proceed on a guess.
  local dry_run=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)  dry_run=1; shift ;;
      -h|--help)  fi_sync_usage; return 0 ;;
      # No `--` passthrough: sync takes no positional operands, so anything
      # after it can only be a flag we would then ignore — `sync -- --help`
      # running a full mutating pass is the same surprise this loop exists to
      # prevent.
      *)
        fi_err "sync: unknown option '$1'"
        fi_sync_usage >&2
        return 2
        ;;
    esac
  done

  local file
  file="$(fi_find_issues_file)" || {
    fi_err "sync: no found-issues.md found"
    return 1
  }

  # A ledger mid-merge has both sides' lines between the markers; rewriting it
  # would close or demote entries the operator is still choosing between, and
  # SessionStart runs this unattended (audit ledger-17).
  if fi_has_conflict_markers "$file"; then
    fi_err "sync: $file has merge-conflict markers — resolve them first; nothing synced"
    return 0
  fi

  local mode
  mode="$(fi_detect_mode)"

  local repo_id=""
  if [[ "$mode" == "github-pr" || "$mode" == "github-direct" ]]; then
    repo_id="$(fi_repo_id 2>/dev/null || true)"
  fi

  local default_branch=""
  if git rev-parse --git-dir >/dev/null 2>&1; then
    default_branch="$(fi_resolve_default_branch)"
  fi

  local closed_pr=0 closed_commit=0 closed_tomb=0
  local woke=0
  # Hook-suggested annotations whose ref HAS landed. These never close an
  # entry — they are diff-inferred, not confirmed (see fi_auto_form in
  # lib/annotate.sh). Collected so sync can say so out loud: a suggestion
  # that is silently ignored forever is as useless as one that silently
  # closes work.
  local -a awaiting_confirm=()
  # Parallel to awaiting_confirm: "kind<US>ref<US>loc" for the printed commands.
  local -a awaiting_cmds=()
  # Landed annotated commits that did not touch the entry's cited file.
  local -a unrelated_notes=()
  local pr_unresolved=0
  local demoted_pr=0
  local demoted_commit=0
  local renamed_count=0
  local -a gh_empty_warnings=()
  local today
  today="$(fi_today)"
  # The gh loop below can take seconds per PR. Anything that rewrites the
  # ledger meanwhile (defer, resolve, an annotate from a commit hook) would be
  # reverted by our final mv, so snapshot the ledger now and let
  # fi_ledger_replace refuse a stale write (audit ledger-1).
  local snapshot
  snapshot="$(fi_ledger_snapshot "$file")"
  local tmp
  tmp="$(fi_ledger_tmp "$file")"
  trap "rm -f '$tmp'" EXIT

  # Demoting an unresolvable (commit:) is permanent, so only do it where git
  # can actually see the whole history: a shallow clone (CI, cloud checkouts)
  # cannot resolve older commits at all (audit ledger-11).
  local shallow_repo=0
  [[ "$(git rev-parse --is-shallow-repository 2>/dev/null || true)" == "true" ]] && shallow_repo=1

  # Loop-invariant; was one `git rev-parse` per path entry (audit ledger-5).
  local repo_root
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

  # One gh call per distinct PR per run, answered as "state<TAB>base<TAB>
  # mergedAt<TAB>head" by gh's built-in --jq — no jq binary needed, so a
  # machine with gh but no jq closes merged PRs too (audit ledger-7, ledger-8b). Fields are
  # \x1f-separated (tab is IFS whitespace: an empty field would collapse).
  # Memo lines: "\n<repo#N>\x1e<answer>"; an empty answer means gh failed.
  local _fi_pr_memo=$'\n'
  _fi_pr_info() {
    local ref="$1" key=$'\n'"$1"$'\x1e'
    if [[ "$_fi_pr_memo" == *"$key"* ]]; then
      _fi_pr_ans="${_fi_pr_memo#*"$key"}"
      _fi_pr_ans="${_fi_pr_ans%%$'\n'*}"
      return 0
    fi
    _fi_pr_ans="$(gh pr view "${ref##*#}" --repo "${ref%#*}" \
      --json state,baseRefName,mergedAt,headRefName \
      --jq '[.state, .baseRefName, (.mergedAt // ""), (.headRefName // "")] | join("\u001f")' 2>/dev/null || true)"
    _fi_pr_memo+="$ref"$'\x1e'"$_fi_pr_ans"$'\n'
  }

  # A PR merged into another branch (a release branch, a stacked PR) reaches
  # the default branch only when that branch does: the newest merged PR from
  # <base> into the default branch, as mergedAt, or "" when there is none.
  # One gh call per repo and base branch per run, memoized like _fi_pr_info.
  local _fi_prom_memo=$'\n'
  _fi_promoted_at() {
    local key=$'\n'"$1#$2"$'\x1e'
    if [[ "$_fi_prom_memo" == *"$key"* ]]; then
      _fi_prom_ans="${_fi_prom_memo#*"$key"}"
      _fi_prom_ans="${_fi_prom_ans%%$'\n'*}"
      return 0
    fi
    _fi_prom_ans="$(gh pr list --repo "$1" --head "$2" --base "$default_branch" --state merged \
      --limit 100 --json mergedAt --jq 'map(.mergedAt // "") | max // ""' 2>/dev/null || true)"
    _fi_prom_memo+="$1#$2"$'\x1e'"$_fi_prom_ans"$'\n'
  }

  local line
  # Final-partial-line guard — see the READ-LOOP GUARD block in bin/found-issues.
  # Worst case of the class: SessionStart runs sync automatically, so the loss
  # happened with no user action and no output saying anything was removed.
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^-\ \[open\] ]]; then
      local e_path e_prs e_commits
      local -a demote_pr_refs=()
      local -a demote_commit_refs=()
      local rename_target="" rename_source=""
      fi_parse_entry_vars "$line" || { printf '%s\n' "$line" >>"$tmp"; continue; }
      e_path="$FE_path"
      e_prs="$FE_prs"
      e_commits="$FE_commits"
      local e_prs_auto="$FE_prs_auto" e_commits_auto="$FE_commits_auto"
      local e_renamed_from="$FE_renamed_from"
      local e_loc
      e_loc="$(fi_entry_loc "$line" 2>/dev/null || printf '%s' "$e_path")"

      local closure_kind="" closure_label=""
      local -a entry_notes=()

      # Pending suggestions: report only, never close. A suggestion whose ref
      # has landed is exactly the case that needs a human/model to compare the
      # entry's symptom against what the commit did — the judgment the hook
      # cannot make and must not fake.
      if [[ -n "$e_commits_auto" && -n "$default_branch" ]]; then
        local IFS_old="$IFS"
        IFS=','
        for sha in $e_commits_auto; do
          IFS="$IFS_old"
          if git rev-parse --verify "$sha" >/dev/null 2>&1 \
             && { git merge-base --is-ancestor "$sha" "$default_branch" 2>/dev/null \
                  || git merge-base --is-ancestor "$sha" "origin/$default_branch" 2>/dev/null; }; then
            awaiting_confirm+=("$e_loc — suggested (commit-auto: $sha) has landed")
            awaiting_cmds+=("commit"$'\x1f'"$sha"$'\x1f'"$e_loc")
          fi
        done
        IFS="$IFS_old"
      fi
      if [[ -n "$e_prs_auto" && -n "$repo_id" ]] && command -v gh >/dev/null 2>&1; then
        local IFS_old="$IFS"
        IFS=','
        for pr_ref in $e_prs_auto; do
          IFS="$IFS_old"
          _fi_pr_info "$pr_ref"
          if [[ "${_fi_pr_ans%%$'\x1f'*}" == "MERGED" ]]; then
            awaiting_confirm+=("$e_loc — suggested (PR-auto: $pr_ref) has merged")
            awaiting_cmds+=("pr"$'\x1f'"$pr_ref"$'\x1f'"$e_loc")
          fi
        done
        IFS="$IFS_old"
      fi

      # PR annotations can only close an entry when sync resolves the GitHub
      # repo; in 'git' mode (no github.com remote, or gh not authenticated)
      # they silently never do. Counted here, warned once at the end.
      if [[ -n "$e_prs" && -z "$repo_id" ]]; then
        pr_unresolved=$((pr_unresolved + 1))
      fi

      # Check PR annotations (single gh call per PR returning all needed fields)
      if [[ -n "$e_prs" && -n "$repo_id" ]] && command -v gh >/dev/null 2>&1; then
        local IFS_old="$IFS"
        IFS=','
        for pr_ref in $e_prs; do
          IFS="$IFS_old"
          _fi_pr_info "$pr_ref"
          if [[ -z "$_fi_pr_ans" ]]; then
            # gh empty: warn at end of sync (don't demote — could be transient)
            gh_empty_warnings+=("$pr_ref")
            continue
          fi
          local pr_state pr_branch pr_merged_at pr_head
          IFS=$'\x1f' read -r pr_state pr_branch pr_merged_at pr_head <<<"$_fi_pr_ans"
          local pr_landed=0
          if [[ "$pr_state" == "MERGED" ]]; then
            if [[ -z "$default_branch" || "$pr_branch" == "$default_branch" ]]; then
              pr_landed=1
            elif [[ "$pr_head" == fi/autofix/* || "$pr_head" == fi/sweep/* ]]; then
              # 3.2.0 (spec section 4): an auto-fix lands in the session's
              # branch; the operator decided that closes the entry.
              pr_landed=1
            elif [[ -n "$pr_branch" && -n "$pr_merged_at" ]]; then
              # Landed once <base> merged into the default branch after it.
              _fi_promoted_at "${pr_ref%#*}" "$pr_branch"
              if [[ "$_fi_prom_ans" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T && ! "$_fi_prom_ans" < "$pr_merged_at" ]]; then pr_landed=1; fi
            fi
          fi
          if (( pr_landed )); then
            closure_kind="pr"
            closure_label="(fixed: $today)"
            closed_pr=$((closed_pr + 1))
            break
          fi

          # A1: CLOSED-without-merge → mark for demotion (don't break — another PR may have merged)
          if [[ "$pr_state" == "CLOSED" && -z "$pr_merged_at" ]]; then
            demote_pr_refs+=("$pr_ref")
          fi
        done
        IFS="$IFS_old"
      fi

      # Check commit annotations (only if not already closed via PR)
      if [[ -z "$closure_kind" && -n "$e_commits" && -n "$default_branch" ]]; then
        local IFS_old="$IFS"
        IFS=','
        for sha in $e_commits; do
          IFS="$IFS_old"
          if git rev-parse --verify "$sha" >/dev/null 2>&1; then
            if git merge-base --is-ancestor "$sha" "$default_branch" 2>/dev/null \
               || git merge-base --is-ancestor "$sha" "origin/$default_branch" 2>/dev/null; then
              # Close only when the commit touched the cited file. Entries with
              # no path, or a repo-prefixed path naming another repo's file,
              # have nothing this repo's history can be compared against.
              if [[ -n "$e_path" && "$e_path" != *:* ]] \
                 && ! fi_commit_touches_entry "$sha" "$e_path" "$e_renamed_from"; then
                entry_notes+=("commit $sha is on $default_branch but did not touch $e_path — left [open] ($e_loc); if the annotation is wrong: found-issues unannotate $(fi_sq "$e_loc") $sha")
                continue
              fi
              closure_kind="commit"
              closure_label="(fixed: $today)"
              closed_commit=$((closed_commit + 1))
              break
            fi
            # SHA exists but isn't ancestor — leave alone (unmerged feature branch)
          elif (( shallow_repo )) \
               || [[ "$(git cat-file -t "$sha" 2>&1 || true)" == *ambiguous* ]]; then
            : # Git cannot tell here (shallow history / ambiguous short SHA) —
              # leave the annotation for a full clone to judge.
          else
            # B1/B2: SHA doesn't resolve (squash-merge dropped it, force-push removed it) → demote
            demote_commit_refs+=("$sha")
          fi
        done
        IFS="$IFS_old"
      fi

      # Notes for annotated commits that landed but never touched the cited
      # file: only worth saying when nothing else closed the entry.
      if [[ -z "$closure_kind" && ${#entry_notes[@]} -gt 0 ]]; then
        unrelated_notes+=("${entry_notes[@]}")
      fi

      # Tombstone check (only if no annotations resolved AND path looks like a file)
      if [[ -z "$closure_kind" && -n "$e_path" ]]; then
        # Entry paths come from a committed file in a possibly-cloned repo —
        # treat as untrusted. Absolute paths and any ../ component would let
        # the probes below (stat, wc -l, rename detection) reach outside the
        # repo: an existence/line-count oracle plus false tombstone flips.
        # SessionStart auto-runs sync, so this fires with no user action.
        if [[ "$e_path" == /* || "$e_path" == "~"* || "$e_path" == \$* \
              || "$e_path" == ".." || "$e_path" == ../* \
              || "$e_path" == */../* || "$e_path" == */.. ]]; then
          : # Not a repo-relative path — never probe the filesystem for it.
            # ~-prefixed and $VAR-prefixed locations cite machine state
            # outside the repo (~/.claude.json, $HOME/.config/...): probing
            # them as repo-relative literals always misses, which tombstoned
            # such entries on every sync (agent-config 2026-07-20 — four
            # false closures of one entry in a day).
        elif [[ "$e_path" == *[\*\?]* || "$e_path" == *\{*\}* || "$e_path" == *\[*\]* ]]; then
          # Glob/brace location tokens (tests/*.bats, config/{dev,prod}.yml)
          # are pattern descriptors, not filenames — the parser accepts them
          # for dedup, but probing them as literal paths always misses and
          # would false-tombstone the entry at every SessionStart sync.
          :
        elif [[ "$e_path" == *:* ]]; then
          # Repo-prefixed locations (`LendMatrix-svc:src/services/foo.ts`)
          # name a file in ANOTHER repo. Probing them against this repo's
          # root always misses, so before #123 taught the parser this shape
          # they would have false-tombstoned on every sync — the same failure
          # the ~/$VAR, glob/brace and directory guards above exist to stop.
          # A plain path can never contain ':' (the parser's charset excludes
          # it), so this only catches the legacy multi-repo shape.
          :
        elif [[ "$e_path" == */* || "$e_path" == *.* ]]; then
          local full_path="$repo_root/$e_path"
          # fi_parse_entry takes the first whitespace-delimited token as the
          # path (lib/parse-entries.sh) — it has to, since the location field
          # also carries `path symbol ~1982-1989` forms. So a path containing
          # spaces ("docs/handoff/HO production env setup.md:88") silently
          # becomes a DIFFERENT, non-existent path ("docs/handoff/HO") and the
          # entry is tombstoned on every pass even though the file is present.
          # `log` creates such entries itself (the */* branch at :476 takes the
          # location verbatim), so this is not limited to hand-edited ledgers.
          # Recover the untruncated location from the raw line and re-probe
          # before declaring a closure. Deliberately does NOT widen the parser:
          # that would shift dedup keys and break the `path symbol ~range`
          # forms first_token exists to support.
          # Only consulted when the parsed path is missing (both branches below
          # are no-ops for a present file), so only computed then — it was a
          # sed per path entry per sync (audit ledger-5). Builtin strip, same
          # anchored prefix the parser uses.
          local recovered_loc=""
          if [[ ! -e "$full_path" && "$e_path" != *[[:space:]]* ]]; then
            local re_entry_prefix='^- \[(open|deferred|fixed)\]( \[!\])? [0-9]{4}-[0-9]{2}-[0-9]{2} '
            recovered_loc="$line"
            [[ "$line" =~ $re_entry_prefix ]] && recovered_loc="${line#"${BASH_REMATCH[0]}"}"
            recovered_loc="${recovered_loc%% — *}"
            recovered_loc="${recovered_loc%:[0-9]*}"
            # only meaningful when the raw location actually contained spaces
            [[ "$recovered_loc" == *[[:space:]]* ]] || recovered_loc=""
          fi
          if [[ -n "$recovered_loc" && -e "$repo_root/$recovered_loc" ]]; then
            : # parser truncated a real, existing path — never tombstone
          elif [[ ! -e "$full_path" ]]; then
            # -e, not -f: an entry may cite a DIRECTORY (.git/worktrees,
            # src/utils) — an existing dir is not a missing file (agent-config
            # 2026-07-27: fresh dir entry false-closed twice within minutes).
            # Ask git about the FULL location, not the whitespace-truncated
            # first token: for "docs/handoff/absent report.md" the parser hands
            # us "docs/handoff/absent", which git has never tracked, so the
            # oracle below would answer "not a removal" for every spaced path.
            # recovered_loc is only non-empty when it actually recovered spaces.
            # Two candidates, and BOTH must be tried — they cover different
            # location shapes and neither subsumes the other:
            #   "docs/handoff/absent report.md:2"  -> the whole thing is the
            #      filename, so only recovered_loc names a real path.
            #   "lib/foo.sh fi_helper ~1-3"        -> only the FIRST token is a
            #      filename; recovered_loc is the whole descriptor, which git
            #      has never tracked. This is the very form the first-token
            #      parser exists to support, so probing recovered_loc alone
            #      silently dropped both tombstone and rename handling for it.
            # Try recovered_loc first (it is the more specific claim), then fall
            # back to e_path. The fallback cannot resurrect the false-close this
            # change removes: a spaced filename's truncated prefix is itself
            # never tracked, so the oracle still declines.
            local detected_new_path="" matched_src=""
            # A rename source and a git-confirmed removal both need the path
            # in history. A never-tracked location (abstract topic, typo,
            # gitignored file) can be neither, so skip the whole-history
            # rename scan it used to pay on every sync (audit ledger-6).
            if [[ -z "$(cd "$repo_root" && git log -1 --format=%H -- "$e_path" 2>/dev/null)" ]] \
               && { [[ -z "$recovered_loc" ]] \
                    || [[ -z "$(cd "$repo_root" && git log -1 --format=%H -- "$recovered_loc" 2>/dev/null)" ]]; }; then
              : # never tracked — leave the entry [open]
            elif [[ -n "$recovered_loc" ]] \
               && detected_new_path="$(cd "$repo_root" && fi_detect_rename "$recovered_loc")"; then
              matched_src="$recovered_loc"
            elif detected_new_path="$(cd "$repo_root" && fi_detect_rename "$e_path")"; then
              matched_src="$e_path"
            fi
            if [[ -n "$matched_src" ]]; then
              rename_target="$detected_new_path"
              # Must be the path we actually MATCHED: the substitution downstream
              # replaces this literal, so using the truncated first token on a
              # spaced location rewrote only the prefix and garbled the entry.
              rename_source="$matched_src"
              # don't set closure_kind — entry stays [open] with corrected path
            elif { [[ -n "$recovered_loc" ]] \
                   && (cd "$repo_root" && fi_git_confirms_removed "$recovered_loc"); } \
                 || (cd "$repo_root" && fi_git_confirms_removed "$e_path"); then
              # Absent from disk AND git confirms a committed removal. Anything
              # git cannot confirm — never-tracked abstract locations, gitignored
              # paths, uncommitted deletions — leaves the entry [open]. See
              # fi_git_confirms_removed in bin/found-issues (issue #151).
              closure_kind="tombstone"
              closure_label="(closure: tombstone) (fixed: $today)"
              closed_tomb=$((closed_tomb + 1))
            fi
          fi
          # NO line-count branch here, deliberately. A present file whose line
          # count fell below the cited line is LINE DRIFT, not a closure: the
          # entry says nothing about whether the issue was fixed, only that the
          # file changed shape. Tombstoning on that false-closed live entries
          # every time a tracked file shrank -- silently, since SessionStart
          # runs sync unattended, and permanently, since no supported command
          # reopens a [fixed] entry. Removed 2026-08-12 after it fired four
          # times during the v2.2.5-v2.2.7 extraction (bin/found-issues
          # 5209 -> 3443 lines closed the entry cited at :4811). Closure above
          # still fires on a genuinely missing or renamed file, which is the
          # only signal that actually relates to the entry.
        fi
      fi

      if [[ -n "$closure_kind" ]]; then
        # Flip [open] -> [fixed], append closure_label
        local fixed_line="${line/\[open\]/[fixed]}" fixed_eol=""
        # CRLF ledger: the label goes before the CR, not after it.
        if [[ "$fixed_line" == *$'\r' ]]; then
          fixed_eol=$'\r'
          fixed_line="${fixed_line%$'\r'}"
        fi
        printf '%s %s%s\n' "$fixed_line" "$closure_label" "$fixed_eol" >>"$tmp"
      elif [[ -n "$rename_target" ]]; then
        # C1: auto-correct entry path after detecting git mv
        local corrected_line="$line" corrected_eol=""
        if [[ "$corrected_line" == *$'\r' ]]; then
          corrected_eol=$'\r'
          corrected_line="${corrected_line%$'\r'}"
        fi
        # First occurrence only, matched literally: an unquoted ${x/pat/rep}
        # treats glob characters in the path as a pattern, and bash 5.2
        # expands & in the replacement to the match.
        local rename_pre="${corrected_line%%"$rename_source"*}"
        if [[ "$rename_pre" != "$corrected_line" ]]; then
          corrected_line="${rename_pre}${rename_target}${corrected_line#"$rename_pre$rename_source"}"
        fi
        if [[ "$corrected_line" != *"(renamed-from:"* ]]; then
          corrected_line="$corrected_line (renamed-from: $rename_source)"
        fi
        printf '%s%s\n' "$corrected_line" "$corrected_eol" >>"$tmp"
        renamed_count=$((renamed_count + 1))
      elif (( ${#demote_pr_refs[@]} > 0 || ${#demote_commit_refs[@]} > 0 )); then
        # A1/B1: demote stale annotations while keeping entry [open]
        local demoted_line="$line"
        local ref
        if (( ${#demote_pr_refs[@]} > 0 )); then
          for ref in "${demote_pr_refs[@]}"; do
            demoted_line="${demoted_line//(PR: $ref)/(PR-closed: $ref)}"
          done
          demoted_pr=$((demoted_pr + 1))
        fi
        if (( ${#demote_commit_refs[@]} > 0 )); then
          for ref in "${demote_commit_refs[@]}"; do
            demoted_line="${demoted_line//(commit: $ref)/(commit-stale: $ref)}"
          done
          demoted_commit=$((demoted_commit + 1))
        fi
        printf '%s\n' "$demoted_line" >>"$tmp"
      else
        printf '%s\n' "$line" >>"$tmp"
      fi
    elif [[ "$line" == "- [deferred]"* && "$line" == *"(until: "* ]] \
         && fi_parse_entry_vars "$line" && [[ -n "$FE_until" ]] \
         && fi_until_due "$FE_until" "$today"; then
      # v3 wake-up (spec §6 step 3): the blocker is gone, so the entry is
      # actionable again. The trigger is dropped; its fix tag is kept.
      fi_entry_retag "$line" drop-until ""
      printf '%s\n' "- [open]${FI_RETAGGED#- \[deferred\]}" >>"$tmp"
      woke=$((woke + 1))
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$file"

  if (( dry_run )); then
    rm -f "$tmp"
    trap - EXIT
  else
    local replace_rc=0
    fi_ledger_replace "$file" "$tmp" "$snapshot" || replace_rc=$?
    trap - EXIT
    if (( replace_rc == 3 )); then
      # Someone wrote the ledger while we were asking gh. Their write stands;
      # redo our pass once against the new content. A second collision means
      # sustained contention — give up loudly rather than loop.
      if [[ -z "${FI_SYNC_RETRY:-}" ]]; then
        FI_SYNC_RETRY=1 cmd_sync
        return $?
      fi
      fi_err "sync: the ledger changed while sync was running — nothing written; run sync again"
      return 1
    elif (( replace_rc != 0 )); then
      return "$replace_rc"
    fi
    # v3 spec §4.1: woken entries may make a sweep due, and so may an
    # untagged backlog nothing else ever re-checks (lib/autofix-sweep.sh:97).
    fi_af_sweep_check || true
  fi

  local total_closed=$((closed_pr + closed_commit + closed_tomb))
  local total_demoted=$((demoted_pr + demoted_commit))
  if [[ "$total_closed" -gt 0 || "$total_demoted" -gt 0 || "$renamed_count" -gt 0 || "$woke" -gt 0 ]]; then
    local summary="Synced."
    (( dry_run )) && summary="Dry run — nothing written."
    if (( total_closed > 0 )); then
      summary+="$(printf ' Closed: %d (%d PR + %d commit + %d tombstone).' \
        "$total_closed" "$closed_pr" "$closed_commit" "$closed_tomb")"
    fi
    if (( total_demoted > 0 )); then
      summary+="$(printf ' Demoted: %d (%d PR-closed + %d commit-stale).' \
        "$total_demoted" "$demoted_pr" "$demoted_commit")"
    fi
    if (( renamed_count > 0 )); then
      summary+="$(printf ' Renamed: %d.' "$renamed_count")"
    fi
    (( woke > 0 )) && summary+="$(printf ' Woke: %d.' "$woke")"
    printf '%s\n' "$summary"
  else
    printf 'Synced. Nothing to close.\n'
  fi
  cmd_status plain

  # Surface pending suggestions whose ref landed. Deliberately NOT a closure
  # and deliberately NOT silent: the whole point of the suggestion form is
  # that a human or model decides, and a decision nobody is told to make
  # never gets made.
  if (( ${#awaiting_confirm[@]} > 0 )); then
    printf '\n%d hook-suggested annotation(s) awaiting confirmation (NOT closed):\n' "${#awaiting_confirm[@]}"
    local ac i ck cr cl
    for (( i = 0; i < ${#awaiting_confirm[@]}; i++ )); do
      ac="${awaiting_confirm[$i]}"
      printf '  - %s\n' "$ac"
      IFS=$'\x1f' read -r ck cr cl <<<"${awaiting_cmds[$i]}"
      if [[ "$ck" == "pr" ]]; then
        # A PR of this repo is confirmed by number; another repo's by org/repo#N.
        local pr_arg="$cr"
        [[ -n "$repo_id" && "$cr" == "$repo_id#"* ]] && pr_arg="${cr##*#}"
        printf '      confirm: found-issues annotate-pr %s --pick %s\n' "$pr_arg" "$(fi_sq "$cl")"
      else
        # --force: the commit is already on the default branch, which
        # annotate-commit refuses from a feature branch without it.
        printf '      confirm: found-issues annotate-commit %s --force --pick %s\n' "$cr" "$(fi_sq "$cl")"
      fi
      printf '      reject:  found-issues unannotate %s %s\n' "$(fi_sq "$cl")" "$cr"
    done
    printf 'Compare each entry against what the change actually did, then run its confirm or reject line.\n'
  fi

  # Landed annotated commits that never touched the file their entry cites.
  # The entry stays [open]; say so, once per entry and commit, with the undo.
  if (( ${#unrelated_notes[@]} > 0 )); then
    local un
    for un in "${unrelated_notes[@]}"; do
      printf 'sync: %s\n' "$un"
    done
  fi

  # (PR: ...) annotations that sync could not check because the GitHub repo
  # did not resolve. Without this the entries just never close.
  if (( pr_unresolved > 0 )); then
    local pr_noun="entries carry"
    (( pr_unresolved == 1 )) && pr_noun="entry carries"
    printf 'Warning: %d %s (PR: ...) annotations but the GitHub repo cannot be resolved (mode: %s) — PR merges will not close them. Check the origin remote and `gh auth status`, or set FOUND_ISSUES_MODE.\n' \
      "$pr_unresolved" "$pr_noun" "$mode" >&2
  fi

  # Surface gh-empty warnings: PRs that couldn't be fetched.
  # Don't demote — could be transient auth/network/rate-limit.
  if (( ${#gh_empty_warnings[@]} > 0 )); then
    printf '\nWarning: %d PR annotation(s) could not be fetched via gh:\n' "${#gh_empty_warnings[@]}" >&2
    local w
    for w in "${gh_empty_warnings[@]}"; do
      printf '  - %s\n' "$w" >&2
    done
    printf '  (Check gh auth status or verify the PR numbers are correct.)\n' >&2
  fi

  # Auto-archive: enforced by default. Users who want pure manual control set
  # FOUND_ISSUES_AUTO_ARCHIVE=off in their shell rc. Without enforcement, users
  # forget /found-issues:archive exists and files balloon to thousands of entries.
  # --dry-run must reach here having written NOTHING: auto-archive rewrites the
  # ledger and creates found-issues-archive.md, so skipping only the `mv` above
  # left a dry run that still moved entries once the 50-[fixed] threshold was
  # crossed — the one case the flag exists to let you inspect first.
  if (( dry_run )); then
    :
  elif [[ "${FOUND_ISSUES_AUTO_ARCHIVE:-on}" != "off" ]]; then
    local archive_output archive_rc=0
    archive_output="$(cmd_archive 2>&1)" || archive_rc=$?
    # A failed archive used to vanish here; say so on stderr (sync's own exit
    # code is unchanged: the sync itself succeeded).
    if (( archive_rc != 0 )); then
      printf 'sync: auto-archive failed (exit %d):\n%s\n' "$archive_rc" "$archive_output" >&2
    # Surface output only when entries actually moved (not on no-op runs)
    elif [[ "$archive_output" == *"moved"*"entries"* ]]; then
      printf '\n%s\n' "$archive_output"
    fi
  else
    # Opted out — surface the hint instead so they know thresholds are exceeded
    local fixed_total
    fixed_total=$(grep -cE '^- \[fixed\]' "$file" 2>/dev/null || true)
    [[ "$fixed_total" =~ ^[0-9]+$ ]] || fixed_total=0
    if (( fixed_total > 50 )); then
      printf '\nHint: %d fixed entries. Run /found-issues:archive to clean up (auto-archive is off).\n' \
        "$fixed_total"
    fi
  fi
}

