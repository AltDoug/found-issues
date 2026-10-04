#!/usr/bin/env bats
# v3.0.0 fix tags (spec docs/superpowers/specs/2026-10-03-autofix-v3-design.md §3).

load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
  mkdir -p docs src
  printf 'x\n' > src/a.sh
  git add -A && git commit -q -m init
}
teardown() { fi_teardown_tmp; }

@test "parser: fix tag and decide/manual/until/decided/autofix-failed come from the tail" {
  fi_source_lib canonicalize
  fi_source_lib parse-entries
  fi_parse_entry_vars "- [open] 2026-10-03 src/a.sh:1 — bug (suggested: x) (fix: medium)"
  [ "$FE_fixtag" = "medium" ]
  [ "$FE_symptom" = "bug" ]
  fi_parse_entry_vars "- [open] 2026-10-03 src/a.sh:1 — bug (decide: A or B?)"
  [ "$FE_decide" = "A or B?" ]
  fi_parse_entry_vars "- [open] 2026-10-03 src/a.sh:1 — bug (decided: A) (fix: small)"
  [ "$FE_decided" = "A" ] && [ "$FE_fixtag" = "small" ]
  fi_parse_entry_vars "- [open] 2026-10-03 src/a.sh:1 — bug (manual: needs a live payload)"
  [ "$FE_manual" = "needs a live payload" ]
  fi_parse_entry_vars "- [deferred] 2026-10-03 src/a.sh:1 — bug (reason: later) (until: date:2026-11-01)"
  [ "$FE_until" = "date:2026-11-01" ]
  fi_parse_entry_vars "- [open] 2026-10-03 src/a.sh:1 — bug (fix: small) (autofix-failed: tests stayed red)"
  [ "$FE_autofix_failed" = "tests stayed red" ]
}

@test "parser: a symptom that mentions (fix: small) mid-line is not tagged" {
  fi_source_lib canonicalize
  fi_source_lib parse-entries
  fi_parse_entry_vars "- [open] 2026-10-03 src/a.sh:1 — docs say (fix: small) but the code disagrees"
  [ -z "$FE_fixtag" ]
}

@test "list --json exposes fix_tag, decide, decided, manual, until, autofix_failed" {
  printf -- '- [open] 2026-10-03 src/a.sh:1 — bug (fix: small)\n- [open] 2026-10-03 src/a.sh:2 — q (decide: A or B?)\n' > docs/found-issues.md
  fi_run list --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.[0].fix_tag == "small" and .[0].decide == null and .[1].decide == "A or B?" and .[1].fix_tag == null and (.[0] | has("until") and has("decided") and has("manual") and has("autofix_failed"))'
}

@test "dedup: re-logging the same symptom with a tag is still a duplicate" {
  printf -- '- [open] 2026-10-03 src/a.sh:1 — bug (fix: small)\n' > docs/found-issues.md
  fi_run log "src/a.sh:1 — bug"
  [[ "$output" == *"already logged"* ]]
  [ "$(grep -c 'src/a.sh:1' docs/found-issues.md)" -eq 1 ]
}
