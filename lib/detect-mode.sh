#!/usr/bin/env bash
# detect-mode.sh — auto-detect repo's found-issues mode
#
# Sourced by other scripts. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Modes:
#   local         — no .git/ at all
#   git           — git repo, no GitHub remote (or no gh auth)
#   github-direct — GitHub remote present but no recent merged PRs (solo workflow)
#   github-pr     — GitHub remote with recent merged PRs (PR workflow)
#
# Detection result is cached per-repo for 1h to avoid GitHub API thrashing.
# Cache lives in $HOME/.cache/found-issues/mode_<owner>_<repo>.
# Honors $FOUND_ISSUES_MODE override (any non-empty value short-circuits detection).
#
# Functions:
#   fi_detect_mode
#       Echoes the detected mode (or override). Always succeeds.
#
#   fi_invalidate_mode_cache
#       Removes cached mode for current repo. Useful in tests / after auth changes.

# Echo the detected mode for the current working directory.
fi_detect_mode() {
  # Honor environment override
  if [[ -n "${FOUND_ISSUES_MODE:-}" ]]; then
    printf '%s' "$FOUND_ISSUES_MODE"
    return 0
  fi

  # Not in a git repo → local
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    printf 'local'
    return 0
  fi

  # Get remote URL — try origin, then any remote
  local remote_url
  remote_url="$(git remote get-url origin 2>/dev/null || true)"
  if [[ -z "$remote_url" ]]; then
    local first_remote
    first_remote="$(git remote 2>/dev/null | head -1)"
    if [[ -n "$first_remote" ]]; then
      remote_url="$(git remote get-url "$first_remote" 2>/dev/null || true)"
    fi
  fi

  # No remote, or non-GitHub remote → git
  if [[ -z "$remote_url" || "$remote_url" != *"github.com"* ]]; then
    printf 'git'
    return 0
  fi

  # GitHub remote present. Check gh availability + auth.
  if ! command -v gh >/dev/null 2>&1; then
    printf 'git'
    return 0
  fi
  if ! gh auth status >/dev/null 2>&1; then
    printf 'git'
    return 0
  fi

  # Cached result for this repo?
  local cache_dir="${HOME}/.cache/found-issues"
  mkdir -p "$cache_dir" 2>/dev/null || true

  local repo_id
  repo_id="$(printf '%s' "$remote_url" \
    | sed -E 's|.*github\.com[:/]([^/]+/[^/.]+)(\.git)?.*|\1|' \
    | tr '/' '_')"
  local cache_file="$cache_dir/mode_${repo_id}"

  local ttl=3600  # 1 hour
  if [[ -f "$cache_file" ]]; then
    local mtime now age
    mtime="$(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    age=$((now - mtime))
    if [[ "$age" -lt "$ttl" ]]; then
      cat "$cache_file"
      return 0
    fi
  fi

  # Query for recent merged PRs (last 30 days, limit 5)
  local cutoff
  cutoff="$(date -v-30d +%Y-%m-%d 2>/dev/null \
    || date -d "30 days ago" +%Y-%m-%d 2>/dev/null \
    || true)"

  local recent_count=0
  if [[ -n "$cutoff" ]]; then
    recent_count="$(gh pr list --state merged --limit 5 \
      --search "merged:>$cutoff" --json number 2>/dev/null \
      | grep -c '"number"' || echo 0)"
  fi

  local mode
  if [[ "$recent_count" -gt 0 ]]; then
    mode="github-pr"
  else
    mode="github-direct"
  fi

  printf '%s' "$mode" > "$cache_file" 2>/dev/null || true
  printf '%s' "$mode"
}

# Remove cached mode for the current repo.
fi_invalidate_mode_cache() {
  local remote_url
  remote_url="$(git remote get-url origin 2>/dev/null || true)"
  if [[ -z "$remote_url" || "$remote_url" != *"github.com"* ]]; then
    return 0
  fi

  local repo_id
  repo_id="$(printf '%s' "$remote_url" \
    | sed -E 's|.*github\.com[:/]([^/]+/[^/.]+)(\.git)?.*|\1|' \
    | tr '/' '_')"
  local cache_file="${HOME}/.cache/found-issues/mode_${repo_id}"
  rm -f "$cache_file" 2>/dev/null || true
}
