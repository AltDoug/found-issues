#!/usr/bin/env bats
# Static source guards over bin/found-issues.
#
# Cheap structural checks that catch a whole bug CLASS at author time, rather
# than waiting for one more per-command regression test to be remembered.
#
# Guard 1: every `while ... read` loop that reads a real file must carry the
# `|| [[ -n "$line" ]]` clause. `read` returns non-zero on a FINAL line with no
# trailing newline, so a plain `while read` never runs its body for that line.
# In a rewrite loop that silently DROPS the entry (the v2.2.1 data-loss bug:
# defer, sync and annotate-commit each turned a 2-entry ledger into 1); in a
# scan loop it makes the final entry unselectable, which is the same input
# shape misbehaving. Hand-edited ledgers and some editors produce exactly this
# shape.
#
# The check only fires on loops fed by a plain redirect (`done <"$file"`).
# Process substitution (`done < <(fi_entries ...)`) and here-strings
# (`done <<<"$content"`) are exempt: awk output and bash here-strings are
# always newline-terminated, so no final partial line can exist.

load 'helpers'

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CLI="$REPO_ROOT/bin/found-issues"

# Print "<line>" for every unguarded file-fed read loop in $1.
#
# Loop openers (while/until/for) are tracked on a stack so the `done` line is
# attributed to the RIGHT `while` -- fi_annotate_auto nests two `read tf` loops
# inside a file-fed `read line` loop, and a naive last-while-seen match would
# blame the wrong one.
#
# POSIX awk only (no GNU extensions): macOS CI runs BSD awk, Windows runs
# whatever Git Bash ships.
fi_unguarded_read_loops() {
  awk '
    {
      s = $0
      sub(/^[[:space:]]+/, "", s)
      if (s ~ /^(while|until|for)[[:space:](]/) {
        sp++
        at[sp] = NR
        isread[sp] = (s ~ /^while[[:space:]]+(IFS=[^[:space:]]*[[:space:]]+)?read[[:space:]]/) ? 1 : 0
        guarded[sp] = (index(s, "|| [[ -n") > 0) ? 1 : 0
      } else if (s ~ /^done([[:space:]]|$)/) {
        if (sp > 0) {
          p = index(s, "<")
          rest = ""
          if (p > 0) {
            rest = substr(s, p + 1)
            sub(/^[[:space:]]+/, "", rest)
          }
          # A plain file redirect: a single "<" whose target is neither a
          # here-string ("<<<") nor a process substitution ("<(").
          fromfile = (p > 0 && rest !~ /^</ && rest !~ /^\(/) ? 1 : 0
          if (isread[sp] && fromfile && !guarded[sp]) print at[sp]
          sp--
        }
      }
    }
  ' "$1"
}

@test "source-guards: every file-fed read loop in the CLI guards the final partial line" {
  run fi_unguarded_read_loops "$CLI"
  [ "$status" -eq 0 ]
  # Any output is a list of offending line numbers. Print them on failure so
  # the fix is a jump-to-line, not a hunt.
  if [ -n "$output" ]; then
    printf 'unguarded read loops (add: || [[ -n "$line" ]]) at bin/found-issues lines:\n%s\n' "$output" >&2
  fi
  [ -z "$output" ]
}

@test "source-guards: the detector recognizes an unguarded file-fed read loop" {
  # Negative control. Without this, a detector that silently stopped matching
  # anything (a bad regex, a refactor of the loop style) would keep the test
  # above green forever while enforcing nothing.
  cat >"$BATS_TEST_TMPDIR/sample.sh" <<'SAMPLE'
f() {
  while IFS= read -r line; do
    printf '%s\n' "$line"
  done <"$file"
}
SAMPLE
  run fi_unguarded_read_loops "$BATS_TEST_TMPDIR/sample.sh"
  [ "$output" = "2" ]
}

@test "source-guards: the detector accepts a guarded loop and exempt feeds" {
  cat >"$BATS_TEST_TMPDIR/ok.sh" <<'SAMPLE'
f() {
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line"
  done <"$file"
  while IFS= read -r entry; do
    printf '%s\n' "$entry"
  done < <(fi_entries "$file" open)
  while IFS= read -r pick; do
    printf '%s\n' "$pick"
  done <<<"$picks"
}
SAMPLE
  run fi_unguarded_read_loops "$BATS_TEST_TMPDIR/ok.sh"
  [ -z "$output" ]
}
