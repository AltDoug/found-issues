#!/usr/bin/env bats
# v3 sweep: candidates, trigger, claim, run, ship (spec §4.1, §6, §7; phase 4 plan).

load 'helpers'
load 'autofix-helpers'

setup() { fi_setup_tmp; }
teardown() { fi_teardown_tmp; }

@test "sweep: candidates are fixable-now entries, critical first, then file groups, then oldest" {
  fi_af_fixture
  cat > docs/found-issues.md <<'LEDGER'
# found-issues

- [open] 2026-10-02 src/b.sh:1 — b late (fix: medium)
- [open] 2026-10-01 src/a.sh:1 — a oldest (fix: small)
- [open] [!] 2026-10-05 src/c.sh:1 — c critical (fix: medium)
- [open] 2026-10-03 src/a.sh:9 — a later (decided: yes)
- [open] 2026-09-01 src/d.sh:1 — d large (fix: large)
- [open] 2026-09-01 src/e.sh:1 — e question (decide: which?)
- [open] 2026-09-01 src/f.sh:1 — f in a PR (fix: medium) (PR: foo/bar#3)
- [open] 2026-09-01 src/g.sh:1 — g failed before (fix: small) (autofix-failed: tests fail)
- [deferred] 2026-09-01 src/h.sh:1 — h deferred (fix: medium)
LEDGER
  source "$FI_BIN"; fi_af_context
  run fi_af_sweep_candidates docs/found-issues.md "$REPO" 10
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
  [[ "${lines[0]}" == *"c critical"* ]]
  [[ "${lines[1]}" == *"a oldest"* ]]
  [[ "${lines[2]}" == *"a later"* ]]
  [[ "${lines[3]}" == *"b late"* ]]
  run fi_af_sweep_candidates docs/found-issues.md "$REPO" 2
  [ "${#lines[@]}" -eq 2 ]
}

@test "sweep: candidates skip an entry with a queued spot item" {
  fi_af_fixture
  fi_af_queue_fixture
  run fi_af_sweep_candidates docs/found-issues.md "$REPO" 10
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sweep: the fifth fixable entry queues one sweep and prints the marker" {
  fi_af_sweep_fixture 4
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUTOFIX-SWEEP-DUE "* ]]
  id="$(printf '%s\n' "$output" | sed -n 's/^AUTOFIX-SWEEP-DUE //p')"
  f="$FOUND_ISSUES_STATE_DIR/autofix/foo__bar/queue/$id"
  grep -q '^kind=sweep$' "$f"
  grep -q '^loc=sweep$' "$f"
}

@test "sweep: four fixable entries do not queue a sweep" {
  fi_af_sweep_fixture 3
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  [ "$status" -eq 0 ]
  [[ "$output" != *"AUTOFIX-SWEEP-DUE"* ]]
}

@test "sweep: a critical fix medium queues a sweep on its own" {
  fi_af_fixture
  printf '# found-issues\n\n' > docs/found-issues.md
  run "$FI_BIN" log --critical --fix medium 'src/calc.sh:1 — add subtracts'
  [[ "$output" == *"AUTOFIX-SWEEP-DUE "* ]]
}

@test "sweep: a pending sweep or today's cap blocks a second sweep" {
  fi_af_sweep_fixture 5
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  [[ "$output" == *"AUTOFIX-SWEEP-DUE "* ]]
  run "$FI_BIN" log --fix medium 'src/calc.sh:2 — add is slow'
  [[ "$output" != *"AUTOFIX-SWEEP-DUE"* ]]
  rm -f "$FOUND_ISSUES_STATE_DIR"/autofix/foo__bar/queue/*
  printf 'x\n' > "$FOUND_ISSUES_STATE_DIR/autofix/foo__bar/day/$(date +%Y-%m-%d).sweep"
  run "$FI_BIN" log --fix medium 'src/calc.sh:3 — add is loud'
  [[ "$output" != *"AUTOFIX-SWEEP-DUE"* ]]
}

@test "sweep: auto-fix off queues nothing" {
  fi_af_sweep_fixture 5
  git config found-issues.autofix false
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  [[ "$output" != *"AUTOFIX-SWEEP-DUE"* ]]
}

@test "sweep: tag and decide also trigger" {
  fi_af_sweep_fixture 4
  "$FI_BIN" log 'src/calc.sh:1 — add subtracts' >/dev/null
  run "$FI_BIN" tag 'add subtracts' --fix medium
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUTOFIX-SWEEP-DUE "* ]]
}

@test "sweep: an answered decision triggers through decide" {
  fi_af_sweep_fixture 4
  "$FI_BIN" log --decide 'which way?' 'src/calc.sh:1 — add subtracts' >/dev/null
  run "$FI_BIN" decide 'add subtracts' --answer 'add them'
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUTOFIX-SWEEP-DUE "* ]]
}

@test "sweep: inside a fixer the sweep is queued without the marker" {
  fi_af_sweep_fixture 4
  FOUND_ISSUES_AUTOFIX_CHILD=1 run "$FI_BIN" log --fix medium 'src/calc.sh:1 — add subtracts'
  [[ "$output" != *"AUTOFIX-SWEEP-DUE"* ]]
  [[ "$output" == *"sweep queued"* ]]
}

@test "sweep: an entry sync wakes can make a sweep due" {
  fi_af_sweep_fixture 4
  export PATH="$TEST_REPO_ROOT/tests/bin-shims:$PATH"
  printf -- '- [deferred] 2026-09-01 src/calc.sh:1 — add subtracts (fix: medium) (until: date:2026-01-01)\n' >> docs/found-issues.md
  run "$FI_BIN" sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"Woke: 1."* ]]
  [[ "$output" == *"AUTOFIX-SWEEP-DUE "* ]]
}

@test "sweep: status shows today's sweeps against the cap" {
  fi_af_fixture
  run "$FI_BIN" autofix status
  [[ "$output" == *"Today: 0/1 sweeps"* ]]
}
