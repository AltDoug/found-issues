#!/usr/bin/env bash
# statusline-uninstall.sh — uninstall-statusline (default file and --target)
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Extracted verbatim from bin/found-issues in v2.2.5 (the tracked §12 split);
# see the [open] loc-validator entry in docs/found-issues.md.
#
# Functions:
#   cmd_uninstall_statusline [...]
#   cmd_uninstall_statusline_custom_target <path>

# === Subcommand: uninstall-statusline ===
#
# Remove the marker-bracketed block added by install-statusline. Idempotent:
# silently no-ops when the block is absent. Preserves everything outside
# the markers byte-for-byte.

cmd_uninstall_statusline() {
  local target_path=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target) fi_need_value uninstall-statusline --target $# "${2:-}" || return 2
                target_path="$2"; shift 2 ;;
      --target=*) target_path="${1#--target=}"; shift ;;
      -h|--help)
        printf 'Usage: found-issues uninstall-statusline [--target <path>]\n'
        return 0 ;;
      *) fi_unknown_arg uninstall-statusline "$1"; return 2 ;;
    esac
  done

  if [[ -n "$target_path" ]]; then
    cmd_uninstall_statusline_custom_target "$target_path"
    return $?
  fi

  if [[ ! -f "$FI_STATUSLINE_FILE" ]]; then
    fi_err "uninstall-statusline: $FI_STATUSLINE_FILE does not exist"
    return 1
  fi

  if ! grep -Fq "$FI_STATUSLINE_START_MARKER" "$FI_STATUSLINE_FILE"; then
    printf 'uninstall-statusline: not installed (no marker in %s)\n' "$FI_STATUSLINE_FILE"
    return 0
  fi

  local sl_file original_mode tmp backup
  sl_file="$(fi_resolve_link "$FI_STATUSLINE_FILE")"
  if ! fi_markers_balanced "$sl_file" "^${FI_STATUSLINE_START_MARKER}\$" "^${FI_STATUSLINE_END_MARKER}\$"; then
    fi_err "uninstall-statusline: unbalanced found-issues markers in $FI_STATUSLINE_FILE — refusing"
    fi_err "  (a start marker with no matching end marker would delete every line after it)."
    fi_err "  Fix the markers by hand, or remove the block manually."
    return 1
  fi
  backup="$(fi_save_statusline_backup "$sl_file" || true)"
  original_mode=$(fi_capture_mode "$sl_file")
  tmp="$(mktemp -t found-issues-statusline.XXXXXX)"
  # Delete every line from the start marker through the end marker, inclusive.
  # No blank-line tracking needed because install no longer inserts one.
  awk -v start="$FI_STATUSLINE_START_MARKER" -v endm="$FI_STATUSLINE_END_MARKER" '
    $0 == start { skip = 1; next }
    skip && $0 == endm { skip = 0; next }
    !skip { print }
  ' "$sl_file" > "$tmp"

  mv "$tmp" "$sl_file"
  # Restore original mode — see comment in cmd_install_statusline_inline.
  chmod "$original_mode" "$sl_file" 2>/dev/null \
    || chmod +x "$sl_file"
  printf 'uninstall-statusline: removed found-issues segment from %s\n' "$FI_STATUSLINE_FILE"
  [[ -n "$backup" ]] && printf '  backup: %s\n' "$backup"
  return 0
}

# Custom-target uninstall: language-agnostic marker-block removal +
# reference-splice cleanup via `# found-issues:seg` micro-marker.
cmd_uninstall_statusline_custom_target() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    fi_err "uninstall-statusline --target: $path does not exist"
    return 12
  fi

  local has_markers has_invocation
  has_markers=0
  has_invocation=0
  grep -Fq "# === found-issues plugin segment ===" "$path" && has_markers=1
  grep -Fq "// === found-issues plugin segment ===" "$path" && has_markers=1
  grep -Fq "found-issues status --format=segment" "$path" && has_invocation=1

  if [[ $has_markers -eq 0 && $has_invocation -eq 1 ]]; then
    fi_err "uninstall-statusline --target: $path has invocation but no markers — needs AI repair"
    fi_err "  Re-run /found-issues:setup to be offered the markers-stripped repair path."
    return 17  # markers_missing_but_invocation_present
  fi
  if [[ $has_markers -eq 0 ]]; then
    printf 'uninstall-statusline --target: %s was never installed (no-op)\n' "$path"
    return 0
  fi

  # Resolve a symlinked target so the rename lands on the real file and the
  # link survives (audit status-7).
  path="$(fi_resolve_link "$path")"
  if ! fi_markers_balanced "$path" '^(#|//) === found-issues plugin segment ===' '^(#|//) === end found-issues plugin segment ==='; then
    fi_err "uninstall-statusline --target: unbalanced found-issues markers in $path — refusing"
    fi_err "  (a start marker with no matching end marker would delete every line after it)."
    return 1
  fi

  # Same literal surgery the migration path uses (fi_strip_target_markers):
  # the installer's call-form splices nest parens that the old per-form
  # regexes missed for plain console.log("x") / print("x") hosts, leaving a
  # call to a function the removed block defined (audit status-5).
  local language
  language="$(fi_detect_target_language "$path")" || {
    if grep -Fq "// === found-issues plugin segment ===" "$path"; then language=node
    elif grep -Fq "_fi_seg" "$path"; then language=python
    else language=bash; fi
  }
  local scratch backup mode
  scratch="$(fi_strip_to_scratch "$path" "$language")" || {
    fi_err "uninstall-statusline --target: could not prepare the stripped copy of $path"
    return 14
  }
  backup="$(fi_save_statusline_backup "$path" || true)"
  mode="$(fi_capture_mode "$path")"
  mv "$scratch" "$path"
  chmod "$mode" "$path" 2>/dev/null || true

  printf 'uninstall-statusline --target: removed segment from %s\n' "$path"
  [[ -n "$backup" ]] && printf '  backup: %s\n' "$backup"
  return 0
}
