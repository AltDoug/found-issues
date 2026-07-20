#!/usr/bin/env bash
# lib/codex-rewrite.sh — shared Claude→Codex text rewrites.
#
# Sourced by BOTH scripts/gen-codex-skills.sh (which regenerates
# codex-skills/ from commands/*.md) and hooks/session-start.sh (which injects
# the rules-skill body into Codex context, since Codex has no auto-loaded-skill
# mechanism). Kept in ONE place so the two paths can't drift — Claude-only
# slash syntax must be rewritten identically wherever it reaches a Codex
# reader. tests/codex-skills-drift.bats and tests/session-start.bats both
# assert the `/found-issues:` slash syntax is absent from Codex output.
#
# Core rewrites (apply to any Claude-authored body destined for Codex):
#   /found-issues:<name>   -> $fi-<name>   (Codex's own $-mention skill sigil)
#   $ARGUMENTS             -> <the user-provided arguments>
#   @found-issues-rules.md -> the auto-injected found-issues rules

# Rewrite stdin -> stdout with the core Claude→Codex substitutions.
fi_codex_rewrite_core() {
  sed -E \
    -e 's|/found-issues:([a-z-]+)|$fi-\1|g' \
    -e 's|\$ARGUMENTS|<the user-provided arguments>|g' \
    -e 's|@found-issues-rules\.md|the auto-injected found-issues rules|g'
}
