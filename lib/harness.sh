#!/usr/bin/env bash
# lib/harness.sh — which agent harness is running this hook, and how to
# emit PostToolUse context for it.
#
# Claude Code sets CLAUDE_CODE_ENTRYPOINT on every hook invocation.
# Codex plugin hooks receive PLUGIN_DATA / PLUGIN_ROOT. Codex ALSO sets
# legacy CLAUDE_PLUGIN_ROOT/CLAUDE_PLUGIN_DATA for compatibility, so those
# must never be used as discriminators. Unknown environments behave as
# claude (plain-text output — the legacy contract).
#
# NOTE: the Codex additionalContext JSON shape is isolated here on purpose.
# Empirical testing (Task 11, Codex CLI 0.144.5) confirmed the required
# nesting: Codex's PostToolUse hook-output JSON Schema
# ("post-tool-use.command.output") sets top-level "additionalProperties": false
# and only accepts additionalContext INSIDE a "hookSpecificOutput" object that
# also carries "hookEventName": "PostToolUse". A flat {additionalContext: .}
# is an unrecognized top-level field and is dropped, so the context never
# reaches the model. The nested shape below matches the schema.

fi_detect_harness() {
  if [[ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ]]; then
    printf 'claude'
  elif [[ -n "${PLUGIN_DATA:-}" ]]; then
    printf 'codex'
  else
    printf 'claude'
  fi
}

# Emit PostToolUse context text for the current harness.
# Claude Code injects plain stdout; Codex requires JSON.
fi_emit_post_context() {
  local text="${1:-}"
  [[ -z "$text" ]] && return 0
  if [[ "$(fi_detect_harness)" == "codex" ]]; then
    command -v jq >/dev/null 2>&1 || return 0
    printf '%s' "$text" | jq -Rs '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: .}}'
  else
    printf '%s\n' "$text"
  fi
}
