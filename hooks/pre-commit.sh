#!/usr/bin/env bash
# pre-commit.sh — git pre-commit hook (per-repo, opt-in)
#
# Installed manually: copy this file to a repo's .git/hooks/pre-commit and
# chmod +x it (there is no installer subcommand).
# Validates staged content of docs/found-issues.md (or .found-issues.md)
# against the format spec. Blocks the commit on any violation.
#
# This hook is the second line of defense for users who edit found-issues.md
# manually outside Claude Code (where the PreToolUse format-enforcer doesn't
# fire). Same validation rules as hooks/format-enforcer.sh — kept in sync
# manually until lib/validate.sh exists in a future refactor.
#
# Exit codes:
#   0 — allow commit (no violations or no found-issues.md staged)
#   1 — block commit; message to stderr

set -euo pipefail

# Allow opt-out
if [[ "${FOUND_ISSUES_PRE_COMMIT:-on}" == "off" ]]; then
  exit 0
fi

# Determine which file to check (prefer docs/, fall back to .found-issues.md)
target=""
for candidate in "docs/found-issues.md" ".found-issues.md"; do
  if git diff --cached --name-only 2>/dev/null | grep -Fxq -- "$candidate"; then
    target="$candidate"
    break
  fi
done

# Nothing relevant staged — allow
if [[ -z "$target" ]]; then
  exit 0
fi

# Get the staged content (the version that would be committed)
staged_content="$(git show ":0:$target" 2>/dev/null || true)"
if [[ -z "$staged_content" ]]; then
  exit 0
fi

# === Validation (mirrors hooks/format-enforcer.sh rules) ===

violations=""

while IFS= read -r line; do
  if [[ ! "$line" =~ ^-[[:space:]]+\[ ]]; then
    continue
  fi

  reason=""

  # 1. Bare 'PR #N' — canonical annotations stripped first so a bare ref
  # can't ride alongside one (mirrors format-enforcer.sh rule 1).
  line_sans_canonical="$(printf '%s' "$line" | sed -E 's|\(PR(-closed)?: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+\)||g')"
  if [[ "$line_sans_canonical" =~ PR[[:space:]]+#[0-9]+ ]]; then
    reason="bare 'PR #N' — use canonical '(PR: org/repo#N)' form"
  fi

  # 2. Wrong-case status
  if [[ -z "$reason" ]] && [[ "$line" =~ ^-[[:space:]]+\[[A-Z]+\] ]]; then
    reason="status must be lowercase: [open] / [deferred] / [fixed]"
  fi

  # 3. Hyphen separator instead of em-dash
  if [[ -z "$reason" ]] \
     && [[ "$line" =~ ^-[[:space:]]+\[(open|deferred|fixed)\] ]] \
     && [[ "$line" != *" — "* ]] \
     && [[ "$line" == *" - "* ]]; then
    reason="separator must be ' — ' (em-dash, U+2014), not ' - ' (hyphen)"
  fi

  # 4. Critical bundled into status
  if [[ -z "$reason" ]] && [[ "$line" =~ ^-[[:space:]]+\[(critical|P[0-9]|high|low)\] ]]; then
    reason="critical flag is a separate token '[!]' after status"
  fi

  # 5. Bare PR with no org prefix
  if [[ -z "$reason" ]] && [[ "$line" =~ \(PR:[[:space:]]+[^/[:space:]]+#[0-9]+\) ]]; then
    reason="PR annotation needs full 'org/repo#N' format"
  fi

  # 6. Workflow: [fixed] lines must carry a verification token (mirrors
  # format-enforcer.sh rule 6 — manual flips committed outside Claude Code
  # bypass exactly the workflow the enforcer blocks). Valid tokens:
  # (PR: org/repo#N), (commit: <sha>), (verified: ai|review),
  # (closure: tombstone). Demoted forms do NOT count.
  if [[ -z "$reason" ]] && [[ "$line" =~ ^-[[:space:]]+\[fixed\] ]]; then
    if ! { [[ "$line" =~ \(PR:[[:space:]]+[^/[:space:]]+/[^#[:space:]]+#[0-9]+\) ]] \
        || [[ "$line" =~ \(commit:[[:space:]]+[0-9a-f]{7,40}\) ]] \
        || [[ "$line" =~ \(verified:[[:space:]]+(ai|review)\) ]] \
        || [[ "$line" =~ \(closure:[[:space:]]+tombstone\) ]]; }; then
      reason="[fixed] requires a verification token: (PR: org/repo#N), (commit: <sha>), (verified: ai|review), or (closure: tombstone). Direct [open]→[fixed] edits bypass the workflow — use /found-issues:sync (after /found-issues:annotate-commit or :annotate-pr) instead."
    fi
  fi

  if [[ -n "$reason" ]]; then
    violations+="$line"$'\t'"$reason"$'\n'
  fi
done <<< "$staged_content"

if [[ -z "$violations" ]]; then
  exit 0
fi

# Report and block
{
  echo "found-issues: pre-commit format violations in $target"
  echo
  while IFS=$'\t' read -r bad_line reason; do
    [[ -z "$bad_line" ]] && continue
    echo "  Line:   $bad_line"
    echo "  Issue:  $reason"
    echo
  done <<< "$violations"
  echo "Use \`found-issues log\` (or /found-issues:log inside Claude Code) to add entries —"
  echo "the format is handled automatically and these errors don't happen."
  echo
  echo "To skip this hook for one commit: git commit --no-verify"
  echo "To uninstall: rm .git/hooks/pre-commit"
} >&2

exit 1
