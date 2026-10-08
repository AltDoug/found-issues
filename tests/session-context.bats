#!/usr/bin/env bats
# lib/session-context.sh: entry selectors for the lean session start (3.4.0).

load 'helpers'

setup() {
  fi_setup_tmp; fi_init_git
  mkdir -p docs src
  printf '1\n2\n3\n' > src/a.sh; printf '1\n' > src/b.sh; printf 'x\n' > tool
  cat > docs/found-issues.md <<'EOT'
# found-issues

- [open] 2026-10-01 src/a.sh:2 — alpha bug (suggested: fix a)
- [open] 2026-10-02 src/a.sh:10-20 — range bug in a
- [open] 2026-10-03 src/b.sh:1 — beta bug
- [fixed] 2026-10-03 src/a.sh:3 — old fixed bug
- [open] 2026-10-04 workflow/release-process — topic one
- [open] 2026-10-05 tool (subcommand x) — existing file, no line
- [open] 2026-10-06 ghost/path.sh:4 — file never existed
- [open] [!] 2026-10-07 nowhere/crit.sh:1 — critical pathless
EOT
  source "$FI_BIN"
}
teardown() { fi_teardown_tmp; }

@test "session-context: entries_for_path matches the exact path, open only" {
  run fi_sc_entries_for_path docs/found-issues.md src/a.sh
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^- \[open\]')" -eq 2 ]
  [[ "$output" == *"alpha bug"* ]]
  [[ "$output" != *"old fixed bug"* ]]
  [[ "$output" != *"beta bug"* ]]
}

@test "session-context: range location matches by path" {
  run fi_sc_entries_for_path docs/found-issues.md src/a.sh
  [[ "$output" == *"range bug in a"* ]]
}

@test "session-context: a prefix path does not match a longer one" {
  printf '1\n' > src/a.shx
  printf -- '- [open] 2026-10-08 src/a.shx:1 — prefix trap\n' >> docs/found-issues.md
  run fi_sc_entries_for_path docs/found-issues.md src/a.sh
  [[ "$output" != *"prefix trap"* ]]
}

@test "session-context: pathless lists missing paths newest first, skips criticals, honours max" {
  open="$(fi_entries docs/found-issues.md open)"
  run fi_sc_pathless "$open" "$PWD" 3
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | head -n 1 | grep -c 'ghost/path.sh')" -eq 1 ]
  [[ "$output" == *"workflow/release-process"* ]]
  [[ "$output" != *"critical pathless"* ]]
  [[ "$output" != *"alpha bug"* ]]
  run fi_sc_pathless "$open" "$PWD" 1
  [ "$(printf '%s\n' "$output" | grep -c '^- ')" -eq 1 ]
}

@test "session-context: existing path without a line is not path-less" {
  open="$(fi_entries docs/found-issues.md open)"
  run fi_sc_pathless "$open" "$PWD" 5
  [[ "$output" != *"existing file, no line"* ]]
}

@test "session-context: list --path prints only that file's open entries" {
  run "$FI_BIN" list --path src/a.sh
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^- \[open\]')" -eq 2 ]
  run "$FI_BIN" list --path
  [ "$status" -eq 2 ]
}
