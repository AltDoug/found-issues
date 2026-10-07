#!/usr/bin/env bash
# lib/harness.sh — which agent harness is running this hook, and how to
# emit PostToolUse / SessionStart context for it.
#
# Claude Code sets CLAUDE_CODE_ENTRYPOINT on every hook invocation.
# Codex plugin hooks receive PLUGIN_DATA / PLUGIN_ROOT. Codex ALSO sets
# legacy CLAUDE_PLUGIN_ROOT/CLAUDE_PLUGIN_DATA for compatibility, so those
# must never be used as discriminators. Unknown environments behave as
# claude (plain-text output — the legacy contract).
#
# FOUND_ISSUES_HARNESS (claude|codex) overrides both signals — set by the
# hook commands `found-issues install-codex-hooks` writes into Codex's
# user-level $CODEX_HOME/hooks.json (Task 11b: plugin_hooks was removed
# in Codex 0.144.5, so hooks installed that way never receive PLUGIN_DATA
# in the first place — the env prefix is how they self-identify).
#
# NOTE: the Codex additionalContext JSON shape is isolated here on purpose.
# Empirical testing (Task 11, Codex CLI 0.144.5) confirmed the required
# nesting: Codex's PostToolUse hook-output JSON Schema
# ("post-tool-use.command.output") sets top-level "additionalProperties": false
# and only accepts additionalContext INSIDE a "hookSpecificOutput" object that
# also carries "hookEventName": "PostToolUse". A flat {additionalContext: .}
# is an unrecognized top-level field and is dropped, so the context never
# reaches the model. The nested shape below matches the schema. The
# "session-start.command.output" schema mirrors this shape with
# hookEventName: "SessionStart" (per the docs' statement that Codex uses
# the same event structure) — unverified live (Task 11 §8, blocked by the
# hook-trust wall), so fi_emit_session_context below is the same
# best-effort mirror.

fi_detect_harness() {
  case "${FOUND_ISSUES_HARNESS:-}" in
    claude|codex)
      printf '%s' "$FOUND_ISSUES_HARNESS"
      return
      ;;
  esac
  if [[ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ]]; then
    printf 'claude'
  elif [[ -n "${PLUGIN_DATA:-}" ]]; then
    printf 'codex'
  else
    printf 'claude'
  fi
}

# Emit PostToolUse context text. Both harnesses read additionalContext from
# hookSpecificOutput JSON; Claude Code writes plain PostToolUse stdout to its
# debug log only and never shows it to the model (hooks docs, re-checked
# 2026-10-03), so plain text is only the no-jq fallback on Claude.
fi_emit_post_context() {
  local text="${1:-}"
  [[ -z "$text" ]] && return 0
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$text" | jq -Rs '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: .}}'
  elif [[ "$(fi_detect_harness)" != "codex" ]]; then
    printf '%s\n' "$text"
  fi
}

# Emit a PreToolUse advisory (a hook that allows the call but wants the model
# to see a note). Claude Code does NOT deliver stderr on a PreToolUse exit 0
# (it reaches nobody), but it does deliver hookSpecificOutput.additionalContext
# on stdout, so that is the path on Claude (measured 2026-10-06). Codex and the
# no-jq fallback keep the advisory on stderr, the pre-3.3.1 behavior. Always
# returns 0; the caller picks the hook's exit code.
fi_emit_pre_context() {
  local text="${1:-}"
  [[ -z "$text" ]] && return 0
  if [[ "$(fi_detect_harness)" != "codex" ]] && command -v jq >/dev/null 2>&1; then
    printf '%s' "$text" | jq -Rs '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: .}}'
  else
    printf '%s\n' "$text" >&2
  fi
  return 0
}

# Emit SessionStart context text for the current harness. Claude Code
# injects plain stdout as context (legacy contract, unchanged); Codex's
# session-start.command.output JSON Schema mirrors the PostToolUse shape
# above, so this wraps the same way — see the file header comment for
# the schema citation and the "unverified live" caveat.
fi_emit_session_context() {
  local text="${1:-}"
  [[ -z "$text" ]] && return 0
  if [[ "$(fi_detect_harness)" == "codex" ]]; then
    command -v jq >/dev/null 2>&1 || return 0
    printf '%s' "$text" | jq -Rs '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: .}}'
  else
    printf '%s\n' "$text"
  fi
}
