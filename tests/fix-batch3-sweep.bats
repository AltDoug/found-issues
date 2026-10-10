#!/usr/bin/env bats
# Ledger batch 3: annotate retry on a changed ledger, stale re-check at sweep
# load, a no-test-command sweep retire counts against the day's sweep cap.

load 'helpers'
load 'autofix-helpers'

setup() { fi_setup_tmp; }
teardown() { fi_teardown_tmp; }

sweep_queue() { # queue a sweep for the fixture; sets SID and ST
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  SID="$(printf '%s\n' "$output" | sed -n 's/^AUTOFIX-SWEEP-DUE //p')"
  ST="$FOUND_ISSUES_STATE_DIR/autofix/foo__bar"
  [ -n "$SID" ]
}

@test "batch3 ship: an annotation that hits a changed ledger is retried" {
  fi_af_sweep_fixture 2
  source "$FI_BIN"; fi_af_context
  eval "$(declare -f fi_ledger_replace | sed '1s/fi_ledger_replace/orig_ledger_replace/')"
  RACES=0
  fi_ledger_replace() {
    if (( RACES < 1 )); then
      RACES=$((RACES + 1))
      printf -- '- [open] 2026-10-09 src/zz.sh:1 — raced in (fix: small)\n' >> docs/found-issues.md
    fi
    orig_ledger_replace "$@"
  }
  AFI_root="$REPO"
  entry="$(grep -m1 '^- \[open\]' docs/found-issues.md)"
  fi_entry_dedup_key_v "$entry" "$REPO"
  AFI_key="$FI_KEY"
  fi_af_annotate_ledger "" "(PR: foo/bar#7)"
  grep -F 'f1 subtracts one' docs/found-issues.md | grep -q '(PR: foo/bar#7)'
  grep -q 'raced in' docs/found-issues.md
}

@test "batch3 sweep load: an entry resolved mid-sweep is skipped, not fixed" {
  fi_af_sweep_fixture 4; fi_use_standins; sweep_queue
  "$FI_BIN" autofix claim "$SID" >/dev/null
  source "$FI_BIN"; fi_af_context
  fi_af_item_read "$ST/running/$SID"
  first="$(sed -n 1p "$ST/sweeps/$SID.entries")"
  fi_entry_loc_v "$first"; firstloc="$FE_loc"
  fi_entry_dedup_key_v "$first" "$REPO"
  firstkey="$FI_KEY"
  # The operator retags that entry to large while the sweep is running.
  sed -i.bak "s|^\(- \[open\].* $firstloc — .*\)(fix: medium)|\1(fix: large)|" docs/found-issues.md
  rm -f docs/found-issues.md.bak
  grep -q "$firstloc.*(fix: large)" docs/found-issues.md
  fi_af_sweep_load "$SID"
  [ "$AFI_cur" = 2 ]
  [ "$AFI_loc" != "$firstloc" ]
  grep -q "^$firstloc	skipped	" "$ST/sweeps/$SID.outcomes"
  grep -q '^cur=2$' "$ST/running/$SID"
}

@test "batch3 sweep claim: a no-test-command retire uses the day's cap so the next check queues nothing" {
  fi_af_sweep_fixture 4; fi_use_standins
  git config --unset found-issues.autofix.testCommand
  # The root checkout has a test command (an untracked bats dir); the
  # landing branch, origin/main, does not.
  mkdir -p tests && printf '@test "x" { true; }\n' > tests/x.bats
  sweep_queue
  run "$FI_BIN" autofix claim "$SID"
  [ "$status" -eq 5 ]
  grep -q '^result=stale: no test command$' "$ST/done/$SID"
  source "$FI_BIN"; fi_af_context
  run fi_af_sweep_check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$(ls "$ST/queue" 2>/dev/null)" ]
}
