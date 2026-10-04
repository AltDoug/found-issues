#!/usr/bin/env bash
# fix-plumbing.sh — `found-issues fix workspace|test|ship`: the interactive
# /found-issues:fix command on the auto-fix plumbing (spec 2026-10-03 §6;
# audit prompt-8 isolation, prompt-9 committed annotations, prompt-10 any
# test stack). The approval gate stays in the command; this is mechanics.
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   cmd_fix <workspace|test|ship> [...]

_fi_fix_usage() {
  cat <<'EOF'
Usage: found-issues fix workspace
         A fresh worktree from origin/<default> on its own fix branch
       found-issues fix test <worktree>
         Run the repo's test command there (any stack)
       found-issues fix ship <worktree> --title "<title>" --body-file <file> --pick <loc>[,<loc>...]
         Push, open the PR, annotate the picked entries (source ledger and PR
         branch). Never merges.
EOF
}

# prompt-8: a unique branch per run (the per-day name collided) from a
# freshly fetched origin/<default>, never the session's own checkout.
_fi_fix_workspace() {
  local root base stamp wt br t
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || { fi_err "fix: not in a git repo"; return 1; }
  git -C "$root" remote get-url origin >/dev/null 2>&1 || { fi_err "fix: no origin remote"; return 1; }
  base="$(cd "$root" && fi_resolve_default_branch)"
  git -C "$root" fetch -q origin "$base" 2>/dev/null || { fi_err "fix: git fetch origin $base failed"; return 1; }
  printf -v stamp '%s-%05d' "$(date +%Y%m%d)" "$RANDOM"
  wt="$root/.claude/worktrees/fi-fix-$stamp"
  br="fix/found-issues-$stamp"
  mkdir -p "$root/.claude/worktrees"
  git -C "$root" worktree add -q -b "$br" "$wt" "origin/$base" >/dev/null 2>&1 \
    || { fi_err "fix: git worktree add failed"; return 1; }
  t="$(fi_af_test_command "$wt" 2>/dev/null || printf 'none')"
  printf 'worktree=%s\nbranch=%s\nbase=%s\nsource=%s\ntest=%s\n' "$wt" "$br" "$base" "$root" "$t"
}

# prompt-10: the detected test command, so allowed-tools needs no runner.
_fi_fix_test() {
  local wt="$1" t log rc=0
  [[ -d "$wt" ]] || { fi_err "fix test: no such worktree: $wt"; return 2; }
  t="$(fi_af_test_command "$wt")" || { fi_err "fix test: no test command found (set found-issues.autofix.testCommand)"; return 2; }
  log="$(mktemp "${TMPDIR:-/tmp}/fi-fix-test.XXXXXX")"
  fi_af_run_tests "$wt" "$t" "$log" || rc=$?
  tail -n 30 "$log" 2>/dev/null
  tail -n 5 "$log.err" 2>/dev/null
  rm -f "$log" "$log.err"
  if (( rc == 0 )); then printf 'tests: pass\n'; else printf 'tests: fail (exit %s)\n' "$rc"; fi
  return $rc
}

# prompt-9: the (PR:) annotation is committed onto the PR branch too, so it
# reaches the default branch on merge, and the run leaves no ledger diff
# behind in the worktree.
_fi_fix_ship() {
  local wt="" title="" bodyf="" picks="" root base br slug url pr p
  [[ $# -gt 0 ]] && { wt="$1"; shift; }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title) fi_need_value "fix ship" --title $# "${2:-}" || return 2; title="$2"; shift 2 ;;
      --body-file) fi_need_value "fix ship" --body-file $# "${2:-}" || return 2; bodyf="$2"; shift 2 ;;
      --pick) fi_need_value "fix ship" --pick $# "${2:-}" || return 2; picks="$2"; shift 2 ;;
      *) fi_unknown_arg "fix ship" "$1"; return 2 ;;
    esac
  done
  [[ -d "$wt" && -n "$title" && -f "$bodyf" && -n "$picks" ]] || { _fi_fix_usage >&2; return 2; }
  # The main checkout: the parent of the common git dir (git < 2.31 has no
  # --path-format, and the dir may be printed relative to the worktree).
  root="$(cd "$wt" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && cd .. && pwd)" \
    || { fi_err "fix ship: $wt is not a git worktree"; return 1; }
  slug="$(cd "$root" && fi_repo_id 2>/dev/null)" || { fi_err "fix ship: origin is not a GitHub repo"; return 1; }
  base="$(cd "$root" && fi_resolve_default_branch)"
  br="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [[ -n "$br" && "$br" != "$base" && "$br" != "HEAD" ]] || { fi_err "fix ship: $wt is on ${br:-no branch}, not a fix branch"; return 1; }
  [[ -n "$(git -C "$wt" rev-list "origin/$base..HEAD" 2>/dev/null)" ]] \
    || { fi_err "fix ship: $br has no commits ahead of origin/$base"; return 1; }
  [[ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ]] \
    || { fi_err "fix ship: $wt has uncommitted changes — commit each fix first"; return 1; }
  _fi_fix_test "$wt" >/dev/null || { fi_err "fix ship: tests fail in $wt — not shipping"; return 1; }
  fi_af_no_prompts
  git -C "$wt" push -q -u origin "$br" 2>/dev/null || { fi_err "fix ship: git push failed"; return 1; }
  url="$(cd "$wt" && gh pr create --repo "$slug" --base "$base" --head "$br" --title "$title" --body-file "$bodyf")" \
    || { fi_err "fix ship: gh pr create failed"; return 1; }
  pr="${url##*/}"
  [[ "$pr" =~ ^[0-9]+$ ]] || { fi_err "fix ship: no PR number in: $url"; return 1; }
  ( cd "$root" && "$FI_SELF" annotate-pr "$pr" --pick "$picks" >/dev/null ) \
    || fi_err "fix ship: source ledger annotation failed — run: found-issues annotate-pr $pr --pick $picks"
  # annotate-pr finds its ledger by walking up from cwd: only run it in the
  # worktree when the worktree has its own ledger, or it would walk up into
  # the source checkout's.
  if [[ -f "$wt/docs/found-issues.md" || -f "$wt/.found-issues.md" ]]; then
    ( cd "$wt" && "$FI_SELF" annotate-pr "$pr" --pick "$picks" >/dev/null 2>&1 ) || true
    if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then
      for p in docs/found-issues.md .found-issues.md; do
        [[ -f "$wt/$p" ]] && git -C "$wt" add -- "$p"
      done
      if ! { git -C "$wt" commit -q -m "docs(found-issues): annotate PR $pr" && git -C "$wt" push -q origin "$br"; } 2>/dev/null; then
        fi_err "fix ship: could not commit the annotation onto $br"
      fi
    fi
  fi
  printf 'PR #%s: %s\n' "$pr" "$url"
}

cmd_fix() {
  local sub="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$sub" in
    workspace) [[ $# -eq 0 ]] || { _fi_fix_usage >&2; return 2; }; _fi_fix_workspace ;;
    test) [[ $# -eq 1 ]] || { _fi_fix_usage >&2; return 2; }; _fi_fix_test "$1" ;;
    ship) _fi_fix_ship "$@" ;;
    -h|--help|"") _fi_fix_usage ;;
    *) fi_unknown_arg fix "$sub"; return 2 ;;
  esac
}
