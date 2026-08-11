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

# Print "<file>:<line>" for every unguarded file-fed read loop in $@.
#
# Scans lib/ and hooks/ as well as the CLI: the two lossiest rewrites found in
# the v2.2.1 sweep (fi_append_touch, fi_increment_defer_cycle) live in
# lib/parse-entries.sh, not in bin/found-issues. A CLI-only check would have
# declared the bug class fixed while `log` still dropped entries -- and the
# scheduled cmd_* extraction into lib/ would quietly move code out of scope.
#
# FNR (not NR) and the per-file stack reset are load-bearing: NR keeps counting
# across files, so a multi-file scan would report line numbers past the end of
# the file it names.
#
# A `done <file` line is paired with its `while` by INDENTATION: the nearest
# preceding non-blank line at the same indent that opens a loop. That correctly
# skips the two nested `read tf` loops inside fi_annotate_auto's file-fed loop,
# where a naive last-while-seen match would blame the wrong one.
#
# Indentation rather than a while/done counter, deliberately. A counter drifts:
# bin/found-issues embeds awk programs (`for (i = 0; ...)`) and heredoc'd
# Node/Python/bash statusline blocks whose loop keywords are text, not shell
# structure -- they open without ever closing, leaving the count 13 too high by
# EOF. A drifted counter pops the wrong entry and MISSES a real unguarded loop,
# which is the one failure mode this check must not have. Indentation reads no
# global state, so embedded text cannot perturb it.
#
# POSIX awk only (no GNU extensions): macOS CI runs BSD awk, Windows runs
# whatever Git Bash ships.
fi_unguarded_read_loops() {
  awk '
    FNR == 1 { n = 0 }
    { n++; raw[n] = $0 }
    {
      s = $0
      ind = match(s, /[^ \t]/) - 1
      sub(/^[[:space:]]+/, "", s)
      if (s !~ /^done([[:space:]]|$)/) next
      p = index(s, "<")
      if (p == 0) next
      rest = substr(s, p + 1)
      sub(/^[[:space:]]+/, "", rest)
      # A plain file redirect: a single "<" whose target is neither a
      # here-string ("<<<") nor a process substitution ("<(").
      if (rest ~ /^</ || rest ~ /^\(/) next
      for (i = n - 1; i > 0; i--) {
        t = raw[i]
        if (t ~ /^[[:space:]]*$/) continue
        ti = match(t, /[^ \t]/) - 1
        if (ti != ind) continue
        sub(/^[[:space:]]+/, "", t)
        if (t !~ /^(while|until|for)[[:space:](]/) continue
        if (t ~ /^while[[:space:]]+(IFS=[^[:space:]]*[[:space:]]+)?read[[:space:]]/ &&
            index(t, "|| [[ -n") == 0) print FILENAME ":" i
        break
      }
    }
  ' "$@"
}

@test "source-guards: every file-fed read loop guards the final partial line" {
  local -a targets=("$CLI")
  local f
  for f in "$REPO_ROOT"/lib/*.sh "$REPO_ROOT"/hooks/*.sh "$REPO_ROOT"/scripts/*.sh; do
    [ -f "$f" ] && targets+=("$f")
  done

  run fi_unguarded_read_loops "${targets[@]}"
  [ "$status" -eq 0 ]
  # Any output is a list of offending file:line pairs. Print them on failure so
  # the fix is a jump-to-line, not a hunt.
  if [ -n "$output" ]; then
    printf 'unguarded read loops (add: || [[ -n "$line" ]]) at:\n%s\n' "$output" >&2
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
  [ "$output" = "$BATS_TEST_TMPDIR/sample.sh:2" ]
}

@test "source-guards: embedded loop keywords do not hide a real unguarded loop" {
  # bin/found-issues embeds awk programs and heredoc'd Node/Python/bash blocks
  # whose loop keywords are text, not shell structure. A while/done counter
  # drifts on those (13 too high by EOF in the real file) and then pops the
  # wrong entry, MISSING a genuinely unguarded loop. The unguarded loop below
  # sits after the noise and must still be reported.
  cat >"$BATS_TEST_TMPDIR/noisy.sh" <<'SAMPLE'
emit() {
  awk '
    for (i = 0; i < 3; i++) { print i }
  ' "$1"
  cat <<'BLOCK'
for x in 1 2 3; do echo $x
while true; do echo hi
BLOCK
}
g() {
  while IFS= read -r line; do
    :
  done <"$file"
}
SAMPLE
  run fi_unguarded_read_loops "$BATS_TEST_TMPDIR/noisy.sh"
  [ "$output" = "$BATS_TEST_TMPDIR/noisy.sh:11" ]
}

@test "source-guards: the detector numbers lines per file, not cumulatively" {
  # awk's NR keeps counting across files; only FNR restarts. With NR the
  # second file's findings are reported at line numbers past its own end,
  # sending a reader to a line that does not exist.
  printf 'x\ny\nz\n' >"$BATS_TEST_TMPDIR/first.sh"
  cat >"$BATS_TEST_TMPDIR/second.sh" <<'SAMPLE'
while IFS= read -r line; do
  :
done <"$file"
SAMPLE
  run fi_unguarded_read_loops "$BATS_TEST_TMPDIR/first.sh" "$BATS_TEST_TMPDIR/second.sh"
  [ "$output" = "$BATS_TEST_TMPDIR/second.sh:1" ]
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
