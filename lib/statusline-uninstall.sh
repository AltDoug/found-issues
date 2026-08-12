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
      --target) target_path="$2"; shift 2 ;;
      --target=*) target_path="${1#--target=}"; shift ;;
      *) shift ;;
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

  local original_mode tmp
  original_mode=$(fi_capture_mode "$FI_STATUSLINE_FILE")
  tmp="$(mktemp -t found-issues-statusline.XXXXXX)"
  # Delete every line from the start marker through the end marker, inclusive.
  # No blank-line tracking needed because install no longer inserts one.
  awk -v start="$FI_STATUSLINE_START_MARKER" -v endm="$FI_STATUSLINE_END_MARKER" '
    $0 == start { skip = 1; next }
    skip && $0 == endm { skip = 0; next }
    !skip { print }
  ' "$FI_STATUSLINE_FILE" > "$tmp"

  mv "$tmp" "$FI_STATUSLINE_FILE"
  # Restore original mode — see comment in cmd_install_statusline_inline.
  chmod "$original_mode" "$FI_STATUSLINE_FILE" 2>/dev/null \
    || chmod +x "$FI_STATUSLINE_FILE"
  printf 'uninstall-statusline: removed found-issues segment from %s\n' "$FI_STATUSLINE_FILE"
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

  # Remove marker block + the `# found-issues:seg` / `// found-issues:seg`
  # micro-marked line's appended variable reference.
  local tmp
  tmp="$(mktemp -t fi-target-uninstall.XXXXXX)"
  awk '
    /# === found-issues plugin segment ===/ { in_block=1; next }
    /# === end found-issues plugin segment ===/ { in_block=0; next }
    /\/\/ === found-issues plugin segment ===/ { in_block=1; next }
    /\/\/ === end found-issues plugin segment ===/ { in_block=0; next }
    in_block { next }
    # Strip the appended seg reference on lines tagged with found-issues:seg.
    /# found-issues:seg/ {
      # Bash: ${__FI_SEG}"  # found-issues:seg  → remove the trailing portion
      sub(/\$\{__FI_SEG\}"[[:space:]]*#[[:space:]]*found-issues:seg.*$/, "\"")
      sub(/\$\{__FI_SEG\}[[:space:]]*#[[:space:]]*found-issues:seg.*$/, "")
      # Node template literal: ${__fiSeg} or ${__fiSeg(...)}  before closing backtick
      sub(/\$\{__fiSeg[^}]*\}[^`]*`[[:space:]]*\)?;[[:space:]]*\/\/[[:space:]]*found-issues:seg.*$/, "`);")
      sub(/\+[[:space:]]*__fiSeg[^)]*\)[[:space:]]*\);[[:space:]]*\/\/[[:space:]]*found-issues:seg.*$/, ");")
      sub(/\+[[:space:]]*__fiSeg[[:space:]]*\);[[:space:]]*\/\/[[:space:]]*found-issues:seg.*$/, ");")
      # Python f-string with double quote: print(f"...{_fi_seg}") or {_fi_seg(...)}  # found-issues:seg
      sub(/\{_fi_seg[^}]*\}"\)[[:space:]]*#[[:space:]]*found-issues:seg.*$/, "\")")
      # Python f-string with single quote: print(f'...{_fi_seg}') or {_fi_seg(...)}  # found-issues:seg
      sub(/\{_fi_seg[^}]*\}['"'"'][)][[:space:]]*#[[:space:]]*found-issues:seg.*$/, "'"'"')")
      # Python plain-string concat: print("..." + _fi_seg) or + _fi_seg(...))  # found-issues:seg
      sub(/\+[[:space:]]*_fi_seg[^)]*\)[[:space:]]*\)[[:space:]]*#[[:space:]]*found-issues:seg.*$/, ")")
      sub(/\+[[:space:]]*_fi_seg[[:space:]]*\)[[:space:]]*#[[:space:]]*found-issues:seg.*$/, ")")
    }
    /\/\/ found-issues:seg/ {
      # Node template literal: ${__fiSeg} or ${__fiSeg(...)}  before closing backtick
      sub(/\$\{__fiSeg[^}]*\}[^`]*`[[:space:]]*\)?;[[:space:]]*\/\/[[:space:]]*found-issues:seg.*$/, "`);")
      sub(/\+[[:space:]]*__fiSeg[^)]*\)[[:space:]]*\);[[:space:]]*\/\/[[:space:]]*found-issues:seg.*$/, ");")
      sub(/\+[[:space:]]*__fiSeg[[:space:]]*\);[[:space:]]*\/\/[[:space:]]*found-issues:seg.*$/, ");")
    }
    { print }
  ' "$path" > "$tmp"

  # Atomic write (preserve mode)
  local mode
  mode="$(fi_capture_mode "$path")"
  mv "$tmp" "$path"
  chmod "$mode" "$path" 2>/dev/null || true

  printf 'uninstall-statusline --target: removed segment from %s\n' "$path"
  return 0
}
