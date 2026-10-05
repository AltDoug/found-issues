# Auto-fix Landing Branch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-fix starts from, and opens its PR into, the branch the session works on (not `origin/<default>`), waits while the cited file is missing or busy, and sync closes `fi/*` PRs on merge. Ships as 3.2.0.

**Architecture:** One resolver (`fi_af_landing_branch`) sets `AFI_base` and `AFI_base_why` before the worktree is cut. Everything downstream already reads `AFI_base` (PR `--base`, diff/reset base, briefs). A claim-time precheck (`_fi_af_wait_check`) keeps a spot item in `queue/` with `waiting=`/`wait_since=`/`wait_next=` (claim rc 8) instead of spending a slot. The Stop launcher and the drain loop skip it until `wait_next`. Sweeps filter out the same entries at claim time. Sync treats a merged PR with head `fi/autofix/*` or `fi/sweep/*` as landed.

**Tech Stack:** bash 3.2-compatible shell (macOS CI), git, gh, bats. Tests use local bare-repo remotes via `url.insteadOf` and the `tests/bin-shims/gh` mock.

**Spec:** `docs/superpowers/specs/2026-10-05-autofix-landing-branch-design.md`

## Global Constraints

- bash 3.2 safe: no `mapfile`, no `${var,,}`, guard empty-array expansions under `set -u` (memory: macOS CI runs bash 3.2).
- bats `@test` names are ASCII only (no em-dash; `tests/ascii-guard` fails the PR).
- A mid-test negative assert is `! cmd || false` or `run` + status check, never a bare `! cmd` (bare `!` asserts nothing).
- Run tests as bare `bats …` commands (the stop-tests-pass hook only credits a command starting with `bats`).
- The README test-count line must match `grep -c '@test' tests/*.bats` totals (`tests/docs-consistency.bats`).
- Never write `docs/found-issues.md` by hand; ledger changes go through `./bin/found-issues`.
- Auto-fix never pushes to the landing branch; it pushes only its own `fi/*` branch.
- Wait recheck interval 900 s (`FOUND_ISSUES_AUTOFIX_WAIT_RECHECK`), give-up 259200 s = 3 days (`FOUND_ISSUES_AUTOFIX_WAIT_MAX`).
- `fix-plumbing.sh` (manual `/found-issues:fix`) is out of scope: it keeps `fi_resolve_default_branch`.
- Version 3.2.0: CHANGELOG `### Changed` + `### Added`; both `plugin.json`; `FI_VERSION`; README status line.

## Review Focus

1. **A root checkout whose `origin/X` ref is stale (deleted remotely, never pruned).** Expected: treated as gone, not as tracked. Pinned by Task 1's "gone upstream" test, which deletes the remote branch without pruning.
2. **A waiting item never blocks other queued items.** Expected: the drain moves on to the next non-waiting item, and the Stop hook skips the waiting one until `wait_next`. Pinned by Task 3's tests.
3. **An entry location that is an abstract topic (no file).** Expected: no wait check, runs as today. Pinned by Task 2's "topic location" test.
4. **The landing branch equals the default branch.** Expected: byte-identical behaviour to 3.1.4 (`base=main`, existing claim tests unchanged). Pinned by the unchanged `tests/autofix-claim.bats` plus Task 1's default-row test.
5. **Sync on a non-auto-fix stacked PR.** Expected: today's promotion rule still applies (`release/v3` stays open until promoted). Pinned by Task 5's negative test and the existing `tests/cli-sync-pr-states.bats` release tests.

---

### Task 1: Landing-branch resolver

**Files:**
- Modify: `lib/autofix-queue.sh` (globals ~35-39, `fi_af_item_read` ~48-66, `fi_af_worktree_add` 215-236, `fi_af_claim` log line ~320)
- Modify: `lib/autofix-sweep.sh` (`fi_af_sweep_claim`: set `base_why`)
- Create: `tests/autofix-landing.bats`
- Modify: `tests/autofix-helpers.bash` (add `fi_af_remote_branch`)

**Interfaces:**
- Produces: `fi_af_landing_branch` (no args; reads `AFI_root`; sets `AFI_base`, `AFI_base_why`; returns 0; may run `git fetch` / `git ls-remote` / `gh pr list`).
- Produces: item keys `base_why`, plus globals `AFI_base_why`, `AFI_waiting`, `AFI_wait_since`, `AFI_wait_next` (the last three are used by Task 2/3; declare them here so `fi_af_item_read` resets them).
- `fi_af_worktree_add` uses `AFI_base` when already set (Task 2 resolves before the cap), otherwise calls the resolver itself.

- [ ] **Step 1: Add the remote-branch helper to `tests/autofix-helpers.bash`**

```bash
# Push a branch <name> to the fixture's remote with one commit adding <file>,
# leaving the checkout on <name> tracking origin/<name>. cwd = the repo.
fi_af_remote_branch() {
  local name="$1" file="${2:-src/$1.sh}"
  git switch -q -c "$name"
  mkdir -p "$(dirname "$file")"
  printf 'echo %s\n' "$name" > "$file"
  git add -A && git commit -q -m "$name"
  git push -q -u origin "$name"
}
```

- [ ] **Step 2: Write the failing resolver tests (`tests/autofix-landing.bats`)**

```bash
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
  git switch -q --orphan lonely && git rm -rq . && printf 'l\n' > l.txt && git add l.txt && git commit -q -m lonely
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
```

- [ ] **Step 3: Run them to confirm they fail**

Run: `bats tests/autofix-landing.bats`
Expected: every test FAILs with `fi_af_landing_branch: command not found` (or `base=main` in the last test).

- [ ] **Step 4: Implement the resolver in `lib/autofix-queue.sh`**

Add `AFI_base_why="" AFI_waiting="" AFI_wait_since="" AFI_wait_next=""` to both the global declaration block and the reset line at the top of `fi_af_item_read`. Add `|base_why|waiting|wait_since|wait_next` to its `case "$k"` key list.

Insert before `fi_af_worktree_add`:

```bash
# 3.2.0 (spec §1): the branch a fix starts from and lands into is the one
# the session works on, never assumed to be the default branch. Sets
# AFI_base and AFI_base_why; every fallback is the default branch.
fi_af_landing_branch() {
  local def cur up b n best="" bestn="" base
  def="$(cd "$AFI_root" && fi_resolve_default_branch)"
  AFI_base="$def"
  cur="$(git -C "$AFI_root" symbolic-ref -q --short HEAD 2>/dev/null || true)"
  if [[ -z "$cur" ]]; then AFI_base_why="detached"; return 0; fi
  if [[ "$cur" == "$def" ]]; then AFI_base_why="default branch"; return 0; fi
  up="$(git -C "$AFI_root" config --get "branch.$cur.merge" 2>/dev/null || true)"
  up="${up#refs/heads/}"
  if [[ -n "$up" ]]; then
    # ls-remote, not origin/<up>: a branch deleted on GitHub keeps its stale
    # remote-tracking ref until someone prunes.
    if git -C "$AFI_root" ls-remote --exit-code --heads origin "$up" >/dev/null 2>&1; then
      AFI_base="$up" AFI_base_why="tracks origin/$up"; return 0
    fi
    base="$(cd "$AFI_root" && gh pr list --repo "${AFI_slug:-$(fi_repo_id 2>/dev/null)}" --head "$up" --state merged --limit 1 \
      --json baseRefName --jq '.[0].baseRefName // ""' 2>/dev/null || true)"
    if [[ -n "$base" ]] && git -C "$AFI_root" ls-remote --exit-code --heads origin "$base" >/dev/null 2>&1; then
      AFI_base="$base" AFI_base_why="$up merged into $base"; return 0
    fi
    AFI_base_why="$up gone, base unknown"; return 0
  fi
  git -C "$AFI_root" fetch -q origin 2>/dev/null || true
  while IFS= read -r b; do
    b="${b#origin/}"
    [[ -n "$b" && "$b" != HEAD && "$b" != fi/* ]] || continue
    git -C "$AFI_root" ls-remote --exit-code --heads origin "$b" >/dev/null 2>&1 || continue
    git -C "$AFI_root" merge-base "origin/$b" HEAD >/dev/null 2>&1 || continue
    n="$(git -C "$AFI_root" rev-list --count "origin/$b..HEAD" 2>/dev/null)" || continue
    if [[ -z "$bestn" ]] || (( n < bestn )) || { (( n == bestn )) && [[ "$b" == "$def" ]]; }; then
      best="$b" bestn="$n"
    fi
  done < <(git -C "$AFI_root" for-each-ref --format='%(refname:short)' refs/remotes/origin 2>/dev/null)
  if [[ -z "$best" ]]; then AFI_base_why="no pushed ancestor"; return 0; fi
  # A tie keeps the default branch: only a strictly nearer branch wins.
  if [[ "$best" != "$def" ]] && [[ "$(git -C "$AFI_root" rev-list --count "origin/$def..HEAD" 2>/dev/null)" == "$bestn" ]]; then
    AFI_base_why="nearest pushed ancestor $def"; return 0
  fi
  AFI_base="$best" AFI_base_why="nearest pushed ancestor $best"
}
```

Change the first lines of `fi_af_worktree_add` to:

```bash
fi_af_worktree_add() {
  local s base
  [[ -n "$AFI_base" ]] || fi_af_landing_branch
  base="$AFI_base"
  git -C "$AFI_root" fetch -q origin "$base" 2>/dev/null || { FI_AF_WHY="git fetch failed"; return 1; }
```

(The `AFI_base="$base"` line that followed the fetch is removed; the rest is unchanged.) In `fi_af_claim`, after `fi_af_item_set "$r" base "$AFI_base"`, add `fi_af_item_set "$r" base_why "$AFI_base_why"` and change the log line to `fi_af_log "$id" "claimed: $AFI_wt ($AFI_branch from origin/$AFI_base: $AFI_base_why)"`. In `fi_af_sweep_claim` (`lib/autofix-sweep.sh`), after `fi_af_item_set "$r" base "$AFI_base"`, add the same `base_why` line.

`fi_af_item_read` resets `AFI_base` to "" and reads it from the item, so a queued item (no `base=`) resolves fresh at claim time.

- [ ] **Step 5: Run the new and existing claim tests**

Run: `bats tests/autofix-landing.bats tests/autofix-claim.bats tests/autofix-sweep.bats`
Expected: all PASS. Existing claim tests still see `base=main`.

- [ ] **Step 6: Commit**

```bash
git add lib/autofix-queue.sh lib/autofix-sweep.sh tests/autofix-landing.bats tests/autofix-helpers.bash
git commit -m "feat(autofix): resolve the landing branch from the session's checkout"
```

### Task 2: Wait while the cited file is missing or busy (claim rc 8)

**Files:**
- Modify: `lib/autofix-queue.sh` (`fi_af_claim`, new `_fi_af_wait_check`, new `_fi_af_entry_file`)
- Modify: `lib/autofix.sh` (claim CLI rc 8 message ~254-261)
- Test: `tests/autofix-landing.bats`

**Interfaces:**
- Consumes: `fi_af_landing_branch` (Task 1), `fi_parse_entry_vars` (sets `FE_path`).
- Produces: `fi_af_claim` returns **8** when the item waits: item stays in `queue/` with `waiting=<text>`, `wait_since=<epoch>`, `wait_next=<epoch>`; lock released; no cap taken; `FI_AF_WHY` = the waiting text. When `now - wait_since > WAIT_MAX`, it retires `stale: <text>` and returns 5.
- Produces: `_fi_af_entry_file` prints the cited file path relative to the root, or returns 1 for an abstract topic.

- [ ] **Step 1: Write the failing tests (append to `tests/autofix-landing.bats`)**

```bash
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

@test "wait: once the change is pushed the item claims normally and keeps wait_since out of running" {
  printf '# local commit\n' >> src/calc.sh && git commit -qam local
  id="$(fi_af_queue_spot "$(grep -m1 '^- \[open\]' docs/found-issues.md)" >/dev/null; ls "$FI_AF_ST/queue" | head -1)"
  run "$FI_BIN" autofix claim "$id"; [ "$status" -eq 8 ]
  git push -q origin main
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 0 ]
  [ -f "$FI_AF_ST/running/$id" ]
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

@test "wait: a topic location skips the check" {
  queue_entry "- [open] 2026-10-05 environment (agent PATH) — bug (fix: small)"
  run "$FI_BIN" autofix claim "$id"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `bats tests/autofix-landing.bats -f '^wait:'`
Expected: FAIL (`status` is 0, not 8).

- [ ] **Step 3: Implement in `lib/autofix-queue.sh`**

```bash
# The file an entry cites, relative to the root; rc 1 for an abstract topic
# (no slash and no such file in the checkout).
_fi_af_entry_file() {
  fi_parse_entry_vars "$AFI_entry" 2>/dev/null || return 1
  [[ -n "$FE_path" ]] || return 1
  [[ "$FE_path" == */* || -e "$AFI_root/$FE_path" ]] || return 1
  printf '%s' "$FE_path"
}

# Spec §2: rc 0 = go; rc 8 = wait (item stays queued); rc 5 = waited too long.
_fi_af_wait_check() {
  local q="$1" p why now since
  p="$(_fi_af_entry_file)" || return 0
  git -C "$AFI_root" fetch -q origin "$AFI_base" 2>/dev/null || return 0
  if ! git -C "$AFI_root" cat-file -e "origin/$AFI_base:$p" 2>/dev/null; then
    why="$p not on origin/$AFI_base"
  elif [[ -n "$(git -C "$AFI_root" diff --name-only "origin/$AFI_base" -- "$p" 2>/dev/null)" ]]; then
    why="$p busy in $AFI_root"
  else
    return 0
  fi
  now="$(date +%s)"
  since="$AFI_wait_since"; [[ "$since" =~ ^[0-9]+$ ]] || since="$now"
  if (( now - since > ${FOUND_ISSUES_AUTOFIX_WAIT_MAX:-259200} )); then
    FI_AF_WHY="$why"; return 5
  fi
  fi_af_item_set "$q" waiting "$why"
  fi_af_item_set "$q" wait_since "$since"
  fi_af_item_set "$q" wait_next "$(( now + ${FOUND_ISSUES_AUTOFIX_WAIT_RECHECK:-900} ))"
  FI_AF_WHY="$why"
  return 8
}
```

In `fi_af_claim`, after the `fi_af_cap_ok` line and before `fi_af_item_set "$q" pid …`, insert:

```bash
  fi_af_landing_branch
  local wrc=0
  _fi_af_wait_check "$q" || wrc=$?
  case $wrc in
    5) fi_af_retire "$id" stale "$FI_AF_WHY" || fi_af_unlock "$id"; return 5 ;;
    8) fi_af_unlock "$id"; fi_af_log "$id" "waiting: $FI_AF_WHY"; return 8 ;;
  esac
  fi_af_item_set "$q" waiting ""
```

- [ ] **Step 4: Claim CLI message (`lib/autofix.sh`, the `claim)` case)**

Add a row to the `case $rc in` block:

```bash
        8) fi_err "autofix: $1 waits — $FI_AF_WHY (rechecked on the next stop)" ;;
```

- [ ] **Step 5: Run tests**

Run: `bats tests/autofix-landing.bats tests/autofix-claim.bats`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/autofix-queue.sh lib/autofix.sh tests/autofix-landing.bats
git commit -m "feat(autofix): wait while the cited file is missing on the landing branch or busy"
```

### Task 3: Waiting items in the drain loop and the Stop launcher

**Files:**
- Modify: `lib/autofix.sh` (`_fi_af_next_queued` 186-192, the drain `case $rc` ~219-224)
- Modify: `lib/autofix-hook.sh` (`fi_afh_stop` loop ~154-165)
- Modify: `agents/found-issues-fixer.md` (step 1: name exit 8)
- Test: `tests/autofix-landing.bats`, `tests/autofix-stop.bats`

**Interfaces:**
- Consumes: item key `wait_next` (Task 2); `fi_af_claim` rc 8.
- Produces: `_fi_af_next_queued [<skip-id>]` returns the first queued id whose `wait_next` is empty or in the past, skipping `<skip-id>`.

- [ ] **Step 1: Failing tests**

Append to `tests/autofix-stop.bats`:

```bash
@test "stop: a waiting item is not launched before wait_next" {
  printf 'wait_next=%s\n' "$(( $(date +%s) + 600 ))" >> "$QITEM"
  run stop "$REPO"
  [ "$status" -eq 0 ]
  no_spawn
}

@test "stop: a waiting item whose wait_next passed is launched" {
  printf 'wait_next=%s\n' "$(( $(date +%s) - 1 ))" >> "$QITEM"
  run stop "$REPO"
  wait_spawn
}
```

Append to `tests/autofix-landing.bats`:

```bash
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
```

- [ ] **Step 2: Run to confirm failure**

Run: `bats tests/autofix-stop.bats -f 'waiting' && bats tests/autofix-landing.bats -f '^drain:'`
Expected: the first stop test FAILs (spawned), and the drain test FAILs (second item still queued).

- [ ] **Step 3: Implement**

`lib/autofix.sh`:

```bash
_fi_af_next_queued() {
  local f n now; now="$(date +%s)"
  for f in "$FI_AF_ST"/queue/*; do
    [[ -f "$f" ]] || continue
    [[ "${f##*/}" == "${1:-}" ]] && continue
    n="$(_fi_af_field "$f" wait_next 2>/dev/null || true)"
    [[ "$n" =~ ^[0-9]+$ ]] && (( n > now )) && continue
    printf '%s' "${f##*/}"; return 0
  done
  return 1
}
```

In the drain `case $rc in`, add `8) printf 'Auto-fix: %s waits (%s).\n' "$id" "$FI_AF_WHY" ;;` (no return: fall through to picking the next item), and change `next="$(_fi_af_next_queued || true)"` to `next="$(_fi_af_next_queued "$id" || true)"`.

`lib/autofix-hook.sh`, in `fi_afh_stop` after `fi_af_item_read "$f" || continue`:

```bash
    [[ "$AFI_wait_next" =~ ^[0-9]+$ ]] && (( AFI_wait_next > FI_AFH_NOW )) && continue
```

`agents/found-issues-fixer.md` step 1, replace the last sentence with: "If it exits non-zero, reply with its message and stop: another run has the item, the daily cap is reached, the item waits for its file to be pushed or freed (exit 8), or the item is no longer fixable."

- [ ] **Step 4: Run tests**

Run: `bats tests/autofix-stop.bats tests/autofix-landing.bats tests/autofix-run.bats`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/autofix.sh lib/autofix-hook.sh agents/found-issues-fixer.md tests/autofix-stop.bats tests/autofix-landing.bats
git commit -m "feat(autofix): waiting items never block the drain or relaunch before wait_next"
```

### Task 4: Sweeps skip missing and busy entries

**Files:**
- Modify: `lib/autofix-sweep.sh` (`fi_af_sweep_claim` candidate step ~196-199; new `_fi_af_sweep_ready`)
- Test: `tests/autofix-landing.bats`

**Interfaces:**
- Consumes: `_fi_af_entry_file`, `AFI_base` (Tasks 1-2).
- Produces: `_fi_af_sweep_ready <id>` filters stdin candidate lines and prints only ready ones, logging each skip.

- [ ] **Step 1: Failing test (append to `tests/autofix-landing.bats`)**

```bash
@test "sweep: candidates missing on the landing branch or busy are skipped and logged" {
  fi_af_sweep_fixture 5
  printf '# busy\n' >> src/f1.sh                               # busy
  printf -- '- [open] 2026-10-05 src/ghost.sh:1 — not pushed (fix: medium)\n' >> docs/found-issues.md
  git config found-issues.autofix.testCommand 'sh test.sh'
  source "$FI_BIN"; fi_af_context
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
```

- [ ] **Step 2: Run to confirm failure**

Run: `bats tests/autofix-landing.bats -f '^sweep:'`
Expected: FAIL (`src/f1.sh` is in the entries file).

- [ ] **Step 3: Implement**

```bash
# Spec §3: a sweep leaves out entries whose file is not on the landing
# branch yet or is busy in the sweep's root checkout; they stay eligible.
_fi_af_sweep_ready() {
  local id="$1" entry p keep="$AFI_entry"
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    [[ -n "$entry" ]] || continue
    AFI_entry="$entry"
    if p="$(_fi_af_entry_file)"; then
      fi_entry_loc_v "$entry" || true
      if ! git -C "$AFI_root" cat-file -e "origin/$AFI_base:$p" 2>/dev/null; then
        fi_af_log "$id" "sweep: skip $FE_loc (not on origin/$AFI_base)"; continue
      fi
      if [[ -n "$(git -C "$AFI_root" diff --name-only "origin/$AFI_base" -- "$p" 2>/dev/null)" ]]; then
        fi_af_log "$id" "sweep: skip $FE_loc (busy)"; continue
      fi
    fi
    printf '%s\n' "$entry"
  done
  AFI_entry="$keep"
}
```

In `fi_af_sweep_claim`, replace the candidates line with:

```bash
    fi_af_sweep_candidates "$file" "$AFI_root" 1000 | _fi_af_sweep_ready "$id" \
      | head -n "$(fi_af_int sweepMax 8)" >"$FI_AF_ST/sweeps/$id.entries"
```

Check `fi_entry_loc_v` sets `FE_loc` (`lib/annotate.sh:40`). If it names the variable differently, use that name in the two log lines.

- [ ] **Step 4: Run tests**

Run: `bats tests/autofix-landing.bats tests/autofix-sweep.bats tests/autofix-sweep-b.bats`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/autofix-sweep.sh tests/autofix-landing.bats
git commit -m "feat(autofix): sweeps skip entries missing on the landing branch or busy"
```

### Task 5: Sync closes merged auto-fix PRs whatever their base

**Files:**
- Modify: `lib/sync.sh` (`_fi_pr_info` jq ~135-136; landed check ~216-226)
- Test: `tests/cli-sync-pr-states.bats`

**Interfaces:**
- `_fi_pr_ans` becomes 4 fields: state, baseRefName, mergedAt, headRefName (`\x1f`-joined). Every existing reader takes field 1 (`%%$'\x1f'*`) or reads 3 fields with `read -r a b c` (the 4th is absorbed into `c` unless a 4th var is added). Update the one 3-var read to 4 vars.

- [ ] **Step 1: Failing tests (append to `tests/cli-sync-pr-states.bats`)**

```bash
@test "sync: a merged auto-fix PR into a working branch flips to fixed" {
  fi_init_github_repo foo/bar main
  export GH_MOCK_PR_VIEW=$'42\t{"state":"MERGED","baseRefName":"gsd/phase-01","mergedAt":"2026-10-05T06:00:00Z","headRefName":"fi/autofix/src-foo-py-1-20261005-000000-00001","isDraft":false}'
  export GH_MOCK_PR_LIST='[]'
  mkdir -p src && printf 'x\n' > src/foo.py
  fi_seed_entry "src/foo.py:1 — bug (PR: foo/bar#42)"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[fixed\].*(PR: foo/bar#42)' docs/found-issues.md
}

@test "sync: a merged non-auto-fix PR into a working branch still waits for main" {
  fi_init_github_repo foo/bar main
  export GH_MOCK_PR_VIEW=$'42\t{"state":"MERGED","baseRefName":"gsd/phase-01","mergedAt":"2026-10-05T06:00:00Z","headRefName":"feat/x","isDraft":false}'
  export GH_MOCK_PR_LIST='[]'
  mkdir -p src && printf 'x\n' > src/foo.py
  fi_seed_entry "src/foo.py:1 — bug (PR: foo/bar#42)"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q '^- \[open\].*(PR: foo/bar#42)' docs/found-issues.md
}
```

- [ ] **Step 2: Run to confirm the first fails**

Run: `bats tests/cli-sync-pr-states.bats -f 'working branch'`
Expected: the auto-fix test FAILs (entry stays `[open]`); the second passes already.

- [ ] **Step 3: Implement**

In `_fi_pr_info`: `--json state,baseRefName,mergedAt,headRefName` and `--jq '[.state, .baseRefName, (.mergedAt // ""), (.headRefName // "")] | join("\u001f")'`.

In the landed block:

```bash
          local pr_state pr_branch pr_merged_at pr_head
          IFS=$'\x1f' read -r pr_state pr_branch pr_merged_at pr_head <<<"$_fi_pr_ans"
          local pr_landed=0
          if [[ "$pr_state" == "MERGED" ]]; then
            if [[ -z "$default_branch" || "$pr_branch" == "$default_branch" ]]; then
              pr_landed=1
            elif [[ "$pr_head" == fi/autofix/* || "$pr_head" == fi/sweep/* ]]; then
              # 3.2.0 (spec §4): an auto-fix lands in the session's branch;
              # the operator decided that closes the entry.
              pr_landed=1
            elif [[ -n "$pr_branch" && -n "$pr_merged_at" ]]; then
```

(The rest of the `elif` chain is unchanged.) Run `rg -n "_fi_pr_ans" lib/` and confirm no other reader splits more than the first field.

- [ ] **Step 4: Run tests**

Run: `bats tests/cli-sync-pr-states.bats tests/cli-sync.bats tests/autofix-tags.bats`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/sync.sh tests/cli-sync-pr-states.bats
git commit -m "feat(sync): a merged auto-fix PR closes its entry whatever branch it landed in"
```

### Task 6: Status shows landing and waiting

**Files:**
- Modify: `lib/autofix-status.sh` (`fi_af_status` running/queued rows ~112-120)
- Test: `tests/autofix-status.bats`

- [ ] **Step 1: Failing test (append to `tests/autofix-status.bats`; reuse that file's setup)**

```bash
@test "status: a waiting queued item shows why, a running item shows its landing branch" {
  fi_af_context
  q="$(ls "$FI_AF_ST/queue" | head -1)"
  fi_af_item_set "$FI_AF_ST/queue/$q" waiting "src/calc.sh busy in $REPO"
  run "$FI_BIN" autofix status
  [[ "$output" == *"waiting: src/calc.sh busy in $REPO"* ]]
}
```

If `tests/autofix-status.bats`'s setup does not queue an item, call `fi_af_queue_fixture` first in this test.

- [ ] **Step 2: Run to confirm failure**

Run: `bats tests/autofix-status.bats -f 'waiting queued'`
Expected: FAIL.

- [ ] **Step 3: Implement**

In the queued branch of the row loop:

```bash
        printf '  %s  %s  %s\n' "$AFI_id" "${AFI_kind:-spot}" "${AFI_loc:-sweep}"
        [[ -n "$AFI_waiting" ]] && printf '      waiting: %s\n' "$AFI_waiting"
```

In the running branch, after its printf: `[[ -n "$AFI_base" ]] && printf '      into %s (%s)\n' "$AFI_base" "${AFI_base_why:-?}"`.

- [ ] **Step 4: Run tests**

Run: `bats tests/autofix-status.bats tests/cli-status-autofix.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/autofix-status.sh tests/autofix-status.bats
git commit -m "feat(autofix): status shows waiting items and each run's landing branch"
```

### Task 7: Full suite, red-on-old proof, release 3.2.0

**Files:**
- Modify: `CHANGELOG.md`, `README.md` (status line + test count), `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, `bin/found-issues` (`FI_VERSION`)

- [ ] **Step 1: Prove every new test fails on 3.1.4.** In a scratch worktree at `origin/main`, copy in only the new and changed `tests/*.bats` and `tests/autofix-helpers.bash`, then run `bats tests/autofix-landing.bats tests/cli-sync-pr-states.bats tests/autofix-stop.bats tests/autofix-status.bats`. Expected: every new test FAILs and every pre-existing test passes. Record the counts.
- [ ] **Step 2: Full suite on the branch.** Run `bats tests/` (it takes about 10 minutes; run it in the background). Expected: 0 failures. Quote the summary line.
- [ ] **Step 3: shellcheck.** Run `shellcheck lib/autofix-queue.sh lib/autofix.sh lib/autofix-hook.sh lib/autofix-sweep.sh lib/sync.sh lib/autofix-status.sh`. Expected: clean.
- [ ] **Step 4: Version bump to 3.2.0.** Bump both `plugin.json` files and `FI_VERSION`. In README, change `**v3.1.4**` to `**v3.2.0**` and set the test count to the new `@test` total. Add this CHANGELOG section:

```markdown
## [3.2.0] - 2026-10-05

### Changed

- Auto-fix starts from, and opens its PR into, the branch the session works on instead of the default branch: the tracked branch; for a merged branch, the base of its merged PR; for a never-pushed branch, its nearest pushed ancestor; the default branch when on it or detached. The item, run log and `autofix status` record the branch and why.
- Sync closes an entry whose `fi/autofix/*` or `fi/sweep/*` PR merged, whatever branch it merged into. Other stacked PRs still wait until their branch reaches the default branch.

### Added

- A spot item whose cited file is not on the landing branch yet, or has uncommitted or unpushed changes in the session's checkout, waits in the queue (`waiting=`) instead of spending a daily slot. It is rechecked at most every 15 minutes, on a stop inside its checkout, and retired stale after 3 days. Sweeps skip such entries.
```

- [ ] **Step 5: Run `bats tests/check-version.bats tests/docs-consistency.bats` and `bash scripts/check-version.sh`.** Expected: PASS, MINOR bump with `### Added`.
- [ ] **Step 6: Commit**, then open the PR through the normal flow (merge main in if BEHIND; never force-push). Watch CI to a terminal state, then watch the post-merge main run to a terminal state on macos-latest.

### Task 8: Live verification and rollout (after merge)

- [ ] **Step 1: Throwaway repo AltDoug/fi-v3-e2e.** `gh repo view AltDoug/fi-v3-e2e` must exist; if not, stop and ask the operator. Clone into the scratchpad and enable auto-fix. Push branch `work/live` containing the fixture bug, log `--fix small` from a checkout on `work/live`, and run `found-issues autofix run <id> --engine claude`. Expected: the PR has base `work/live`, it merges into `work/live`, and `found-issues sync` flips the entry `[fixed]`. Quote `gh pr view <N> --json baseRefName,state`.
- [ ] **Step 2: Retarget case.** Open a fix PR into `work/live2`, merge `work/live2` into main first (auto-delete on), and record `gh pr view <N> --json baseRefName,state`. If it was closed instead of retargeted, log it with `found-issues log --decide`.
- [ ] **Step 3: Release and marketplace.** Confirm the v3.2.0 release exists (`gh release list -L 1`), then open the claude-plugins marketplace bump to 3.2.0 and merge it (no CI there; squash).
- [ ] **Step 4: Record the decision on the found-issues ledger entry `lib/autofix-queue.sh:102` with `found-issues decide`** (answer: "3.2.0 waits at claim time and lands on the session's branch") in a ledger-only PR.
- [ ] **Step 5: kh2-midgar (operator checkpoint first).** After dougstation runs 3.2.0, the two parked `(decide:)` entries (`tools/bin/build.sh`, `tools/verify/scenarios/canary-event66.yml:36`) can be retagged `--fix small` with `found-issues tag`. Ask the operator before writing to that repo's ledger.
