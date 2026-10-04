#!/usr/bin/env bash
# parse-entries.sh — read and parse docs/found-issues.md entries
#
# Sourced by other scripts. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# All regex patterns are assigned to variables before matching — bash's
# parser is fussy about `\)` and similar escapes inline within [[ =~ ]].
#
# Functions:
#   fi_find_issues_file [<start_dir>]
#   fi_parse_entry <line>
#   fi_entries <file> [<status_filter>]
#   fi_count <file> [<status_filter>]
#   fi_count_in_pr <file>
#   fi_count_critical <file>
#   fi_count_decide <file>
#   fi_count_residual <file>
#   fi_count_stale <file> [<days=30>]

# Walk up from start_dir looking for the issues file.
# Prefers <dir>/docs/found-issues.md, falls back to <dir>/.found-issues.md.
fi_find_issues_file() {
  local start="${1:-$PWD}"
  local dir
  dir="$(cd "$start" 2>/dev/null && pwd)" || return 1

  while [[ -n "$dir" && "$dir" != "/" ]]; do
    if [[ -f "$dir/docs/found-issues.md" ]]; then
      printf '%s' "$dir/docs/found-issues.md"
      return 0
    fi
    if [[ -f "$dir/.found-issues.md" ]]; then
      printf '%s' "$dir/.found-issues.md"
      return 0
    fi
    dir="${dir%/*}"
    [[ -z "$dir" ]] && dir="/"
  done

  return 1
}

# Return 0 iff $1 is a regular file containing merge-conflict markers.
# A conflict marker is any line beginning with `<<<<<<< `, `=======`, or
# `>>>>>>> ` — git's canonical merge conflict syntax. Used by the parser
# (skip counting inside conflict regions) and by doctor (FAIL-level finding
# when source file is degraded). Cheap: single grep pass, exits on first
# match.
fi_has_conflict_markers() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  LC_ALL=C grep -qE '^(<<<<<<< |=======$|>>>>>>> )' "$file"
}

# fi_icontains <haystack> <needle> — case-insensitive substring test, builtin
# (nocasematch, bash 3.2+). defer and promote-deferred used two subshell+tr
# pairs per entry for this (audit cli-12).
fi_icontains() {
  local was=0 rc=1
  shopt -q nocasematch && was=1
  shopt -s nocasematch
  [[ "$1" == *"$2"* ]] && rc=0
  (( was )) || shopt -u nocasematch
  return $rc
}

# === Argument hygiene (2026-10-03 audit, cli-5 / cli-6 / status-17) ===
#
# Mutating commands used to `shift` past anything they did not recognise, so
# `archive --help` archived, `uninstall --help` deleted state and a typo'd
# `--verifed human` closed an entry as `(verified: ai)`. Every parser now
# refuses unknown options (exit 2) through these two helpers.
#
# fi_need_value <cmd> <flag> <argc> <next> — exit-2 check that a value-taking
# flag got a value (not end of args, not another option).
fi_need_value() {
  if (( $3 < 2 )) || [[ "$4" == -* ]]; then
    fi_err "$1: $2 needs a value"
    return 2
  fi
}

# fi_unknown_arg <cmd> <arg> — the shared refusal.
fi_unknown_arg() {
  if [[ "$2" == -* ]]; then
    fi_err "$1: unknown option '$2' (see: found-issues $1 --help)"
  else
    fi_err "$1: unexpected argument '$2' (see: found-issues $1 --help)"
  fi
  return 2
}

# === Ledger rewrites ===
#
# Every mutator builds the new ledger in a temp file and moves it over the
# old one. Two helpers own that pattern (2026-10-03 audit, ledger-1/ledger-2):
#
#   fi_ledger_tmp <file>
#     Create the temp file BESIDE the ledger. `mktemp -t` put it in $TMPDIR,
#     so on a tmpfs /tmp (or TEMP on another Windows drive) the mv degraded to
#     a non-atomic copy, and the ledger always came out mode 0600.
#
#   fi_ledger_replace <file> <tmp> [<snapshot>]
#     Move tmp over file, but: skip the write entirely when nothing changed
#     (a no-op pass must not replace the inode under a concurrent writer),
#     and when a snapshot from fi_ledger_snapshot is given, refuse with exit 3
#     if the ledger changed since it was taken — someone else wrote it while
#     we were working from the old copy, and moving ours over theirs would
#     silently revert their write. tmp is always consumed.
fi_ledger_tmp() {
  local file="$1" dir="."
  [[ "$file" == */* ]] && dir="${file%/*}"
  mktemp "$dir/.found-issues.tmp.XXXXXX"
}

fi_ledger_snapshot() {
  cksum <"$1" 2>/dev/null || true
}

fi_ledger_replace() {
  local file="$1" tmp="$2" snapshot="${3:-}"
  if cmp -s "$tmp" "$file"; then
    rm -f "$tmp"
    return 0
  fi
  if [[ -n "$snapshot" && "$(fi_ledger_snapshot "$file")" != "$snapshot" ]]; then
    rm -f "$tmp"
    return 3
  fi
  if [[ -f "$file" ]]; then
    local mode
    mode="$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file" 2>/dev/null || true)"
    [[ "$mode" =~ ^[0-7]+$ ]] && { chmod "$mode" "$tmp" 2>/dev/null || true; }
  fi
  mv "$tmp" "$file"
}

# Return the trailing run of recognized "(key: ...)" annotation groups —
# the annotation tail. Walks backward from end-of-line consuming groups
# whose key is in the recognized set; stops at the first thing that is not
# one (prose, a nested-paren suggested block, the symptom). Tokens that
# LOOK like annotations but sit mid-line are therefore excluded.
# Compatible with bash 3.2 (regex in a variable, no lookbehind).
fi_annotation_tail() {
  fi_annotation_tail_v "$1"
  printf '%s' "$FI_ANN_TAIL"
}

# Same walk, result in $FI_ANN_TAIL — no subshell for in-process callers.
fi_annotation_tail_v() {
  local line="$1" tail=""
  local re_tail_group='\((PR|PR-auto|PR-closed|commit|commit-auto|commit-stale|verified|fixed|closure|renamed-from|touched|defer-cycle|reason|mute-until|suggested|fix|decide|decided|manual|until|autofix-failed): [^)]*\)[[:space:]]*$'
  while [[ "$line" =~ $re_tail_group ]]; do
    local grp="${BASH_REMATCH[0]}"
    tail="${grp}${tail}"
    line="${line%"$grp"}"
  done
  FI_ANN_TAIL="$tail"
}

# Parse a single entry line into KEY=VALUE pairs (one per line).
# Returns 1 if the line is not a valid entry. Prints from fi_parse_entry_vars
# below; in-process callers should call that directly and read FE_* instead
# of re-splitting this output with grep pipelines.
fi_parse_entry() {
  fi_parse_entry_vars "$1" || return 1
  printf 'status=%s\n' "$FE_status"
  printf 'critical=%s\n' "$FE_critical"
  printf 'date=%s\n' "$FE_date"
  printf 'path=%s\n' "$FE_path"
  printf 'line=%s\n' "$FE_line"
  # Empty unless the location carried a range. Consumers grep '^line=' and
  # '^line_end=' — anchored, so neither key matches the other's prefix.
  printf 'line_end=%s\n' "$FE_line_end"
  printf 'symptom=%s\n' "$FE_symptom"
  printf 'fix=%s\n' "$FE_fix"
  printf 'prs=%s\n' "$FE_prs"
  printf 'prs_auto=%s\n' "$FE_prs_auto"
  printf 'prs_closed=%s\n' "$FE_prs_closed"
  printf 'commits=%s\n' "$FE_commits"
  printf 'commits_auto=%s\n' "$FE_commits_auto"
  printf 'commits_stale=%s\n' "$FE_commits_stale"
  printf 'renamed_from=%s\n' "$FE_renamed_from"
  printf 'fixed_date=%s\n' "$FE_fixed_date"
  printf 'verified=%s\n' "$FE_verified"
  printf 'fixtag=%s\n' "$FE_fixtag"
  printf 'decide=%s\n' "$FE_decide"
  printf 'decided=%s\n' "$FE_decided"
  printf 'manual=%s\n' "$FE_manual"
  printf 'until=%s\n' "$FE_until"
  printf 'autofix_failed=%s\n' "$FE_autofix_failed"
}

# fi_parse_entry_vars <line> — builtin-only twin of fi_parse_entry. Sets the
# FE_* globals instead of printing KEY=VALUE lines; returns 1 if the line is
# not a valid entry. Zero processes: fi_parse_entry used to fork a sed, a
# subshell for the annotation tail and six grep|sed|paste pipelines per call,
# and its callers re-split the output with three to five more pipelines —
# ~65 process creations per [open] entry in sync, ~650 per SessionStart on an
# 8-entry ledger (2026-10-03 audit, ledger-5 / cli-10 / annot-2). On Git Bash
# every one of those is a Windows process creation.
#
# Field semantics are identical to fi_parse_entry (which now prints from
# these variables); tests/parse-entries*.bats pin them.
FE_status="" FE_critical="" FE_date="" FE_path="" FE_line="" FE_line_end=""
FE_symptom="" FE_fix="" FE_prs="" FE_prs_auto="" FE_prs_closed=""
FE_commits="" FE_commits_auto="" FE_commits_stale="" FE_renamed_from=""
FE_fixed_date="" FE_verified=""
FE_fixtag="" FE_decide="" FE_decided="" FE_manual="" FE_until="" FE_autofix_failed=""

# _fi_collect <tail> <regex with one capture group> — comma-join every
# capture, left to right, the way `grep -oE | sed | paste -sd ,` did.
_fi_collect() {
  local rest="$1" re="$2" out=""
  while [[ "$rest" =~ $re ]]; do
    out+="${out:+,}${BASH_REMATCH[1]}"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done
  _fi_collected="$out"
}

fi_parse_entry_vars() {
  local line="$1"
  FE_status="" FE_critical="no" FE_date="" FE_path="" FE_line="" FE_line_end=""
  FE_symptom="" FE_fix="" FE_prs="" FE_prs_auto="" FE_prs_closed=""
  FE_commits="" FE_commits_auto="" FE_commits_stale="" FE_renamed_from=""
  FE_fixed_date="" FE_verified=""
  FE_fixtag="" FE_decide="" FE_decided="" FE_manual="" FE_until="" FE_autofix_failed=""

  local re_status='^- \[(open|deferred|fixed)\]'
  [[ "$line" =~ $re_status ]] || return 1
  FE_status="${BASH_REMATCH[1]}"

  local re_critical='^- \[(open|deferred|fixed)\] \[!\]'
  [[ "$line" =~ $re_critical ]] && FE_critical="yes"

  local re_date='([0-9]{4}-[0-9]{2}-[0-9]{2})'
  [[ "$line" =~ $re_date ]] && FE_date="${BASH_REMATCH[1]}"

  # Strip the status prefix + entry date (anchored, so a date inside the
  # symptom is never consumed). No match leaves the line unchanged — what
  # the sed it replaces did.
  local re_prefix='^- \[(open|deferred|fixed)\]( \[!\])? [0-9]{4}-[0-9]{2}-[0-9]{2} '
  local after_date="$line"
  [[ "$line" =~ $re_prefix ]] && after_date="${line#"${BASH_REMATCH[0]}"}"
  local location_part="${after_date%% — *}"

  local re_path_line='^([^:[:space:]]+):([0-9]+)(-([0-9]+))?$'
  local re_path_only='^([^:[:space:]]+)$'
  local re_repo_line='^(.+):([0-9]+)(-([0-9]+))?$'
  local first_token="${location_part%%[[:space:]]*}"
  if [[ "$first_token" =~ $re_path_line ]]; then
    FE_path="${BASH_REMATCH[1]}"
    FE_line="${BASH_REMATCH[2]}"
    FE_line_end="${BASH_REMATCH[4]}"
  elif [[ "$first_token" =~ $re_path_only ]]; then
    FE_path="${BASH_REMATCH[1]}"
  elif [[ "$first_token" == *:* && ( "${first_token#*:}" == */* || "${first_token#*:}" == *.* ) ]]; then
    if [[ "$first_token" =~ $re_repo_line ]]; then
      FE_path="${BASH_REMATCH[1]}"
      FE_line="${BASH_REMATCH[2]}"
      FE_line_end="${BASH_REMATCH[4]}"
    else
      FE_path="$first_token"
    fi
  fi

  if [[ "$after_date" == *" — "* ]]; then
    # Drop only the trailing run of recognised "(key: …)" annotations. Cutting
    # at the first "(" made "parse() returns None" and "parse() raises" the
    # same symptom ("parse"), so the second log was skipped as a duplicate
    # (2026-10-03 audit, cli-3).
    local rest="${after_date#* — }"
    fi_annotation_tail_v "$rest"
    FE_symptom="${rest%"$FI_ANN_TAIL"}"
    FE_symptom="${FE_symptom%"${FE_symptom##*[![:space:]]}"}"
  fi

  local re_fix='\(suggested: ([^)]+)\)'
  [[ "$line" =~ $re_fix ]] && FE_fix="${BASH_REMATCH[1]}"

  fi_annotation_tail_v "$line"
  local tail="$FI_ANN_TAIL"
  if [[ -n "$tail" ]]; then
    local repo='[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+' sha='[a-f0-9]{7,40}'
    _fi_collect "$tail" "\\(PR: ($repo)\\)";            FE_prs="$_fi_collected"
    _fi_collect "$tail" "\\(PR-auto: ($repo)\\)";       FE_prs_auto="$_fi_collected"
    _fi_collect "$tail" "\\(PR-closed: ($repo)\\)";     FE_prs_closed="$_fi_collected"
    _fi_collect "$tail" "\\(commit: ($sha)\\)";         FE_commits="$_fi_collected"
    _fi_collect "$tail" "\\(commit-auto: ($sha)\\)";    FE_commits_auto="$_fi_collected"
    _fi_collect "$tail" "\\(commit-stale: ($sha)\\)";   FE_commits_stale="$_fi_collected"
    # v3 fix tags — tail only, so a symptom that merely mentions one is not
    # tagged (spec §3.5).
    local re_fixtag='\(fix: (small|medium|large)\)'
    [[ "$tail" =~ $re_fixtag ]] && FE_fixtag="${BASH_REMATCH[1]}"
    local re_decide='\(decide: ([^)]*)\)'
    [[ "$tail" =~ $re_decide ]] && FE_decide="${BASH_REMATCH[1]}"
    local re_decided='\(decided: ([^)]*)\)'
    [[ "$tail" =~ $re_decided ]] && FE_decided="${BASH_REMATCH[1]}"
    local re_manual='\(manual: ([^)]*)\)'
    [[ "$tail" =~ $re_manual ]] && FE_manual="${BASH_REMATCH[1]}"
    local re_until='\(until: ([^)]*)\)'
    [[ "$tail" =~ $re_until ]] && FE_until="${BASH_REMATCH[1]}"
    local re_afail='\(autofix-failed: ([^)]*)\)'
    [[ "$tail" =~ $re_afail ]] && FE_autofix_failed="${BASH_REMATCH[1]}"
  fi

  local re_renamed='\(renamed-from: ([^)]+)\)'
  [[ "$line" =~ $re_renamed ]] && FE_renamed_from="${BASH_REMATCH[1]}"
  local re_fixed='\(fixed: ([0-9]{4}-[0-9]{2}-[0-9]{2})\)'
  [[ "$line" =~ $re_fixed ]] && FE_fixed_date="${BASH_REMATCH[1]}"
  local re_verified='\(verified: (ai|review)\)'
  [[ "$line" =~ $re_verified ]] && FE_verified="${BASH_REMATCH[1]}"
  return 0
}

# Output entries matching status_filter (open|deferred|fixed|all).
# Returns 1 if file doesn't exist.
# Conflict-aware: lines inside <<<<<<< ... >>>>>>> blocks are excluded.
# Both branches of a conflict are dropped — we never inflate counts during
# a merge conflict. fi_has_conflict_markers exposes this state to doctor
# for prominent surfacing.
fi_entries() {
  local file="$1"
  local status_filter="${2:-all}"
  # Optional 3rd arg "numbered": prefix each line with its file line number
  # ("<n>:<entry>"). The 2-arg form is a frozen contract (statusline
  # snapshots) — output must stay byte-identical when the arg is absent.
  # Any other non-empty value is rejected: silently degrading to
  # un-numbered output would make the caller's "<n>:" split eat into the
  # entry text.
  local numbered="${3:-}"
  if [[ -n "$numbered" && "$numbered" != "numbered" ]]; then
    return 2
  fi

  if [[ ! -f "$file" ]]; then
    return 1
  fi

  case "$status_filter" in
    all|open|deferred|fixed) : ;;
    *) return 2 ;;
  esac

  # Conflict-aware: lines inside <<<<<<< ... >>>>>>> blocks are excluded.
  # Both branches of a conflict are dropped — we never inflate counts during
  # a merge conflict. fi_has_conflict_markers exposes this state to doctor
  # for prominent surfacing.
  #
  # Note: the status_filter is passed as a plain string (-v sf=) and matched
  # with index() rather than a regex variable — bracket characters in awk -v
  # strings are not reliably escaped across all awk implementations.
  LC_ALL=C awk -v sf="$status_filter" -v numbered="$numbered" '
    function emit() { if (numbered == "numbered") print FNR ":" $0; else print $0 }
    /^<<<<<<< / { in_conflict = 1; next }
    /^>>>>>>> / { in_conflict = 0; next }
    /^=======$/ && in_conflict { next }
    !in_conflict && /^- \[/ {
      if (sf == "all") {
        if (index($0, "- [open]")     == 1 ||
            index($0, "- [deferred]") == 1 ||
            index($0, "- [fixed]")    == 1) { emit(); next }
      } else {
        if (index($0, "- [" sf "]") == 1) emit()
      }
    }
  ' "$file"
}

# Count entries by status. Always prints a number (0 if no file or no matches).
fi_count() {
  local file="$1"
  local status_filter="${2:-open}"

  if [[ ! -f "$file" ]]; then
    printf '0'
    return
  fi

  local count
  count="$(fi_entries "$file" "$status_filter" 2>/dev/null | grep -c . || true)"
  printf '%s' "${count:-0}"
}

# Count [open] entries with at least one ACTIVE (PR: ...) annotation.
# Excludes (PR-closed: ...) demoted forms: the literal colon-space in
# '(PR: ' cannot match '(PR-closed:' (hyphen-c), so the regex naturally
# distinguishes the two. Demoted forms flow into fi_count_stale instead.
# Counts via fi_entries (not a raw-file grep) so both sides of a merge
# conflict are excluded, preserving the invariant documented on fi_entries.
fi_count_in_pr() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    printf '0'
    return
  fi

  local count
  count="$(fi_entries "$file" open 2>/dev/null \
    | grep -cE '\(PR: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+\)' || true)"
  printf '%s' "${count:-0}"
}

# Count [open] [!] entries (critical). Conflict-aware via fi_entries.
fi_count_critical() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    printf '0'
    return
  fi

  local count
  count="$(fi_entries "$file" open 2>/dev/null \
    | grep -cE '^- \[open\] \[!\]' || true)"
  printf '%s' "${count:-0}"
}

# Count [open] entries waiting on a decision: a (decide: ...) tag in the
# entry (v3 decision queue, spec §3.4). Conflict-aware via fi_entries.
fi_count_decide() {
  local file="$1" count
  if [[ ! -f "$file" ]]; then printf '0'; return; fi
  count="$(fi_entries "$file" open 2>/dev/null | grep -cE '\(decide: [^)]*\)' || true)"
  printf '%s' "${count:-0}"
}

# Count [open] entries in the residual bucket: neither critical ([!]) nor
# carrying an active (PR: ...) annotation. Computed by exclusion in one
# conflict-aware pass so an entry that is BOTH critical and in-PR is
# excluded once, not twice — the old total-minus-critical-minus-in_pr
# arithmetic in cmd_status double-subtracted the overlap, making plain
# open entries vanish from every rendered counter.
fi_count_residual() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    printf '0'
    return
  fi

  local count
  count="$(fi_entries "$file" open 2>/dev/null \
    | grep -vE '^- \[open\] \[!\]' \
    | grep -cvE '\(PR: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+\)' || true)"
  printf '%s' "${count:-0}"
}

# Count [open] entries that are stale.
# Stale ≡ (date older than N days) ∪ (has demoted annotation).
# Demoted forms: (PR-closed: ...) and (commit-stale: ...) — these signal
# the linked artifact is gone, so the entry is "abandoned" regardless of age.
# Math: |A ∪ B| = |A| + |B| − |A ∩ B| (inclusion-exclusion), so an entry
# that is BOTH date-stale AND demoted counts once, not twice.
# Cross-platform: BSD `date -v` and GNU `date -d` both supported.
fi_count_stale() {
  local file="$1"
  local days="${2:-30}"

  if [[ ! -f "$file" ]]; then
    printf '0'
    return
  fi

  local cutoff
  cutoff="$(date -v-"${days}"d +%Y-%m-%d 2>/dev/null \
    || date -d "${days} days ago" +%Y-%m-%d 2>/dev/null \
    || true)"

  if [[ -z "$cutoff" ]]; then
    printf '0'
    return
  fi

  # |A| — date-based stale count (existing behavior).
  # The capture is anchored to the status prefix (mirroring fi_parse_entry):
  # the earlier `^- \[open\].*\ (date)\ ` form was greedy, so an ISO date
  # inside the symptom text was captured instead of the entry date —
  # corrupting the count in both directions (fresh entry with an old date
  # in the symptom counted stale; stale entry with a fresh date was missed).
  local re_open_date='^- \[open\]( \[!\])? ([0-9]{4}-[0-9]{2}-[0-9]{2}) '
  local re_demoted='\((PR-closed|commit-stale): '
  local date_stale=0
  local overlap=0
  while IFS= read -r line; do
    if [[ "$line" =~ $re_open_date ]]; then
      local entry_date="${BASH_REMATCH[2]}"
      if [[ "$entry_date" < "$cutoff" ]]; then
        date_stale=$((date_stale + 1))
        # |A ∩ B| — entries that are BOTH date-stale AND demoted.
        if [[ "$line" =~ $re_demoted ]]; then
          overlap=$((overlap + 1))
        fi
      fi
    fi
  done < <(fi_entries "$file" open 2>/dev/null)

  # |B| — entries with a demoted annotation, regardless of date.
  # Conflict-aware via fi_entries, like the |A| loop above.
  local demoted
  demoted="$(fi_entries "$file" open 2>/dev/null \
    | grep -cE '\((PR-closed|commit-stale): ' || true)"
  demoted="${demoted:-0}"

  printf '%d' "$((date_stale + demoted - overlap))"
}

# Extract the value of the (touched: ...) annotation from an entry line.
# Echoes the raw value (comma-separated dates, possibly with ';' cycle
# separators). Echoes empty string if the annotation is absent.
fi_extract_touched_segment() {
  local line="$1"
  local re_touched='\(touched: ([^)]+)\)'
  if [[ "$line" =~ $re_touched ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Extract the integer value of the (defer-cycle: N) annotation.
# Defaults to 1 (implicit cycle 1) if the annotation is absent or
# non-numeric.
fi_extract_defer_cycle() {
  local line="$1"
  local re_cycle='\(defer-cycle: ([0-9]+)\)'
  if [[ "$line" =~ $re_cycle ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '1'
  fi
}

# Extract the value of the (reason: ...) annotation.
# Echoes empty string if absent.
fi_extract_reason() {
  local line="$1"
  local re_reason='\(reason: ([^)]+)\)'
  if [[ "$line" =~ $re_reason ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Extract the value of the (mute-until: YYYY-MM-DD) annotation.
# Echoes empty string if absent.
fi_extract_mute_until() {
  local line="$1"
  local re_mute='\(mute-until: ([0-9]{4}-[0-9]{2}-[0-9]{2})\)'
  if [[ "$line" =~ $re_mute ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Returns 0 if the entry has an active mute-until (today < mute date),
# 1 otherwise (no annotation, or annotation present but the date has
# passed). Cross-platform: ISO YYYY-MM-DD sorts lexically so plain string
# comparison works without `date` arithmetic.
#
# Args:
#   $1 — entry line
#   $2 — today's date as YYYY-MM-DD (caller supplies; cheaper than re-running
#        `date` per call)
fi_is_muted() {
  local line="$1"
  local today="$2"
  local mute_date
  mute_date="$(fi_extract_mute_until "$line")"
  [[ -z "$mute_date" ]] && return 1
  [[ "$today" < "$mute_date" ]] && return 0
  return 1
}

# --- JSON emission (consumed by `found-issues list --json`) -----------------
# Hand-rolled: bin/found-issues has no jq dependency (hooks may use jq;
# the CLI must run on a bare Git Bash / macOS bash 3.2).

# Escape a string for embedding in a JSON string literal.
fi_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/}"
  printf '%s' "$s"
}

# Emit a JSON string literal, or null for the empty string.
# The escape expansions are inlined (not a nested $(fi_json_escape) call):
# this runs 13x per entry in list --json, and the subshell per field
# roughly doubled the fork count on Windows Git Bash for zero gain.
fi_json_str() {
  local s="$1"
  if [[ -z "$s" ]]; then
    printf 'null'
  else
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/}"
    printf '"%s"' "$s"
  fi
}

# Emit one entry as a single-line JSON object.
# $1 = file line number, $2 = raw entry line. Returns 1 if unparseable.
fi_entry_to_json() {
  local line_no="$1" raw="$2"
  # Strip C0 control characters up front (except TAB, which fi_json_escape
  # encodes, and CR, which it strips): RFC 8259 forbids them raw inside
  # string literals, and one pasted ANSI escape in a symptom would
  # otherwise poison the whole emitted array. One tr per entry.
  raw="$(printf '%s' "$raw" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')"
  local parsed
  parsed="$(fi_parse_entry "$raw")" || return 1

  local status="" critical="" date="" path="" line="" line_end="" symptom="" fix=""
  local prs="" prs_auto="" prs_closed="" commits="" commits_auto="" commits_stale="" renamed_from=""
  local fixed_date="" verified=""
  local fixtag="" decide="" decided="" manual="" until_="" autofix_failed=""
  local kv key val
  while IFS= read -r kv; do
    key="${kv%%=*}"
    val="${kv#*=}"
    case "$key" in
      status)        status="$val" ;;
      critical)      critical="$val" ;;
      date)          date="$val" ;;
      path)          path="$val" ;;
      line)          line="$val" ;;
      line_end)      line_end="$val" ;;
      symptom)       symptom="$val" ;;
      fix)           fix="$val" ;;
      prs)           prs="$val" ;;
      prs_auto)      prs_auto="$val" ;;
      prs_closed)    prs_closed="$val" ;;
      commits)       commits="$val" ;;
      commits_auto)  commits_auto="$val" ;;
      commits_stale) commits_stale="$val" ;;
      renamed_from)  renamed_from="$val" ;;
      fixed_date)    fixed_date="$val" ;;
      verified)      verified="$val" ;;
      fixtag)         fixtag="$val" ;;
      decide)         decide="$val" ;;
      decided)        decided="$val" ;;
      manual)         manual="$val" ;;
      until)          until_="$val" ;;
      autofix_failed) autofix_failed="$val" ;;
    esac
  done <<< "$parsed"

  local crit_bool="false"
  [[ "$critical" == "yes" ]] && crit_bool="true"
  local line_json="null"
  # 10# base coercion: ":007" must emit as 7 — leading zeros are illegal
  # JSON number syntax and would invalidate the whole array.
  [[ -n "$line" ]] && line_json="$((10#$line))"
  # Range end, additive and null for single-line entries. `line` stays the
  # numeric START so existing consumers are untouched; the pair is what
  # reconstructs the `path:23-49` token that --pick matches on.
  local line_end_json="null"
  [[ -n "$line_end" ]] && line_end_json="$((10#$line_end))"
  local mute
  mute="$(fi_extract_mute_until "$raw")"

  printf '{"line_no":%s,"status":"%s","critical":%s,"date":%s,"path":%s,"line":%s,"line_end":%s,"symptom":%s,"suggested":%s,"prs":%s,"prs_auto":%s,"prs_closed":%s,"commits":%s,"commits_auto":%s,"commits_stale":%s,"verified":%s,"fixed_date":%s,"renamed_from":%s,"mute_until":%s,"fix_tag":%s,"decide":%s,"decided":%s,"manual":%s,"until":%s,"autofix_failed":%s,"raw":%s}' \
    "$line_no" "$status" "$crit_bool" \
    "$(fi_json_str "$date")" "$(fi_json_str "$path")" "$line_json" "$line_end_json" \
    "$(fi_json_str "$symptom")" "$(fi_json_str "$fix")" \
    "$(fi_json_str "$prs")" "$(fi_json_str "$prs_auto")" "$(fi_json_str "$prs_closed")" \
    "$(fi_json_str "$commits")" "$(fi_json_str "$commits_auto")" "$(fi_json_str "$commits_stale")" \
    "$(fi_json_str "$verified")" "$(fi_json_str "$fixed_date")" \
    "$(fi_json_str "$renamed_from")" "$(fi_json_str "$mute")" \
    "$(fi_json_str "$fixtag")" "$(fi_json_str "$decide")" "$(fi_json_str "$decided")" \
    "$(fi_json_str "$manual")" "$(fi_json_str "$until_")" "$(fi_json_str "$autofix_failed")" \
    "$(fi_json_str "$raw")"
}

# Compute touch threshold for a given defer-cycle.
# Formula: BASE * FACTOR^(cycle-1), defaulting to 3 * 2^(N-1).
# Env vars FOUND_ISSUES_DEFER_TOUCH_THRESHOLD (base) and
# FOUND_ISSUES_DEFER_ESCALATION_FACTOR (factor) override defaults.
# Invalid values (non-numeric, <= 0) warn to stderr and fall back.
fi_compute_threshold() {
  local cycle="${1:-1}"
  local base="${FOUND_ISSUES_DEFER_TOUCH_THRESHOLD:-3}"
  local factor="${FOUND_ISSUES_DEFER_ESCALATION_FACTOR:-2}"

  if ! [[ "$base" =~ ^[0-9]+$ ]] || (( base <= 0 )); then
    printf 'warning: invalid FOUND_ISSUES_DEFER_TOUCH_THRESHOLD=%s (must be positive integer); using default 3\n' "$base" >&2
    base=3
  fi
  if ! [[ "$factor" =~ ^[0-9]+$ ]] || (( factor <= 0 )); then
    printf 'warning: invalid FOUND_ISSUES_DEFER_ESCALATION_FACTOR=%s (must be positive integer); using default 2\n' "$factor" >&2
    factor=2
  fi
  if ! [[ "$cycle" =~ ^[0-9]+$ ]] || (( cycle <= 0 )); then
    cycle=1
  fi

  # Compute base * factor^(cycle-1) using awk (bash has no power operator).
  awk -v b="$base" -v f="$factor" -v c="$cycle" 'BEGIN { printf "%d", b * (f ^ (c - 1)) }'
}

# Mutate file: append date to the matching entry's (touched: ...) annotation.
# Atomic via temp+mv. Matches entry by exact line equality.
#
# Append rules:
#   - No (touched: ...) annotation: insert " (touched: <date>)" at end of line.
#   - Has (touched: ...) and current segment is empty (annotation ends with ';' or '; '):
#     append "<date>" right before the closing ')'.
#   - Has (touched: ...) with content in current segment:
#     append ", <date>" right before the closing ')'.
#
# Returns:
#   0  — success
#   1  — file does not exist
#   2  — target entry not found in file
fi_append_touch() {
  local file="$1"
  local target_entry="$2"
  local date="$3"

  if [[ ! -f "$file" ]]; then
    return 1
  fi

  local tmp
  tmp="$(fi_ledger_tmp "$file")"

  FI_TOUCHED_LINE=""
  local found=0
  local re_touched='\(touched: ([^)]+)\)'
  local line

  # Final-partial-line guard — see READ-LOOP GUARD at the top of bin/found-issues.
  # Reached from `log` when the entry matches a [deferred] entry's dedup key,
  # against a ledger no earlier pass has normalized.
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$target_entry" ]] && (( found == 0 )); then
      found=1
      local new_line
      if [[ "$line" =~ $re_touched ]]; then
        local existing="${BASH_REMATCH[1]}"
        # Determine current cycle segment (after last ';').
        local current="${existing##*;}"
        # Trim leading whitespace from current segment.
        current="${current#"${current%%[![:space:]]*}"}"
        local new_value
        if [[ -z "$current" ]]; then
          # Current segment is empty — normalize to '; <date>'.
          # Strip any trailing whitespace from the part before ';',
          # then append ' <date>'.
          local before_semi="${existing%%;*}"
          # Trim trailing whitespace from before_semi.
          before_semi="${before_semi%"${before_semi##*[![:space:]]}"}"
          new_value="${before_semi}; ${date}"
        else
          # Current segment has content — append ', <date>'.
          new_value="${existing}, ${date}"
        fi
        # Replace the annotation using sed (safe against special chars in bash glob).
        # Escape characters that are special in sed's BRE/ERE and replacement strings.
        local esc_existing esc_new_value
        esc_existing="$(printf '%s' "$existing" | sed 's/[[\.*^$()+?{|]/\\&/g')"
        esc_new_value="$(printf '%s' "$new_value" | sed 's/[&/\\]/\\&/g')"
        new_line="$(printf '%s' "$line" \
          | sed "s/(touched: ${esc_existing})/(touched: ${esc_new_value})/")"
      else
        # No existing annotation: append at end of line.
        new_line="${line} (touched: ${date})"
      fi
      # The rewritten line, for callers that must re-find exactly this entry
      # (a prefix search hits a same-prefix neighbour — audit cli-14).
      # shellcheck disable=SC2034  # read by fi_handle_deferred_touch (help.sh)
      FI_TOUCHED_LINE="$new_line"
      printf '%s\n' "$new_line" >> "$tmp"
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"

  if (( found == 0 )); then
    rm -f "$tmp"
    return 2
  fi

  fi_ledger_replace "$file" "$tmp"
}

# Count the number of well-formed YYYY-MM-DD dates in the CURRENT cycle's
# segment of the (touched: ...) annotation. The current segment is the
# substring after the last ';' separator (or the entire annotation if no
# ';' is present). Echoes 0 if the annotation is absent or the current
# segment contains no well-formed dates.
fi_current_cycle_touch_count() {
  local line="$1"
  local segment
  segment="$(fi_extract_touched_segment "$line")"
  if [[ -z "$segment" ]]; then
    printf '0'
    return
  fi

  # Take everything after the last ';' (if no ';', this is the full segment).
  local current="${segment##*;}"

  # Count well-formed dates (defensive: ignore garbage tokens).
  local count
  count="$(printf '%s' "$current" \
    | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' \
    | grep -c . || true)"
  printf '%s' "${count:-0}"
}

# Mutate file: increment the (defer-cycle: N) annotation on a target entry.
# If absent, sets to 2 (since absent means cycle 1 implicitly).
# Also appends ';' separator to (touched: ...) IF that annotation exists
# AND its current segment has content. Skips ';' append when there's
# nothing to separate (preventing ';;' artifacts).
#
# Returns:
#   0  — success
#   1  — file does not exist
#   2  — target entry not found in file
fi_increment_defer_cycle() {
  local file="$1"
  local target_entry="$2"

  if [[ ! -f "$file" ]]; then
    return 1
  fi

  local tmp
  tmp="$(fi_ledger_tmp "$file")"

  local found=0
  local line

  # Final-partial-line guard — see READ-LOOP GUARD at the top of bin/found-issues.
  # Today's only caller (cmd_defer's re-defer path) has already normalized the
  # file with its own guarded rewrite, so this site is safe by call ORDER alone.
  # Guarded regardless: relying on a caller's side effect is not a safety
  # property, and a future direct caller would silently drop the final entry.
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$target_entry" ]] && (( found == 0 )); then
      found=1
      local new_line="$line"

      # Bump (or add) defer-cycle annotation.
      if [[ "$new_line" =~ \(defer-cycle:\ ([0-9]+)\) ]]; then
        local current_cycle="${BASH_REMATCH[1]}"
        local next_cycle=$((current_cycle + 1))
        # Use sed for safety (bash 3.2 glob with parens is unreliable).
        new_line="$(printf '%s' "$new_line" | sed "s/(defer-cycle: ${current_cycle})/(defer-cycle: ${next_cycle})/")"
      else
        new_line="${new_line} (defer-cycle: 2)"
      fi

      # Append ';' to touched annotation if it has content in current segment.
      if [[ "$new_line" =~ \(touched:\ ([^\)]*)\) ]]; then
        local existing="${BASH_REMATCH[1]}"
        # Determine current cycle segment (after last ';').
        local current="${existing##*;}"
        # Trim leading whitespace from current segment.
        current="${current#"${current%%[![:space:]]*}"}"
        if [[ -n "$current" ]]; then
          local new_touched="${existing}; "
          # Escape characters that are special in sed's BRE search pattern.
          local esc_existing esc_new_touched
          esc_existing="$(printf '%s' "$existing" | sed 's/[[\.*^$()+?{|]/\\&/g')"
          esc_new_touched="$(printf '%s' "$new_touched" | sed 's/[&/\\]/\\&/g')"
          new_line="$(printf '%s' "$new_line" | sed "s/(touched: ${esc_existing})/(touched: ${esc_new_touched})/")"
        fi
        # If current segment is empty (already ends in '; '), do nothing.
      fi

      printf '%s\n' "$new_line" >> "$tmp"
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"

  if (( found == 0 )); then
    rm -f "$tmp"
    return 2
  fi

  fi_ledger_replace "$file" "$tmp"
}
