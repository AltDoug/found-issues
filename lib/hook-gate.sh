#!/usr/bin/env bash
# hook-gate.sh — zero-fork relevance gates for the Bash-matcher hooks.
#
# Sourced by hooks/pre-branch-delete.sh and hooks/post-bash-dispatch.sh.
# Defines functions only. Compatible with bash 3.2+ (macOS system bash).
#
# Why (2026-10-03, dougstation): Windows 11 leaks a kernel token for every
# process created while the foreground lock is armed, and under Git Bash every
# fork and every exec IS a Windows process. Both hooks run on EVERY Bash tool
# call and used to spend 14-21 process creations (jq, sed, tr, $(...)) only to
# learn the command was not theirs. A gate decides that with bash builtins on
# the raw JSON first; a command no route cares about exits 0 with zero forks.
#
# Contract — a gate tests a NECESSARY condition of its hook's own matchers, so
# skipping can never change behaviour:
#   - The gate text is the still-escaped tool_input.command cut out of the raw
#     payload (the whole payload when it cannot be cut out — a superset), with
#     every escaped backslash pair (\\) deleted. JSON escaping never changes a
#     letter except through \uXXXX, so any word the decoded command contains is
#     still in the gate text.
#   - A payload carrying a \uXXXX escape could hide a letter: fi_gate_text
#     returns 1 and the caller runs its full path, as does
#     FOUND_ISSUES_HOOK_GATES=off (escape hatch for debugging).
#
# Functions:
#   fi_gate_text <payload>    sets FI_GATE; returns 1 = do not trust a gate
#   fi_gate_has <word>...     0 iff FI_GATE contains any word
#   fi_gate_gapped <word>     0 iff FI_GATE contains word, possibly with quoted
#                             spans spliced between its letters

# fi_gate_text <payload> — see contract above. Only a real key can match the
# "command" regex: a "command" inside any JSON string is itself escaped
# (\"command\"). Past 400 escaped quotes the scan gives up and widens to the
# whole payload (each step is O(length)).
fi_gate_text() {
  # Byte mode: in a UTF-8 locale every ${rest#*\"} below rescans multi-byte
  # text from the start, which made a 70 KB command take ~4 s per hook.
  local LC_ALL=C
  local input="$1" rest pre bs raw="" i=0
  local re='"command"[[:space:]]*:[[:space:]]*"'
  [[ "${FOUND_ISSUES_HOOK_GATES:-on}" == "off" ]] && return 1
  # The ${raw//...} pass below is quadratic in bash: ~2-4 s on a 70 KB
  # heredoc payload. A gate exists to save forks on ordinary commands; a
  # payload this large just takes the full path.
  (( ${#input} > 16384 )) && return 1
  if [[ "$input" =~ $re ]]; then
    rest="${input#*"${BASH_REMATCH[0]}"}"
    while :; do
      if (( i++ >= 400 )); then raw="$input"; break; fi
      case "$rest" in *\"*) ;; *) raw="$input"; break ;; esac
      pre="${rest%%\"*}"; rest="${rest#*\"}"
      raw+="$pre"
      bs="${pre##*[!\\]}"                     # trailing backslash run
      if (( ${#bs} % 2 == 0 )); then break; fi  # unescaped quote: string ends
      raw+='"'
    done
  else
    raw="$input"
  fi
  raw="${raw//\\\\/}"
  [[ "$raw" == *'\u'* ]] && return 1
  FI_GATE="$raw"
  return 0
}

fi_gate_has() {
  local w
  for w in "$@"; do
    [[ "$FI_GATE" == *"$w"* ]] && return 0
  done
  return 1
}

# fi_gate_gapped <word> — for hooks that match the command AFTER deleting its
# quoted spans ('...' and "..."): there `bra''nch` and `bra"x"nch` both read
# "branch". Between any two letters the gate allows one gap that starts with a
# quote (' or the \ of an escaped \") and ends with a quote (' or ").
fi_gate_gapped() {
  local w="$1" re="" i q="'"
  local gap="((\\\\|$q).*(\"|$q))?"
  for (( i = 0; i < ${#w}; i++ )); do
    (( i > 0 )) && re+="$gap"
    re+="${w:i:1}"
  done
  [[ "$FI_GATE" =~ $re ]]
}
