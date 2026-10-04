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

@test "offlimits: categories" {
  fi_source_lib canonicalize; fi_source_lib parse-entries; fi_source_lib autofix-tags
  for p in .github/workflows/ci.yml .gitlab-ci.yml .circleci/config.yml Jenkinsfile; do
    run fi_offlimits_category "$p"; [ "$status" -eq 0 ]; [ "$output" = "ci" ]
  done
  for p in .env .env.local certs/server.pem keys/id.key src/auth/login.py lib/auth.sh config/secrets/x.yml credentials.json; do
    run fi_offlimits_category "$p"; [ "$status" -eq 0 ]; [ "$output" = "secrets" ]
  done
  for p in package.json web/package-lock.json yarn.lock pnpm-lock.yaml go.sum Cargo.lock pyproject.toml uv.lock requirements-dev.txt Gemfile.lock; do
    run fi_offlimits_category "$p"; [ "$status" -eq 0 ]; [ "$output" = "dependencies" ]
  done
  for p in db/migrate/001_init.rb app/migrations/0002.py; do
    run fi_offlimits_category "$p"; [ "$status" -eq 0 ]; [ "$output" = "migrations" ]
  done
  for p in /etc/hosts ../other/x.sh; do
    run fi_offlimits_category "$p"; [ "$status" -eq 0 ]; [ "$output" = "outside-repo" ]
  done
}

@test "offlimits: lookalikes are not off-limits" {
  fi_source_lib canonicalize; fi_source_lib parse-entries; fi_source_lib autofix-tags
  for p in src/author.py lib/clock.py blocklist.py tools/migrate_helpers.py docs/package.json.md src/authority/x.ts README.md; do
    run fi_offlimits_category "$p"; [ "$status" -eq 1 ]
  done
}

@test "offlimits_check: untracked and no-file" {
  fi_source_lib canonicalize; fi_source_lib parse-entries; fi_source_lib autofix-tags
  printf 'y\n' > src/new.sh
  run fi_offlimits_check src/new.sh "$TMP"; [ "$status" -eq 0 ]; [ "$output" = "untracked" ]
  run fi_offlimits_check src/a.sh "$TMP"; [ "$status" -eq 1 ]
  run fi_offlimits_check "" "$TMP"; [ "$status" -eq 0 ]; [ "$output" = "no-file" ]
}

@test "tag text: parentheses become brackets, whitespace collapses, empty is refused" {
  fi_source_lib canonicalize; fi_source_lib parse-entries; fi_source_lib autofix-tags
  fi_tag_text "  use fix() or   patch()?  "
  [ "$FI_TAG_TEXT" = "use fix[] or patch[]?" ]
  run fi_tag_text "   "; [ "$status" -eq 1 ]
  run fi_tag_text $'a\nb'; [ "$status" -eq 1 ]
}

@test "retag: replaces the previous tag, keeps closing annotations, decided clears decide" {
  fi_source_lib canonicalize; fi_source_lib parse-entries; fi_source_lib autofix-tags
  fi_entry_retag "- [open] 2026-10-03 src/a.sh:1 — bug (PR: o/r#1) (fix: small)" decide "A or B?"
  [ "$FI_RETAGGED" = "- [open] 2026-10-03 src/a.sh:1 — bug (PR: o/r#1) (decide: A or B?)" ]
  fi_entry_retag "$FI_RETAGGED" decided "A"
  [ "$FI_RETAGGED" = "- [open] 2026-10-03 src/a.sh:1 — bug (PR: o/r#1) (decided: A)" ]
  fi_entry_retag "- [deferred] 2026-10-03 src/a.sh:1 — bug (reason: x) (until: date:2026-01-01)" drop-until ""
  [ "$FI_RETAGGED" = "- [deferred] 2026-10-03 src/a.sh:1 — bug (reason: x)" ]
}

@test "tag_resolve: --fix on an off-limits path becomes manual off-limits" {
  fi_source_lib canonicalize; fi_source_lib parse-entries; fi_source_lib autofix-tags
  fi_tag_resolve fix small .github/workflows/ci.yml "$TMP"
  [ "$FI_TAG_KIND" = "manual" ] && [ "$FI_TAG_VALUE" = "off-limits: ci" ]
  fi_tag_resolve fix small src/a.sh "$TMP"
  [ "$FI_TAG_KIND" = "fix" ] && [ "$FI_TAG_VALUE" = "small" ]
  run fi_tag_resolve fix tiny src/a.sh "$TMP"; [ "$status" -eq 2 ]
  fi_tag_resolve decide "x (y)" "" ""
  [ "$FI_TAG_KIND" = "decide" ] && [ "$FI_TAG_VALUE" = "x [y]" ]
}

@test "tag: sets, replaces, keeps closing annotations; matches open and deferred" {
  printf -- '- [open] 2026-10-03 src/a.sh:1 — bug one (PR: o/r#1)\n- [deferred] 2026-10-03 src/a.sh:2 — bug two (reason: later)\n' > docs/found-issues.md
  fi_run tag "bug one" --fix small
  [ "$status" -eq 0 ]
  grep -qx -- '- \[open\] 2026-10-03 src/a.sh:1 — bug one (PR: o/r#1) (fix: small)' docs/found-issues.md
  fi_run tag "bug one" --decide "A or B?"
  grep -qx -- '- \[open\] 2026-10-03 src/a.sh:1 — bug one (PR: o/r#1) (decide: A or B?)' docs/found-issues.md
  [ "$(grep -c '(fix:' docs/found-issues.md)" -eq 0 ]
  fi_run tag "bug two" --manual "needs a captured payload"
  [ "$status" -eq 0 ]
  grep -q 'bug two (reason: later) (manual: needs a captured payload)' docs/found-issues.md
}

@test "tag: off-limits path is forced to manual and says so" {
  mkdir -p .github/workflows && printf 'x\n' > .github/workflows/ci.yml && git add -A && git commit -q -m ci
  printf -- '- [open] 2026-10-03 .github/workflows/ci.yml:3 — wrong runner\n' > docs/found-issues.md
  fi_run tag "wrong runner" --fix small
  [ "$status" -eq 0 ]
  [[ "$output" == *"off-limits"* ]]
  grep -q '(manual: off-limits: ci)' docs/found-issues.md
}

@test "tag: usage errors, ambiguity and no match" {
  printf -- '- [open] 2026-10-03 src/a.sh:1 — bug one\n- [open] 2026-10-03 src/a.sh:2 — bug two\n' > docs/found-issues.md
  fi_run tag "bug" --fix small;            [ "$status" -eq 2 ]
  fi_run tag "nothing here" --fix small;   [ "$status" -eq 1 ]
  fi_run tag "bug one";                    [ "$status" -eq 2 ]
  fi_run tag "bug one" --fix tiny;         [ "$status" -eq 2 ]
  fi_run tag "bug one" --bogus x;          [ "$status" -eq 2 ]
  fi_run tag --help;                       [ "$status" -eq 0 ]
  ! grep -q '(fix:' docs/found-issues.md
}

@test "log: --fix writes the tag; off-limits becomes manual" {
  fi_run log --fix small "src/a.sh:1 — off by one"
  [ "$status" -eq 0 ]
  grep -qx -- "- \[open\] $(date +%Y-%m-%d) src/a.sh:1 — off by one (fix: small)" docs/found-issues.md
  printf '{}\n' > package.json && git add -A && git commit -q -m pkg
  fi_run log --critical --fix medium "package.json:1 — wrong engines field"
  [ "$status" -eq 0 ]
  grep -q '^- \[open\] \[!\] .*package.json:1 — wrong engines field (manual: off-limits: dependencies)' docs/found-issues.md
}

@test "log: --decide and --manual; flags in any order before the entry" {
  fi_run log --decide "rename or alias?" --critical "src/a.sh:2 — confusing flag name"
  [ "$status" -eq 0 ]
  grep -q '^- \[open\] \[!\] .*src/a.sh:2 — confusing flag name (decide: rename or alias?)' docs/found-issues.md
  fi_run log --manual "needs prod payload" "src/a.sh:3 — webhook parse"
  grep -q 'src/a.sh:3 — webhook parse (manual: needs prod payload)' docs/found-issues.md
  fi_run log --fix small --manual x "src/a.sh:4 — two tags"
  [ "$status" -eq 2 ]
}

@test "log: re-logging an untagged entry with a tag tags it instead of skipping" {
  fi_run log "src/a.sh:1 — off by one"
  fi_run log --fix small "src/a.sh:1 — off by one"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tagged:"* ]]
  [ "$(grep -c 'src/a.sh:1' docs/found-issues.md)" -eq 1 ]
  grep -q 'off by one (fix: small)' docs/found-issues.md
}

@test "log/tag: an abstract topic with --fix is tagged manual no-file, not untracked" {
  fi_run log --fix small "release-process — changelog step is manual"
  [ "$status" -eq 0 ]
  grep -q 'changelog step is manual (manual: off-limits: no-file)' docs/found-issues.md
  fi_run log "ci-flakes — retries hide real failures"
  fi_run tag "ci-flakes" --fix medium
  grep -q 'retries hide real failures (manual: off-limits: no-file)' docs/found-issues.md
}

@test "decide: lists questions critical first, counts, records answers" {
  printf -- '- [open] 2026-10-01 src/a.sh:1 — naming (decide: rename or alias?)\n- [open] [!] 2026-10-02 src/a.sh:2 — data shape (decide: keep v1 or migrate?)\n- [open] 2026-10-03 src/a.sh:3 — plain bug (fix: small)\n' > docs/found-issues.md
  fi_run decide
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "1. [!] src/a.sh:2 — keep v1 or migrate?" ]
  [ "${lines[1]}" = "2. src/a.sh:1 — rename or alias?" ]
  fi_run decide --count
  [ "$output" = "2" ]
  fi_run decide "src/a.sh:1" --answer "alias (keep old name)"
  [ "$status" -eq 0 ]
  grep -q 'naming (decided: alias \[keep old name\])' docs/found-issues.md
  ! grep -q 'rename or alias' docs/found-issues.md
  fi_run decide "plain bug" --answer x
  [ "$status" -eq 3 ]
  fi_run decide "src/a.sh" --answer x
  [ "$status" -eq 2 ]
}

@test "decide: empty queue" {
  printf -- '- [open] 2026-10-03 src/a.sh:3 — plain bug\n' > docs/found-issues.md
  fi_run decide
  [ "$status" -eq 0 ]
  [ "$output" = "No decisions waiting." ]
  fi_run decide --count
  [ "$output" = "0" ]
}

@test "defer --until: validates pr:/date:/text and writes the annotation" {
  printf -- '- [open] 2026-10-03 src/a.sh:1 — one\n- [open] 2026-10-03 src/a.sh:2 — two\n- [open] 2026-10-03 src/a.sh:3 — three\n' > docs/found-issues.md
  fi_run defer "one" --until "pr:foo/bar#12"
  [ "$status" -eq 0 ]
  grep -q 'one (until: pr:foo/bar#12)' docs/found-issues.md
  fi_run defer "two" --until "date:2026-13-45x"
  [ "$status" -eq 2 ]
  fi_run defer "two" --until "after phase 3 (auth rewrite)"
  [ "$status" -eq 0 ]
  grep -q 'two (until: after phase 3 \[auth rewrite\])' docs/found-issues.md
  fi_run defer "three" --until "pr:not-a-ref"
  [ "$status" -eq 2 ]
}

@test "sync: wakes a deferred entry whose date passed, keeps a future one" {
  printf -- '- [deferred] 2026-09-01 src/a.sh:1 — past (reason: wait) (until: date:2026-01-01)\n- [deferred] 2026-09-01 src/a.sh:2 — future (until: date:2999-01-01)\n- [deferred] 2026-09-01 src/a.sh:3 — vague (until: after the redesign)\n' > docs/found-issues.md
  FOUND_ISSUES_AUTO_ARCHIVE=off fi_run sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"Woke: 1"* ]]
  grep -qx -- '- \[open\] 2026-09-01 src/a.sh:1 — past (reason: wait)' docs/found-issues.md
  grep -q '^- \[deferred\].*future (until: date:2999-01-01)' docs/found-issues.md
  grep -q '^- \[deferred\].*vague (until: after the redesign)' docs/found-issues.md
}

@test "sync: wakes on a merged PR trigger; an unanswered or open PR leaves it deferred" {
  fi_init_github_repo foo/bar main
  mkdir -p "$TMP/stub" && cat > "$TMP/stub/gh" <<'EOS'
#!/usr/bin/env bash
case "$*" in
  "auth status"*) exit 0 ;;
  "repo view"*) echo foo/bar ;;
  "pr view 12 "*) printf 'MERGED\037main\0372026-10-01T00:00:00Z\n' ;;
  *) exit 1 ;;
esac
EOS
  chmod +x "$TMP/stub/gh"
  printf -- '- [deferred] 2026-09-01 src/a.sh:1 — after pr (until: pr:foo/bar#12)\n' > docs/found-issues.md
  PATH="$TMP/stub:$PATH" FOUND_ISSUES_AUTO_ARCHIVE=off fi_run sync
  grep -q '^- \[open\] 2026-09-01 src/a.sh:1 — after pr$' docs/found-issues.md
  # gh cannot answer for #13, and #14 is still OPEN: both stay deferred.
  printf -- '- [deferred] 2026-09-01 src/a.sh:2 — unknown pr (until: pr:foo/bar#13)\n' >> docs/found-issues.md
  cat > "$TMP/stub/gh" <<'EOS'
#!/usr/bin/env bash
case "$*" in
  "auth status"*) exit 0 ;;
  "repo view"*) echo foo/bar ;;
  "pr view 14 "*) printf 'OPEN\037main\037\n' ;;
  *) exit 1 ;;
esac
EOS
  printf -- '- [deferred] 2026-09-01 src/a.sh:3 — open pr (until: pr:foo/bar#14)\n' >> docs/found-issues.md
  PATH="$TMP/stub:$PATH" FOUND_ISSUES_AUTO_ARCHIVE=off fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[deferred\].*unknown pr (until: pr:foo/bar#13)' docs/found-issues.md
  grep -q '^- \[deferred\].*open pr (until: pr:foo/bar#14)' docs/found-issues.md
}

@test "sync --dry-run reports a wake-up but writes nothing" {
  printf -- '- [deferred] 2026-09-01 src/a.sh:1 — past (until: date:2026-01-01)\n' > docs/found-issues.md
  cp docs/found-issues.md "$TMP/before"
  FOUND_ISSUES_AUTO_ARCHIVE=off fi_run sync --dry-run
  [[ "$output" == *"Woke: 1"* ]]
  cmp "$TMP/before" docs/found-issues.md
}

@test "log: a tag flag after the entry or in --fix= form is never silently dropped (review I1)" {
  fi_run log --fix=small "src/a.sh:2 — equals form"
  [ "$status" -eq 0 ]
  grep -qx -- "- \[open\] $(date +%Y-%m-%d) src/a.sh:2 — equals form (fix: small)" docs/found-issues.md
  fi_run log "src/a.sh:1 — crash on empty input" --fix small
  [ "$status" -eq 2 ]
  [[ "$output" == *"before the entry"* ]]
  ! grep -q 'crash on empty input' docs/found-issues.md
}

@test "log: the tag survives --critical escalation and a deferred match (review I2)" {
  fi_run log "src/a.sh:1 — escalate me"
  fi_run log --critical --fix small "src/a.sh:1 — escalate me"
  [ "$status" -eq 0 ]
  grep -q '^- \[open\] \[!\] .*escalate me (fix: small)' docs/found-issues.md
  printf -- '- [deferred] 2026-10-01 src/a.sh:5 — parked (reason: later)\n' >> docs/found-issues.md
  fi_run log --fix medium "src/a.sh:5 — parked"
  [ "$status" -eq 0 ]
  grep -q '^- \[deferred\] .*parked (reason: later).*(fix: medium)' docs/found-issues.md
  fi_run log --manual "other" "src/a.sh:5 — parked"
  [[ "$output" == *"already tagged"* ]]
}

@test "autofix-tags: autofix-failed replaces only its own group and keeps the fix tag" {
  source "$FI_BIN"
  fi_entry_retag '- [open] 2026-10-01 a.sh:1 — x (fix: small) (autofix-failed: old)' autofix-failed 'tests fail'
  [ "$FI_RETAGGED" = '- [open] 2026-10-01 a.sh:1 — x (fix: small) (autofix-failed: tests fail)' ]
  fi_tag_resolve autofix-failed 'verifier said (no)' '' ''
  [ "$FI_TAG_KIND" = autofix-failed ]
  [ "$FI_TAG_VALUE" = 'verifier said [no]' ]
}
