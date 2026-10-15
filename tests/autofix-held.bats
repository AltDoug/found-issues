#!/usr/bin/env bats
# 3.10.0 review fixes: auto-fix never queues a held entry, the already-fixed
# hold/close respects CRLF and the annotation tail, and a differently-cased
# ledger is reverted inside a fixer worktree.

load 'helpers'
load 'autofix-helpers'

setup() { fi_setup_tmp; }
teardown() { fi_teardown_tmp; }

@test "held: a (hold: ...) entry is not fixable now, a hold in the symptom is" {
  fi_af_fixture
  source "$FI_BIN"; fi_af_context
  run fi_af_fixable_now '- [open] 2026-10-01 src/a.sh:1 — a held (fix: small) (hold: needs human verify)'
  [ "$status" -eq 1 ]
  run fi_af_fixable_now '- [open] 2026-10-01 src/a.sh:1 — says (hold: x) in prose (fix: small)'
  [ "$status" -eq 0 ]
}

@test "held: the sweep candidate list leaves a held entry out" {
  fi_af_fixture
  cat > docs/found-issues.md <<'LEDGER'
# found-issues

- [open] 2026-10-01 src/a.sh:1 — a free (fix: small)
- [open] [!] 2026-10-01 src/b.sh:1 — b held (fix: medium) (hold: needs human verify)
- [open] 2026-10-01 src/c.sh:1 — c held (decided: yes) (hold: owner checks)
LEDGER
  source "$FI_BIN"; fi_af_context
  run fi_af_sweep_candidates docs/found-issues.md "$REPO" 10
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == *"a free"* ]]
}

@test "held: a spot item is not queued for a held entry" {
  fi_af_fixture
  source "$FI_BIN"; fi_af_context
  run fi_af_queue_spot '- [open] 2026-10-01 src/calc.sh:1 — add subtracts (fix: small) (hold: needs human verify)'
  [ "$status" -eq 0 ]
  [[ "$output" != *"AUTOFIX-QUEUED"* ]]
  [ -z "$(ls -A "$FI_AF_ST/queue" 2>/dev/null)" ]
}

@test "held: a queued spot item whose entry is now held is not eligible" {
  fi_af_fixture
  fi_af_queue_fixture
  sed -i.bak 's/(fix: small)$/(fix: small) (hold: needs human verify)/' docs/found-issues.md && rm -f docs/found-issues.md.bak
  AFI_id="$ID"; fi_af_item_read "$QITEM"
  run fi_af_eligible
  [ "$status" -eq 1 ]
}

@test "held: untagged held entries do not count toward the sweep threshold" {
  fi_af_sweep_fixture 0
  printf -- '- [open] 2026-09-01 src/u1.sh:1 — untagged one\n' >> docs/found-issues.md
  printf -- '- [open] 2026-09-02 src/u2.sh:1 — untagged held (hold: owner checks)\n' >> docs/found-issues.md
  source "$FI_BIN"; fi_af_context
  [ "$(_fi_af_untagged_count docs/found-issues.md "$REPO")" -eq 1 ]
}

@test "held: the classifier is not shown a held untagged entry" {
  fi_af_sweep_fixture 0
  printf -- '- [open] 2026-09-01 src/u1.sh:1 — untagged one\n' >> docs/found-issues.md
  printf -- '- [open] 2026-09-02 src/u2.sh:1 — untagged held (hold: owner checks)\n' >> docs/found-issues.md
  source "$FI_BIN"; fi_af_context
  _fi_af_classify_list docs/found-issues.md "$TMP/list"
  grep -q 'untagged one' "$TMP/list"
  ! grep -q 'untagged held' "$TMP/list" || false
}

# --- finding 2: CRLF and the annotation tail in the already-fixed branch ---

crlf_ledger() {
  fi_af_fixture
  printf '# found-issues\r\n\r\n%s\r\n' "$1" > docs/found-issues.md
  fi_af_queue_fixture
  "$FI_BIN" autofix claim "$ID" >/dev/null
}

@test "held: already-fixed on a critical CRLF entry puts the hold before the CR" {
  crlf_ledger '- [open] [!] 2026-10-01 src/calc.sh:1 — add subtracts (fix: small)'
  run "$FI_BIN" autofix release "$ID" --already-fixed "fixed at origin"
  [ "$status" -eq 0 ]
  last="$(grep 'add subtracts' docs/found-issues.md)"
  [ "$last" = $'- [open] [!] 2026-10-01 src/calc.sh:1 \xe2\x80\x94 add subtracts (fix: small) (hold: needs human verify)\r' ]
}

@test "held: already-fixed on a plain CRLF entry keeps the CR at the end" {
  crlf_ledger '- [open] 2026-10-01 src/calc.sh:1 — add subtracts (fix: small)'
  run "$FI_BIN" autofix release "$ID" --already-fixed "fixed at origin"
  [ "$status" -eq 0 ]
  last="$(grep 'add subtracts' docs/found-issues.md)"
  [ "$last" = "- [fixed] 2026-10-01 src/calc.sh:1 — add subtracts (fix: small) (verified: ai) (fixed: $(date +%Y-%m-%d))"$'\r' ]
}

@test "held: a symptom that mentions (hold: ...) in prose is still closed" {
  fi_af_fixture
  printf '# found-issues\n\n- [open] 2026-10-01 src/calc.sh:1 — add subtracts, see (hold: x) note (fix: small)\n' > docs/found-issues.md
  fi_af_queue_fixture
  "$FI_BIN" autofix claim "$ID" >/dev/null
  run "$FI_BIN" autofix release "$ID" --already-fixed "fixed at origin"
  [ "$status" -eq 0 ]
  grep -q '^- \[fixed\] 2026-10-01 src/calc.sh:1 — add subtracts, see (hold: x) note (fix: small) (verified: ai)' docs/found-issues.md
}

# --- finding 3: a differently-cased ledger in a fixer worktree ---

@test "ship: a differently-cased ledger is reverted in the worktree" {
  fi_af_fixture
  mkdir -p Docs
  git mv docs/found-issues.md Docs/Found-Issues.md
  git commit -q -m "recase ledger"
  wt="$TMP/wt"
  git worktree add -q "$wt" HEAD
  ref="$(git -C "$wt" rev-parse HEAD)"
  printf -- '- [fixed] 2026-10-01 src/calc.sh:1 — fixer edit\n' >> "$wt/Docs/Found-Issues.md"
  source "$FI_BIN"; fi_af_context
  fi_af_reset_ledger "$wt" "$ref"
  ! grep -q 'fixer edit' "$wt/Docs/Found-Issues.md" || false
  [ -z "$(git -C "$wt" status --porcelain)" ]
}

@test "ship: a recased ledger the fixer deleted is restored" {
  fi_af_fixture
  mkdir -p Docs
  git mv docs/found-issues.md Docs/Found-Issues.md
  git commit -q -m "recase ledger"
  wt="$TMP/wt"
  git worktree add -q "$wt" HEAD
  ref="$(git -C "$wt" rev-parse HEAD)"
  git -C "$wt" rm -q -f -- Docs/Found-Issues.md
  source "$FI_BIN"; fi_af_context
  fi_af_reset_ledger "$wt" "$ref"
  git -C "$wt" add -A
  [ -z "$(git -C "$wt" status --porcelain)" ]
  git -C "$wt" ls-files | grep -q '^Docs/Found-Issues.md$'
}

# --- 3.10.2 (#164): the archive is reset in the case git tracks it ---

recased_archive_wt() {
  # $1 = tracked archive path, $2 = tracked ledger path
  fi_af_fixture
  mkdir -p Docs
  git mv docs/found-issues.md "$2"
  printf '# archive\n\n- [fixed] 2026-09-01 old.sh:1 — old (verified: ai)\n' > "$1"
  git add -A && git commit -q -m "recase docs"
  wt="$TMP/wt"
  git worktree add -q "$wt" HEAD
  ref="$(git -C "$wt" rev-parse HEAD)"
  source "$FI_BIN"; fi_af_context
}

@test "ship: a tracked Docs/found-issues-archive.md is kept, and a fixer edit reverted (#164)" {
  recased_archive_wt Docs/found-issues-archive.md Docs/Found-Issues.md
  printf -- '- [fixed] 2026-10-01 x.sh:1 — fixer edit\n' >> "$wt/Docs/found-issues-archive.md"
  fi_af_reset_ledger "$wt" "$ref"
  [ -f "$wt/Docs/found-issues-archive.md" ]
  ! grep -q 'fixer edit' "$wt/Docs/found-issues-archive.md" || false
  git -C "$wt" add -A
  [ -z "$(git -C "$wt" status --porcelain)" ]
}

@test "ship: a tracked Docs/Found-Issues-Archive.md fixer edit is reverted (#164)" {
  recased_archive_wt Docs/Found-Issues-Archive.md Docs/Found-Issues.md
  printf -- '- [fixed] 2026-10-01 x.sh:1 — fixer edit\n' >> "$wt/Docs/Found-Issues-Archive.md"
  fi_af_reset_ledger "$wt" "$ref"
  [ -f "$wt/Docs/Found-Issues-Archive.md" ]
  ! grep -q 'fixer edit' "$wt/Docs/Found-Issues-Archive.md" || false
  git -C "$wt" add -A
  [ -z "$(git -C "$wt" status --porcelain)" ]
}

@test "ship: an archive the fixer created is removed, a recased one too (#164)" {
  fi_af_fixture
  mkdir -p Docs
  git mv docs/found-issues.md Docs/Found-Issues.md
  git commit -q -m "recase ledger"
  wt="$TMP/wt"
  git worktree add -q "$wt" HEAD
  ref="$(git -C "$wt" rev-parse HEAD)"
  printf '# a\n' > "$wt/Docs/Found-Issues-Archive.md"
  source "$FI_BIN"; fi_af_context
  fi_af_reset_ledger "$wt" "$ref"
  [ -z "$(git -C "$wt" status --porcelain --untracked-files=all)" ]
}
