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
    dir="$(dirname "$dir")"
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

# Return the trailing run of recognized "(key: ...)" annotation groups —
# the annotation tail. Walks backward from end-of-line consuming groups
# whose key is in the recognized set; stops at the first thing that is not
# one (prose, a nested-paren suggested block, the symptom). Tokens that
# LOOK like annotations but sit mid-line are therefore excluded.
# Compatible with bash 3.2 (regex in a variable, no lookbehind).
fi_annotation_tail() {
  local line="$1" tail=""
  local re_tail_group='\((PR|PR-closed|commit|commit-stale|verified|fixed|closure|renamed-from|touched|defer-cycle|reason|mute-until|suggested): [^)]*\)[[:space:]]*$'
  while [[ "$line" =~ $re_tail_group ]]; do
    local grp="${BASH_REMATCH[0]}"
    tail="${grp}${tail}"
    line="${line%"$grp"}"
  done
  printf '%s' "$tail"
}

# Parse a single entry line into KEY=VALUE pairs (one per line).
# Returns 1 if the line is not a valid entry.
fi_parse_entry() {
  local line="$1"

  # Status (acts as entry-validity check)
  local re_status='^- \[(open|deferred|fixed)\]'
  local status=""
  if [[ "$line" =~ $re_status ]]; then
    status="${BASH_REMATCH[1]}"
  else
    return 1
  fi

  # Critical flag
  local re_critical='^- \[(open|deferred|fixed)\] \[!\]'
  local critical="no"
  if [[ "$line" =~ $re_critical ]]; then
    critical="yes"
  fi

  # Date (first ISO date in the line)
  local re_date='([0-9]{4}-[0-9]{2}-[0-9]{2})'
  local date=""
  if [[ "$line" =~ $re_date ]]; then
    date="${BASH_REMATCH[1]}"
  fi

  # Location: path:line, path-only, or abstract topic
  # Note: em-dash is U+2014 (—); using grep for portability instead of inline regex
  local path="" line_num=""
  local after_date
  # Anchor the strip to the status-prefix pattern so only the entry's leading
  # date is consumed. The earlier `^.*[0-9]{4}-…` form was greedy: if the
  # symptom mentioned another ISO date (very common — "regressed on YYYY-MM-DD",
  # "surfaced YYYY-MM-DD"), `.*` happily ate past the entry-date and stripped
  # into the symptom, returning a broken location and silently breaking
  # annotate-pr / annotate-commit path matching.
  after_date="$(printf '%s' "$line" | sed -E 's/^- \[(open|deferred|fixed)\]( \[!\])? [0-9]{4}-[0-9]{2}-[0-9]{2} //')"
  # after_date now starts with location followed by ' — symptom...'
  local location_part="${after_date%% — *}"

  # Charset parity with cmd_log's location acceptance ([^:[:space:]]+):
  # the earlier [A-Za-z0-9_./-] set rejected legitimate path characters
  # like + (src/UIView+Ext.swift), so accepted-at-log-time entries
  # round-tripped with an empty path — dedup double-logged, annotate-pr /
  # annotate-commit never matched, tombstone sync never fired.
  local re_path_line='^([^:[:space:]]+):([0-9]+)$'
  local re_path_only='^([^:[:space:]]+)$'
  # Entries sometimes follow the path with a symbol name and/or approximate
  # line range (e.g. `bin/found-issues fi_strip_target_markers ~1982-1989`),
  # which the standalone regexes can't match. Take the first whitespace-
  # delimited token as the path candidate and treat the remainder as
  # supplementary location info. Regression coverage in tests/parse-entries.bats.
  local first_token="${location_part%%[[:space:]]*}"
  if [[ "$first_token" =~ $re_path_line ]]; then
    path="${BASH_REMATCH[1]}"
    line_num="${BASH_REMATCH[2]}"
  elif [[ "$first_token" =~ $re_path_only ]]; then
    path="${BASH_REMATCH[1]}"
  elif [[ "$first_token" == *:* && ( "${first_token#*:}" == */* || "${first_token#*:}" == *.* ) ]]; then
    # Legacy multi-repo locations use a `Repo:path` / `Repo:path:line` shape.
    # The charsets above exclude ':' from a path, so these tokens matched
    # neither regex and returned an EMPTY path — fi_entry_loc rejects an empty
    # path, so the entries never reached the --pick candidate list and could
    # not be closed through annotate-pr / annotate-commit at all. cmd_log
    # writes the shape verbatim, so the CLI produced entries it could not
    # then select.
    #
    # The repo prefix stays INSIDE the path on purpose. Exposing the bare
    # sub-path would make it look repo-relative to every caller that resolves
    # paths against this repo: sync would probe it and false-tombstone the
    # entry, and auto-annotate would match it against a same-named local file
    # and false-flip a foreign-repo entry on merge. Both callers additionally
    # skip ':' paths outright, so keeping the prefix means a missed guard
    # degrades to "no match" instead of a wrong match.
    #
    # The remainder after the FIRST colon must still look path-ish ('/' or
    # '.', the same heuristic the tombstone probe uses) so that abstract topic
    # locations like `topic:with:colons` keep parsing as pathless. Without
    # that check this branch swallowed them and broke fi_entry_to_json's
    # "path":null contract.
    #
    # Greedy `.+` splits on the LAST colon, so only a trailing all-numeric
    # segment is taken as the line number.
    if [[ "$first_token" =~ ^(.+):([0-9]+)$ ]]; then
      path="${BASH_REMATCH[1]}"
      line_num="${BASH_REMATCH[2]}"
    else
      path="$first_token"
    fi
  fi

  # Symptom: text after ' — ' up to first '(' or end of line
  local symptom=""
  if [[ "$after_date" == *" — "* ]]; then
    local rest="${after_date#* — }"
    symptom="${rest%%(*}"
    symptom="${symptom%"${symptom##*[![:space:]]}"}"
  fi

  # Suggested fix
  local re_fix='\(suggested: ([^)]+)\)'
  local fix=""
  if [[ "$line" =~ $re_fix ]]; then
    fix="${BASH_REMATCH[1]}"
  fi

  # Flip-driving annotations (PR/PR-closed/commit/commit-stale) are extracted
  # from the trailing annotation run ONLY — a canonical form quoted inside
  # the symptom ("earlier repair shipped as (commit: abc1234) but…") is
  # narrative, not an annotation. Whole-line extraction let sync flip a live
  # entry whenever a PR/commit it merely MENTIONED landed (agent-config
  # 2026-07-20, twice on the same entry).
  local ann_tail
  ann_tail="$(fi_annotation_tail "$line")"

  # PR annotations (multiple allowed) — extract via grep -oE
  local prs
  prs="$(printf '%s' "$ann_tail" \
    | grep -oE '\(PR: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+\)' \
    | sed -E 's/^\(PR: //; s/\)$//' \
    | paste -sd , - 2>/dev/null || true)"

  # PR-closed annotations (sync-demoted form; multiple allowed)
  local prs_closed
  prs_closed="$(printf '%s' "$ann_tail" \
    | grep -oE '\(PR-closed: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+\)' \
    | sed -E 's/^\(PR-closed: //; s/\)$//' \
    | paste -sd , - 2>/dev/null || true)"

  # Commit annotations (multiple allowed)
  local commits
  commits="$(printf '%s' "$ann_tail" \
    | grep -oE '\(commit: [a-f0-9]{7,40}\)' \
    | sed -E 's/^\(commit: //; s/\)$//' \
    | paste -sd , - 2>/dev/null || true)"

  # Commit-stale annotations (sync-demoted form; multiple allowed)
  local commits_stale
  commits_stale="$(printf '%s' "$ann_tail" \
    | grep -oE '\(commit-stale: [a-f0-9]{7,40}\)' \
    | sed -E 's/^\(commit-stale: //; s/\)$//' \
    | paste -sd , - 2>/dev/null || true)"

  # Renamed-from annotation (single occurrence — sync auto-correct trail)
  local re_renamed='\(renamed-from: ([^)]+)\)'
  local renamed_from=""
  if [[ "$line" =~ $re_renamed ]]; then
    renamed_from="${BASH_REMATCH[1]}"
  fi

  # Fixed date
  local re_fixed='\(fixed: ([0-9]{4}-[0-9]{2}-[0-9]{2})\)'
  local fixed_date=""
  if [[ "$line" =~ $re_fixed ]]; then
    fixed_date="${BASH_REMATCH[1]}"
  fi

  # Verified source
  local re_verified='\(verified: (ai|review)\)'
  local verified=""
  if [[ "$line" =~ $re_verified ]]; then
    verified="${BASH_REMATCH[1]}"
  fi

  printf 'status=%s\n' "$status"
  printf 'critical=%s\n' "$critical"
  printf 'date=%s\n' "$date"
  printf 'path=%s\n' "$path"
  printf 'line=%s\n' "$line_num"
  printf 'symptom=%s\n' "$symptom"
  printf 'fix=%s\n' "$fix"
  printf 'prs=%s\n' "$prs"
  printf 'prs_closed=%s\n' "$prs_closed"
  printf 'commits=%s\n' "$commits"
  printf 'commits_stale=%s\n' "$commits_stale"
  printf 'renamed_from=%s\n' "$renamed_from"
  printf 'fixed_date=%s\n' "$fixed_date"
  printf 'verified=%s\n' "$verified"
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

  local status="" critical="" date="" path="" line="" symptom="" fix=""
  local prs="" prs_closed="" commits="" commits_stale="" renamed_from=""
  local fixed_date="" verified=""
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
      symptom)       symptom="$val" ;;
      fix)           fix="$val" ;;
      prs)           prs="$val" ;;
      prs_closed)    prs_closed="$val" ;;
      commits)       commits="$val" ;;
      commits_stale) commits_stale="$val" ;;
      renamed_from)  renamed_from="$val" ;;
      fixed_date)    fixed_date="$val" ;;
      verified)      verified="$val" ;;
    esac
  done <<< "$parsed"

  local crit_bool="false"
  [[ "$critical" == "yes" ]] && crit_bool="true"
  local line_json="null"
  # 10# base coercion: ":007" must emit as 7 — leading zeros are illegal
  # JSON number syntax and would invalidate the whole array.
  [[ -n "$line" ]] && line_json="$((10#$line))"
  local mute
  mute="$(fi_extract_mute_until "$raw")"

  printf '{"line_no":%s,"status":"%s","critical":%s,"date":%s,"path":%s,"line":%s,"symptom":%s,"suggested":%s,"prs":%s,"prs_closed":%s,"commits":%s,"commits_stale":%s,"verified":%s,"fixed_date":%s,"renamed_from":%s,"mute_until":%s,"raw":%s}' \
    "$line_no" "$status" "$crit_bool" \
    "$(fi_json_str "$date")" "$(fi_json_str "$path")" "$line_json" \
    "$(fi_json_str "$symptom")" "$(fi_json_str "$fix")" \
    "$(fi_json_str "$prs")" "$(fi_json_str "$prs_closed")" \
    "$(fi_json_str "$commits")" "$(fi_json_str "$commits_stale")" \
    "$(fi_json_str "$verified")" "$(fi_json_str "$fixed_date")" \
    "$(fi_json_str "$renamed_from")" "$(fi_json_str "$mute")" \
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
  tmp="$(mktemp -t fi-touch.XXXXXX)"

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
      printf '%s\n' "$new_line" >> "$tmp"
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"

  if (( found == 0 )); then
    rm -f "$tmp"
    return 2
  fi

  mv "$tmp" "$file"
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
  tmp="$(mktemp -t fi-defercycle.XXXXXX)"

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

  mv "$tmp" "$file"
}
