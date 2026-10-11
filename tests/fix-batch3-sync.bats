#!/usr/bin/env bats
# Sync batch 3: commit closer relates the commit to the entry, the awaiting
# confirmation block prints real commands, and an unresolved repo id is loud.
load 'helpers'

setup() {
  fi_setup_tmp
  fi_init_git
  export HOME="$TMP/home"
  mkdir -p "$HOME"
}
teardown() { fi_teardown_tmp; }

# --- entry 1: the commit closer ----------------------------------------------

@test "closer: a landed commit that never touched the cited file does not close the entry" {
  mkdir -p src
  echo a > src/foo.py; echo b > src/other.py
  git add . && git commit -q -m "add"
  echo c >> src/other.py && git commit -q -am "touch other"
  sha="$(git rev-parse --short=7 HEAD)"
  fi_seed_entry "src/foo.py:1 — bug (commit: $sha)"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q "^- \[open\].*(commit: $sha)" docs/found-issues.md
  [[ "$output" == *"$sha"* ]]
  [[ "$output" == *"src/foo.py:1"* ]]
  [[ "$output" == *"did not touch"* ]]
}

@test "closer: a landed commit that touched the cited file still closes the entry" {
  mkdir -p src
  echo a > src/foo.py
  git add . && git commit -q -m "add"
  echo c >> src/foo.py && git commit -q -am "fix foo"
  sha="$(git rev-parse --short=7 HEAD)"
  fi_seed_entry "src/foo.py:1 — bug (commit: $sha)"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q "^- \[fixed\].*(commit: $sha)" docs/found-issues.md
  [[ "$output" != *"did not touch"* ]]
}

@test "closer: a second annotated commit that did touch the file closes the entry" {
  mkdir -p src
  echo a > src/foo.py; echo b > src/other.py
  git add . && git commit -q -m "add"
  echo c >> src/other.py && git commit -q -am "touch other"
  bad="$(git rev-parse --short=7 HEAD)"
  echo d >> src/foo.py && git commit -q -am "fix foo"
  good="$(git rev-parse --short=7 HEAD)"
  fi_seed_entry "src/foo.py:1 — bug (commit: $bad) (commit: $good)"
  fi_run sync
  grep -q "^- \[fixed\]" docs/found-issues.md
  [[ "$output" != *"did not touch"* ]]
}

@test "closer: a merge commit counts the files the merge brought in" {
  mkdir -p src
  echo a > src/foo.py
  git add . && git commit -q -m "add"
  git checkout -q -b feat
  echo c >> src/foo.py && git commit -q -am "fix foo on branch"
  echo z > src/zzz.py && git add . && git commit -q -m "other"
  git checkout -q main
  echo q > src/qq.py && git add . && git commit -q -m "main moves"
  git merge -q --no-ff feat -m "merge feat"
  sha="$(git rev-parse --short=7 HEAD)"
  fi_seed_entry "src/foo.py:1 — bug (commit: $sha)"
  fi_run sync
  grep -q "^- \[fixed\].*(commit: $sha)" docs/found-issues.md
}

@test "closer: an entry citing a directory closes on a commit touching a file inside it" {
  mkdir -p src/utils
  echo a > src/utils/x.py; echo b > top.py
  git add . && git commit -q -m "add"
  echo c >> src/utils/x.py && git commit -q -am "fix utils"
  sha="$(git rev-parse --short=7 HEAD)"
  fi_seed_entry "src/utils — messy (commit: $sha)"
  fi_run sync
  grep -q "^- \[fixed\].*(commit: $sha)" docs/found-issues.md
}

@test "closer: a renamed entry also accepts a commit touching the pre-rename path" {
  mkdir -p src
  echo a > src/old.py; echo b > src/other.py
  git add . && git commit -q -m "add"
  echo c >> src/old.py && git commit -q -am "fix old"
  sha="$(git rev-parse --short=7 HEAD)"
  git mv src/old.py src/new.py && git commit -q -m "rename"
  fi_seed_entry "src/new.py:1 — bug (renamed-from: src/old.py) (commit: $sha)"
  fi_run sync
  grep -q "^- \[fixed\].*(commit: $sha)" docs/found-issues.md
}

@test "closer: an entry with no path keeps closing on any landed annotated commit" {
  mkdir -p src
  echo a > src/foo.py
  git add . && git commit -q -m "add"
  sha="$(git rev-parse --short=7 HEAD)"
  fi_seed_entry "TODO: general cleanup — messy (commit: $sha)"
  fi_run sync
  grep -q "^- \[fixed\].*(commit: $sha)" docs/found-issues.md
}

@test "closer: the note is printed on --dry-run and nothing is written" {
  mkdir -p src
  echo a > src/foo.py; echo b > src/other.py
  git add . && git commit -q -m "add"
  echo c >> src/other.py && git commit -q -am "touch other"
  sha="$(git rev-parse --short=7 HEAD)"
  fi_seed_entry "src/foo.py:1 — bug (commit: $sha)"
  before="$(cat docs/found-issues.md)"
  fi_run sync --dry-run
  [[ "$output" == *"did not touch"* ]]
  [ "$(cat docs/found-issues.md)" = "$before" ]
}

# --- entry 2: the awaiting-confirmation block ---------------------------------

@test "awaiting: a landed commit-auto prints a working confirm command and a reject command" {
  mkdir -p src
  echo a > src/foo.py
  git add . && git commit -q -m "add foo"
  sha="$(git rev-parse --short=7 HEAD)"
  fi_seed_entry "src/foo.py:1 — bug (commit-auto: $sha)"
  fi_run sync
  [[ "$output" == *"found-issues annotate-commit $sha --force --pick 'src/foo.py:1'"* ]]
  [[ "$output" == *"found-issues unannotate 'src/foo.py:1' $sha"* ]]
  [[ "$output" != *"by hand"* ]]
  # The printed confirm command works from a feature branch.
  git checkout -q -b feat
  fi_run annotate-commit "$sha" --force --pick 'src/foo.py:1'
  [ "$status" -eq 0 ]
  grep -q "(commit: $sha)" docs/found-issues.md
}

@test "awaiting: the printed reject command removes the suggestion" {
  mkdir -p src
  echo a > src/foo.py
  git add . && git commit -q -m "add foo"
  sha="$(git rev-parse --short=7 HEAD)"
  fi_seed_entry "src/foo.py:1 — bug (commit-auto: $sha)"
  fi_run unannotate 'src/foo.py:1' "$sha"
  [ "$status" -eq 0 ]
  ! grep -q "commit-auto" docs/found-issues.md || false
}

@test "awaiting: a merged PR-auto prints annotate-pr, never annotate-commit" {
  fi_use_gh_shim
  fi_init_github_repo foo/bar main
  export GH_MOCK_PR_VIEW=$'42\t{"state":"MERGED","baseRefName":"main","mergedAt":"2026-05-01T12:00:00Z","isDraft":false}'
  mkdir -p src; printf 'x\n' > src/foo.py
  fi_seed_entry "src/foo.py:1 — bug (PR-auto: foo/bar#42)"
  fi_run sync
  [[ "$output" == *"awaiting confirmation"* ]]
  [[ "$output" == *"found-issues annotate-pr 42 --pick 'src/foo.py:1'"* ]]
  [[ "$output" == *"found-issues unannotate 'src/foo.py:1' foo/bar#42"* ]]
  [[ "$output" != *"annotate-commit"* ]]
}

# --- entry 4: PR annotations with no resolvable repo --------------------------

@test "mode: sync warns on stderr, naming the mode, when PR annotations cannot be resolved" {
  mkdir -p src; printf 'x\n' > src/foo.py
  git add . && git commit -q -m "init"
  fi_seed_entry "src/foo.py:1 — bug (PR: foo/bar#42)"
  run bash -c "cd '$TMP' && '$FI_BIN' sync 2>&1 >/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(PR: ...)"* ]]
  [[ "$output" == *"mode: git"* ]]
  grep -q "^- \[open\]" docs/found-issues.md
}

@test "mode: no warning when no entry carries a PR annotation" {
  mkdir -p src; printf 'x\n' > src/foo.py
  git add . && git commit -q -m "init"
  fi_seed_entry "src/foo.py:1 — bug"
  run bash -c "cd '$TMP' && '$FI_BIN' sync 2>&1 >/dev/null"
  [[ "$output" != *"(PR: ...)"* ]]
}

@test "mode: the warning appears once per run however many entries carry PRs" {
  mkdir -p src; printf 'x\n' > src/foo.py
  git add . && git commit -q -m "init"
  fi_seed_entry "src/foo.py:1 — bug (PR: foo/bar#42)"
  fi_seed_entry "src/foo.py:2 — bug two (PR: foo/bar#43)"
  run bash -c "cd '$TMP' && '$FI_BIN' sync 2>&1 >/dev/null"
  [ "$(printf '%s\n' "$output" | grep -c 'cannot be resolved')" -eq 1 ]
}

@test "detect_mode: an empty cache file is ignored" {
  fi_source_lib detect-mode
  fi_use_gh_shim
  git remote add origin https://github.com/foo/bar.git
  mkdir -p "$HOME/.cache/found-issues"
  : > "$HOME/.cache/found-issues/mode_foo_bar"
  export GH_MOCK_PR_LIST='[]'
  result="$(fi_detect_mode)"
  [ "$result" = "github-direct" ]
  [ "$(cat "$HOME/.cache/found-issues/mode_foo_bar")" = "github-direct" ]
}

@test "detect_mode: a cache file holding garbage is ignored" {
  fi_source_lib detect-mode
  fi_use_gh_shim
  git remote add origin https://github.com/foo/bar.git
  mkdir -p "$HOME/.cache/found-issues"
  printf 'github-pr garbage\nmore' > "$HOME/.cache/found-issues/mode_foo_bar"
  export GH_MOCK_PR_LIST='[]'
  result="$(fi_detect_mode)"
  [ "$result" = "github-direct" ]
}

@test "detect_mode: a fresh cache holding a known mode is still returned verbatim" {
  fi_source_lib detect-mode
  fi_use_gh_shim
  git remote add origin https://github.com/foo/bar.git
  mkdir -p "$HOME/.cache/found-issues"
  printf 'github-pr' > "$HOME/.cache/found-issues/mode_foo_bar"
  export GH_MOCK_AUTH=fail
  result="$(fi_detect_mode)"
  [ "$result" = "github-pr" ]
}

@test "doctor: git mode with a non-github remote is a warning that names the reason" {
  git remote add origin https://gitlab.example.com/foo/bar.git
  fi_run doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"Detected mode: git"* ]]
  [[ "$output" == *"will not close entries"* ]]
  [[ "$output" == *"remote host is not github.com"* ]]
}

@test "doctor: git mode with no remote at all stays a plain pass" {
  fi_run doctor
  [[ "$output" == *"Detected mode: git"* ]]
  [[ "$output" != *"will not close entries"* ]]
}
