#!/usr/bin/env bats
# Batch 3 review fixes: start times as TZ-free epochs compared with slack,
# spaced worktree retries, sweep claims stamp running/ only, a topic entry's
# commit still closes it, unannotate never drops a concurrent write.

load 'helpers'
load 'autofix-helpers'

setup() { fi_setup_tmp; }
teardown() { fi_teardown_tmp; }

_pstart_works() { [ -n "$(ps -o lstart= -p $$ 2>/dev/null)" ]; }

@test "review pstart: the same process reads the same start time under another TZ" {
  _pstart_works || skip "ps has no lstart here"
  source "$FI_BIN"
  _fi_af_pstart $$; a="$FI_AF_PSTART"
  b="$(TZ=Asia/Tokyo LC_ALL=C bash -c 'source "$1"; _fi_af_pstart "$2"; printf "%s" "$FI_AF_PSTART"' _ "$FI_BIN" $$)"
  [ -n "$a" ]
  [ "$a" = "$b" ]
}

@test "review pstart: a start time within 2 s is the same process, 3 s off is not" {
  source "$FI_BIN"
  _fi_af_pstart_same 1000 1002
  _fi_af_pstart_same 1002 1000
  run _fi_af_pstart_same 1000 1003
  [ "$status" -eq 1 ]
}

@test "review pstart: an unknown start time on either side lets the pid decide" {
  source "$FI_BIN"
  _fi_af_pstart_same "" 1000
  _fi_af_pstart_same 1000 ""
  _fi_af_pid_alive $$ ""
}

@test "review worktree: a requeued worktree failure waits before the next try" {
  fi_af_fixture; fi_af_queue_fixture; ST="$FI_AF_ST"
  real="$(command -v git)"; mkdir -p "$TMP/stubbin"
  printf '#!/usr/bin/env bash\ncase " $* " in *" worktree add "*) exit 1 ;; esac\nexec "%s" "$@"\n' "$real" > "$TMP/stubbin/git"
  chmod +x "$TMP/stubbin/git"; export PATH="$TMP/stubbin:$PATH"
  now="$(date +%s)"
  rc=0; "$FI_BIN" autofix claim "$ID" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 8 ]
  next="$(grep '^wait_next=' "$ST/queue/$ID" | cut -d= -f2)"
  [ -n "$next" ]
  [ "$next" -ge $(( now + 60 )) ]
  grep -q '^waiting=.\+' "$ST/queue/$ID"
}

@test "review sweep: a cancel between the check and the stamp cannot revive a sweep" {
  fi_af_sweep_fixture 2; source "$FI_BIN"; fi_af_context; ST="$FI_AF_ST"
  ID=20261010-000000-00091
  fi_af_item_write "$ST/queue/$ID" "id=$ID" kind=sweep "root=$REPO" slug=foo/bar loc=sweep engine=claude crashes=0
  eval "_orig_item_set() $(declare -f fi_af_item_set | sed '1d')"
  fi_af_item_set() {
    if [[ "$1" == "$ST/queue/"* && "$2" == pid ]]; then
      cp "$1" "$1.race"
      mv "$1" "$ST/done/${1##*/}"
      mv "$1.race" "$1"
      return 0
    fi
    _orig_item_set "$@"
  }
  rc=0; fi_af_claim "$ID" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ]
  [ ! -f "$ST/done/$ID" ]
  [ -f "$ST/running/$ID" ]
}

@test "review closer: a topic entry's landed commit still closes it" {
  fi_init_git; export HOME="$TMP/home"; mkdir -p "$HOME"
  echo a > f.txt && git add . && git commit -q -m add
  echo b >> f.txt && git commit -q -am "fix runner env"
  sha="$(git rev-parse --short=7 HEAD)"
  fi_seed_entry "(host env, not repo code) — runner offline (commit: $sha)"
  fi_run sync
  [ "$status" -eq 0 ]
  grep -q "^- \[fixed\].*(commit: $sha)" docs/found-issues.md
  [[ "$output" != *"did not touch"* ]]
}

@test "review unannotate: a write that lands mid-edit is kept, not overwritten" {
  fi_init_git; export HOME="$TMP/home"; mkdir -p "$HOME"
  fi_seed_entry "src/a.sh:1 — bug one (PR: foo/bar#7)"
  source "$FI_BIN"
  # The first replace finds the ledger changed (another session appended an
  # entry after the snapshot); the retry must rebuild from the new file.
  eval "_orig_replace() $(declare -f fi_ledger_replace | sed '1d')"
  n=0
  fi_ledger_replace() {
    n=$((n + 1))
    if (( n == 1 )); then
      printf -- '- [open] 2026-10-10 src/b.sh:2 — CONCURRENT entry\n' >> "$1"
    fi
    _orig_replace "$@"
  }
  run cmd_unannotate "src/a.sh:1" 7
  [ "$status" -eq 0 ]
  grep -q 'CONCURRENT entry' docs/found-issues.md
  ! grep -q '(PR: foo/bar#7)' docs/found-issues.md || false
}
