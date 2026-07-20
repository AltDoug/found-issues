#!/usr/bin/env bats
# Tests for hooks/stop-reminder.sh

load 'helpers'

HOOK="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/hooks/stop-reminder.sh"

setup() {
  fi_setup_tmp
}

teardown() {
  fi_teardown_tmp
  unset FOUND_ISSUES_STOP_REMINDER
  unset CLAUDE_CODE_ENTRYPOINT
}

@test "stop-reminder: blocks when marker missing AND substantive tool use occurred" {
  TR="$(mktemp)"
  # Simulate a transcript where the assistant turn included an Edit tool use
  # but did not include the required marker.
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"please fix the bug"}
{"type":"assistant","message":"sure, editing now","tool_uses":[{"name":"Edit","input":{"file_path":"foo.py"}}]}
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "FOUND_ISSUES_REMINDER_VERBOSITY=full echo '$input' | FOUND_ISSUES_REMINDER_VERBOSITY=full '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"acknowledgment"* ]]
  rm -f "$TR"
}

@test "stop-reminder: allows pure-conversation turn without marker (smart-fire)" {
  TR="$(mktemp)"
  # Simulate a transcript where the assistant just had a chat reply — no
  # Edit/Write/Bash tool use. The marker shouldn't be required for that.
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"hello"}
{"type":"assistant","message":"hi, what would you like to work on?"}
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
  rm -f "$TR"
}

@test "stop-reminder: allows when marker present (none-noticed)" {
  TR="$(mktemp)"
  # Include both a tool use (so smart-fire would normally trigger) AND the marker.
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"fix this"}
{"type":"assistant","message":"done","tool_uses":[{"name":"Edit","input":{}}]}
response <!-- found-issues-checked: none-noticed --> done
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
  rm -f "$TR"
}

@test "stop-reminder: allows when marker present (logged)" {
  TR="$(mktemp)"
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"fix this"}
{"type":"assistant","message":"done","tool_uses":[{"name":"Edit","input":{}}]}
response <!-- found-issues-checked: logged --> done
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
  rm -f "$TR"
}

@test "stop-reminder: allows when marker present (deferred)" {
  TR="$(mktemp)"
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"fix this"}
{"type":"assistant","message":"done","tool_uses":[{"name":"Edit","input":{}}]}
response <!-- found-issues-checked: deferred --> done
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
  rm -f "$TR"
}

@test "stop-reminder: respects FOUND_ISSUES_STOP_REMINDER=off" {
  export FOUND_ISSUES_STOP_REMINDER=off
  TR="$(mktemp)"
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"fix this"}
{"type":"assistant","message":"done","tool_uses":[{"name":"Edit","input":{}}]}
no marker
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
  rm -f "$TR"
}

@test "stop-reminder: skips silently when CLAUDE_CODE_ENTRYPOINT=sdk-cli (headless)" {
  # Headless / dispatched Claude Code sessions (`claude -p`, SDK, orchard
  # engine) have no interactive operator to interpret the "Stop blocked"
  # stderr. Without this skip the dispatched model gets stuck in a
  # multi-turn confusion spiral trying to "fix" a requirement it has no
  # context for. Regression for the 2026-05-22 orchard proposal-build
  # incident where a session stalled 23 min with 0/23 tasks done.
  TR="$(mktemp)"
  # Use a transcript shape that would otherwise block: substantive Bash
  # tool use, no marker, smart-fire would normally fire.
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"please fix the bug"}
{"type":"assistant","message":"sure, editing now","tool_uses":[{"name":"Edit","input":{"file_path":"foo.py"}}]}
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "CLAUDE_CODE_ENTRYPOINT=sdk-cli echo '$input' | CLAUDE_CODE_ENTRYPOINT=sdk-cli '$HOOK'"
  [ "$status" -eq 0 ]
  # Nothing written to stderr (silent skip — the model can't read it anyway)
  [ -z "$output" ] || { echo "FAIL: expected silent skip but got output: $output"; false; }
  rm -f "$TR"
}

@test "stop-reminder: still enforces marker when CLAUDE_CODE_ENTRYPOINT=cli (interactive)" {
  # Sanity: the entrypoint escape hatch must only fire for non-`cli` values.
  # An explicit "cli" value keeps the original interactive behavior.
  TR="$(mktemp)"
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"please fix the bug"}
{"type":"assistant","message":"sure, editing now","tool_uses":[{"name":"Edit","input":{"file_path":"foo.py"}}]}
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "CLAUDE_CODE_ENTRYPOINT=cli FOUND_ISSUES_REMINDER_VERBOSITY=full echo '$input' | CLAUDE_CODE_ENTRYPOINT=cli FOUND_ISSUES_REMINDER_VERBOSITY=full '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"acknowledgment"* ]]
  rm -f "$TR"
}

@test "stop-reminder: enforces marker when CLAUDE_CODE_ENTRYPOINT is unset (backward compat)" {
  # Existing tests and direct hook runs (e.g. bats invocations, manual
  # debugging) don't set CLAUDE_CODE_ENTRYPOINT. The skip must NOT fire on
  # an empty/missing var — original behavior is preserved.
  TR="$(mktemp)"
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"please fix the bug"}
{"type":"assistant","message":"sure, editing now","tool_uses":[{"name":"Edit","input":{"file_path":"foo.py"}}]}
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  # Explicitly unset to defeat any inherited env from the developer's shell.
  run bash -c "unset CLAUDE_CODE_ENTRYPOINT; FOUND_ISSUES_REMINDER_VERBOSITY=full echo '$input' | FOUND_ISSUES_REMINDER_VERBOSITY=full '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"acknowledgment"* ]]
  rm -f "$TR"
}

@test "stop-reminder: skips for any non-cli entrypoint value (sdk, future modes)" {
  # The check is "anything other than cli" so future entrypoints (direct
  # SDK without -p, etc.) get the same treatment without code changes.
  TR="$(mktemp)"
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"please fix the bug"}
{"type":"assistant","message":"sure, editing now","tool_uses":[{"name":"Edit","input":{"file_path":"foo.py"}}]}
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  # Generic SDK entrypoint (not the -p mediated form).
  run bash -c "CLAUDE_CODE_ENTRYPOINT=sdk echo '$input' | CLAUDE_CODE_ENTRYPOINT=sdk '$HOOK'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  rm -f "$TR"
}

@test "stop-reminder: fails open when transcript_path is missing or invalid" {
  input='{"hook_event_name":"Stop","transcript_path":"/nonexistent/path"}'
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "stop-reminder: blocks on realistic Claude Code transcript with tool_result envelope (regression)" {
  # Real Claude Code transcripts wrap tool_result content in a top-level
  # "type":"user" envelope (role:user, content:tool_result). The smart-fire
  # awk used to treat those as user-message boundaries, throwing away the
  # earlier assistant tool_use and silently allowing every code-modifying
  # turn through with no marker requirement.
  #
  # Repros bug observed 2026-05-12. Hook must exit 2 (block) here.
  TR="$(mktemp)"
  cat > "$TR" <<'TRANSCRIPT'
{"parentUuid":"u-1","isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"text","text":"please run git status"}]},"uuid":"user-1","timestamp":"2026-05-12T00:00:00Z","sessionId":"s-1","cwd":"/x","version":"2.1.139"}
{"parentUuid":"user-1","type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_01","name":"Bash","input":{"command":"git status"}}]},"uuid":"asst-1","timestamp":"2026-05-12T00:00:01Z","sessionId":"s-1"}
{"parentUuid":"asst-1","type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01","type":"tool_result","content":"On branch main","is_error":false}]},"uuid":"toolres-1","timestamp":"2026-05-12T00:00:02Z","toolUseResult":{"stdout":"On branch main","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false},"sourceToolAssistantUUID":"asst-1","sessionId":"s-1"}
{"parentUuid":"toolres-1","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"You are on main."}]},"uuid":"asst-2","timestamp":"2026-05-12T00:00:03Z","sessionId":"s-1"}
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "FOUND_ISSUES_REMINDER_VERBOSITY=full echo '$input' | FOUND_ISSUES_REMINDER_VERBOSITY=full '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"acknowledgment"* ]]
  rm -f "$TR"
}

@test "stop-reminder: honors stop_hook_active=true (skip on retry-fire)" {
  # Claude Code fires Stop before the final assistant text is flushed to
  # disk, so the first-fire marker check can race. On retry, Claude Code
  # sets stop_hook_active=true; the hook must exit 0 unconditionally to
  # break the loop, regardless of marker / smart-fire state.
  TR="$(mktemp)"
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"fix this"}
{"type":"assistant","message":"done","tool_uses":[{"name":"Edit","input":{}}]}
no marker
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"stop_hook_active\":true,\"transcript_path\":\"$TR\"}"
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
  rm -f "$TR"
}

@test "stop-reminder: stop_hook_active=false still enforces marker" {
  # Sanity: the stop_hook_active escape hatch must only fire on `true`.
  TR="$(mktemp)"
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"fix this"}
{"type":"assistant","message":"done","tool_uses":[{"name":"Edit","input":{}}]}
no marker
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"transcript_path\":\"$TR\"}"
  run bash -c "FOUND_ISSUES_REMINDER_VERBOSITY=full echo '$input' | FOUND_ISSUES_REMINDER_VERBOSITY=full '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"acknowledgment"* ]]
  rm -f "$TR"
}

@test "stop-reminder: allows realistic transcript with marker present" {
  # Same realistic shape, with the marker baked into the assistant's
  # final text response. Hook must allow.
  TR="$(mktemp)"
  cat > "$TR" <<'TRANSCRIPT'
{"parentUuid":"u-1","isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"text","text":"edit foo.py"}]},"uuid":"user-1","timestamp":"2026-05-12T00:00:00Z","sessionId":"s-1"}
{"parentUuid":"user-1","type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_02","name":"Edit","input":{"file_path":"foo.py"}}]},"uuid":"asst-1","timestamp":"2026-05-12T00:00:01Z","sessionId":"s-1"}
{"parentUuid":"asst-1","type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_02","type":"tool_result","content":"edited","is_error":false}]},"uuid":"toolres-1","timestamp":"2026-05-12T00:00:02Z","sessionId":"s-1"}
{"parentUuid":"toolres-1","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done. <!-- found-issues-checked: none-noticed -->"}]},"uuid":"asst-2","timestamp":"2026-05-12T00:00:03Z","sessionId":"s-1"}
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "echo '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
  rm -f "$TR"
}

@test "stop-reminder: terse message when FOUND_ISSUES_REMINDER_VERBOSITY=terse" {
  TR="$(mktemp)"
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"please fix the bug"}
{"type":"assistant","message":"sure, editing now","tool_uses":[{"name":"Edit","input":{"file_path":"foo.py"}}]}
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "FOUND_ISSUES_REMINDER_VERBOSITY=terse echo '$input' | FOUND_ISSUES_REMINDER_VERBOSITY=terse '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Stop blocked"* ]]
  [[ "$output" == *"missing"* ]]
  [[ "$output" != *"Add ONE of these"* ]]
  line_count="$(printf '%s' "$output" | grep -c '' || true)"
  [ "$line_count" -le 2 ]
  rm -f "$TR"
}

@test "stop-reminder: full message when FOUND_ISSUES_REMINDER_VERBOSITY=full" {
  TR="$(mktemp)"
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"please fix the bug"}
{"type":"assistant","message":"sure, editing now","tool_uses":[{"name":"Edit","input":{"file_path":"foo.py"}}]}
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "FOUND_ISSUES_REMINDER_VERBOSITY=full echo '$input' | FOUND_ISSUES_REMINDER_VERBOSITY=full '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"acknowledgment"* ]]
  [[ "$output" == *"Add ONE of these"* ]]
  rm -f "$TR"
}

@test "stop-reminder: auto-detects terse mode when .onboarded marker exists" {
  TR="$(mktemp)"
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"please fix the bug"}
{"type":"assistant","message":"sure, editing now","tool_uses":[{"name":"Edit","input":{"file_path":"foo.py"}}]}
TRANSCRIPT
  FAKE_HOME="$(mktemp -d)"
  mkdir -p "$FAKE_HOME/.claude/found-issues"
  touch "$FAKE_HOME/.claude/found-issues/.onboarded"
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "HOME='$FAKE_HOME' echo '$input' | HOME='$FAKE_HOME' '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" != *"Add ONE of these"* ]]
  rm -rf "$FAKE_HOME" "$TR"
}

@test "stop-reminder: auto-detects full mode when .onboarded marker absent" {
  TR="$(mktemp)"
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"please fix the bug"}
{"type":"assistant","message":"sure, editing now","tool_uses":[{"name":"Edit","input":{"file_path":"foo.py"}}]}
TRANSCRIPT
  FAKE_HOME="$(mktemp -d)"
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "HOME='$FAKE_HOME' echo '$input' | HOME='$FAKE_HOME' '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Add ONE of these"* ]]
  rm -rf "$FAKE_HOME" "$TR"
}

@test "stop-reminder: handles multibyte UTF-8 in transcript without awk towc errors" {
  # Regression for `awk: towc: multibyte conversion failure` on transcript
  # tails containing em-dashes, check marks, smart quotes — content common in
  # AI responses. GNU awk under UTF-8 locales (en_US.UTF-8, default on most
  # Linux CI runners) calls libc's mbrtowc() per input byte, which can fail
  # on certain byte boundaries even with valid UTF-8 input.
  # Fix: LC_ALL=C prefix on the hook's awk call — awk processes bytes
  # opaquely, no multibyte conversion attempted. The hook's patterns are
  # all ASCII so byte-mode awk is sufficient.
  TR="$(mktemp)"
  cat > "$TR" <<'TRANSCRIPT'
{"parentUuid":"u-1","isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"text","text":"install the package"}]},"uuid":"user-1","timestamp":"2026-05-12T00:00:00Z","sessionId":"s-1"}
{"parentUuid":"user-1","type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_03","name":"Bash","input":{"command":"npm install"}}]},"uuid":"asst-1","timestamp":"2026-05-12T00:00:01Z","sessionId":"s-1"}
{"parentUuid":"asst-1","type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_03","type":"tool_result","content":"installed — package@1.0.0 ✅","is_error":false}]},"uuid":"toolres-1","timestamp":"2026-05-12T00:00:02Z","sessionId":"s-1"}
{"parentUuid":"toolres-1","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done — installed the package ✓ and verified ✅. <!-- found-issues-checked: none-noticed -->"}]},"uuid":"asst-2","timestamp":"2026-05-12T00:00:03Z","sessionId":"s-1"}
TRANSCRIPT
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  # Force a UTF-8 locale so this test exercises the bug-prone code path even
  # in CI environments that default to C/POSIX. If the awk call lacks the
  # LC_ALL=C prefix, GNU awk will emit `towc: multibyte conversion failure`.
  LC_ALL=en_US.UTF-8 run bash -c "echo '$input' | '$HOOK'"
  # The towc error must not appear in stdout OR stderr (bats's $output combines them).
  [[ "$output" != *"towc"* ]] || { echo "FAIL: awk towc error leaked through. Full output:"; echo "$output"; false; }
  [[ "$output" != *"multibyte conversion failure"* ]] || { echo "FAIL: multibyte conversion failure leaked. Full output:"; echo "$output"; false; }
  # The marker is present in the assistant's final text, so the hook must allow (exit 0).
  [ "$status" -eq 0 ] || { echo "FAIL: expected exit 0 (marker present), got $status. Full output:"; echo "$output"; false; }
  rm -f "$TR"
}

@test "stop-reminder: codex harness exits 0 without reading stdin transcript" {
  unset CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
  TR="$(mktemp)"
  # Substantive tool use without marker would normally block (exit 2) on Claude,
  # but with Codex detection it should exit 0 (fail open).
  cat > "$TR" <<'TRANSCRIPT'
{"type":"user","message":"please fix the bug"}
{"type":"assistant","message":"sure, editing now","tool_uses":[{"name":"Edit","input":{"file_path":"foo.py"}}]}
TRANSCRIPT
  export PLUGIN_DATA="$TMP/pd"
  input="{\"hook_event_name\":\"Stop\",\"transcript_path\":\"$TR\"}"
  run bash -c "echo '$input' | PLUGIN_DATA='$PLUGIN_DATA' '$HOOK'"
  [ "$status" -eq 0 ]
  rm -f "$TR"
}
