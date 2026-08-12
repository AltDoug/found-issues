#!/usr/bin/env bash
# fi-alias.sh — install-fi-alias / uninstall-fi-alias
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Extracted verbatim from bin/found-issues in v2.2.6 (the tracked §12 split);
# see the [open] loc-validator entry in docs/found-issues.md.
#
# Functions:
#   fi_fi_alias_content
#   fi_fi_alias_is_ours <file>
#   cmd_install_fi_alias [...]
#   cmd_uninstall_fi_alias [...]

# === Subcommands: install-fi-alias / uninstall-fi-alias ===
#
# Optional `/fi` slash-command shortcut so the user can type
# `/fi log src/foo.py:42 — bug` instead of `/found-issues:log src/foo.py:42 — bug`.
#
# Why a deterministic CLI subcommand and not "tell the LLM to write the file":
# v0.1.15 setup told the agent to handcraft `~/.claude/commands/fi.md` from a
# markdown code block in setup.md. The agent dropped `$ARGUMENTS` on at least
# one real install — alias was created but didn't pass through args. Same
# failure mode statusline had pre-v0.1.11. Fix is the same: deterministic
# CLI path, LLM just calls the subcommand.

readonly FI_FI_ALIAS_FILE="$HOME/.claude/commands/fi.md"
readonly FI_FI_ALIAS_OPERATIVE_LINE='Run /found-issues:$ARGUMENTS'

# Canonical content of our /fi alias file. The operative line MUST contain
# the literal `$ARGUMENTS` — that's how Claude Code passes positional args
# from the slash command to the wrapped command.
fi_fi_alias_content() {
  cat <<'EOF'
---
description: Shorthand for /found-issues commands
---

Run /found-issues:$ARGUMENTS
EOF
}

# Heuristic for "is this our alias file?": the operative line is present.
# If the user has their own fi.md without that line, it's theirs — leave it.
fi_fi_alias_is_ours() {
  [[ -f "$FI_FI_ALIAS_FILE" ]] \
    && grep -Fq "$FI_FI_ALIAS_OPERATIVE_LINE" "$FI_FI_ALIAS_FILE" 2>/dev/null
}

cmd_install_fi_alias() {
  mkdir -p "$(dirname "$FI_FI_ALIAS_FILE")"

  if [[ -f "$FI_FI_ALIAS_FILE" ]]; then
    if fi_fi_alias_is_ours; then
      printf 'install-fi-alias: already installed at %s\n' "$FI_FI_ALIAS_FILE"
      return 0
    fi
    printf 'install-fi-alias: %s exists but is not the found-issues alias\n' "$FI_FI_ALIAS_FILE" >&2
    printf 'Not overwriting your /fi command. Move or remove that file first if you want the shortcut.\n' >&2
    return 1
  fi

  fi_fi_alias_content > "$FI_FI_ALIAS_FILE"
  printf 'install-fi-alias: created %s\n' "$FI_FI_ALIAS_FILE"
  printf '`/fi log src/foo.py:42 — bug` now works as a shortcut for `/found-issues:log src/foo.py:42 — bug`.\n'
}

cmd_uninstall_fi_alias() {
  if [[ ! -f "$FI_FI_ALIAS_FILE" ]]; then
    printf 'uninstall-fi-alias: not installed (no file at %s)\n' "$FI_FI_ALIAS_FILE"
    return 0
  fi

  if ! fi_fi_alias_is_ours; then
    printf 'uninstall-fi-alias: %s is not the found-issues alias\n' "$FI_FI_ALIAS_FILE" >&2
    printf 'Leaving it alone — looks like your own /fi command.\n' >&2
    return 0
  fi

  rm -f "$FI_FI_ALIAS_FILE"
  printf 'uninstall-fi-alias: removed %s\n' "$FI_FI_ALIAS_FILE"
}

