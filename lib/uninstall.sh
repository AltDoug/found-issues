#!/usr/bin/env bash
# uninstall.sh — uninstall — clear plugin-private state
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Extracted verbatim from bin/found-issues in v2.2.6 (the tracked §12 split);
# see the [open] loc-validator entry in docs/found-issues.md.
#
# Functions:
#   cmd_uninstall [...]

# === Subcommand: uninstall ===
#
# Wipes plugin-private state that Claude Code's `/plugin uninstall` doesn't
# clean: the onboarding marker, the mode-detection cache, the statusline
# integration block, and the optional `/fi` shorthand alias from setup.
#
# Does NOT touch: per-repo `docs/found-issues.md` files (user data),
# Claude Code's plugin cache (Claude Code manages those — `/plugin uninstall`),
# or the marketplace clone (separate via `/plugin marketplace remove`).
#
# Order matters: run this BEFORE `/plugin uninstall found-issues` so the
# plugin's CLI is still on PATH while the cleanup runs.

cmd_uninstall() {
  local removed_count=0

  # 1a. Statusline integration — marker-bracketed block (v1.0.0+ installs)
  if [[ -f "$FI_STATUSLINE_FILE" ]] && grep -Fq "$FI_STATUSLINE_START_MARKER" "$FI_STATUSLINE_FILE"; then
    cmd_uninstall_statusline >/dev/null
    printf '✓ removed statusline segment block from %s\n' "$FI_STATUSLINE_FILE"
    removed_count=$((removed_count + 1))
  fi

  # 1b. Statusline integration — pre-v0.1.7 handwritten snippet (no markers).
  # Without this, dogfood-era users running `uninstall` would still have the
  # broken handwritten lines left in their statusline.sh. Use the same
  # surgical-strip helper that `install-statusline --migrate` uses.
  if [[ -f "$FI_STATUSLINE_FILE" ]] && awk -v start="$FI_STATUSLINE_START_MARKER" \
                                          -v endm="$FI_STATUSLINE_END_MARKER" '
      $0 == start { in_block = 1; next }
      $0 == endm { in_block = 0; next }
      !in_block && /found-issues[[:space:]]+status[[:space:]]+--format[=[:space:]]+segment/ { found = 1 }
      END { exit (found ? 0 : 1) }
    ' "$FI_STATUSLINE_FILE" 2>/dev/null; then
    fi_strip_legacy_handwritten "$FI_STATUSLINE_FILE"
    printf '✓ removed pre-v0.1.7 handwritten snippet from %s\n' "$FI_STATUSLINE_FILE"
    removed_count=$((removed_count + 1))
  fi

  # 2. Onboarding marker dir
  if [[ -d "$HOME/.claude/found-issues" ]]; then
    rm -rf "$HOME/.claude/found-issues"
    printf '✓ removed onboarding state at ~/.claude/found-issues/\n'
    removed_count=$((removed_count + 1))
  fi

  # 3. Mode detection cache
  if [[ -d "$HOME/.cache/found-issues" ]]; then
    rm -rf "$HOME/.cache/found-issues"
    printf '✓ removed mode-detection cache at ~/.cache/found-issues/\n'
    removed_count=$((removed_count + 1))
  fi

  # 4. /fi alias (created optionally by /found-issues:setup → install-fi-alias).
  # Delegates the "is this ours?" check to fi_fi_alias_is_ours so we can't
  # drift between install and uninstall heuristics.
  if fi_fi_alias_is_ours; then
    cmd_uninstall_fi_alias >/dev/null
    printf '✓ removed /fi alias at %s\n' "$FI_FI_ALIAS_FILE"
    removed_count=$((removed_count + 1))
  fi

  if (( removed_count == 0 )); then
    printf 'uninstall: nothing to clean (plugin-private state already empty)\n'
  fi

  cat <<'EOF'

Plugin-private state is now clean. Per-repo `docs/found-issues.md` and
`docs/found-issues-archive.md` files are intentionally preserved — they're
your project data.

Next steps to fully remove the plugin:

  /plugin uninstall found-issues
  /plugin marketplace remove altdoug-plugins   (if installed via aggregator)

The above can only be run from inside Claude Code (slash commands).
EOF
}

