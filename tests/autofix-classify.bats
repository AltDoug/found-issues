#!/usr/bin/env bats
# v3 sweep classify/wake pass (spec §3.1, §6 steps 2-3; phase 4 plan Task 4).

load 'helpers'
load 'autofix-helpers'

setup() {
  fi_setup_tmp; fi_af_fixture; fi_use_standins
  mkdir -p .github/workflows; printf 'on: push\n' > .github/workflows/ci.yml
  cat > docs/found-issues.md <<'LEDGER'
# found-issues

- [open] 2026-10-01 src/calc.sh:1 — add subtracts
- [open] 2026-10-01 .github/workflows/ci.yml:1 — ci typo
- [open] 2026-10-01 src/calc.sh:1 — already tagged (fix: small)
- [deferred] 2026-10-01 src/calc.sh:1 — waits on upstream (until: when upstream ships 2.0)
- [deferred] 2026-10-01 src/calc.sh:1 — waits on a date (until: date:2099-01-01)
LEDGER
  git add -A && git commit -q -m ledger
  source "$FI_BIN"; fi_af_context
  U1='- [open] 2026-10-01 src/calc.sh:1 — add subtracts'
  U2='- [open] 2026-10-01 .github/workflows/ci.yml:1 — ci typo'
  W1='- [deferred] 2026-10-01 src/calc.sh:1 — waits on upstream (until: when upstream ships 2.0)'
  printf 'U1\t%s\nU2\t%s\nW1\t%s\n' "$U1" "$U2" "$W1" > "$TMP/list"
  AFI_root="$REPO"
}
teardown() { fi_teardown_tmp; }

@test "classify apply: valid tags and wakes are written" {
  fi_af_classify_apply docs/found-issues.md '{"tags":[{"n":"U1","kind":"fix","value":"medium"}],"wake":["W1"]}' "$TMP/list"
  grep -qxF -- '- [open] 2026-10-01 src/calc.sh:1 — add subtracts (fix: medium)' docs/found-issues.md
  grep -qxF -- '- [open] 2026-10-01 src/calc.sh:1 — waits on upstream' docs/found-issues.md
}

@test "classify apply: an off-limits path classified fix becomes manual" {
  fi_af_classify_apply docs/found-issues.md '{"tags":[{"n":"U2","kind":"fix","value":"small"}],"wake":[]}' "$TMP/list"
  grep -F 'ci typo' docs/found-issues.md | grep -q '(manual: off-limits: ci)'
}

@test "classify apply: classifier garbage writes nothing" {
  before="$(cksum < docs/found-issues.md)"
  fi_af_classify_apply docs/found-issues.md 'no json here' "$TMP/list"
  fi_af_classify_apply docs/found-issues.md '{"tags":[{"n":"U9","kind":"fix","value":"small"},{"n":"U1","kind":"fix","value":"huge"},{"n":"U1","kind":"rm -rf","value":"x"},{"n":"W1","kind":"fix","value":"small"}],"wake":["W7","U1"]}' "$TMP/list"
  fi_af_classify_apply docs/found-issues.md '{"tags":"nope","wake":7}' "$TMP/list"
  [ "$(cksum < docs/found-issues.md)" = "$before" ]
}

@test "classify: the pass sees only untagged open and free-text deferred entries" {
  export FI_STANDIN_CLASSIFY='{"tags":[{"n":"U1","kind":"fix","value":"small"}],"wake":[]}'
  AFI_wt="$REPO" AFI_id=c1 AFI_engine=claude
  fi_af_classify docs/found-issues.md c1
  grep -qxF -- '- [open] 2026-10-01 src/calc.sh:1 — add subtracts (fix: small)' docs/found-issues.md
  p="$(tr '\037' '\n' < "$FI_STANDIN_TRACE")"
  [[ "$p" == *"found-issues classifier"* ]]
  [[ "$p" == *"U1"*"add subtracts"* ]]
  [[ "$p" == *"W1"*"waits on upstream"* ]]
  [[ "$p" != *"already tagged"* ]]
  [[ "$p" != *"waits on a date"* ]]
  grep -q -- '--allowedTools' "$FI_STANDIN_TRACE"
  # 3.3.1: restricted, no MCP, read-only tools only, no sandbox settings
  t="$(tr '\037' '\n' < "$FI_STANDIN_TRACE")"
  [[ "$t" == *$'\n--restricted\n'* ]]
  [[ "$t" == *$'\n--strict-mcp-config\n'* ]]
  [[ "$t" == *$'\n--tools\nRead\nGlob\nGrep\n--'* ]]
  [[ "$t" != *$'\n--settings\n'* ]]
}

@test "classify: a failed engine turn tags nothing, even when its text looks like an answer" {
  export FI_STANDIN_ERROR='{"tags":[{"n":"U1","kind":"fix","value":"small"}],"wake":[]}'
  AFI_wt="$REPO" AFI_id=c1 AFI_engine=claude AFI_root="$REPO"
  before="$(cksum < docs/found-issues.md)"
  fi_af_classify docs/found-issues.md c1
  [ "$(cksum < docs/found-issues.md)" = "$before" ]
  grep -q 'classify: engine error: ' "$FI_AF_RUNS/c1.log"
  [ ! -s "$FI_AF_ST/classify-offered" ]
  unset FI_STANDIN_ERROR
  export FI_STANDIN_CODEX_FAIL=read-only
  AFI_engine=codex
  fi_af_classify docs/found-issues.md c2
  [ "$(cksum < docs/found-issues.md)" = "$before" ]
  grep -q 'classify: engine error: ' "$FI_AF_RUNS/c2.log"
  [ ! -s "$FI_AF_ST/classify-offered" ]
}

@test "classify: nothing to classify runs no model" {
  printf '# found-issues\n\n- [open] 2026-10-01 src/calc.sh:1 — tagged (fix: small)\n' > docs/found-issues.md
  AFI_wt="$REPO" AFI_id=c1 AFI_engine=claude
  fi_af_classify docs/found-issues.md c1
  [ ! -s "$FI_STANDIN_TRACE" ]
}

@test "classify: an engine missing from PATH leaves a skipped line in the run log" {
  AFI_wt="$REPO" AFI_id=c1 AFI_engine=claude
  PATH="/usr/bin:/bin" fi_af_classify docs/found-issues.md c1
  grep -q 'classify: skipped (no engine on PATH)' "$FI_AF_RUNS/c1.log"
}

@test "classify: a sweep claim classifies before it picks entries" {
  printf '# found-issues\n\n' > docs/found-issues.md
  # 3 tagged + 1 untagged = 4: below the threshold (untagged entries count).
  for i in 1 2 3; do printf -- '- [open] 2026-10-01 src/calc.sh:1 — bug %s (fix: medium)\n' "$i" >> docs/found-issues.md; done
  printf -- '- [open] 2026-10-01 src/calc.sh:1 — untagged bug\n' >> docs/found-issues.md
  git add -A && git commit -q -m l && git push -q origin main
  export FI_STANDIN_CLASSIFY='{"tags":[{"n":"U1","kind":"fix","value":"medium"}],"wake":[]}'
  run "$FI_BIN" tag 'bug 3' --fix medium
  SID="$(printf '%s\n' "$output" | sed -n 's/^AUTOFIX-SWEEP-DUE //p')"
  [ -z "$SID" ]
  run "$FI_BIN" log --fix medium 'src/calc.sh:1 — bug 5'
  SID="$(printf '%s\n' "$output" | sed -n 's/^AUTOFIX-SWEEP-DUE //p')"
  [ -n "$SID" ]
  "$FI_BIN" autofix claim "$SID" >/dev/null
  grep -q 'untagged bug' "$FI_AF_ST/sweeps/$SID.entries"
}
