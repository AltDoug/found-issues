#!/usr/bin/env bash
# lib/repo-id.sh — fi_repo_id, shared by bin/found-issues and hooks/post-bash-dispatch.sh
# so the CLI and the hook derive the origin slug by one set of rules.

# Get the GitHub repo identifier (org/repo) from the current repo's origin.
# Echoes empty if not on GitHub.
fi_repo_id() {
  local remote_url
  remote_url="$(git remote get-url origin 2>/dev/null || true)"
  if [[ "$remote_url" != *"github.com"* ]]; then
    # get-url expands url.<x>.insteadOf; the configured URL still names the
    # GitHub repo (a mirror or a local bare remote in tests).
    remote_url="$(git config --get remote.origin.url 2>/dev/null || true)"
    [[ "$remote_url" == *"github.com"* ]] || return 1
  fi
  # Strip trailing slashes, then a literal .git suffix, then capture the
  # last two path segments verbatim. The earlier single-pass form used
  # [^/.]+ for the repo segment, truncating dotted repo names
  # (vercel/next.js -> vercel/next) in (PR: ...) annotations, which then
  # made sync query the wrong repo. The slash strip comes first so
  # pasted-URL remotes like https://github.com/org/repo.git/ still lose
  # the .git suffix.
  # Builtin (no sed fork); same three steps.
  while [[ "$remote_url" == */ ]]; do remote_url="${remote_url%/}"; done
  remote_url="${remote_url%.git}"
  local re_gh='github\.com[:/]([^/]+/[^/]+)'
  [[ "$remote_url" =~ $re_gh ]] || return 1
  local id="${BASH_REMATCH[1]}"
  local re_id='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
  [[ "$id" =~ $re_id ]] || return 1
  printf '%s' "$id"
}
