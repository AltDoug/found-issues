#!/usr/bin/env bash
# stop-reminder.sh — Stop hook
#
# Forces <!-- found-issues-checked: ... --> marker on every assistant turn.
# This is the discipline-enforcer that creates the proactive logging habit.
#
# Hook event: Stop
# Exit codes:
#   0  — allow stop (marker present, or check skipped)
#   2  — block stop (marker missing); message to stderr
#
# Stdin: JSON describing the hook event including transcript_path.

set -euo pipefail

# Allow opt-out via env var (for users who installed but want it off)
if [[ "${FOUND_ISSUES_STOP_REMINDER:-on}" == "off" ]]; then
  exit 0
fi

# Skip when there is no interactive operator to read the block message.
#
# Claude Code sets CLAUDE_CODE_ENTRYPOINT for every hook invocation:
#   - "cli"       — interactive terminal session (operator is watching)
#   - "sdk-cli"   — headless `claude -p` (one-shot or driven by automation)
#   - other       — direct SDK / future entrypoints (no human in the loop)
#
# The marker discipline is a human-operator habit: the operator reads each
# response, decides whether anything out-of-scope deserves logging, and acks
# via the marker. Dispatched / headless sessions have no addressee for that
# discipline — the model can't satisfy a requirement it has no context for,
# and stop_hook_active (above) only breaks immediate same-turn retry loops,
# not multi-turn confusion spirals where Claude reads the stderr, tries to
# "fix" it the wrong way, and burns turns without progress.
#
# Real-world incident 2026-05-22: orchard proposal-build sessions stalled
# 23 min with 0/23 tasks done because the dispatched Claude couldn't satisfy
# the marker convention. The hook here unconditionally skips when the
# session is not in interactive `cli` mode. Empty / missing entrypoint
# (e.g. local test invocations) is treated as `cli` so existing tests and
# direct hook runs keep the original enforcement behavior.
if [[ -n "${CLAUDE_CODE_ENTRYPOINT:-}" && "${CLAUDE_CODE_ENTRYPOINT}" != "cli" ]]; then
  exit 0
fi

# Codex v1: the marker discipline is Claude-only. Codex transcripts use a
# different rollout format the smart-fire parser below does not understand,
# and a Stop block it can't satisfy burns full-context turns. Fail open.
if [[ -z "${CLAUDE_CODE_ENTRYPOINT:-}" && -n "${PLUGIN_DATA:-}" ]]; then
  exit 0
fi

# Read JSON from stdin
input="$(cat)"

# Honor stop_hook_active: when Claude Code re-fires Stop after a previous
# block, the assistant has already had its chance to add the marker. Exit
# 0 to break the loop. Required because Claude Code fires Stop *before*
# the final assistant text is flushed to the transcript file (tool
# results stream as tools run, but the closing text is buffered until
# end-of-turn), so the marker check below can race even when the
# assistant included the marker. Other Stop hooks in the wild (e.g.
# stop-tests-pass.sh) follow this same pattern.
stop_hook_active=""
if command -v jq >/dev/null 2>&1; then
  stop_hook_active="$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || true)"
fi
if [[ -z "$stop_hook_active" || "$stop_hook_active" == "false" ]]; then
  # Fallback: grep for the literal flag in the input
  if printf '%s' "$input" | grep -qE '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
    stop_hook_active="true"
  fi
fi
if [[ "$stop_hook_active" == "true" ]]; then
  exit 0
fi

# Extract transcript_path
transcript_path=""
if command -v jq >/dev/null 2>&1; then
  transcript_path="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
fi
if [[ -z "$transcript_path" ]]; then
  # Fallback: grep extraction
  transcript_path="$(printf '%s' "$input" \
    | grep -oE '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' \
    | head -1)"
fi

# If we can't find the transcript, don't block — fail open.
if [[ -z "$transcript_path" || ! -f "$transcript_path" ]]; then
  exit 0
fi

# Smart-fire: only block when the most recent assistant turn included a
# substantive tool use — Edit/Write/MultiEdit/NotebookEdit, or a Bash command
# that MUTATES something. Pure-conversation turns (greetings, Q&A,
# brainstorm) and read-only Bash turns (`open <folder>`, `git status`,
# `cat`, `rg`) skip the marker requirement — those don't create code-change
# opportunities to notice issues against. Under bypass-permissions mode every
# turn carries a Bash call, so counting ANY Bash blocked a bare "opened the
# folder for you" reply: 54 of the 86 stop blocks in a 60-session audit
# (2026-08-28, F5) were on turns with zero Write/Edit.
#
# "Mutating" = a redirect (`>`/`>>`, not `2>&1` / `>/dev/null`), `sed -i` /
# `perl -i`, a file verb (mv cp rm mkdir rmdir touch ln tee chmod chown
# install rsync patch), a git write verb (commit push merge rebase
# cherry-pick revert apply am add rm mv checkout switch restore reset stash
# tag worktree), a gh write verb (pr create/merge/edit/…, issue/release/repo
# writes, `api -X POST|PATCH|PUT|DELETE`), a package-manager
# install/remove, or an interpreter fed a heredoc (`python3 - <<`). Quoted
# strings are dropped first so a `>` inside a commit message is text.
# Without jq the commands cannot be read out of the transcript, so any Bash
# counts — the pre-2.7.0 behaviour, fail-closed.
MUTATING_RE='(^|[[:space:];&|(])(mv|cp|rm|rmdir|mkdir|touch|ln|tee|chmod|chown|install|rsync|patch)([[:space:]]|$)'
MUTATING_RE="$MUTATING_RE"'|(^|[[:space:];&|(])(sed|perl)[[:space:]]+(-[A-Za-z]*i|--in-place)'
MUTATING_RE="$MUTATING_RE"'|(^|[[:space:];&|(])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+(commit|push|merge|rebase|cherry-pick|revert|apply|am|add|rm|mv|checkout|switch|restore|reset|stash|tag|worktree)([[:space:]]|$)'
MUTATING_RE="$MUTATING_RE"'|(^|[[:space:];&|(])gh[[:space:]]+(pr[[:space:]]+(create|merge|edit|close|reopen|ready|review|comment|checkout)|issue[[:space:]]+(create|edit|close|reopen|comment|delete|transfer|pin|unpin)|release[[:space:]]+(create|delete|edit|upload)|repo[[:space:]]+(create|delete|edit|archive|unarchive|rename|sync|fork|clone))([[:space:]]|$)'
MUTATING_RE="$MUTATING_RE"'|(^|[[:space:];&|(])gh[[:space:]]+api[[:space:]].*(-X|--method)[[:space:]]*(POST|PATCH|PUT|DELETE)'
MUTATING_RE="$MUTATING_RE"'|(^|[[:space:];&|(])(npm|pnpm|yarn|bun|uv|pip|pip3|cargo|brew)[[:space:]]+(install|add|remove|uninstall|update|upgrade|i)([[:space:]]|$)'
MUTATING_RE="$MUTATING_RE"'|(^|[[:space:]])(python3?|node|bun|ruby|perl|bash|sh|zsh)[[:space:]]+-[[:space:]]*<<'
MUTATING_RE="$MUTATING_RE"'|>'

bash_turn_mutates() { # $1 = the turn's transcript lines
  local cmds
  command -v jq >/dev/null 2>&1 || { printf '%s' "$1" | grep -q '"name":"Bash"'; return; }
  # Real transcripts: assistant message.content[] tool_use blocks. Also the
  # flat {"tool_uses":[…]} shape the fixtures use.
  cmds="$(printf '%s' "$1" | jq -R -r 'fromjson? | select(.type=="assistant")
      | ((.message | objects | .content[]?), (.tool_uses[]?)) | objects
      | select(.name=="Bash") | .input.command? // empty' 2>/dev/null || true)"
  [[ -n "$cmds" ]] || return 1
  printf '%s\n' "$cmds" \
    | sed "s/'[^']*'//g" \
    | sed -E 's/"([^"\\]|\\.)*"//g; s/[0-9]*>&[0-9]//g; s/[0-9&]*>>?[[:space:]]*\/dev\/null//g' \
    | grep -qE "$MUTATING_RE"
}
#
# Logic: walk back through the last ~16KB of transcript, find the most
# recent user message boundary, then check if any tool_use of a
# substantive type appears between that boundary and end-of-transcript.
#
# Important: Claude Code wraps tool_result content in a top-level
# `"type":"user"` envelope (role:"user" content:tool_result). Those are
# NOT real user-message boundaries — they appear mid-turn after every
# assistant tool_use. Detect them by the presence of `"tool_use_id"` on
# the same line and skip them when finding the turn boundary; otherwise
# every tool-call turn looks like "nothing happened after the user spoke"
# and smart-fire silently exits 0.
recent_tail="$(tail -c 16384 "$transcript_path" 2>/dev/null || true)"
if [[ -n "$recent_tail" ]]; then
  # Take everything after the last real user message marker (excluding
  # tool_result envelopes, which also carry "type":"user").
  # LC_ALL=C: awk processes bytes opaquely; without this, GNU awk under
  # UTF-8 locales (en_US.UTF-8 default on most Linux CI + dev environments)
  # can fail with `towc: multibyte conversion failure` on transcript content
  # containing em-dashes, check marks, smart quotes, etc. Our patterns are
  # all ASCII so byte-mode awk is sufficient. See tests/stop-reminder.bats
  # ("handles multibyte UTF-8 in transcript without awk towc errors").
  last_turn="$(printf '%s' "$recent_tail" | LC_ALL=C awk '
    /"type":"user"/ && !/"tool_use_id"/ { buf=""; next }
    { buf = buf "\n" $0 }
    END { print buf }
  ')"
  # If no substantive tool use in the most recent assistant turn, allow stop
  if ! printf '%s' "$last_turn" \
     | grep -qE '"name":"(Edit|Write|MultiEdit|NotebookEdit)"' \
     && ! bash_turn_mutates "$last_turn"; then
    exit 0
  fi
fi

# Check the last ~8KB of the transcript for the marker. 8KB is enough to
# capture the most recent assistant turn even with long output.
#
# Brief retry: Claude Code fires Stop before the final assistant text is
# flushed to disk, so a first-pass check can miss a marker the assistant
# actually included. One short sleep gives the flush a chance to land
# before we block. If the marker still isn't present, stop_hook_active
# on the retry-fire (above) prevents an infinite block loop.
for attempt in 1 2; do
  if tail -c 8192 "$transcript_path" 2>/dev/null \
     | grep -q '<!-- found-issues-checked:'; then
    exit 0
  fi
  [[ $attempt -eq 1 ]] && sleep 0.3
done

# Block with an adaptive message. Verbosity:
#   FOUND_ISSUES_REMINDER_VERBOSITY=full  → 8-line educational form (default for new installs)
#   FOUND_ISSUES_REMINDER_VERBOSITY=terse → 1-line form (post-onboarding default)
#   FOUND_ISSUES_REMINDER_VERBOSITY=auto  → terse iff ~/.claude/found-issues/.onboarded exists
# Default is auto, which gracefully degrades verbosity once the user has seen
# the message enough times to internalize the marker options. Claude Code
# always displays the stderr text to the user — there is no API for hiding
# the reason while still passing it to Claude (verified 2026-05-13).
__fi_verbosity="${FOUND_ISSUES_REMINDER_VERBOSITY:-auto}"
if [[ "$__fi_verbosity" == "auto" ]]; then
  if [[ -f "$HOME/.claude/found-issues/.onboarded" ]]; then
    __fi_verbosity="terse"
  else
    __fi_verbosity="full"
  fi
fi

if [[ "$__fi_verbosity" == "terse" ]]; then
  printf 'Stop blocked: missing <!-- found-issues-checked: ... --> marker. (Options: none-noticed | logged | deferred)\n' >&2
else
  cat >&2 <<'EOF'
Stop blocked: include a found-issues acknowledgment in your final message.

Add ONE of these as an HTML comment anywhere in your response:
  <!-- found-issues-checked: none-noticed -->
  <!-- found-issues-checked: logged -->
  <!-- found-issues-checked: deferred -->

The marker forces conscious consideration; it does not auto-detect issues.
Use /found-issues:log to log items frictionlessly.
EOF
fi
exit 2
