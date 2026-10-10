#!/usr/bin/env bats
# found-issues unannotate <match> <ref> -- strip exactly one annotation marker
# ((PR:), (PR-auto:), (commit:), (commit-auto:)) from one [open] entry.
load 'helpers'

setup() { fi_setup_tmp; fi_init_git; }
teardown() { fi_teardown_tmp; }

seed_line() {
  mkdir -p docs
  printf -- '%s\n' "$1" >> docs/found-issues.md
}

@test "unannotate: strips (PR: o/r#N) by #N and leaves the rest byte-identical" {
  seed_line '- [open] 2026-10-01 src/a.py:3 — bug here (suggested: fix it) (PR: foo/bar#12) (fix: small)'
  fi_run unannotate 'src/a.py:3' '#12'
  [ "$status" -eq 0 ]
  [ "$(cat docs/found-issues.md)" = '- [open] 2026-10-01 src/a.py:3 — bug here (suggested: fix it) (fix: small)' ]
}

@test "unannotate: a bare number and a full o/r#N ref select the same PR marker" {
  seed_line '- [open] 2026-10-01 src/a.py:3 — bug here (PR: foo/bar#12)'
  fi_run unannotate 'src/a.py:3' 12
  [ "$status" -eq 0 ]
  [ "$(cat docs/found-issues.md)" = '- [open] 2026-10-01 src/a.py:3 — bug here' ]
  seed_line '- [open] 2026-10-01 src/b.py:3 — other bug (PR: foo/bar#12)'
  fi_run unannotate 'src/b.py:3' 'foo/bar#12'
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 docs/found-issues.md)" = '- [open] 2026-10-01 src/b.py:3 — other bug' ]
}

@test "unannotate: a full ref for another repo does not match" {
  seed_line '- [open] 2026-10-01 src/a.py:3 — bug here (PR: foo/bar#12)'
  fi_run unannotate 'src/a.py:3' 'other/repo#12'
  [ "$status" -eq 1 ]
  grep -q '(PR: foo/bar#12)' docs/found-issues.md
}

@test "unannotate: strips a (PR-auto:) suggestion" {
  seed_line '- [open] 2026-10-01 src/a.py:3 — bug here (PR-auto: foo/bar#12)'
  fi_run unannotate 'src/a.py:3' 'foo/bar#12'
  [ "$status" -eq 0 ]
  [ "$(cat docs/found-issues.md)" = '- [open] 2026-10-01 src/a.py:3 — bug here' ]
}

@test "unannotate: strips (commit: sha) by a sha prefix, keeping a neighbouring PR marker" {
  seed_line '- [open] 2026-10-01 src/a.py:3 — bug here (PR: foo/bar#12) (commit: abc1234)'
  fi_run unannotate 'src/a.py:3' abc12
  [ "$status" -eq 0 ]
  [ "$(cat docs/found-issues.md)" = '- [open] 2026-10-01 src/a.py:3 — bug here (PR: foo/bar#12)' ]
}

@test "unannotate: strips (commit-auto: sha) from the middle of the tail" {
  seed_line '- [open] 2026-10-01 src/a.py:3 — bug here (commit-auto: abc1234) (fix: small)'
  fi_run unannotate 'src/a.py:3' abc1234
  [ "$status" -eq 0 ]
  [ "$(cat docs/found-issues.md)" = '- [open] 2026-10-01 src/a.py:3 — bug here (fix: small)' ]
}

@test "unannotate: leaves other entries untouched" {
  seed_line '- [open] 2026-10-01 src/a.py:3 — bug here (PR: foo/bar#12)'
  seed_line '- [open] 2026-10-01 src/b.py:9 — another (PR: foo/bar#12)'
  fi_run unannotate 'src/a.py:3' 12
  [ "$status" -eq 0 ]
  [ "$(sed -n 2p docs/found-issues.md)" = '- [open] 2026-10-01 src/b.py:9 — another (PR: foo/bar#12)' ]
}

@test "unannotate: preserves a CRLF line ending" {
  mkdir -p docs
  printf -- '- [open] 2026-10-01 src/a.py:3 — bug here (PR: foo/bar#12)\r\n' > docs/found-issues.md
  fi_run unannotate 'src/a.py:3' 12
  [ "$status" -eq 0 ]
  [ "$(od -c docs/found-issues.md | tail -n 3 | tr -d ' \n' | grep -c '\\r\\n')" -eq 1 ]
  ! grep -q 'PR:' docs/found-issues.md || false
}

@test "unannotate: ambiguous match exits 2 and changes nothing" {
  seed_line '- [open] 2026-10-01 src/a.py:3 — bug one (PR: foo/bar#12)'
  seed_line '- [open] 2026-10-01 src/a.py:4 — bug two (PR: foo/bar#12)'
  before="$(cat docs/found-issues.md)"
  fi_run unannotate 'src/a.py' 12
  [ "$status" -eq 2 ]
  [ "$(cat docs/found-issues.md)" = "$before" ]
}

@test "unannotate: no matching entry exits 1" {
  seed_line '- [open] 2026-10-01 src/a.py:3 — bug here (PR: foo/bar#12)'
  fi_run unannotate 'nothing-like-this' 12
  [ "$status" -eq 1 ]
}

@test "unannotate: entry without that marker exits 1 and changes nothing" {
  seed_line '- [open] 2026-10-01 src/a.py:3 — bug here (PR: foo/bar#12)'
  before="$(cat docs/found-issues.md)"
  fi_run unannotate 'src/a.py:3' 99
  [ "$status" -eq 1 ]
  [ "$(cat docs/found-issues.md)" = "$before" ]
}

@test "unannotate: marker-like text inside the symptom is not an annotation" {
  seed_line '- [open] 2026-10-01 src/a.py:3 — the text (PR: foo/bar#12) is prose here and more words follow'
  fi_run unannotate 'src/a.py:3' 12
  [ "$status" -eq 1 ]
}

@test "unannotate: refuses a [fixed] entry with exit 3" {
  seed_line '- [fixed] 2026-10-01 src/a.py:3 — bug here (PR: foo/bar#12) (fixed: 2026-10-02)'
  before="$(cat docs/found-issues.md)"
  fi_run unannotate 'src/a.py:3' 12
  [ "$status" -eq 3 ]
  [ "$(cat docs/found-issues.md)" = "$before" ]
}

@test "unannotate: usage errors exit 2" {
  fi_run unannotate
  [ "$status" -eq 2 ]
  fi_run unannotate 'src/a.py:3'
  [ "$status" -eq 2 ]
  seed_line '- [open] 2026-10-01 src/a.py:3 — bug here (PR: foo/bar#12)'
  fi_run unannotate 'src/a.py:3' 'not a ref!'
  [ "$status" -eq 2 ]
  fi_run unannotate --bogus a b
  [ "$status" -eq 2 ]
}

@test "unannotate: --help exits 0 and the verb is listed in found-issues help" {
  fi_run unannotate --help
  [ "$status" -eq 0 ]
  fi_run help
  [[ "$output" == *"unannotate <match> <ref>"* ]]
}

@test "unannotate: the entry is still counted and the status line is printed" {
  seed_line '- [open] 2026-10-01 src/a.py:3 — bug here (PR: foo/bar#12)'
  fi_run unannotate 'src/a.py:3' 12
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removed (PR: foo/bar#12)"* ]]
}
