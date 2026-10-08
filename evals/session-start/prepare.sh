#!/usr/bin/env bash
# prepare.sh --out DIR -- build the old arm for the session-start eval.
#
# Extracts the v3.3.1 tag into <out>/arms/old with `git archive | tar -x`
# (never `git worktree add`) and verifies .claude-plugin/plugin.json says
# 3.3.1. Idempotent: an already-correct <out>/arms/old is left alone; a
# non-empty directory with anything else in it is an error. Also reports the
# version of the checkout the other arms use. No claude run, no cost.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) EVAL_OUT="$2"; shift 2 ;;
    *) fi_eval_die "unknown argument '$1'" ;;
  esac
done
fi_eval_require_out

TAG=v3.3.1
OLD="$EVAL_OUT/arms/old"

version_of() { jq -r '.version // empty' "$1/.claude-plugin/plugin.json" 2>/dev/null; }

git -C "$EVAL_REPO" rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
  || fi_eval_die "tag $TAG not found in $EVAL_REPO"

if [[ -f "$OLD/.claude-plugin/plugin.json" && -f "$OLD/hooks/session-start.sh" ]]; then
  [[ "$(version_of "$OLD")" == "3.3.1" ]] || fi_eval_die "$OLD exists but is not 3.3.1 (is '$(version_of "$OLD")'); use a fresh --out"
  echo "old arm already prepared: $OLD (3.3.1)"
else
  if [[ -d "$OLD" && -n "$(ls -A "$OLD" 2>/dev/null)" ]]; then
    fi_eval_die "$OLD is not empty and is not a 3.3.1 plugin; use a fresh --out"
  fi
  mkdir -p "$OLD"
  git -C "$EVAL_REPO" archive "$TAG" | tar -x -C "$OLD" || fi_eval_die "git archive $TAG failed"
  [[ "$(version_of "$OLD")" == "3.3.1" ]] || fi_eval_die "extracted $OLD but plugin.json says '$(version_of "$OLD")', not 3.3.1"
  [[ -f "$OLD/hooks/session-start.sh" ]] || fi_eval_die "extracted $OLD has no hooks/session-start.sh"
  echo "old arm ready: $OLD (3.3.1, from tag $TAG = $(git -C "$EVAL_REPO" rev-parse --short "$TAG^{commit}"))"
fi
echo "this checkout: $EVAL_REPO (plugin.json $(version_of "$EVAL_REPO"), HEAD $(git -C "$EVAL_REPO" rev-parse --short HEAD))"
