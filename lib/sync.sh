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
file git confirms was removed. Runs automatically at SessionStart.

  --dry-run   Report what would change; write nothing.
  -h, --help  Show this help.

Closures are not reversible — there is no command that reopens a [fixed]
entry. Use --dry-run first when in doubt.
EOF
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
  local demoted_pr=0
  local demoted_commit=0
  local renamed_count=0
  local -a gh_empty_warnings=()
  local today
  today="$(fi_today)"
  local tmp
  tmp="$(mktemp -t found-issues.XXXXXX)"
  trap "rm -f '$tmp'" EXIT

  local line
  # Final-partial-line guard — see the READ-LOOP GUARD block in bin/found-issues.
  # Worst case of the class: SessionStart runs sync automatically, so the loss
  # happened with no user action and no output saying anything was removed.
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^-\ \[open\] ]]; then
      local e_data e_path e_prs e_commits
      local -a demote_pr_refs=()
      local -a demote_commit_refs=()
      local rename_target="" rename_source=""
      e_data="$(fi_parse_entry "$line")" || { printf '%s\n' "$line" >>"$tmp"; continue; }
      e_path="$(printf '%s' "$e_data" | grep '^path=' | head -1 | cut -d= -f2-)"
      e_prs="$(printf '%s' "$e_data" | grep '^prs=' | head -1 | cut -d= -f2-)"
      e_commits="$(printf '%s' "$e_data" | grep '^commits=' | head -1 | cut -d= -f2-)"

      local closure_kind="" closure_label=""

      # Check PR annotations (single gh call per PR returning all needed fields)
      if [[ -n "$e_prs" && -n "$repo_id" ]] && command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        local IFS_old="$IFS"
        IFS=','
        for pr_ref in $e_prs; do
          IFS="$IFS_old"
          local pr_num="${pr_ref##*#}"
          local pr_repo="${pr_ref%#*}"
          local pr_json
          pr_json="$(gh pr view "$pr_num" --repo "$pr_repo" \
            --json state,baseRefName,mergedAt,isDraft 2>/dev/null || true)"
          if [[ -z "$pr_json" ]]; then
            # gh empty: warn at end of sync (don't demote — could be transient)
            gh_empty_warnings+=("$pr_ref")
            continue
          fi
          local pr_state pr_branch
          pr_state="$(printf '%s' "$pr_json" | jq -r '.state // empty')"
          pr_branch="$(printf '%s' "$pr_json" | jq -r '.baseRefName // empty')"
          if [[ "$pr_state" == "MERGED" && ( -z "$default_branch" || "$pr_branch" == "$default_branch" ) ]]; then
            closure_kind="pr"
            closure_label="(fixed: $today)"
            closed_pr=$((closed_pr + 1))
            break
          fi

          # A1: CLOSED-without-merge → mark for demotion (don't break — another PR may have merged)
          local pr_merged_at
          pr_merged_at="$(printf '%s' "$pr_json" | jq -r '.mergedAt // empty')"
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
              closure_kind="commit"
              closure_label="(fixed: $today)"
              closed_commit=$((closed_commit + 1))
              break
            fi
            # SHA exists but isn't ancestor — leave alone (unmerged feature branch)
          else
            # B1/B2: SHA doesn't resolve (squash-merge dropped it, force-push removed it) → demote
            demote_commit_refs+=("$sha")
          fi
        done
        IFS="$IFS_old"
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
          local repo_root
          repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
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
          local recovered_loc=""
          if [[ "$e_path" != *[[:space:]]* ]]; then
            recovered_loc="$(printf '%s' "$line" | sed -E 's/^- \[(open|deferred|fixed)\]( \[!\])? [0-9]{4}-[0-9]{2}-[0-9]{2} //')"
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
            if [[ -n "$recovered_loc" ]] \
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
        local fixed_line="${line/\[open\]/[fixed]}"
        printf '%s %s\n' "$fixed_line" "$closure_label" >>"$tmp"
      elif [[ -n "$rename_target" ]]; then
        # C1: auto-correct entry path after detecting git mv
        local corrected_line="$line"
        corrected_line="${corrected_line/$rename_source/$rename_target}"
        if [[ "$corrected_line" != *"(renamed-from:"* ]]; then
          corrected_line="$corrected_line (renamed-from: $rename_source)"
        fi
        printf '%s\n' "$corrected_line" >>"$tmp"
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
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$file"

  if (( dry_run )); then
    rm -f "$tmp"
    trap - EXIT
  else
    mv "$tmp" "$file"
    trap - EXIT
  fi

  local total_closed=$((closed_pr + closed_commit + closed_tomb))
  local total_demoted=$((demoted_pr + demoted_commit))
  if [[ "$total_closed" -gt 0 || "$total_demoted" -gt 0 || "$renamed_count" -gt 0 ]]; then
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
    printf '%s\n' "$summary"
  else
    printf 'Synced. Nothing to close.\n'
  fi
  cmd_status plain

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
    local archive_output
    archive_output="$(cmd_archive 2>&1 || true)"
    # Surface output only when entries actually moved (not on no-op runs)
    if [[ "$archive_output" == *"moved"*"entries"* ]]; then
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

