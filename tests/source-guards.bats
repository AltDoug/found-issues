#!/usr/bin/env bats
# Static source guards over the shell sources (bin/, lib/, hooks/, scripts/).
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

# Per-test tmpdir via the suite's own helper rather than BATS_TEST_TMPDIR:
# that variable only exists in bats >= 1.4, and this suite runs on apt bats
# (ubuntu), brew bats-core (macOS) and npm bats (Windows Git Bash). Every other
# test file here uses fi_setup_tmp, so it is the portable, already-proven path.
setup() { fi_setup_tmp; }
teardown() { fi_teardown_tmp; }

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
# The per-file line counter `n` resets on FNR == 1 rather than riding awk's NR:
# NR keeps counting across files, so a multi-file scan would report line numbers
# past the end of the file it names.
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
      # Whitespace is what separates the two forms, so test BEFORE stripping:
      # a here-string is "<<<" (another "<" immediately), while process
      # substitution is "< <(" (a space, then "<("). Stripping first collapses
      # them and the exemptions below cannot be told apart.
      #
      # here-strings are exempt unconditionally: bash appends a trailing
      # newline, so a final partial line cannot exist.
      if (rest ~ /^</) next
      sub(/^[[:space:]]+/, "", rest)
      if (rest ~ /^<\(/) {
        # Process substitution is exempt only for producers KNOWN to emit
        # newline-terminated output -- today just fi_entries, which is awk
        # (awk terminates every record with ORS even when its input did not).
        # It is NOT safe in general: `< <(cat "$file")` and
        # `< <(git show ref:path)` hand a missing trailing newline straight
        # through and carry the identical bug, so they must still be guarded.
        if (rest ~ /^<\([[:space:]]*fi_entries[[:space:]]/) next
      }
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
  cat >"$TMP/sample.sh" <<'SAMPLE'
f() {
  while IFS= read -r line; do
    printf '%s\n' "$line"
  done <"$file"
}
SAMPLE
  run fi_unguarded_read_loops "$TMP/sample.sh"
  [ "$output" = "$TMP/sample.sh:2" ]
}

@test "source-guards: embedded loop keywords do not hide a real unguarded loop" {
  # bin/found-issues embeds awk programs and heredoc'd Node/Python/bash blocks
  # whose loop keywords are text, not shell structure. A while/done counter
  # drifts on those (13 too high by EOF in the real file) and then pops the
  # wrong entry, MISSING a genuinely unguarded loop. The unguarded loop below
  # sits after the noise and must still be reported.
  cat >"$TMP/noisy.sh" <<'SAMPLE'
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
  run fi_unguarded_read_loops "$TMP/noisy.sh"
  [ "$output" = "$TMP/noisy.sh:11" ]
}

@test "source-guards: the detector numbers lines per file, not cumulatively" {
  # awk's NR keeps counting across files; only FNR restarts. With NR the
  # second file's findings are reported at line numbers past its own end,
  # sending a reader to a line that does not exist.
  printf 'x\ny\nz\n' >"$TMP/first.sh"
  cat >"$TMP/second.sh" <<'SAMPLE'
while IFS= read -r line; do
  :
done <"$file"
SAMPLE
  run fi_unguarded_read_loops "$TMP/first.sh" "$TMP/second.sh"
  [ "$output" = "$TMP/second.sh:1" ]
}

@test "source-guards: the detector accepts a guarded loop and exempt feeds" {
  cat >"$TMP/ok.sh" <<'SAMPLE'
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
  run fi_unguarded_read_loops "$TMP/ok.sh"
  [ -z "$output" ]
}

@test "source-guards: process substitution is exempt only for known-safe producers" {
  # `< <(fi_entries ...)` is awk-backed, so every record is newline-terminated
  # regardless of the input file. `cat` and `git show` are not -- they hand the
  # missing trailing newline straight through, so a loop fed by either carries
  # the identical bug and must still be guarded. A blanket process-substitution
  # exemption would call all three of these clean.
  cat >"$TMP/procsub.sh" <<'SAMPLE'
f() {
  while IFS= read -r line; do
    :
  done < <(fi_entries "$file" open)
  while IFS= read -r line; do
    :
  done < <(cat "$file")
  while IFS= read -r line; do
    :
  done < <(git show "$ref:$path")
}
SAMPLE
  run fi_unguarded_read_loops "$TMP/procsub.sh"
  [ "$output" = "$TMP/procsub.sh:5
$TMP/procsub.sh:8" ]
}
