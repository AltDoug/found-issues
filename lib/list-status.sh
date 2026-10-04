#!/usr/bin/env bash
# list-status.sh — list and status — the two read-only ledger renderers
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Extracted verbatim from bin/found-issues in v2.2.7 (the tracked §12 split);
# see the [open] loc-validator entry in docs/found-issues.md.
#
# Functions:
#   cmd_list [...]
#   cmd_status <format> <cwd>

# === Subcommand: list ===

# List ledger entries, optionally as JSON. Read-only: never creates the
# ledger file. Default filter: open — the actionable set, matching the
# statusline's mental model.
cmd_list() {
  local status_filter="open" json="no" cwd=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status=*) status_filter="${1#--status=}"; shift ;;
      --status)
        if [[ $# -lt 2 ]]; then
          printf 'found-issues list: --status requires a value (open|deferred|fixed|all)\n' >&2
          return 2
        fi
        status_filter="$2"; shift 2
        ;;
      --cwd=*)    cwd="${1#--cwd=}"; shift ;;
      --cwd)
        if [[ $# -lt 2 ]]; then
          printf 'found-issues list: --cwd requires a path\n' >&2
          return 2
        fi
        cwd="$2"; shift 2
        ;;
      --json)     json="yes"; shift ;;
      *)
        printf 'found-issues list: unknown option: %s\n' "$1" >&2
        return 2
        ;;
    esac
  done

  case "$status_filter" in
    open|deferred|fixed|all) : ;;
    *)
      printf 'found-issues list: invalid --status: %s (use open|deferred|fixed|all)\n' "$status_filter" >&2
      return 2
      ;;
  esac

  # Same search-root priority and upward walk as cmd_status (:941-953) —
  # list and status must agree on which ledger "the" ledger is, or a fix
  # run sees [] while the statusline counts open entries.
  local search_root="${cwd:-${CLAUDE_PROJECT_DIR:-$PWD}}"
  local file
  file="$(fi_find_issues_file "$search_root")" || true

  if [[ -z "$file" || ! -f "$file" ]]; then
    [[ "$json" == "yes" ]] && printf '[]\n'
    return 0
  fi

  if [[ "$json" == "no" ]]; then
    fi_entries "$file" "$status_filter"
    return 0
  fi

  local numbered_line line_no raw obj sep=""
  printf '['
  while IFS= read -r numbered_line; do
    line_no="${numbered_line%%:*}"
    raw="${numbered_line#*:}"
    obj="$(fi_entry_to_json "$line_no" "$raw")" || continue
    printf '%s%s' "$sep" "$obj"
    sep=","
  done < <(fi_entries "$file" "$status_filter" numbered)
  printf ']\n'
}

# === Subcommand: status ===

cmd_status() {
  local format="${1:-segment}"
  local cwd="${2:-}"

  # Resolve search root for the issues file. Priority:
  #   1. --cwd PATH (explicit flag, deterministic — caller knows the workspace)
  #   2. $CLAUDE_PROJECT_DIR (set by Claude Code in hook contexts)
  #   3. $PWD (current behavior — walk up from wherever we were invoked)
  # This matters because Claude Code's statusline subprocess does NOT inherit
  # the workspace as cwd; it inherits whatever spawned the harness ($HOME on
  # macOS). Without an explicit cwd, the file walk finds nothing → empty
  # segment → silent breakage. See v1.0.2 install-statusline cwd fix and the
  # v1.0.3 self-heal migration that pairs with this flag.
  local search_root="${cwd:-${CLAUDE_PROJECT_DIR:-$PWD}}"

  local file
  file="$(fi_find_issues_file "$search_root")" || true

  # Segment cache (lib/segment-cache.sh): key and ledger bytes are taken
  # BEFORE counting, so a write that lands mid-render leaves a cache that no
  # longer matches the file instead of one that hides the write.
  local _seg_cacheable=0
  if [[ "$format" == "segment" && -n "$file" && -f "$file" ]] \
      && fi_segment_cache_key "$file" && fi_segment_read_ledger "$file"; then
    _seg_cacheable=1
  fi

  local critical=0 issues=0 in_pr=0 stale=0 total_open=0 decisions=0 running=0
  if [[ -n "$file" && -f "$file" ]]; then
    critical="$(fi_count_critical "$file")"
    # Only the json format prints it (audit status-14).
    [[ "$format" == "json" ]] && total_open="$(fi_count "$file" open)"
    in_pr="$(fi_count_in_pr "$file")"
    # Residual computed by exclusion (entries neither critical nor in-PR),
    # NOT by subtraction: total_open - in_pr - critical double-subtracts
    # entries that are BOTH critical and in-PR, making plain open entries
    # vanish from every rendered counter.
    issues="$(fi_count_residual "$file")"
    stale="$(fi_count_stale "$file" "${FOUND_ISSUES_STALE_DAYS:-30}")"
    # v3: entries waiting on a decision (❓N), ledger-derived so cached.
    decisions="$(fi_count_decide "$file")"
  fi

  # Segment-autosync: when called for statusline rendering, opportunistically
  # refresh on-disk state in the background. Without this, `(PR: …)`
  # annotations only flip to `[fixed]` at SessionStart — so users who leave
  # Claude running while a teammate merges their PR (or who use the GitHub
  # web UI from another window) see a stale count until they restart.
  #
  # Throttled so even rapid statusline renders don't fire repeated gh calls.
  # The timestamp file is touched BEFORE spawning sync so a concurrent
  # render in another session sees the fresh stamp and skips. Race window
  # is tiny (microseconds); the worst case is two parallel syncs, both of
  # which write atomically via tmp+mv.
  #
  # Disable with FOUND_ISSUES_SEGMENT_AUTOSYNC=off.
  # Tune cadence (seconds) with FOUND_ISSUES_SEGMENT_AUTOSYNC_INTERVAL (default 600).
  # Internal/testing knob: FOUND_ISSUES_AUTOSYNC_CMD overrides the dispatched command.
  if [[ "$format" == "segment" \
        && "${FOUND_ISSUES_SEGMENT_AUTOSYNC:-on}" != "off" \
        && -n "$file" && -f "$file" ]]; then
    local _autosync_interval="${FOUND_ISSUES_SEGMENT_AUTOSYNC_INTERVAL:-600}"
    local _autosync_cache="${FOUND_ISSUES_CACHE_DIR:-$HOME/.cache/found-issues}"
    # One stamp PER LEDGER (audit status-2): a single global stamp let only
    # the first repo to render in each window sync, with 3-5 sessions open.
    # Same sanitized name as the segment cache; the fast path in
    # lib/segment-cache.sh reads the same file.
    local _autosync_ts
    _autosync_ts="$(fi_autosync_stamp_path "$_autosync_cache" "$file")"
    mkdir -p "${_autosync_ts%/*}" 2>/dev/null || true
    local _autosync_now _autosync_last _autosync_age
    _autosync_now="${EPOCHSECONDS:-$(date +%s)}"
    _autosync_last=0
    # The stamp carries the epoch (2.9.0+): read it builtin, stat only as a
    # fallback for an older stamp.
    if [[ -f "$_autosync_ts" ]]; then
      IFS= read -r _autosync_last <"$_autosync_ts" 2>/dev/null || true
    fi
    if [[ -f "$_autosync_ts" && ! "$_autosync_last" =~ ^[0-9]+$ ]]; then
      # GNU first (Linux), then BSD (macOS). On Linux `stat -f` is the
      # filesystem-status form, NOT file mtime — it can succeed-with-garbage
      # and break the arithmetic below under `set -e`. Trying `-c` first
      # lets Linux short-circuit cleanly.
      _autosync_last="$(stat -c %Y "$_autosync_ts" 2>/dev/null \
                        || stat -f %m "$_autosync_ts" 2>/dev/null \
                        || echo 0)"
    fi
    # Defensive: if either stat returned non-numeric (rare but possible —
    # e.g. an exotic platform whose stat accepts the format but emits text),
    # treat as "no recent sync" rather than crashing.
    [[ "$_autosync_last" =~ ^[0-9]+$ ]] || _autosync_last=0
    _autosync_age=$(( _autosync_now - _autosync_last ))
    if (( _autosync_age >= _autosync_interval )); then
      # The epoch goes INTO the stamp too: the segment fast path reads it with
      # a builtin instead of stat'ing the mtime. Readers here keep the mtime.
      # Spawn only if the stamp landed (audit status-1): an unwritable cache
      # dir otherwise meant a background sync on EVERY render. The spawned
      # sync runs from search_root (audit status-3) — sync finds its ledger
      # from PWD, and the statusline's PWD is not the workspace.
      if ! printf '%s\n' "$_autosync_now" >"$_autosync_ts" 2>/dev/null; then
        :
      elif [[ -n "${FOUND_ISSUES_AUTOSYNC_CMD:-}" ]]; then
        # Testing knob: a self-contained command STRING, dispatched via bash -c.
        ( cd "$search_root" 2>/dev/null && bash -c "$FOUND_ISSUES_AUTOSYNC_CMD" >/dev/null 2>&1 & ) >/dev/null 2>&1
      else
        # Default: invoke ourselves as argv, never through a bash -c string —
        # an install path containing a space (e.g. C:/Users/John Doe/...)
        # word-splits inside the string and exits 127 silently.
        # No auto-archive in an unattended sync — see hooks/session-start.sh.
        ( cd "$search_root" 2>/dev/null && FOUND_ISSUES_AUTO_ARCHIVE=off "$0" sync >/dev/null 2>&1 & ) >/dev/null 2>&1
      fi
    fi
  fi

  case "$format" in
    json)
      fi_segment_af_suffix "$file"
      running="$FI_SEG_AF_N"
      printf '{"critical":%d,"issues":%d,"in_pr":%d,"stale":%d,"total_open":%d,"decisions":%d,"running":%d}\n' \
        "$critical" "$issues" "$in_pr" "$stale" "$total_open" "$decisions" "$running"
      ;;
    plain)
      # Label policy (2026-05-10 UX audit, surfaces 2.1 + 9.1):
      # The "issues" bucket is the residual: open entries that are neither
      # critical nor in-PR. When it's the ONLY counter on display (no critical / no
      # in_pr / no stale), "issue/issues" reads naturally. When other
      # counters are present, "other" disambiguates the residual so users
      # don't try to mentally add "2 critical + 5 issues = 7 open" (which
      # double-counts because critical is excluded from the residual).
      local has_other_counter=0
      [[ "$critical" -gt 0 ]] && has_other_counter=1
      [[ "$in_pr" -gt 0 ]] && has_other_counter=1
      [[ "$stale" -gt 0 ]] && has_other_counter=1
      local issues_word
      if (( has_other_counter == 1 )); then
        issues_word="other"
      else
        issues_word="$([[ "$issues" -eq 1 ]] && echo "issue" || echo "issues")"
      fi
      local parts=()
      [[ "$critical" -gt 0 ]] && parts+=("$critical critical")
      [[ "$issues" -gt 0 ]] && parts+=("$issues $issues_word")
      [[ "$in_pr" -gt 0 ]] && parts+=("$in_pr in PR")
      [[ "$stale" -gt 0 ]] && parts+=("$stale stale")
      if [[ ${#parts[@]} -gt 0 ]]; then
        local out=""
        local first=1
        for p in "${parts[@]}"; do
          if [[ $first -eq 1 ]]; then
            out="$p"; first=0
          else
            out="$out · $p"
          fi
        done
        printf '%s\n' "$out"
      elif [[ -n "$file" && -f "$file" ]]; then
        # A ledger exists and it's clean: say so. Silence here is
        # indistinguishable from a broken invocation (2026-07-23 consumer
        # report). No-file stays silent — plain is also scripted against
        # repos that never adopted a ledger, and segment keeps its
        # quiet-at-zero statusline contract.
        printf '0 open\n'
      fi
      ;;
    segment)
      # ANSI-colored, with leading separator (for inline statusline injection).
      # Same label policy as the plain branch — see comment above.
      local has_other_counter=0
      [[ "$critical" -gt 0 ]] && has_other_counter=1
      [[ "$in_pr" -gt 0 ]] && has_other_counter=1
      [[ "$stale" -gt 0 ]] && has_other_counter=1
      local issues_word
      if (( has_other_counter == 1 )); then
        issues_word="other"
      else
        issues_word="$([[ "$issues" -eq 1 ]] && echo "issue" || echo "issues")"
      fi
      local parts=()
      [[ "$critical" -gt 0 ]] && parts+=($'\033[1;31m'"$critical critical"$'\033[0m')
      [[ "$issues" -gt 0 ]] && parts+=($'\033[31m'"$issues $issues_word"$'\033[0m')
      [[ "$in_pr" -gt 0 ]] && parts+=($'\033[33m'"$in_pr in PR"$'\033[0m')
      [[ "$stale" -gt 0 ]] && parts+=($'\033[2m'"$stale stale"$'\033[0m')
      [[ "$decisions" -gt 0 ]] && parts+=($'\033[36m'"❓$decisions"$'\033[0m')
      local seg=""
      if [[ ${#parts[@]} -gt 0 ]]; then
        local out=""
        local first=1
        for p in "${parts[@]}"; do
          if [[ $first -eq 1 ]]; then
            out="$p"; first=0
          else
            out="$out"$' · '"$p"
          fi
        done
        printf -v seg ' | %s' "$out"
      fi
      (( _seg_cacheable )) && fi_segment_cache_put "$seg"
      # 🔧N is not ledger-derived: appended after the cache, never stored.
      if [[ -n "$file" ]]; then fi_segment_af_suffix "$file"; else FI_SEG_AF=""; fi
      fi_segment_join "$seg"
      ;;
    *)
      fi_err "Unknown format: $format (expected segment|plain|json)"
      return 2
      ;;
  esac
}

