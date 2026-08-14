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

# Shared Claude→Codex rewrites, also used by hooks/session-start.sh. Sourced
# (not duplicated) so the two rewrite paths can't drift — see
# tests/codex-skills-drift.bats (which copies this helper into its sandbox).
# shellcheck source=../lib/codex-rewrite.sh
source lib/codex-rewrite.sh

rm -rf codex-skills
mkdir -p codex-skills

for cmd in commands/*.md; do
  name="$(basename "$cmd" .md)"

  # Frontmatter description. A slash command is invoked BY NAME, so its
  # `description:` is a terse picker label; a Codex skill is MODEL-ROUTED,
  # so its description is the only routing text the model chooses from.
  # The optional `codex-description:` key carries the rich when-to-use /
  # when-NOT-to-use text for Codex while the Claude picker label stays
  # short — prefer it, fall back to `description:` when absent. Both pass
  # through the same Claude-only rewrites, plus two narrow fixes for
  # commands/uninstall.md's text (the only one that names Claude Code's own
  # `/plugin` command family and the Claude-only `/fi` alias file). No other
  # description matches these two patterns, so this is a no-op everywhere
  # else.
  desc_src="$(awk '/^codex-description:/ { sub(/^codex-description:[ ]*/, ""); print; exit }' "$cmd")"
  if [[ -z "$desc_src" ]]; then
    desc_src="$(awk '/^description:/ { sub(/^description:[ ]*/, ""); print; exit }' "$cmd")"
  fi
  desc="$(printf '%s\n' "$desc_src" \
    | fi_codex_rewrite_core \
    | sed -E \
        -e 's|/plugin uninstall|removing the found-issues plugin|g' \
        -e 's|/fi alias|fi alias|g')"

  mkdir -p "codex-skills/fi-$name"
  {
    printf -- '---\n'
    printf 'name: fi-%s\n' "$name"
    printf 'description: %s\n' "$desc"
    printf -- '---\n'
    printf '<!-- loc-override: generated 1:1 from commands/%s.md by scripts/gen-codex-skills.sh; length is owned by the source command file -->\n' "$name"
    # Body = everything after the closing frontmatter fence, with Claude-only
    # syntax rewritten for Codex. The trailing sed fixes relative-link depth:
    # commands/*.md live one level under the repo root, but generated skills
    # live at codex-skills/fi-<name>/ (two levels down), so a `](../foo)`
    # link resolves to the wrong parent unless bumped to `](../../foo)`.
    awk 'c >= 2 { print } /^---$/ { c++ }' "$cmd" \
      | fi_codex_rewrite_core \
      | sed -E -e 's|\]\(\.\./|](../../|g'
  } > "codex-skills/fi-$name/SKILL.md"
done

printf 'generated %s codex skills\n' "$(ls codex-skills | wc -l | tr -d ' ')"
