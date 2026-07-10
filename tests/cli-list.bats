#!/usr/bin/env bats
# Tests for `found-issues list`

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
  TODAY="$(date +%Y-%m-%d)"
  mkdir -p docs
  cat > docs/found-issues.md <<EOF
# found-issues

- [open] $TODAY src/a.sh:10 — plain open symptom (suggested: fix a)
- [open] [!] $TODAY src/b.sh:20 — critical "quoted" symptom (PR: org/repo#5)
- [deferred] $TODAY src/c.sh — parked symptom (reason: waiting) (mute-until: 2099-01-01)
- [fixed] $TODAY src/d.sh:40 — done symptom (commit: abc1234) (fixed: $TODAY)
EOF
}

teardown() {
  fi_teardown_tmp
}

@test "list defaults to open entries only" {
  fi_run list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == *"src/a.sh:10"* ]]
  [[ "${lines[1]}" == *"src/b.sh:20"* ]]
}

@test "list --status=deferred filters to deferred" {
  fi_run list --status=deferred
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *"src/c.sh"* ]]
}

@test "list --status=all prints every entry" {
  fi_run list --status=all
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "list --json emits an array with typed fields" {
  fi_run list --json
  [ "$status" -eq 0 ]
  [[ "$output" == "["* ]]
  [[ "$output" == *"]" ]]
  [[ "$output" == *'"path":"src/a.sh"'* ]]
  [[ "$output" == *'"line":10'* ]]
  [[ "$output" == *'"critical":true'* ]]
  [[ "$output" == *'"prs":"org/repo#5"'* ]]
}

@test "list --json escapes double quotes inside symptoms" {
  fi_run list --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'critical \"quoted\" symptom'* ]]
}

@test "list --json carries the file line number as line_no" {
  fi_run list --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"line_no":3'* ]]
  [[ "$output" == *'"line_no":4'* ]]
}

@test "list --status=deferred --json includes mute_until" {
  fi_run list --status=deferred --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"mute_until":"2099-01-01"'* ]]
}

@test "list with no ledger file prints nothing and exits 0" {
  rm docs/found-issues.md
  fi_run list
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f docs/found-issues.md ]
}

@test "list --json with no ledger file prints empty array" {
  rm docs/found-issues.md
  fi_run list --json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
  [ ! -f docs/found-issues.md ]
}

@test "list rejects an unknown status filter with exit 2" {
  fi_run list --status=bogus
  [ "$status" -eq 2 ]
}

@test "list rejects an unknown option with exit 2" {
  fi_run list --frobnicate
  [ "$status" -eq 2 ]
}

@test "list excludes entries inside merge-conflict blocks" {
  cat > docs/found-issues.md <<EOF
- [open] $TODAY a.sh:1 — outside
<<<<<<< HEAD
- [open] $TODAY b.sh:2 — ours
=======
- [open] $TODAY c.sh:3 — theirs
>>>>>>> other
EOF
  fi_run list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *"a.sh:1"* ]]
}

@test "list resolves via CLAUDE_PROJECT_DIR when cwd is outside the repo" {
  proj="$TMP"
  cd /
  CLAUDE_PROJECT_DIR="$proj" fi_run list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  cd "$TMP"
}

@test "list --cwd resolves against the given directory" {
  proj="$TMP"
  cd /
  fi_run list --cwd "$proj"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  cd "$TMP"
}

@test "list walks up from a subdirectory like status does" {
  mkdir -p sub/deeper
  cd sub/deeper
  fi_run list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  cd "$TMP"
}

@test "list --status with missing value errors with exit 2 and a message" {
  fi_run list --status
  [ "$status" -eq 2 ]
  [[ "$output" == *"--status"* ]]
}

@test "list --json stays valid JSON when an entry contains a control character" {
  printf -- '- [open] %s ctl.sh:1 — bad \x1b[31mansi\x1b[0m paste\n' "$TODAY" >> docs/found-issues.md
  fi_run list --json
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\x1b'* ]]
  [[ "$output" == *'"path":"ctl.sh"'* ]]
}

@test "list --json normalizes leading-zero line numbers to valid JSON" {
  printf -- '- [open] %s zero.sh:007 — leading zero line ref\n' "$TODAY" >> docs/found-issues.md
  fi_run list --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"line":7'* ]]
  [[ "$output" != *'"line":007'* ]]
}
