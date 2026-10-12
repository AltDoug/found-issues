#!/usr/bin/env bash
# autofix-ready.sh — 3.9.0 per-repo auto-fix readiness: the measured base
# suite, the watchdog sized from it, the queue gate, the SessionStart line,
# `autofix ready`, and the superseded retire (ledger lib/autofix-ship.sh:206).
# Design: docs/superpowers/specs/2026-10-12-autofix-readiness-design.md.
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   fi_af_ready_write <root> <green|red|timeout> <secs> <cmd>
#   fi_af_ready_read <root> [<cmd>]
#   fi_af_timeout_secs [<root>] [<dir>]
#   fi_af_ready_ok <root>
#   fi_af_ready_line
#   fi_af_ready_report
#   fi_af_superseded

# shellcheck disable=SC2154,SC2153  # AFI_*/FI_AF_* come from autofix-queue.sh, autofix-config.sh, segment-cache.sh

# The longest watchdog the measurement may ask for; a runTimeoutMin set
# above it still wins. A record older than a week is not trusted.
FI_AF_TIMEOUT_CAP_MIN="${FI_AF_TIMEOUT_CAP_MIN:-120}"
FI_AF_READY_MAX_AGE="${FI_AF_READY_MAX_AGE:-604800}"

# One line per field, so a test command is kept on one line.
_fi_af_ready_cmd() { printf '%s' "${1//$'\n'/ }"; }

# Every base run that actually ran the suite records its result in
# autofix/ready/<root key> (keyed like stuck/, so linked worktrees share it):
# status, seconds (green: the measured run; timeout: the limit that fired),
# epoch, test command, main worktree.
fi_af_ready_write() {
  local root="$1" st="$2" secs="$3" cmd dir f
  [[ -n "$root" ]] || return 0
  cmd="$(_fi_af_ready_cmd "$4")"
  fi_af_root
  dir="$FI_AF_ROOT/ready"
  fi_af_stuck_key "$root"
  f="$dir/$FI_AF_KEY"
  mkdir -p "$dir" 2>/dev/null || return 0
  if printf '%s\n%s\n%s\n%s\n%s\n' "$st" "$secs" "$(date +%s)" "$cmd" "$FI_AF_STUCK_ROOT" >"$f.$$" 2>/dev/null; then
    mv -f "$f.$$" "$f" 2>/dev/null || rm -f "$f.$$"
  fi
  return 0
}

# Sets FI_AF_RD_STATUS / _SECS / _TS / _CMD, and FI_AF_RD_OLD=1 for a record
# older than FI_AF_READY_MAX_AGE (it still sizes the limit, a suite does not
# shrink by itself, but it no longer gates). rc 1 when there is no usable
# record: none, malformed, or (with <cmd>) measured for another test command.
fi_af_ready_read() {
  local root="$1" f
  FI_AF_RD_STATUS="" FI_AF_RD_SECS="" FI_AF_RD_TS="" FI_AF_RD_CMD="" FI_AF_RD_OLD=""
  [[ -n "$root" ]] || return 1
  fi_af_root
  fi_af_stuck_key "$root"
  f="$FI_AF_ROOT/ready/$FI_AF_KEY"
  [[ -f "$f" ]] || return 1
  { IFS= read -r FI_AF_RD_STATUS || true; IFS= read -r FI_AF_RD_SECS || true
    IFS= read -r FI_AF_RD_TS || true; IFS= read -r FI_AF_RD_CMD || true; } <"$f"
  # A rejected record leaves no fields behind for a caller to misread.
  if ! _fi_af_ready_valid "$@"; then
    FI_AF_RD_STATUS="" FI_AF_RD_SECS="" FI_AF_RD_TS="" FI_AF_RD_CMD="" FI_AF_RD_OLD=""
    return 1
  fi
  return 0
}

_fi_af_ready_valid() {
  case "$FI_AF_RD_STATUS" in green|red|timeout) ;; *) return 1 ;; esac
  [[ "$FI_AF_RD_SECS" =~ ^[0-9]+$ && "$FI_AF_RD_TS" =~ ^[0-9]+$ ]] || return 1
  (( $(date +%s) - 10#$FI_AF_RD_TS <= FI_AF_READY_MAX_AGE )) || FI_AF_RD_OLD=1
  if [[ $# -ge 2 && "$FI_AF_RD_CMD" != "$(_fi_af_ready_cmd "$2")" ]]; then return 1; fi
  return 0
}

# The watchdog limit in seconds for one child of a run in <root> (<dir>
# finds the test command; default the root). FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS
# wins; otherwise runTimeoutMin is a floor and the measurement may raise it,
# up to the cap: twice a suite that ran to the end (green or red: a red run
# measures the suite as well), or twice the limit a timed-out one hit.
fi_af_timeout_secs() {
  local root="${1:-}" dir="${2:-${1:-}}" lim cap auto=0 cmd
  if [[ -n "${FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS:-}" ]]; then
    printf '%s' "$FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS"; return 0
  fi
  lim=$(( $(fi_af_int runTimeoutMin 20) * 60 ))
  cap=$(( FI_AF_TIMEOUT_CAP_MIN * 60 ))
  [[ -n "$dir" ]] || dir="$(pwd)"
  [[ -n "$root" ]] || root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$root" ]] && cmd="$(fi_af_test_command "$dir" 2>/dev/null)" && fi_af_ready_read "$root" "$cmd"; then
    case "$FI_AF_RD_STATUS" in
      green|red) auto=$(( (2 * 10#$FI_AF_RD_SECS + 59) / 60 * 60 )) ;;
      timeout) auto=$(( 2 * 10#$FI_AF_RD_SECS )) ;;
    esac
    (( auto <= cap )) || auto=$cap
  fi
  (( auto <= lim )) || lim=$auto
  printf '%s' "$lim"
}

# "40 min" for whole minutes, "75s" otherwise (the base-test wording).
_fi_af_ready_lim() {
  if (( $1 % 60 == 0 )); then printf '%s min' "$(( $1 / 60 ))"; else printf '%ss' "$1"; fi
}

# "42m41s" / "12s".
_fi_af_ready_dur() {
  if (( $1 >= 60 )); then printf '%sm%02ds' "$(( $1 / 60 ))" "$(( $1 % 60 ))"; else printf '%ss' "$1"; fi
}

# The queue gate: rc 1 (FI_AF_WHY set) while the last base run timed out at
# a limit the next run would not exceed (the cap, or a pinned override), so
# every item would only time out again. No test command is gated by the
# callers themselves; a red base is not gated (the known-red cache retires
# it for $0 and the STUCK streak needs those retires).
fi_af_ready_ok() {
  local root="$1" cmd lim
  FI_AF_WHY=""
  cmd="$(fi_af_test_command "$root" 2>/dev/null)" || return 0
  fi_af_ready_read "$root" "$cmd" || return 0
  [[ "$FI_AF_RD_STATUS" == timeout && -z "$FI_AF_RD_OLD" ]] || return 0
  lim="$(fi_af_timeout_secs "$root")"
  [[ "$lim" =~ ^[0-9]+$ ]] || return 0
  (( 10#$lim > 10#$FI_AF_RD_SECS )) && return 0
  FI_AF_WHY="waiting: base tests timed out at the $(_fi_af_ready_lim "$FI_AF_RD_SECS") limit; point found-issues.autofix.testCommand at a faster subset or raise found-issues.autofix.runTimeoutMin"
  return 1
}

# The SessionStart line for a repo where auto-fix is on, has open entries it
# could take, and cannot run (empty otherwise). Fixed text only.
fi_af_ready_line() {
  local root file
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  fi_af_enabled >/dev/null 2>&1 || return 0
  file="$(fi_find_issues_file "$root" 2>/dev/null)" || return 0
  [[ -f "$file" ]] || return 0
  # Something auto-fix could take: a (fix: small|medium) entry, or an untagged
  # one a sweep would classify. Manual, decide, fix-large and autofix-failed
  # entries never reach it, nor one whose fix is already in a PR or commit.
  # One process, no pipe: under pipefail an early-exiting reader can fail it.
  awk '/^- \[open\]/ && !/\((manual|decide): / && !/\(fix: large\)/ && !/autofix-failed/ && !/\((PR|commit): / { f = 1; exit } END { exit !f }' "$file" 2>/dev/null || return 0
  if ! fi_af_test_command "$root" >/dev/null 2>&1; then
    printf '%s\n' 'Auto-fix is waiting in this repo: no test command, so none of its open entries gets queued. Set one with found-issues config autofix.testCommand "<cmd>", or switch auto-fix off here with found-issues config autofix false.'
    return 0
  fi
  fi_af_ready_ok "$root" && return 0
  printf 'Auto-fix is waiting in this repo: %s.\n' "${FI_AF_WHY#waiting: }"
}

# `found-issues autofix ready`: what auto-fix knows about this repo's suite.
fi_af_ready_report() {
  local root cmd="" lim cfg on="on" verdict="ready" how
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || { fi_err "autofix ready: not in a git repo"; return 1; }
  fi_af_enabled >/dev/null 2>&1 || on="off ($FI_AF_WHY)"
  printf 'Auto-fix readiness: %s\n' "$root"
  printf 'auto-fix: %s\n' "$on"
  if cmd="$(fi_af_test_command "$root" 2>/dev/null)"; then
    printf 'test command: %s\n' "$cmd"
  else
    cmd=""; printf 'test command: none\n'
  fi
  if [[ -n "$cmd" ]] && fi_af_ready_read "$root" "$cmd"; then
    case "$FI_AF_RD_STATUS" in
      green) printf 'last base run: green in %s (%s)\n' "$(_fi_af_ready_dur "$FI_AF_RD_SECS")" "$(fi_af_fmt_epoch "$FI_AF_RD_TS")" ;;
      red) printf 'last base run: red after %s (%s)\n' "$(_fi_af_ready_dur "$FI_AF_RD_SECS")" "$(fi_af_fmt_epoch "$FI_AF_RD_TS")" ;;
      timeout) printf 'last base run: timed out at the %s limit (%s)\n' "$(_fi_af_ready_lim "$FI_AF_RD_SECS")" "$(fi_af_fmt_epoch "$FI_AF_RD_TS")" ;;
    esac
    [[ -z "$FI_AF_RD_OLD" ]] || printf '  (over a week old: it still sizes the run limit, but no longer gates the queue)\n'
  else
    printf 'last base run: never\n'
  fi
  lim="$(fi_af_timeout_secs "$root")"
  [[ "$lim" =~ ^[0-9]+$ ]] || lim=0
  cfg="$(fi_af_int runTimeoutMin 20)"
  if [[ -n "${FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS:-}" ]]; then how="FOUND_ISSUES_AUTOFIX_TIMEOUT_SECS"
  elif (( lim > cfg * 60 )); then how="measured, runTimeoutMin $cfg is the floor, cap $FI_AF_TIMEOUT_CAP_MIN min"
  else how="runTimeoutMin $cfg"; fi
  printf 'run limit: %s (%s)\n' "$(_fi_af_ready_lim "$lim")" "$how"
  if [[ -z "$cmd" ]]; then verdict="waiting: no test command (set one: found-issues config autofix.testCommand \"<cmd>\")"
  elif ! fi_af_ready_ok "$root"; then verdict="$FI_AF_WHY"
  elif fi_af_ready_read "$root" "$cmd" && [[ "$FI_AF_RD_STATUS" == red ]]; then verdict="ready, but the base was red last time (see found-issues autofix status)"
  fi
  printf 'verdict: %s\n' "$verdict"
}

# A local date for an epoch (BSD date -r, GNU date -d @).
fi_af_fmt_epoch() {
  date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$1"
}

# Ledger lib/autofix-ship.sh:206 (operator go 2026-10-12, recommended
# variant): rc 0 (FI_AF_WHY set) when origin/<base> changed the cited code
# since the commit the run was cut from, i.e. a live session worked on it
# meanwhile (kh2-midgar#19 shipped a fix 6cdefeb had made). path:line(-line)
# counts only a change within FI_AF_SUPERSEDED_NEAR lines of the cited ones,
# so another entry's fix elsewhere in the file does not retire this one;
# path:name counts a changed line naming it; a bare path counts any change.
# A topic entry, a path not in the base, or any git failure: not superseded.
FI_AF_SUPERSEDED_NEAR="${FI_AF_SUPERSEDED_NEAR:-3}"
fi_af_superseded() {
  local loc="${AFI_loc:-}" p="" l1="" l2="" name="" rc=0 hit=0 line a b hi
  local re_line='^(.+):([0-9]+)(-([0-9]+))?$' re_hunk='^@@ -([0-9]+)(,([0-9]+))? '
  FI_AF_WHY=""
  [[ -n "${AFI_root:-}" && -n "${AFI_base:-}" && -n "${AFI_base_sha:-}" && -n "$loc" ]] || return 1
  if [[ "$loc" =~ $re_line ]]; then
    p="${BASH_REMATCH[1]}" l1="${BASH_REMATCH[2]}" l2="${BASH_REMATCH[4]:-${BASH_REMATCH[2]}}"
  elif [[ "$loc" == *:* ]]; then
    p="${loc%:*}" name="${loc##*:}"
  else
    p="$loc"
  fi
  [[ -n "$p" && "$p" != *found-issues*.md ]] || return 1
  git -C "$AFI_root" cat-file -e "$AFI_base_sha:$p" 2>/dev/null || return 1
  # A caller that fetched already (the sweep drop scan) sets FI_AF_SUP_FETCHED.
  [[ -n "${FI_AF_SUP_FETCHED:-}" ]] || git -C "$AFI_root" fetch -q origin "$AFI_base" >/dev/null 2>&1 || return 1
  git -C "$AFI_root" diff --quiet "$AFI_base_sha" "origin/$AFI_base" -- "$p" >/dev/null 2>&1 || rc=$?
  (( rc == 1 )) || return 1
  if [[ -n "$l1$name" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ -n "$l1" ]]; then
        [[ "$line" =~ $re_hunk ]] || continue
        a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[3]:-1}"
        hi=$(( 10#$a + (10#$b > 0 ? 10#$b - 1 : 0) ))
        if (( 10#$a - FI_AF_SUPERSEDED_NEAR <= 10#$l2 && hi + FI_AF_SUPERSEDED_NEAR >= 10#$l1 )); then hit=1; break; fi
      else
        case "$line" in
          "+++"*|"---"*) ;;
          [+-]*"$name"*) hit=1; break ;;
        esac
      fi
    done < <(git -C "$AFI_root" diff -U0 "$AFI_base_sha" "origin/$AFI_base" -- "$p" 2>/dev/null || true)
    (( hit )) || return 1
  fi
  FI_AF_WHY="superseded: $p changed on $AFI_base since ${AFI_base_sha:0:7}"
  return 0
}
