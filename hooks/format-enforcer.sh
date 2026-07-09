#!/usr/bin/env bash
# format-enforcer.sh — PreToolUse hook on Write|Edit|MultiEdit
#
# Validates entries written to docs/found-issues.md against the format spec.
# Blocks malformed entries before they land. Catches:
#   - Bare 'PR #N' (must be '(PR: org/repo#N)')
#   - Wrong-case status ([OPEN] vs [open])
#   - Hyphen separator ' - ' vs em-dash ' — '
#   - Wrong date format
#   - [critical] / [P0] etc. (must be '[!]' separate token)
#
# Mode-aware behavior (auto-detected from cwd):
#   local         — disabled (no consumer of the format here)
#   git           — passive warn (advisory but doesn't block)
#   github-direct — hard block (sync depends on canonical (commit:..))
#   github-pr     — hard block (sync depends on canonical (PR:..))
#
# Hook event: PreToolUse (matchers: Write, Edit, MultiEdit)
# Exit codes:
#   0 — allow (no violations, or warn-only mode)
#   2 — block (violations in github-* mode)

set -euo pipefail

# Allow opt-out
if [[ "${FOUND_ISSUES_FORMAT_ENFORCER:-on}" == "off" ]]; then
  exit 0
fi

input="$(cat)"

# Extract fields via jq (with grep fallback)
get_field() {
  local field="$1"
  local default="${2:-}"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$input" | jq -r "$field // empty" 2>/dev/null || printf '%s' "$default"
  else
    printf '%s' "$default"
  fi
}

tool_name="$(get_field '.tool_name')"
file_path="$(get_field '.tool_input.file_path')"

# Only fire for found-issues files
case "$file_path" in
  *docs/found-issues.md|*.found-issues.md) ;;
  *) exit 0 ;;
esac

# Collect candidate content based on tool
content=""
case "$tool_name" in
  Write)
    content="$(get_field '.tool_input.content')"
    ;;
  Edit)
    content="$(get_field '.tool_input.new_string')"
    ;;
  MultiEdit)
    if command -v jq >/dev/null 2>&1; then
      content="$(printf '%s' "$input" | jq -r '.tool_input.edits[]?.new_string // empty' 2>/dev/null || true)"
    fi
    ;;
  *)
    exit 0
    ;;
esac

if [[ -z "$content" ]]; then
  exit 0
fi

# === Validation ===
#
# Each violation is recorded as "LINE_TEXT||REASON". We collect all violations
# in $content and report them together so Claude can fix in one pass.

violations=""

while IFS= read -r line; do
  # Skip non-entry lines (only validate lines that look like entries)
  if [[ ! "$line" =~ ^-[[:space:]]+\[ ]]; then
    continue
  fi

  reason=""

  # 1. Bare 'PR #N' — must be canonical (PR: org/repo#N). Canonical
  # annotations are stripped BEFORE the check: the earlier whole-line
  # "(PR: " whitelist let a bare ref ride alongside a canonical one —
  # format-spec declares that pattern blocked, and the bare ref stays
  # invisible to sync and the statusline.
  line_sans_canonical="$(printf '%s' "$line" | sed -E 's|\(PR(-closed)?: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+\)||g')"
  if [[ "$line_sans_canonical" =~ PR[[:space:]]+#[0-9]+ ]]; then
    reason="bare 'PR #N' — use canonical '(PR: org/repo#N)' form (or run /found-issues:annotate-pr)"
  fi

  # 2. Wrong-case status
  if [[ -z "$reason" ]] && [[ "$line" =~ ^-[[:space:]]+\[[A-Z]+\] ]]; then
    reason="status must be lowercase: [open] / [deferred] / [fixed]"
  fi

  # 3. Hyphen separator (' - ') instead of em-dash (' — ')
  # Heuristic: line has format-shaped prefix but uses ' - ' as separator.
  if [[ -z "$reason" ]] \
     && [[ "$line" =~ ^-[[:space:]]+\[(open|deferred|fixed)\] ]] \
     && [[ "$line" != *" — "* ]] \
     && [[ "$line" == *" - "* ]]; then
    reason="separator must be ' — ' (em-dash, U+2014), not ' - ' (hyphen)"
  fi

  # 4. Critical priority bundled into status
  if [[ -z "$reason" ]] && [[ "$line" =~ ^-[[:space:]]+\[(critical|P[0-9]|high|low)\] ]]; then
    reason="critical flag is a separate token '[!]' after status, not '[${BASH_REMATCH[1]}]'"
  fi

  # 5. Bare PR with no org prefix: (PR: foo#5) without slash
  if [[ -z "$reason" ]] && [[ "$line" =~ \(PR:[[:space:]]+[^/[:space:]]+#[0-9]+\) ]]; then
    reason="PR annotation needs full 'org/repo#N' format, missing org prefix"
  fi

  # 6. Workflow: [fixed] lines must carry a verification token.
  # Catches direct [open]→[fixed] flips that bypass /found-issues:sync.
  # Valid tokens (any one is enough):
  #   (PR: org/repo#N)      — canonical PR
  #   (commit: <sha>)       — canonical commit
  #   (verified: ai)        — sync phase-2 AI verification
  #   (verified: review)    — code-review verification
  #   (closure: tombstone)  — auto-closure (file/line gone)
  # Demoted forms ((PR-closed: …), (commit-stale: …)) do NOT count — they are
  # weak evidence per the sync spec, not verification.
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
done <<< "$content"

if [[ -z "$violations" ]]; then
  exit 0
fi

# === Determine action based on mode ===

mode="local"
# Locate lib for detect-mode (plugin root preferred)
if [[ -n "${FOUND_ISSUES_LIB_DIR:-}" ]]; then
  lib_dir="$FOUND_ISSUES_LIB_DIR"
elif [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
  lib_dir="$CLAUDE_PLUGIN_ROOT/lib"
else
  cli_dir="$(dirname "$(readlink -f "${FOUND_ISSUES_BIN:-found-issues}" 2>/dev/null || command -v "${FOUND_ISSUES_BIN:-found-issues}" 2>/dev/null || echo "")")"
  lib_dir="$cli_dir/../lib"
fi
if [[ -f "$lib_dir/detect-mode.sh" ]]; then
  # shellcheck source=../lib/detect-mode.sh
  source "$lib_dir/detect-mode.sh"
  mode="$(fi_detect_mode 2>/dev/null || echo "local")"
fi

# Format the violation report
report="found-issues format violations in ${file_path##*/}:"$'\n\n'
while IFS=$'\t' read -r bad_line reason; do
  [[ -z "$bad_line" ]] && continue
  report+="  Line:   $bad_line"$'\n'
  report+="  Issue:  $reason"$'\n\n'
done <<< "$violations"

report+="Use /found-issues:log to add entries — it handles format automatically and prevents these errors."

case "$mode" in
  local)
    # No consumer; skip entirely
    exit 0
    ;;
  git)
    # Passive warn — emit to stderr but allow
    printf '%s\n' "$report" >&2
    exit 0
    ;;
  github-direct|github-pr)
    # Hard block
    printf '%s\n' "$report" >&2
    exit 2
    ;;
  *)
    # Unknown mode — fail open
    exit 0
    ;;
esac
