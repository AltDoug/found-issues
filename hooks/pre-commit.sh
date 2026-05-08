#!/usr/bin/env bash
# pre-commit.sh — git pre-commit hook (per-repo, opt-in)
#
# Installed via `found-issues install-precommit` into a repo's .git/hooks/.
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

  # 1. Bare 'PR #N'
  if [[ "$line" =~ PR[[:space:]]+#[0-9]+ ]] && [[ "$line" != *"(PR: "* ]]; then
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
  echo "To uninstall: found-issues install-precommit --remove"
} >&2

exit 1
