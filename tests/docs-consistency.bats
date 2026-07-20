#!/usr/bin/env bats
# Tests for docs/spec consistency between README.md and AGENTS.md.
#
# Prevents drift between the human-facing source of truth (README) and the
# AI-facing source of truth (AGENTS.md). The 2026-05-10 UX audit found two
# divergences: (1) install order (4-cmd /reload-plugins vs 2-then-restart),
# (2) uninstall order (AGENTS.md said /plugin uninstall handles everything;
# it doesn't — leaves orphaned ~/.claude/found-issues, statusline block,
# mode cache, /fi alias).
#
# These tests are cheap structural checks, not full semantic equivalence.

load 'helpers'

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
README="$REPO_ROOT/README.md"
AGENTS="$REPO_ROOT/AGENTS.md"

# Echo the line number of the first match of $2 in $1 (empty if no match).
fi_first_line() {
  local file="$1"
  local pat="$2"
  grep -nF -- "$pat" "$file" | head -1 | cut -d: -f1
}

@test "docs-consistency: README and AGENTS.md both exist" {
  [ -f "$README" ]
  [ -f "$AGENTS" ]
}

@test "docs-consistency: both reference the canonical /found-issues:uninstall skill" {
  grep -Fq "/found-issues:uninstall" "$README"
  grep -Fq "/found-issues:uninstall" "$AGENTS"
}

@test "docs-consistency: README's uninstall order has /found-issues:uninstall before /plugin uninstall found-issues" {
  local our_line their_line
  our_line="$(fi_first_line "$README" '/found-issues:uninstall')"
  their_line="$(fi_first_line "$README" '/plugin uninstall found-issues')"
  [ -n "$our_line" ]
  [ -n "$their_line" ]
  (( our_line < their_line ))
}

@test "docs-consistency: AGENTS.md's uninstall order has /found-issues:uninstall before /plugin uninstall found-issues" {
  local our_line their_line
  our_line="$(fi_first_line "$AGENTS" '/found-issues:uninstall')"
  their_line="$(fi_first_line "$AGENTS" '/plugin uninstall found-issues')"
  [ -n "$our_line" ]
  [ -n "$their_line" ]
  (( our_line < their_line ))
}

@test "docs-consistency: both install instructions reference the canonical marketplace" {
  grep -Fq "/plugin marketplace add AltDoug/claude-plugins" "$README"
  grep -Fq "/plugin marketplace add AltDoug/claude-plugins" "$AGENTS"
}

@test "docs-consistency: AGENTS.md uninstall section warns about order" {
  # Either explicit 'Order matters' or 'order matters' in the AGENTS.md
  # uninstall context. README has the same warning.
  grep -iFq "order matters" "$AGENTS"
  grep -iFq "order matters" "$README"
}

@test "docs-consistency: commands/fix.md exists with frontmatter description" {
  [ -f "$REPO_ROOT/commands/fix.md" ]
  head -6 "$REPO_ROOT/commands/fix.md" | grep -q '^description:'
}

@test "docs-consistency: README documents the fix command" {
  grep -q 'found-issues:fix' "$README"
}

@test "docs-consistency: fix.md forbids annotate-pr --all" {
  grep -q 'never .*--all' "$REPO_ROOT/commands/fix.md"
}

@test "docs-consistency: README test-count stat matches actual @test count across tests/*.bats" {
  # found-issues.md 2026-07-20 (README.md:11) — the stat strip's literal
  # "N tests" number drifts every time a test is added without a matching
  # README edit (it already said "618" while the suite was at 623+ before
  # this test existed). Turn that into a CI failure instead of a ledger
  # entry: compute the actual count here and compare.
  local actual=0 f n
  for f in "$REPO_ROOT"/tests/*.bats; do
    n="$(grep -c '^@test ' "$f")"
    actual=$(( actual + n ))
  done

  local stated
  stated="$(grep -oE '[0-9]+ tests on Linux/macOS/Windows' "$README" | grep -oE '^[0-9]+')"
  [ -n "$stated" ]

  echo "README states \"$stated tests\"; tests/*.bats actually defines $actual @test cases."
  if [ "$stated" -ne "$actual" ]; then
    echo "FIX: update the '... tests on Linux/macOS/Windows' stat-strip line near the top of README.md to say \"$actual tests\"."
  fi
  [ "$stated" -eq "$actual" ]
}

@test "rules skill stays under the 3.7KB injection budget" {
  size=$(wc -c < "$TEST_REPO_ROOT/skills/rules/SKILL.md")
  # budget raised 3584->3700 on review to restore the commit-annotation rule; the diet target is the 8.6KB->3.6KB reduction, not the exact byte line.
  [ "$size" -le 3700 ]
}
