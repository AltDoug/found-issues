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
  # The generator sources lib/codex-rewrite.sh (shared with session-start.sh);
  # copy it into the sandbox too or the regeneration can't run.
  mkdir -p "$tmp/lib" && cp "$TEST_REPO_ROOT/lib/codex-rewrite.sh" "$tmp/lib/"
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

  # The one allowed form is the literal Claude /fi alias body the setup skill
  # checks for (`Run /found-issues:$ARGUMENTS`) — rewriting it corrupted the
  # check (2026-10-03 audit, prompt-13).
  run bash -c "grep -r '\\\$ARGUMENTS' '$TEST_REPO_ROOT/codex-skills' | grep -v '/found-issues:\\\$ARGUMENTS'"
  [ -z "$output" ]
}

@test "generator prefers codex-description over description when both are present" {
  # A slash command is invoked BY NAME, so `description:` is a terse picker
  # label; a Codex skill is MODEL-ROUTED, so its description is the only
  # routing text the model sees. The optional `codex-description:` key lets
  # one source file serve both surfaces without desyncing them.
  tmp="$(mktemp -d -t fi-gen.XXXXXX)"
  mkdir -p "$tmp/commands" "$tmp/scripts" "$tmp/lib"
  cp "$TEST_REPO_ROOT/scripts/gen-codex-skills.sh" "$tmp/scripts/"
  cp "$TEST_REPO_ROOT/lib/codex-rewrite.sh" "$tmp/lib/"
  cat > "$tmp/commands/demo.md" <<'EOF'
---
description: Terse picker label
codex-description: Rich model-routed text with when-to-use boundaries
---
Body.
EOF
  (cd "$tmp" && bash scripts/gen-codex-skills.sh)
  run grep '^description: "Rich model-routed text with when-to-use boundaries"$' "$tmp/codex-skills/fi-demo/SKILL.md"
  [ "$status" -eq 0 ]
  run grep 'Terse picker label' "$tmp/codex-skills/fi-demo/SKILL.md"
  [ "$status" -ne 0 ]
  rm -rf "$tmp"
}

@test "generator falls back to description when codex-description is absent" {
  tmp="$(mktemp -d -t fi-gen.XXXXXX)"
  mkdir -p "$tmp/commands" "$tmp/scripts" "$tmp/lib"
  cp "$TEST_REPO_ROOT/scripts/gen-codex-skills.sh" "$tmp/scripts/"
  cp "$TEST_REPO_ROOT/lib/codex-rewrite.sh" "$tmp/lib/"
  cat > "$tmp/commands/demo.md" <<'EOF'
---
description: Only label present
---
Body.
EOF
  (cd "$tmp" && bash scripts/gen-codex-skills.sh)
  run grep '^description: "Only label present"$' "$tmp/codex-skills/fi-demo/SKILL.md"
  [ "$status" -eq 0 ]
  rm -rf "$tmp"
}

@test "codex skills use the \$fi- mention sigil for skill references" {
  # Positive control for the rewrite above: /found-issues:<name> becomes
  # $fi-<name> (Codex's own $-mention invocation syntax), not a bare
  # fi-<name> or a "the ... skill" wrapper. Confirms the sigil actually
  # made it into the generated output, not just that the old syntax is gone.
  run grep -rl '\$fi-' "$TEST_REPO_ROOT/codex-skills"
  [ "$status" -eq 0 ]
}

# cli-19 (2026-10-03 audit): descriptions were written as YAML plain scalars,
# and several contain ": " (e.g. "reality: flip", "(PR: org/repo#N)"), which a
# strict YAML loader rejects ("mapping values are not allowed here"). Codex's
# loader decides whether the skill exists at all, so emit a quoted scalar.
@test "codex skill descriptions are double-quoted YAML scalars" {
  local f line
  for f in "$TEST_REPO_ROOT"/codex-skills/*/SKILL.md; do
    line="$(sed -n '2,4{/^description: /p;}' "$f")"
    [[ "$line" =~ ^description:\ \".*\"$ ]] || { echo "unquoted: $f"; false; }
    # no unescaped double quote inside the scalar
    local inner="${line#description: \"}"; inner="${inner%\"}"
    inner="${inner//\\\\/}"; inner="${inner//\\\"/}"
    [[ "$inner" != *'"'* ]] || { echo "stray quote: $f"; false; }
  done
}

@test "codex skill frontmatter parses with a strict YAML loader (when one is available)" {
  local f fm
  if command -v ruby >/dev/null 2>&1 && ruby -ryaml -e '' 2>/dev/null; then
    for f in "$TEST_REPO_ROOT"/codex-skills/*/SKILL.md; do
      fm="$(awk 'NR == 1 { next } /^---$/ { exit } { print }' "$f")"
      printf '%s\n' "$fm" | ruby -ryaml -e 'd = YAML.safe_load(STDIN.read); exit(d["name"].to_s.empty? || d["description"].to_s.empty? ? 1 : 0)' \
        || { echo "YAML rejects: $f"; false; }
    done
  elif command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    for f in "$TEST_REPO_ROOT"/codex-skills/*/SKILL.md; do
      awk 'NR == 1 { next } /^---$/ { exit } { print }' "$f" \
        | python3 -c 'import sys, yaml; d = yaml.safe_load(sys.stdin); sys.exit(0 if d.get("name") and d.get("description") else 1)' \
        || { echo "YAML rejects: $f"; false; }
    done
  else
    skip "no strict YAML loader (ruby or python3 + PyYAML)"
  fi
}
