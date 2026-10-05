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
