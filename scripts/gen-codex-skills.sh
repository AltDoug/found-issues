#!/usr/bin/env bash
# gen-codex-skills.sh — regenerate codex-skills/ from commands/*.md.
#
# Codex discovers skills as <dir>/SKILL.md with name/description frontmatter
# (no argument-hint, no allowed-tools — both are Claude-only concepts, so the
# generated frontmatter carries only name + description). Claude-only body
# syntax gets rewritten for Codex:
#   - `/found-issues:<name>` (a Claude Code slash command) -> `$fi-<name>`
#     (Codex's own $-mention invocation syntax for the skill, per the design
#     spec — reads naturally in both prose and example-invocation code
#     fences, stays a single token so it can't produce the double-article
#     grammar that "the ... skill" wrapping did in an earlier iteration).
#   - `$ARGUMENTS` (Claude Code's slash-command argument placeholder) ->
#     `<the user-provided arguments>`.
#   - `@found-issues-rules.md` (Claude Code's context-include syntax for the
#     always-on rules file) -> `the auto-injected found-issues rules`.
#
# A few bodies contain paragraphs that are irreducibly Claude-only (e.g.
# `commands/setup.md`'s AskUserQuestion picker and statusline-splice
# mechanics, `commands/uninstall.md`'s `/plugin uninstall` sequencing) —
# those are intentionally left as-is; a Codex reader sees an inert
# paragraph, which is an acceptable v1 trade-off (see
# docs/superpowers/sdd/task-7-report.md for the full list).
#
# Output is CHECKED IN; tests/codex-skills-drift.bats fails the build when
# commands/ changes without a matching regeneration.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

export LC_ALL=C

rm -rf codex-skills
mkdir -p codex-skills

for cmd in commands/*.md; do
  name="$(basename "$cmd" .md)"

  # Frontmatter description — same Claude-only rewrites as the body, plus
  # two narrow fixes for commands/uninstall.md's description (the only one
  # that names Claude Code's own `/plugin` command family and the Claude-only
  # `/fi` alias file). No other description matches these two patterns, so
  # this is a no-op everywhere else.
  desc="$(awk '/^description:/ { sub(/^description:[ ]*/, ""); print; exit }' "$cmd" \
    | sed -E \
        -e 's|/found-issues:([a-z-]+)|$fi-\1|g' \
        -e 's|\$ARGUMENTS|<the user-provided arguments>|g' \
        -e 's|@found-issues-rules\.md|the auto-injected found-issues rules|g' \
        -e 's|/plugin uninstall|removing the found-issues plugin|g' \
        -e 's|/fi alias|fi alias|g')"

  mkdir -p "codex-skills/fi-$name"
  {
    printf -- '---\n'
    printf 'name: fi-%s\n' "$name"
    printf 'description: %s\n' "$desc"
    printf -- '---\n'
    # Body = everything after the closing frontmatter fence, with Claude-only
    # syntax rewritten for Codex.
    awk 'c >= 2 { print } /^---$/ { c++ }' "$cmd" \
      | sed -E \
          -e 's|/found-issues:([a-z-]+)|$fi-\1|g' \
          -e 's|\$ARGUMENTS|<the user-provided arguments>|g' \
          -e 's|@found-issues-rules\.md|the auto-injected found-issues rules|g'
  } > "codex-skills/fi-$name/SKILL.md"
done

printf 'generated %s codex skills\n' "$(ls codex-skills | wc -l | tr -d ' ')"
