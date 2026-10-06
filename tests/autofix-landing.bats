#!/usr/bin/env bats
# 3.2.0 landing branch: fixes start from and land into the session's branch.

load 'helpers'
load 'autofix-helpers'

setup() { fi_setup_tmp; fi_af_fixture; source "$FI_BIN"; fi_af_context; AFI_root="$REPO"; }
teardown() { fi_teardown_tmp; }

@test "landing: on the default branch it is the default branch" {
  fi_af_landing_branch
  [ "$AFI_base" = main ]
  [ "$AFI_base_why" = "default branch" ]
}

@test "landing: a detached HEAD lands on the default branch" {
  git checkout -q --detach
  fi_af_landing_branch
  [ "$AFI_base" = main ]
  [ "$AFI_base_why" = detached ]
}

@test "landing: a branch tracking a live origin branch lands there" {
  fi_af_remote_branch gsd/phase-01
  fi_af_landing_branch
  [ "$AFI_base" = gsd/phase-01 ]
  [ "$AFI_base_why" = "tracks origin/gsd/phase-01" ]
}

@test "landing: a gone upstream lands on its merged PR base" {
  fi_af_remote_branch release/v9 src/rel.sh
  fi_af_remote_branch feat/gone src/gone.sh
  git push -q origin --delete feat/gone      # origin/feat/gone ref stays (no prune)
  fi_use_gh_shim
  export GH_MOCK_PR_LIST='[{"baseRefName":"release/v9"}]'
  fi_af_landing_branch
  [ "$AFI_base" = release/v9 ]
  [ "$AFI_base_why" = "feat/gone merged into release/v9" ]
}

@test "landing: a gone upstream with no merged PR lands on the default branch" {
  fi_af_remote_branch feat/gone src/gone.sh
  git push -q origin --delete feat/gone
  fi_use_gh_shim
  export GH_MOCK_PR_LIST='[]'
  fi_af_landing_branch
  [ "$AFI_base" = main ]
  [ "$AFI_base_why" = "feat/gone gone, base unknown" ]
}

@test "landing: a never-pushed branch lands on its nearest pushed ancestor" {
  fi_af_remote_branch gsd/phase-01
  git switch -q -c worktree-agent-abc
  printf 'x\n' > src/local.sh && git add -A && git commit -q -m local
  fi_af_landing_branch
  [ "$AFI_base" = gsd/phase-01 ]
  [ "$AFI_base_why" = "nearest pushed ancestor gsd/phase-01" ]
}

@test "landing: fi branches are never a landing branch" {
  fi_af_remote_branch gsd/phase-01
  git switch -q -c fi/autofix/x && printf 'y\n' > src/y.sh && git add -A && git commit -q -m y
  git push -q -u origin fi/autofix/x
  git switch -q -c worktree-x && git branch -q --unset-upstream 2>/dev/null || true
  printf 'z\n' > src/z.sh && git add -A && git commit -q -m z
  fi_af_landing_branch
  [ "$AFI_base" = gsd/phase-01 ]
}

@test "landing: a tie between pushed ancestors goes to the default branch" {
  git push -q origin main:refs/heads/feat/same    # same commit as main
  git switch -q -c worktree-tie
  printf 't\n' > src/t.sh && git add -A && git commit -q -m t
  fi_af_landing_branch
  [ "$AFI_base" = main ]
}

@test "landing: an unrelated history lands on the default branch" {
  git switch -q --orphan lonely
  printf 'l\n' > l.txt && git add l.txt && git commit -q -m lonely
  git rev-parse -q --verify HEAD >/dev/null    # the orphan commit exists
  ! git merge-base origin/main HEAD >/dev/null 2>&1 || false
  fi_af_landing_branch
  [ "$AFI_base" = main ]
  [ "$AFI_base_why" = "no pushed ancestor" ]
}

@test "landing: a claim cuts the worktree from the landing branch and records why" {
  fi_af_remote_branch gsd/phase-01
  fi_af_queue_spot "$(grep -m1 '^- \[open\]' docs/found-issues.md)" >/dev/null
  id="$(ls "$FI_AF_ST/queue" | head -1)"
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 0 ]
  grep -q '^base=gsd/phase-01$' "$FI_AF_ST/running/$id"
  grep -q '^base_why=tracks origin/gsd/phase-01$' "$FI_AF_ST/running/$id"
  [ -f "$REPO/.claude/worktrees/fi-autofix-$id/src/gsd/phase-01.sh" ]
}

@test "landing: a requeued item resolves its landing branch again" {
  fi_af_remote_branch gsd/phase-01
  fi_af_queue_spot "$(grep -m1 '^- \[open\]' docs/found-issues.md)" >/dev/null
  id="$(ls "$FI_AF_ST/queue" | head -1)"
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 0 ]
  grep -q '^base=gsd/phase-01$' "$FI_AF_ST/running/$id"
  fi_af_requeue "$id" "engine outage"
  [ -f "$FI_AF_ST/queue/$id" ]
  grep -q '^base=$' "$FI_AF_ST/queue/$id"
  grep -q '^base_why=$' "$FI_AF_ST/queue/$id"
  ! grep -q '^wait_since=[0-9]' "$FI_AF_ST/queue/$id" || false
  fi_af_remote_branch gsd/phase-02
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 0 ]
  grep -q '^base=gsd/phase-02$' "$FI_AF_ST/running/$id"
  grep -q '^base_why=tracks origin/gsd/phase-02$' "$FI_AF_ST/running/$id"
  [ -f "$REPO/.claude/worktrees/fi-autofix-$id/src/gsd/phase-02.sh" ]
}

@test "landing: a crash-requeued item resolves its landing branch again" {
  fi_af_remote_branch gsd/phase-01
  fi_af_queue_spot "$(grep -m1 '^- \[open\]' docs/found-issues.md)" >/dev/null
  id="$(ls "$FI_AF_ST/queue" | head -1)"
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 0 ]
  fi_af_item_set "$FI_AF_ST/running/$id" pid 999999
  fi_af_reap
  [ -f "$FI_AF_ST/queue/$id" ]
  grep -q '^base=$' "$FI_AF_ST/queue/$id"
  fi_af_remote_branch gsd/phase-02
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 0 ]
  grep -q '^base=gsd/phase-02$' "$FI_AF_ST/running/$id"
}

queue_entry() { # $1 = ledger line to append and queue; sets id
  printf '%s\n' "$1" >> docs/found-issues.md
  fi_af_queue_spot "$1" >/dev/null
  id="$(ls -t "$FI_AF_ST/queue" | head -1)"
}

@test "wait: a file missing on the landing branch waits without a slot or a worktree" {
  fi_af_remote_branch gsd/phase-01
  git switch -q -c worktree-w
  printf 'n\n' > src/new.sh && git add -A && git commit -q -m new     # not pushed
  queue_entry "- [open] 2026-10-05 src/new.sh:1 — bug (fix: small)"
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 8 ]
  [[ "$output" == *"waits — src/new.sh not on origin/gsd/phase-01"* ]]
  [ -f "$FI_AF_ST/queue/$id" ]
  grep -q '^waiting=src/new.sh not on origin/gsd/phase-01$' "$FI_AF_ST/queue/$id"
  grep -q '^wait_since=[0-9]' "$FI_AF_ST/queue/$id"
  grep -q '^wait_next=[0-9]' "$FI_AF_ST/queue/$id"
  [ ! -e "$FI_AF_ST/day/$(date +%Y-%m-%d).spot" ]
  [ ! -d "$REPO/.claude/worktrees/fi-autofix-$id" ]
  [ ! -d "$FI_AF_ST/lock" ]
}

@test "wait: an uncommitted edit to the cited file makes it busy" {
  printf '# local edit\n' >> src/calc.sh
  id="$(fi_af_queue_spot "$(grep -m1 '^- \[open\]' docs/found-issues.md)" >/dev/null; ls "$FI_AF_ST/queue" | head -1)"
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 8 ]
  grep -q "^waiting=src/calc.sh busy in $REPO\$" "$FI_AF_ST/queue/$id"
}

@test "wait: an unpushed commit to the cited file makes it busy" {
  printf '# local commit\n' >> src/calc.sh && git commit -qam local
  id="$(fi_af_queue_spot "$(grep -m1 '^- \[open\]' docs/found-issues.md)" >/dev/null; ls "$FI_AF_ST/queue" | head -1)"
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 8 ]
}

@test "wait: once the change is pushed the item claims normally" {
  printf '# local commit\n' >> src/calc.sh && git commit -qam local
  id="$(fi_af_queue_spot "$(grep -m1 '^- \[open\]' docs/found-issues.md)" >/dev/null; ls "$FI_AF_ST/queue" | head -1)"
  run "$FI_BIN" autofix claim "$id"; [ "$status" -eq 8 ]
  git push -q origin main
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 0 ]
  [ -f "$FI_AF_ST/running/$id" ]
  grep -q '^waiting=$' "$FI_AF_ST/running/$id"
  # A successful claim ends the wait: the next wait must start its own clock.
  grep -q '^wait_since=$' "$FI_AF_ST/running/$id"
  grep -q '^wait_next=$' "$FI_AF_ST/running/$id"
}

# Another clone pushes a change to <file> on main; the session's checkout stays behind.
push_from_other_clone() {
  git clone -q "$TMP/remote.git" "$TMP/other"
  ( cd "$TMP/other" && printf '# upstream change\n' >> "$1" \
    && git -c user.email=a@b -c user.name=x -c commit.gpgsign=false commit -qam up && git push -q origin main )
}

@test "wait: a checkout merely behind origin is not busy" {
  push_from_other_clone src/calc.sh
  [ -z "$(git -C "$REPO" status --porcelain -- src/calc.sh)" ]
  id="$(fi_af_queue_spot "$(grep -m1 '^- \[open\]' docs/found-issues.md)" >/dev/null; ls "$FI_AF_ST/queue" | head -1)"
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 0 ]
  [ -f "$FI_AF_ST/running/$id" ]
}

@test "wait: a staged but uncommitted edit makes it busy" {
  printf '# staged\n' >> src/calc.sh && git add src/calc.sh
  id="$(fi_af_queue_spot "$(grep -m1 '^- \[open\]' docs/found-issues.md)" >/dev/null; ls "$FI_AF_ST/queue" | head -1)"
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 8 ]
}

@test "wait: a commit already on the branch's own stale upstream ref is not busy" {
  fi_af_remote_branch feat/squashed src/sq.sh
  printf '# on the branch\n' >> src/calc.sh && git commit -qam onbranch && git push -q origin feat/squashed
  git -C "$TMP/remote.git" branch -D feat/squashed >/dev/null     # merged elsewhere; origin/feat/squashed stays stale
  fi_use_gh_shim
  export GH_MOCK_PR_LIST='[]'
  id="$(fi_af_queue_spot "$(grep -m1 '^- \[open\]' docs/found-issues.md)" >/dev/null; ls "$FI_AF_ST/queue" | head -1)"
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 0 ]
}

@test "wait: a wait that ended in a claim does not carry its clock into the next wait" {
  printf '# local commit\n' >> src/calc.sh && git commit -qam local
  id="$(fi_af_queue_spot "$(grep -m1 '^- \[open\]' docs/found-issues.md)" >/dev/null; ls "$FI_AF_ST/queue" | head -1)"
  run "$FI_BIN" autofix claim "$id"; [ "$status" -eq 8 ]
  fi_af_item_set "$FI_AF_ST/queue/$id" wait_since 1000     # the first wait was long ago
  git push -q origin main
  run "$FI_BIN" autofix claim "$id"; [ "$status" -eq 0 ]
  grep -q '^wait_since=$' "$FI_AF_ST/running/$id"
  grep -q '^wait_next=$' "$FI_AF_ST/running/$id"
  fi_af_requeue "$id" "engine outage"
  printf '# edit again\n' >> src/calc.sh
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 8 ]
  grep -q "^waiting=src/calc.sh busy in $REPO\$" "$FI_AF_ST/queue/$id"
}

@test "wait: a wait older than the maximum retires the item stale" {
  printf '# local edit\n' >> src/calc.sh
  id="$(fi_af_queue_spot "$(grep -m1 '^- \[open\]' docs/found-issues.md)" >/dev/null; ls "$FI_AF_ST/queue" | head -1)"
  run "$FI_BIN" autofix claim "$id"; [ "$status" -eq 8 ]
  fi_af_item_set "$FI_AF_ST/queue/$id" wait_since 1000
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 5 ]
  grep -q "^result=stale: src/calc.sh busy in $REPO\$" "$FI_AF_ST/done/$id"
}

@test "wait: a slashed topic location skips the check" {
  queue_entry "- [open] 2026-10-05 dispatch/shutdown — bug (fix: small)"
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 0 ]
}

@test "wait: a cited file that exists nowhere skips the check" {
  queue_entry "- [open] 2026-10-05 src/ghost.sh:1 — bug (fix: small)"
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 0 ]
}

@test "drain: a waiting item does not stop the next queued item" {
  printf '# local edit\n' >> src/calc.sh                          # makes calc busy
  first="$(fi_af_queue_spot "$(grep -m1 '^- \[open\]' docs/found-issues.md)" >/dev/null; ls "$FI_AF_ST/queue" | head -1)"
  sleep 1
  queue_entry "- [open] 2026-10-05 environment (agent PATH) — topic bug (fix: small)"
  fi_use_standins
  run "$FI_BIN" autofix run "$first" --engine claude
  [ -f "$FI_AF_ST/queue/$first" ]
  [ ! -f "$FI_AF_ST/queue/$id" ]
}

@test "sweep: candidates missing on the landing branch or busy are skipped and logged" {
  cd "$TMP"; rm -rf "$TMP/repo" "$TMP/remote.git" "$TMP/state"    # setup's single-entry fixture
  fi_af_sweep_fixture 5
  REPO="$(pwd -P)"
  printf '# busy\n' >> src/f1.sh                               # busy: edited, not committed
  printf 'g\n' > src/ghost.sh                                  # exists locally only, never on origin
  printf -- '- [open] 2026-10-05 src/ghost.sh:1 — not pushed (fix: medium)\n' >> docs/found-issues.md
  git config found-issues.autofix.testCommand 'sh test.sh'
  fi_use_standins
  fi_af_context; AFI_root="$REPO"                             # setup sourced the CLI already
  fi_af_sweep_check >/dev/null
  id="$(ls "$FI_AF_ST/queue" | head -1)"
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 0 ]
  ! grep -q 'src/f1.sh' "$FI_AF_ST/sweeps/$id.entries" || false
  ! grep -q 'src/ghost.sh' "$FI_AF_ST/sweeps/$id.entries" || false
  grep -q 'src/f2.sh' "$FI_AF_ST/sweeps/$id.entries"
  grep -q 'sweep: skip src/f1.sh:1 (busy)' "$FI_AF_RUNS/$id.log"
  grep -q 'sweep: skip src/ghost.sh:1 (not on origin/main)' "$FI_AF_RUNS/$id.log"
}

@test "sweep: a checkout merely behind origin keeps its entries as candidates" {
  cd "$TMP"; rm -rf "$TMP/repo" "$TMP/remote.git" "$TMP/state"
  fi_af_sweep_fixture 5
  REPO="$(pwd -P)"
  push_from_other_clone src/f1.sh
  fi_use_standins
  fi_af_context; AFI_root="$REPO"
  fi_af_sweep_check >/dev/null
  id="$(ls "$FI_AF_ST/queue" | head -1)"
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 0 ]
  grep -q 'src/f1.sh' "$FI_AF_ST/sweeps/$id.entries"
  ! grep -q 'skip src/f1.sh' "$FI_AF_RUNS/$id.log" || false
}

@test "sweep: the claim log line says why the landing branch was chosen" {
  cd "$TMP"; rm -rf "$TMP/repo" "$TMP/remote.git" "$TMP/state"
  fi_af_sweep_fixture 5
  REPO="$(pwd -P)"
  fi_use_standins
  fi_af_context; AFI_root="$REPO"
  fi_af_sweep_check >/dev/null
  id="$(ls "$FI_AF_ST/queue" | head -1)"
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 0 ]
  grep -q 'claimed sweep: 5 entries in .* from origin/main: default branch)$' "$FI_AF_RUNS/$id.log"
}

@test "sweep: every candidate skipped does not spend the day's sweep slot" {
  cd "$TMP"; rm -rf "$TMP/repo" "$TMP/remote.git" "$TMP/state"
  fi_af_sweep_fixture 5
  REPO="$(pwd -P)"
  printf '# busy\n' | tee -a src/f1.sh -a src/f2.sh -a src/f3.sh -a src/f4.sh -a src/f5.sh >/dev/null   # all busy: edited, not committed
  fi_use_standins
  fi_af_context; AFI_root="$REPO"
  fi_af_sweep_check >/dev/null
  id="$(ls "$FI_AF_ST/queue" | head -1)"
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 5 ]
  grep -q '^result=stale: nothing fixable now$' "$FI_AF_ST/done/$id"
  [ ! -e "$FI_AF_ST/day/$(date +%Y-%m-%d).sweep" ]
}
