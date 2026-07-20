#!/usr/bin/env bats
# Unit tests for fi_diff_old_ranges (bin/found-issues) — the function that
# converts a unified diff into OLD-side "path<TAB>start<TAB>end" removal
# ranges used by --hook-auto line matching.
#
# Sourced directly (bin/found-issues only calls main when executed, not when
# sourced) so the pure awk parser can be exercised in isolation with hand-
# crafted diffs that the ledger grammar can't express (e.g. paths with
# spaces).

load 'helpers'

setup() { fi_setup_tmp; }
teardown() { fi_teardown_tmp; }

# Run fi_diff_old_ranges over the diff on stdin, capturing its output.
ranges() { # stdin: unified diff
  run bash -c 'source "'"$FI_BIN"'" >/dev/null 2>&1; fi_diff_old_ranges'
}

@test "old-ranges: a single removal emits only the removed line, not the whole hunk" {
  ranges <<'DIFF'
diff --git a/src/foo.py b/src/foo.py
--- a/src/foo.py
+++ b/src/foo.py
@@ -40,6 +40,7 @@
 ctx40
 ctx41
-old42
+new42
+added
 ctx43
 ctx44
 ctx45
DIFF
  [ "$status" -eq 0 ]
  [ "$output" = $'src/foo.py\t42\t42' ]
}

@test "old-ranges: context-only proximity does NOT put the cited line in a range" {
  # The critical bug: a change 3 lines BELOW line 40 sits in the same hunk as
  # line 40 (3 lines of leading context), but line 40 is untouched context.
  # The old whole-hunk emitter wrongly included 40; the body parser must not.
  ranges <<'DIFF'
diff --git a/src/foo.py b/src/foo.py
--- a/src/foo.py
+++ b/src/foo.py
@@ -40,7 +40,7 @@
 ctx40
 ctx41
 ctx42
-old43
+new43
 ctx44
 ctx45
 ctx46
DIFF
  [ "$status" -eq 0 ]
  [ "$output" = $'src/foo.py\t43\t43' ]
  # line 40 (the cited context line) must be OUTSIDE the emitted range
  [[ "$output" != *$'\t40\t'* ]]
}

@test "old-ranges: a pure-addition hunk emits no range" {
  ranges <<'DIFF'
diff --git a/src/foo.py b/src/foo.py
--- a/src/foo.py
+++ b/src/foo.py
@@ -40,3 +40,4 @@
 ctx40
+inserted
 ctx41
 ctx42
DIFF
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "old-ranges: a brand-new file (--- /dev/null) emits no range" {
  ranges <<'DIFF'
diff --git a/src/new.py b/src/new.py
new file mode 100644
--- /dev/null
+++ b/src/new.py
@@ -0,0 +1,3 @@
+line1
+line2
+line3
DIFF
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "old-ranges: contiguous removals collapse into one run" {
  ranges <<'DIFF'
diff --git a/src/foo.py b/src/foo.py
--- a/src/foo.py
+++ b/src/foo.py
@@ -10,5 +10,3 @@
 ctx10
-del11
-del12
-del13
 ctx14
DIFF
  [ "$status" -eq 0 ]
  [ "$output" = $'src/foo.py\t11\t13' ]
}

@test "old-ranges: a deleted '-- comment' line is not misread as a file header" {
  # A deleted SQL comment ('-- foo') becomes '--- foo' in the diff and used to
  # match the '^--- ' file-header regex, corrupting path attribution for the
  # NEXT hunk in the same file. With header-state tracking it stays a removal.
  ranges <<'DIFF'
diff --git a/db/schema.sql b/db/schema.sql
--- a/db/schema.sql
+++ b/db/schema.sql
@@ -10,3 +10,3 @@
 ctx10
--- old comment
+-- new comment
 ctx12
@@ -50,3 +50,3 @@
 ctx50
-old51
+new51
 ctx52
DIFF
  [ "$status" -eq 0 ]
  # Both hunks attribute to db/schema.sql — the second is NOT stolen by a
  # bogus "old comment" path.
  [[ "$output" == *$'db/schema.sql\t11\t11'* ]]
  [[ "$output" == *$'db/schema.sql\t51\t51'* ]]
  [[ "$output" != *"comment"* ]]
}

@test "old-ranges: a path containing a space parses fully (not truncated at the space)" {
  ranges <<'DIFF'
diff --git a/src/my file.py b/src/my file.py
--- a/src/my file.py
+++ b/src/my file.py
@@ -5,3 +5,3 @@
 ctx5
-old6
+new6
 ctx7
DIFF
  [ "$status" -eq 0 ]
  [ "$output" = $'src/my file.py\t6\t6' ]
}
