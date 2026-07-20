#!/usr/bin/env bats
# Generated codex-skills/ must exactly match scripts/gen-codex-skills.sh output
#
# The generator's only inputs are commands/*.md and itself — this test copies
# both into an isolated tempdir and regenerates there, so a stale checked-in
# codex-skills/ (commands changed without re-running the generator) fails
# the build instead of silently drifting from Claude's commands/*.md.

load 'helpers'

@test "codex-skills are up to date with commands" {
  tmp="$(mktemp -d -t fi-drift.XXXXXX)"
  cp -R "$TEST_REPO_ROOT/commands" "$tmp/commands"
  cp "$TEST_REPO_ROOT/scripts/gen-codex-skills.sh" "$tmp/"
  mkdir -p "$tmp/scripts" && mv "$tmp/gen-codex-skills.sh" "$tmp/scripts/"
  (cd "$tmp" && bash scripts/gen-codex-skills.sh)
  diff -r "$tmp/codex-skills" "$TEST_REPO_ROOT/codex-skills"
  rm -rf "$tmp"
}

@test "every command has a generated codex skill" {
  for cmd in "$TEST_REPO_ROOT"/commands/*.md; do
    name="$(basename "$cmd" .md)"
    [ -f "$TEST_REPO_ROOT/codex-skills/fi-$name/SKILL.md" ]
  done
}

@test "codex skills contain no claude-only slash references" {
  # NOTE: two bare `! grep ...` statements would NOT reliably fail this test
  # on a match — bash's `set -e` explicitly exempts commands whose exit
  # status is inverted with `!` from triggering errexit, so only the LAST
  # statement's status would ever actually be enforced. Use `run` + an
  # explicit status check instead (this bit us during Task 7 development:
  # the naive form passed even with unrewritten refs present).
  #
  # The pattern requires a command-name character (`[a-z-]`) right after the
  # colon — real `/found-issues:<name>` slash references are always followed
  # by one, so this correctly ignores coincidental substrings like a
  # `bin/found-issues:880` path:line citation in an example commit message.
  run grep -rE '/found-issues:[a-z-]' "$TEST_REPO_ROOT/codex-skills"
  [ "$status" -ne 0 ]

  run grep -r '\$ARGUMENTS' "$TEST_REPO_ROOT/codex-skills"
  [ "$status" -ne 0 ]
}

@test "codex skills use the \$fi- mention sigil for skill references" {
  # Positive control for the rewrite above: /found-issues:<name> becomes
  # $fi-<name> (Codex's own $-mention invocation syntax), not a bare
  # fi-<name> or a "the ... skill" wrapper. Confirms the sigil actually
  # made it into the generated output, not just that the old syntax is gone.
  run grep -rl '\$fi-' "$TEST_REPO_ROOT/codex-skills"
  [ "$status" -eq 0 ]
}
