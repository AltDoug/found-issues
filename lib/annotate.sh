#!/usr/bin/env bash
# annotate.sh — shared annotate engine for annotate-pr and annotate-commit
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Extracted verbatim from bin/found-issues in v2.2.9 — the final step of the
# tracked §12 split, which closes the loc-validator entry and removes the
# loc-override marker from the CLI header.
#
# Functions:
#   fi_entry_loc <entry>
#   fi_split_picks <spec>
#   fi_annotate_apply_picks [...]
#   fi_diff_old_ranges <diff>
#   fi_line_matched [...]
#   fi_annotate_auto [...]

# === Shared annotate engine (annotate-pr / annotate-commit) ===
#
# Both annotate commands share the same matching machinery: file-level
# auto-annotation with an ambiguity guard, plus explicit --pick / --all
# selection. Keeping it in one place means the guard cannot drift between
# the two commands (annotate-commit shipped guard-less at first).

# Echo the entry's location token (path:line, path:start-end for line-range
# entries, or bare path for line-less entries) — the same form the candidate
# list prints and --pick matches.
# Returns 1 when the line does not parse as an entry with a path.
fi_entry_loc() {
  local line="$1"
  local e_data e_path e_line e_line_end
  e_data="$(fi_parse_entry "$line")" || return 1
  e_path="$(printf '%s' "$e_data" | grep '^path=' | head -1 | cut -d= -f2-)"
  e_line="$(printf '%s' "$e_data" | grep '^line=' | head -1 | cut -d= -f2-)"
  # The parser splits `:23-49` into a numeric start plus line_end so the three
  # arithmetic consumers of `line` stay correct; rejoining is this function's
  # job, since --pick matches the location token by exact string equality.
  e_line_end="$(printf '%s' "$e_data" | grep '^line_end=' | head -1 | cut -d= -f2-)"
  [[ -z "$e_path" ]] && return 1
  if [[ -n "$e_line" && -n "$e_line_end" ]]; then
    printf '%s:%s-%s' "$e_path" "$e_line" "$e_line_end"
  elif [[ -n "$e_line" ]]; then
    printf '%s:%s' "$e_path" "$e_line"
  else
    printf '%s' "$e_path"
  fi
}

# Split one --pick flag value into newline-separated selectors. A value
# containing the extended-form separator ' — ' is ONE selector (symptom
# fragments and comma-containing paths must not be comma-split); plain
# values split on commas.
fi_split_picks() {
  local val="$1"
  if [[ "$val" == *" — "* ]]; then
    printf '%s\n' "$val"
    return
  fi
  local IFS_old="$IFS" p out=""
  IFS=','
  for p in $val; do
    IFS="$IFS_old"
    [[ -n "$p" ]] && out+="$p"$'\n'
  done
  IFS="$IFS_old"
  printf '%s' "$out"
}

# Apply explicit --pick selectors.
#   $1 file, $2 annotation, $3 picks_nl (newline-separated selectors),
#   $4 cmd_label (annotate-pr|annotate-commit), $5 rerun_cmd (hint text)
# Selector forms:
#   path:line                — entries whose location token equals the value
#   path:line — fragment     — extended form: location AND symptom contains
#                              the fragment (disambiguates co-located entries)
# A selector matching SEVERAL entries is refused outright — location alone
# cannot select between co-located entries, and annotating both false-flips
# the unfixed one when the PR/commit lands.
# Returns 0 when anything was annotated (or was already annotated); 1 when
# no selector produced an annotation.
fi_annotate_apply_picks() {
  local file="$1" annotation="$2" picks_nl="$3" cmd_label="$4" rerun_cmd="$5"

  local -a pick_arr=() pick_hits=() pick_lines=()
  local pick
  while IFS= read -r pick; do
    [[ -z "$pick" ]] && continue
    pick_arr+=("$pick")
    pick_hits+=(0)
    pick_lines+=("")
  done <<<"$picks_nl"

  # Pass A: per selector, count matching [open] entries and keep their lines.
  local line loc sym i p_loc p_frag
  # Final-partial-line guard (READ-LOOP GUARD, bin/found-issues). This pass only
  # scans, but dropping the final entry here makes it unpickable — the pick
  # reports "no [open] entry matches" for an entry that is plainly there.
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^-\ \[open\] ]] || continue
    loc="$(fi_entry_loc "$line")" || continue
    sym=""
    for (( i = 0; i < ${#pick_arr[@]}; i++ )); do
      pick="${pick_arr[$i]}"
      if [[ "$pick" == *" — "* ]]; then
        p_loc="${pick%% — *}"
        p_frag="${pick#* — }"
        [[ "$loc" == "$p_loc" ]] || continue
        if [[ -z "$sym" ]]; then
          sym="$(fi_parse_entry "$line" | grep '^symptom=' | head -1 | cut -d= -f2-)"
        fi
        [[ "$sym" == *"$p_frag"* ]] || continue
      else
        [[ "$loc" == "$pick" ]] || continue
      fi
      pick_hits[$i]=$(( ${pick_hits[$i]} + 1 ))
      pick_lines[$i]+="$line"$'\n'
    done
  done <"$file"

  # Partition selectors: single hit → annotate; several hits → refuse;
  # zero hits → report (a bad selection must never fail silently).
  local auto_set="" unmatched="" ambiguous=""
  for (( i = 0; i < ${#pick_arr[@]}; i++ )); do
    if (( ${pick_hits[$i]} == 0 )); then
      unmatched+="  ${pick_arr[$i]}"$'\n'
    elif (( ${pick_hits[$i]} == 1 )); then
      auto_set+="${pick_lines[$i]}"
    else
      ambiguous+="  pick '${pick_arr[$i]}' matches ${pick_hits[$i]} entries:"$'\n'
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        ambiguous+="    $line"$'\n'
      done <<<"${pick_lines[$i]}"
    fi
  done

  # Pass B: rewrite the file.
  local tmp matched=0 already=0
  tmp="$(mktemp -t found-issues.XXXXXX)"
  trap "rm -f '$tmp'" EXIT
  # Final-partial-line guard — see the READ-LOOP GUARD block in bin/found-issues.
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$auto_set" ]] && printf '%s' "$auto_set" | grep -Fxq -- "$line"; then
      if [[ "$line" == *"$annotation"* ]]; then
        already=$((already + 1))
        printf '%s\n' "$line" >>"$tmp"
      else
        printf '%s %s\n' "$line" "$annotation" >>"$tmp"
        matched=$((matched + 1))
      fi
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$file"

  if (( matched > 0 )); then
    mv "$tmp" "$file"
    trap - EXIT
    printf 'Annotated %d entr%s with %s\n' "$matched" "$([[ $matched -eq 1 ]] && echo y || echo ies)" "$annotation"
  else
    rm -f "$tmp"
    trap - EXIT
    if (( already > 0 )); then
      printf '%s: selected entr%s already annotated with %s. No changes.\n' \
        "$cmd_label" "$([[ $already -eq 1 ]] && echo y || echo ies)" "$annotation"
    fi
  fi
  if [[ -n "$ambiguous" ]]; then
    printf '%s: refusing picks that match several co-located entries:\n%s' "$cmd_label" "$ambiguous"
    printf 'Disambiguate with the extended pick form (location + symptom fragment):\n'
    printf '  %s --pick "<path:line> — <symptom fragment>"\n' "$rerun_cmd"
  fi
  if [[ -n "$unmatched" ]]; then
    printf '%s: no [open] entry matches pick:\n%s' "$cmd_label" "$unmatched"
  fi

  if (( matched > 0 )); then
    cmd_status plain
    return 0
  fi
  (( already > 0 )) && return 0
  return 1
}

# Default / --all annotation over file-level matches.
#   $1 file, $2 annotation, $3 touched_files (newline-separated paths),
#   $4 annotate_all (yes|no), $5 cmd_label, $6 rerun_cmd, $7 ref_desc
#     (human name of the artifact, e.g. "PR #7" / "commit ab12cd3")
# A candidate auto-annotates only when NONE of the touched files it matches
# is also matched by another [open] entry:
#   - candidate↔candidate sharing on ANY common file is ambiguous — an
#     entry matching several touched files must not split into its own
#     group and sneak past the guard
#   - entries already annotated with this annotation still count as
#     competitors, so a plain re-run after an explicit --pick cannot
#     auto-annotate the deliberately-excluded sibling
# fi_diff_old_ranges — stdin: unified diff; stdout: "path<TAB>start<TAB>end"
# per contiguous run of REMOVED lines, OLD-side line numbers. Ledger entries
# cite pre-fix locations, so the old side is the side that corresponds to the
# cited line numbers.
#
# Only actually-removed lines produce ranges — context lines within a hunk do
# NOT, so a cited line merely NEAR (but not in) an edit never auto-annotates.
# Pure-addition hunks produce no range (a fix that only adds lines is
# conservative by design).
#
# Parser shape:
#   - Header-state tracking: '--- ' is a file header ONLY when armed by a
#     preceding 'diff --git' (git and `gh pr diff` always emit that). A hunk
#     BODY line like '--- old comment' (a deleted SQL '-- comment') is then a
#     removal, not a bogus header, so it can't corrupt path attribution.
#   - The path is the substring after '--- ' (leading 'a/' stripped,
#     /dev/null → empty), not $2 — so paths containing spaces parse fully.
#   - An old-side line counter starts at the @@ old-start and advances on
#     context (' ') and removed ('-') lines; added ('+') lines do not advance
#     it. Contiguous '-' lines are emitted as one start/end run.
fi_diff_old_ranges() {
  LC_ALL=C awk '
    function flush() {
      if (in_run) { printf "%s\t%d\t%d\n", cur, run_start, run_end; in_run = 0 }
    }
    /^diff --git / { flush(); armed = 1; next }
    armed && /^--- / {
      p = substr($0, 5)          # strip the "--- " marker (4 chars)
      sub(/^a\//, "", p)
      cur = (p == "/dev/null" ? "" : p)
      armed = 0                  # consumed; the "+++" that follows is not a header
      next
    }
    /^@@ / {
      flush()
      armed = 0
      s = $2; sub(/^-/, "", s); split(s, m, ",")
      oldline = m[1] + 0
      next
    }
    {
      if (cur == "") next
      c = substr($0, 1, 1)
      if (c == "+") { flush(); next }        # addition: no old-side advance
      if (c == "-") {                        # removal on the old side
        if (in_run) { run_end = oldline } else { in_run = 1; run_start = oldline; run_end = oldline }
        oldline++
        next
      }
      flush()                                # context or metadata ends any run
      if (c == " ") oldline++                # only real context advances the counter
    }
    END { flush() }
  '
}

# fi_line_matched <path> <line> <ranges> [line_end] — 0 iff <path>'s cited
# lines OVERLAP any old-side range. Path comparison mirrors the entry/touched-
# file rule used in fi_annotate_auto (exact or suffix match either way).
#
# <line_end> is the parser's line_end for a range entry (`path:23-49`). A range
# whose START sits outside every hunk can still have its BODY overlap one, so
# testing the start alone silently missed those. Empty line_end degrades to the
# single-line test (start == end), which is the identical comparison.
fi_line_matched() {
  local p="$1" ln="$2" ranges="$3" lend="${4:-}"
  [[ -z "$ln" || -z "$ranges" ]] && return 1
  # Guard the arithmetic: a non-numeric end would make (( )) evaluate garbage.
  [[ "$lend" =~ ^[0-9]+$ ]] || lend="$ln"
  (( 10#$lend < 10#$ln )) && lend="$ln"
  local rp rs re
  while IFS=$'\t' read -r rp rs re; do
    [[ -z "$rp" ]] && continue
    if [[ "$rp" == "$p" || "$rp" == */"$p" || "$p" == */"$rp" ]]; then
      # Overlap: the entry starts at or before the hunk ends AND ends at or
      # after the hunk starts. `10#` on the entry-side values because they come
      # from ledger text — a zero-padded `path:08` is a base-8 literal to
      # (( )) and errors out under bash 3.2 (macOS CI) without it.
      if (( 10#$ln <= re && 10#$lend >= rs )); then
        return 0
      fi
    fi
  done <<<"$ranges"
  return 1
}

# --all annotates every candidate.
# hook_auto (yes|no, $8) gates auto-annotation on a stricter rule for the
# PostToolUse hook: a candidate must ALSO be unambiguous under the
# file-contest rule below AND have its cited lines OVERLAP an old_ranges
# ($9, from fi_diff_old_ranges) hunk range for its path — for a range entry
# that means any part of start..line_end, not just the start. Line-less entries
# never line-match (fi_line_matched short-circuits on empty line), so they
# never auto-annotate in hook mode. See cmd_annotate_pr/cmd_annotate_commit
# for how hook_auto/old_ranges are produced.
fi_annotate_auto() {
  local file="$1" annotation="$2" touched_files="$3" annotate_all="$4"
  local cmd_label="$5" rerun_cmd="$6" ref_desc="$7"
  local hook_auto="${8:-no}" old_ranges="${9:-}"

  # Pass 1: collect candidates with the FULL set of touched files each one
  # matches; already-annotated entries contribute their files to ann_tfs.
  local -a cand_lines=() cand_locs=() cand_syms=() cand_tfs=()
  local -a cand_paths=() cand_lnums=() cand_lends=()
  local ann_tfs=""
  local line tf
  # Final-partial-line guard (READ-LOOP GUARD, bin/found-issues). Scan-only, but a
  # dropped final entry never becomes a candidate — it would silently miss
  # annotation while pass 3 below rewrites the file around it.
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^-\ \[open\] ]] || continue
    local e_data e_path e_line e_line_end e_symptom
    e_data="$(fi_parse_entry "$line")" || continue
    e_path="$(printf '%s' "$e_data" | grep '^path=' | head -1 | cut -d= -f2-)"
    [[ -z "$e_path" ]] && continue
    # Repo-prefixed locations (`LendMatrix-svc:src/foo.ts`, #123) name another
    # repo's file. The comparison below matches with glob suffix tolerance, so
    # a local `services/foo.ts` would match `LendMatrix-svc:src/services/foo.ts`
    # and silently false-flip a foreign-repo entry to [fixed] on merge, wearing
    # a plausible-looking annotation — harder to notice than a tombstone.
    # Explicit --pick still selects these entries by their exact location.
    [[ "$e_path" == *:* ]] && continue
    local matched_tfs=""
    while IFS= read -r tf; do
      [[ -z "$tf" ]] && continue
      if [[ "$tf" == "$e_path" || "$tf" == */"$e_path" || "$e_path" == */"$tf" ]]; then
        matched_tfs+="$tf"$'\n'
      fi
    done <<<"$touched_files"
    [[ -z "$matched_tfs" ]] && continue
    if [[ "$line" == *"$annotation"* ]]; then
      ann_tfs+="$matched_tfs"
      continue
    fi
    e_line="$(printf '%s' "$e_data" | grep '^line=' | head -1 | cut -d= -f2-)"
    e_line_end="$(printf '%s' "$e_data" | grep '^line_end=' | head -1 | cut -d= -f2-)"
    e_symptom="$(printf '%s' "$e_data" | grep '^symptom=' | head -1 | cut -d= -f2-)"
    cand_lines+=("$line")
    # Must render the SAME token fi_entry_loc emits — this list is what the
    # user copies into --pick, which matches by exact string equality. Line
    # ranges therefore have to be rejoined here too. cand_lnums/cand_lends stay
    # the split numeric halves: they feed fi_line_matched's (( )) hunk overlap.
    local loc
    loc="$(fi_entry_loc "$line")" || loc="$e_path"
    cand_locs+=("$loc")
    cand_syms+=("$e_symptom")
    cand_tfs+=("$matched_tfs")
    cand_paths+=("$e_path")
    cand_lnums+=("$e_line")
    cand_lends+=("$e_line_end")
  done <"$file"

  if (( ${#cand_lines[@]} == 0 )); then
    printf '%s: no [open] entries match files touched by %s. No changes.\n' "$cmd_label" "$ref_desc"
    return 0
  fi

  # Pass 2: partition — a candidate is ambiguous when any of its matched
  # files is contested by another candidate or an already-annotated entry.
  local auto_set=""
  local -a ambig_indices=()
  local i j shared
  for (( i = 0; i < ${#cand_lines[@]}; i++ )); do
    if [[ "$annotate_all" == "yes" ]]; then
      auto_set+="${cand_lines[$i]}"$'\n'
      continue
    fi
    shared=0
    while IFS= read -r tf; do
      [[ -z "$tf" ]] && continue
      for (( j = 0; j < ${#cand_lines[@]}; j++ )); do
        (( j == i )) && continue
        if printf '%s' "${cand_tfs[$j]}" | grep -Fxq -- "$tf"; then
          shared=1
          break
        fi
      done
      if (( shared == 0 )) && [[ -n "$ann_tfs" ]] \
         && printf '%s' "$ann_tfs" | grep -Fxq -- "$tf"; then
        shared=1
      fi
      (( shared == 1 )) && break
    done <<<"${cand_tfs[$i]}"
    if (( shared == 0 )); then
      if [[ "$hook_auto" == "yes" ]] && ! fi_line_matched "${cand_paths[$i]}" "${cand_lnums[$i]}" "$old_ranges" "${cand_lends[$i]}"; then
        ambig_indices+=("$i")
      else
        auto_set+="${cand_lines[$i]}"$'\n'
      fi
    else
      ambig_indices+=("$i")
    fi
  done

  if [[ "$hook_auto" == "yes" ]]; then
    local max_auto="${FOUND_ISSUES_AUTO_ANNOTATE_MAX:-3}"
    local auto_count
    auto_count="$(printf '%s' "$auto_set" | grep -c '^-' || true)"
    if (( auto_count > max_auto )); then
      # Mass-touch guard: a sweep PR line-matches everything (2026-07-09
      # incident shape). Annotate nothing; surface all as candidates.
      auto_set=""
      ambig_indices=()
      for (( i = 0; i < ${#cand_lines[@]}; i++ )); do
        ambig_indices+=("$i")
      done
    fi
  fi

  # Pass 3: rewrite the file with the unambiguous annotations.
  local tmp matched=0
  tmp="$(mktemp -t found-issues.XXXXXX)"
  trap "rm -f '$tmp'" EXIT
  # Final-partial-line guard — see the READ-LOOP GUARD block in bin/found-issues.
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$auto_set" ]] && printf '%s' "$auto_set" | grep -Fxq -- "$line"; then
      printf '%s %s\n' "$line" "$annotation" >>"$tmp"
      matched=$((matched + 1))
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$file"

  if (( matched > 0 )); then
    mv "$tmp" "$file"
    trap - EXIT
    printf 'Annotated %d entr%s with %s\n' "$matched" "$([[ $matched -eq 1 ]] && echo y || echo ies)" "$annotation"
  else
    rm -f "$tmp"
    trap - EXIT
  fi

  if (( ${#ambig_indices[@]} > 0 )); then
    printf '%s: %d [open] entries share touched files with other entries — skipped (file-level match is ambiguous):\n' "$cmd_label" "${#ambig_indices[@]}"
    for i in "${ambig_indices[@]}"; do
      local sym="${cand_syms[$i]}"
      (( ${#sym} > 70 )) && sym="${sym:0:70}..."
      printf '  %s — %s\n' "${cand_locs[$i]}" "$sym"
    done
    printf 'Review which of these %s actually addresses, then annotate them explicitly:\n' "$ref_desc"
    printf '  %s --pick <path:line>[,<path:line>...]\n' "$rerun_cmd"
    printf 'or, if %s addresses every listed entry:\n' "$ref_desc"
    printf '  %s --all\n' "$rerun_cmd"
  fi

  if (( matched > 0 )); then
    cmd_status plain
  fi

  if (( ${#ambig_indices[@]} > 0 )); then
    return 3
  fi
  return 0
}

