#!/bin/bash
# Runs inside hookfork: counts process creations per hook event.
set -u
cp -r /src /w && cd /w && rm -f .git && git init -q -b main && git config user.email t@t && git config user.name t && git add -A && git commit -qm init
export HOME=/home/m; mkdir -p $HOME/.claude; export FOUND_ISSUES_BIN=/w/bin/found-issues PATH=/w/bin:$PATH CLAUDE_CODE_ENTRYPOINT=cli FOUND_ISSUES_CACHE_DIR=/tmp/fic
count(){ # label, then command reading stdin from $PAYLOAD
  local lbl=$1; shift
  printf '%s' "$PAYLOAD" | strace -f -qq -o /tmp/st -e trace=clone,clone3,fork,vfork,execve "$@" >/dev/null 2>&1
  local forks execs
  forks=$(grep -cE '(clone|clone3|fork|vfork)\(.*= [0-9]+$' /tmp/st); execs=$(grep -cE 'execve\(.*= 0$' /tmp/st)
  printf '%-44s forks=%-4s execs=%-4s\n' "$lbl" "$forks" "$execs"
  if [ -n "${DETAIL:-}" ]; then grep -E 'execve\(.*= 0$' /tmp/st | sed -E 's/.*execve\("([^"]+)".*/\1/' | sort | uniq -c | sort -rn | head -12; fi
}
T=$(mktemp); printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}' > $T
PAYLOAD='{"hook_event_name":"SessionStart","source":"startup","session_id":"s1","cwd":"/w"}'; DETAIL=1 count "SessionStart (real ledger, 1st)" bash hooks/session-start.sh
PAYLOAD='{"hook_event_name":"SessionStart","source":"startup","session_id":"s1","cwd":"/w"}'; count "SessionStart (2nd)" bash hooks/session-start.sh
PAYLOAD="{\"hook_event_name\":\"Stop\",\"session_id\":\"s2\",\"transcript_path\":\"$T\",\"stop_hook_active\":false}"; DETAIL=1 count "Stop (trivial transcript)" bash hooks/stop-reminder.sh
PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"/w/src/x.py","old_string":"a","new_string":"b"}}'; DETAIL=1 count "PreToolUse Edit (non-ledger file)" bash hooks/format-enforcer.sh
PAYLOAD='{"tool_name":"Edit","tool_input":{"file_path":"/w/docs/found-issues.md","old_string":"a","new_string":"- [open] 2026-10-03 x.py:1 — y"}}'; count "PreToolUse Edit (ledger file)" bash hooks/format-enforcer.sh
PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'; count "PreToolUse Bash ls" bash hooks/pre-branch-delete.sh
PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"ls -la"},"tool_response":{"stdout":"","exit_code":"0"}}'; count "PostToolUse Bash ls" bash hooks/post-bash-dispatch.sh
PAYLOAD=''; count "segment cold" bash bin/found-issues status --format=segment --cwd /w
PAYLOAD=''; count "segment warm" bash bin/found-issues status --format=segment --cwd /w
