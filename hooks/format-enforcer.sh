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

IFS= read -r -d '' input || true

# Zero-fork gate (audit hook-6): every Write/Edit/MultiEdit/apply_patch runs
# this hook, and it used to fork cat + two jq before learning the file was
# not a ledger. Both accepted targets end in "found-issues.md", which JSON
# escaping cannot hide except through \u — so a payload without either
# substring cannot be a ledger edit.
[[ "$input" == *found-issues.md* || "$input" == *'\u'* ]] || exit 0

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

# Codex edits files through apply_patch: no file_path, the patch envelope is
# in tool_input.command. Collect the ADDED lines of every hunk that targets a
# ledger file — patch lines are whole lines, so they validate as-is below.
_fi_patch_content=""
if [[ "$tool_name" == "apply_patch" ]]; then
  _fi_cur=""
  while IFS= read -r _fi_pl || [[ -n "$_fi_pl" ]]; do
    case "$_fi_pl" in
      '*** Update File: '*|'*** Add File: '*) _fi_cur="${_fi_pl#\*\*\* * File: }" ;;
      '*** Move to: '*) _fi_cur="${_fi_pl#\*\*\* Move to: }" ;;
      '*** Delete File: '*|'*** End Patch'*) _fi_cur="" ;;
      +*)
        case "$_fi_cur" in
          *docs/found-issues.md|*.found-issues.md|found-issues.md) _fi_patch_content+="${_fi_pl#+}"$'\n'; file_path="$_fi_cur" ;;
        esac
        ;;
    esac
  done <<<"$(get_field '.tool_input.command')"
  [[ -z "$_fi_patch_content" ]] && exit 0
fi

# Only fire for found-issues files
case "$file_path" in
  *docs/found-issues.md|*.found-issues.md) ;;
  *) exit 0 ;;
esac

# fi_edit_touched_lines <old> <new> <replace_all> — the FULL lines an Edit
# will leave behind wherever it applies. Validating new_string alone missed
# sub-line edits: old `[open] 2026-09-01 x.sh:4`, new `[fixed] 2026-09-01
# x.sh:4` has no line starting with `- [`, so a token-less [open]->[fixed]
# flip passed (2026-10-03 audit, hook-5). Applies the edit to an in-memory
# copy of the file ($_fi_doc, updated so MultiEdit can chain) and sets
# $_fi_touched to each occurrence's surrounding lines (a variable, not
# stdout: a $(...) subshell would drop the $_fi_doc update). Lines the edit does not touch are not
# returned — a full-file check would block every edit on grandfathered text.
# Falls back to new_string when the file or old_string cannot be found.
_fi_doc=""
_fi_doc_loaded=0
_fi_touched=""
fi_edit_touched_lines() {
  local old="$1" new="$2" all="$3"
  if (( ! _fi_doc_loaded )); then
    _fi_doc_loaded=1
    [[ -f "$file_path" ]] && _fi_doc="$(cat "$file_path"; printf x)" && _fi_doc="${_fi_doc%x}"
  fi
  if [[ -z "$old" || "$_fi_doc" != *"$old"* ]]; then
    _fi_touched="$new"
    return 0
  fi
  local rest="$_fi_doc" out="" pre head tail touched=""
  while [[ "$rest" == *"$old"* ]]; do
    pre="${rest%%"$old"*}"
    rest="${rest#*"$old"}"
    head="${pre##*$'\n'}"
    tail="${rest%%$'\n'*}"
    touched+="$head$new$tail"$'\n'
    out+="$pre$new"
    [[ "$all" == "true" ]] || break
  done
  _fi_doc="$out$rest"
  _fi_touched="$touched"
}

# Collect candidate content based on tool
content=""
case "$tool_name" in
  Write)
    content="$(get_field '.tool_input.content')"
    ;;
  Edit)
    fi_edit_touched_lines \
      "$(get_field '.tool_input.old_string')" \
      "$(get_field '.tool_input.new_string')" \
      "$(get_field '.tool_input.replace_all')"
    content="$_fi_touched"
    ;;
  MultiEdit)
    if command -v jq >/dev/null 2>&1; then
      # Edits apply in order; each one is validated against the file as the
      # earlier ones left it. One jq call per field: MultiEdit is rare, and
      # NUL-safe batching would need a read loop over process substitution.
      _fi_n="$(printf '%s' "$input" | jq -r '.tool_input.edits | length' 2>/dev/null || echo 0)"
      [[ "$_fi_n" =~ ^[0-9]+$ ]] || _fi_n=0
      for (( _fi_i = 0; _fi_i < _fi_n; _fi_i++ )); do
        fi_edit_touched_lines \
          "$(get_field ".tool_input.edits[$_fi_i].old_string")" \
          "$(get_field ".tool_input.edits[$_fi_i].new_string")" \
          "$(get_field ".tool_input.edits[$_fi_i].replace_all")"
        content+="$_fi_touched"$'\n'
      done
    fi
    ;;
  apply_patch)
    content="$_fi_patch_content"   # collected above
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
  # invisible to sync and the statusline. [fixed] lines are exempt: they
  # are immutable history per the spec, and a full-file Write must not be
  # blocked by grandfathered lines that were legal when written.
  if [[ ! "$line" =~ ^-[[:space:]]+\[fixed\] ]]; then
    line_sans_canonical="$(printf '%s' "$line" | sed -E 's|\(PR(-closed)?: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+\)||g')"
    if [[ "$line_sans_canonical" =~ PR[[:space:]]+#[0-9]+ ]]; then
      reason="bare 'PR #N' — use canonical '(PR: org/repo#N)' form (or run /found-issues:annotate-pr)"
    fi
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
# Locate lib for detect-mode. Script-relative first after the explicit
# override: Codex hooks get no CLAUDE_PLUGIN_ROOT, and the old PATH/readlink
# fallback resolved `found-issues` against the CWD under GNU readlink, so
# mode stayed "local" and nothing was ever blocked there (audit hook-14).
_fi_hook_dir="${BASH_SOURCE[0]%/*}"
[[ "$_fi_hook_dir" == "${BASH_SOURCE[0]}" ]] && _fi_hook_dir=.
lib_dir=""
for _fi_cand in "${FOUND_ISSUES_LIB_DIR:-}" "$_fi_hook_dir/../lib" \
    "${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/lib}"; do
  if [[ -n "$_fi_cand" && -f "$_fi_cand/detect-mode.sh" ]]; then
    lib_dir="$_fi_cand"
    break
  fi
done
if [[ -n "$lib_dir" ]]; then
  # shellcheck source=../lib/detect-mode.sh
  source "$lib_dir/detect-mode.sh"
  mode="$(fi_detect_mode 2>/dev/null || echo "local")"
else
  # Lib-free on purpose (the lib is what is missing): no jq, no helpers. On
  # Claude, stderr on a PreToolUse exit 0 reaches nobody, so the fixed line
  # goes out as hookSpecificOutput.additionalContext JSON; Codex (the same
  # signals as lib/harness.sh fi_detect_harness) keeps stderr.
  if [[ "${FOUND_ISSUES_HARNESS:-}" == "codex" ]] \
      || { [[ "${FOUND_ISSUES_HARNESS:-}" != "claude" && -z "${CLAUDE_CODE_ENTRYPOINT:-}" && -n "${PLUGIN_DATA:-}" ]]; }; then
    echo "found-issues: format-enforcer could not find its lib; ledger format NOT enforced." >&2
  else
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"found-issues: format-enforcer could not find its lib; ledger format NOT enforced."}}'
  fi
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
    # Passive warn, allow. stderr on a PreToolUse exit 0 reaches nobody, so
    # on Claude the report goes out as additionalContext on stdout
    # (fi_emit_pre_context; Codex and no-jq keep stderr).
    if [[ -n "$lib_dir" && -f "$lib_dir/harness.sh" ]]; then
      # shellcheck source=../lib/harness.sh
      source "$lib_dir/harness.sh"
      fi_emit_pre_context "$report"
    else
      printf '%s\n' "$report" >&2
    fi
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
