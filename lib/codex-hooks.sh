#!/usr/bin/env bash
# codex-hooks.sh — install-codex-hooks / uninstall-codex-hooks
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Extracted verbatim from bin/found-issues in v2.2.6 (the tracked §12 split);
# see the [open] loc-validator entry in docs/found-issues.md.
#
# Functions:
#   fi_codex_home_default
#   fi_codex_hooks_dir
#   fi_shell_quote <s>
#   fi_codex_hooks_new_entries_json [...]
#   fi_codex_hooks_parse_args [...]
#   fi_codex_hooks_is_valid_json <file>
#   fi_codex_hooks_atomic_write [...]
#   cmd_install_codex_hooks [...]
#   cmd_uninstall_codex_hooks [...]

# === Subcommands: install-codex-hooks / uninstall-codex-hooks ===
#
# Codex CLI 0.144.5 removed the plugin_hooks feature (ledger:
# .codex-plugin/plugin.json:14) — a plugin's own hooks.json manifest
# pointer never loads there. The stable alternative is Codex's user-level
# hooks file, $CODEX_HOME/hooks.json (the `hooks` feature, which stayed
# stable). This installer merges found-issues' own hook entries into that
# file, preserving every entry that isn't ours.
#
# Ownership rule for "is this entry ours?": its command string starts
# with our literal sentinel prefix, `env FOUND_ISSUES_HARNESS=codex `
# (exactly what fi_codex_hooks_new_entries_json generates — see below).
# Tightened from an earlier "/hooks/ + found-issues substring" rule that
# was too loose: a user's own hook whose command happened to contain both
# substrings (e.g. their own script living under a path with "/hooks/"
# and "found-issues" in it) would get silently deleted. The sentinel
# prefix is stable across versions — stale prior-version entries carry
# the identical prefix (only the path after it changes), so the
# self-heal-on-update behavior described below is preserved.
#
# Install always removes every entry matching that rule first, then
# appends fresh ones built from the CURRENTLY running binary's own
# location — idempotent, and self-heals stale paths left behind by a
# prior `codex plugin update` (the cache path embeds a version segment
# that changes on update).
#
# No Stop entry: Stop-hook marker discipline needs the transcript rollout
# format parsed, which Codex support doesn't have yet (deferred — see
# docs/found-issues.md).

readonly FI_CODEX_HOOKS_SENTINEL='env FOUND_ISSUES_HARNESS=codex '

# shellcheck disable=SC2016 # $sentinel is a jq variable (--arg sentinel), not a bash one
readonly FI_CODEX_HOOKS_STRIP_JQ='
  .hooks //= {}
  | .hooks |= (
      with_entries(
        .value = (
          (.value // [])
          | map(.hooks |= ((. // []) | map(select(((.command // "") | startswith($sentinel)) | not))))
          | map(select((.hooks | length) > 0))
        )
      )
      | with_entries(select((.value | length) > 0))
    )
'

# Default $CODEX_HOME, honoring the FOUND_ISSUES_CODEX_HOME override.
# The --codex-home flag on either subcommand wins over both.
fi_codex_home_default() {
  if [[ -n "${FOUND_ISSUES_CODEX_HOME:-}" ]]; then
    printf '%s' "$FOUND_ISSUES_CODEX_HOME"
  else
    printf '%s' "$HOME/.codex"
  fi
}

# Absolute path to this checkout/cache copy's hooks/ dir, derived from
# the CURRENTLY running binary's own location (FI_BIN_DIR is resolved by
# fi_script_dir at the top of this file, follows symlinks, always
# absolute). Per Task 11 §3 the plugin cache copies bin/, lib/, hooks/
# together, so hooks/ is always FI_BIN_DIR's sibling.
fi_codex_hooks_dir() {
  printf '%s/hooks' "$(cd "$FI_BIN_DIR/.." && pwd)"
}

# Single-quote $1 for safe embedding in a generated shell command string
# (found-issues.md:4368 — an unquoted install root breaks on a path
# containing a space, same class as the fixed bin/found-issues:927
# segment-autosync bug). Escapes embedded single quotes via the standard
# close-escape-reopen technique: ' -> '\''.
fi_shell_quote() {
  local s="$1"
  printf "'%s'" "${s//\'/\'\\\'\'}"
}

# Build the JSON object of found-issues' own hook entries (3 events, 4
# command entries — no Stop), commands resolved to the current install
# root. Each script path is single-quoted (fi_shell_quote) so the
# generated command string is safe if the install root ever contains a
# space or other shell-special character.
fi_codex_hooks_new_entries_json() {
  local hooks_dir
  hooks_dir="$(fi_codex_hooks_dir)"
  local q_session q_fmt q_preb q_postb
  q_session="$(fi_shell_quote "$hooks_dir/session-start.sh")"
  q_fmt="$(fi_shell_quote "$hooks_dir/format-enforcer.sh")"
  q_preb="$(fi_shell_quote "$hooks_dir/pre-branch-delete.sh")"
  q_postb="$(fi_shell_quote "$hooks_dir/post-bash-dispatch.sh")"
  jq -n \
    --arg session_cmd "env FOUND_ISSUES_HARNESS=codex $q_session" \
    --arg fmt_cmd "env FOUND_ISSUES_HARNESS=codex $q_fmt" \
    --arg preb_cmd "env FOUND_ISSUES_HARNESS=codex $q_preb" \
    --arg postb_cmd "env FOUND_ISSUES_HARNESS=codex $q_postb" \
    '{
      SessionStart: [ { hooks: [ { type: "command", command: $session_cmd } ] } ],
      PreToolUse: [
        { matcher: "Write|Edit|MultiEdit", hooks: [ { type: "command", command: $fmt_cmd } ] },
        { matcher: "Bash", hooks: [ { type: "command", command: $preb_cmd } ] }
      ],
      PostToolUse: [
        { matcher: "Bash", hooks: [ { type: "command", command: $postb_cmd } ] }
      ]
    }'
}

# Parse the shared --codex-home / --codex-home=VALUE flag for both
# subcommands below. Sets $codex_home in the caller's scope (must be
# `local codex_home=""` before calling). $1 is the caller's own name,
# used only in the error message.
fi_codex_hooks_parse_args() {
  local self="$1"; shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --codex-home)
        # Guard the trailing-flag case: `--codex-home` with no value would
        # otherwise `shift 2` on a single remaining arg, which fails silently
        # (errexit is off — this fn is called on the left of `|| return 1`),
        # leaving $# unchanged so the loop spins forever at 100% CPU.
        if [[ -z "${2:-}" ]]; then
          fi_err "$self: --codex-home requires a directory path"
          return 1
        fi
        codex_home="$2"; shift 2 ;;
      --codex-home=*) codex_home="${1#--codex-home=}"; shift ;;
      *) fi_err "$self: unknown argument: $1"; return 1 ;;
    esac
  done
  [[ -z "$codex_home" ]] && codex_home="$(fi_codex_home_default)"
  return 0
}

# True (exit 0) iff $1 is non-empty, well-formed JSON. jq silently
# produces zero output — not an error — when fed empty or whitespace-only
# input, so an empty `$merged`/`$stripped` must be checked explicitly
# before ever writing it out; a bare `jq -e .` on an empty string alone
# would report success on effectively no content.
fi_codex_hooks_is_valid_json() {
  [[ -n "$1" ]] && printf '%s' "$1" | jq -e . >/dev/null 2>&1
}

# Atomically write $2 (content) to $1 (target path). mktemp is created in
# the SAME directory as the target (not system tmp) so the final `mv` is
# a same-filesystem rename — atomic — rather than a cross-filesystem
# copy+unlink that could leave a partial file on interruption. Caller
# must validate $2 first (fi_codex_hooks_is_valid_json). Returns 1 (target
# untouched) if the temp file can't be created.
fi_codex_hooks_atomic_write() {
  local target="$1" content="$2" dir tmp
  dir="$(dirname "$target")"
  tmp="$(mktemp "$dir/$(basename "$target").XXXXXX")" || return 1
  trap 'rm -f "$tmp"' EXIT
  printf '%s\n' "$content" > "$tmp"
  mv "$tmp" "$target"
  trap - EXIT
}

cmd_install_codex_hooks() {
  local codex_home=""
  fi_codex_hooks_parse_args "install-codex-hooks" "$@" || return 1

  if ! command -v jq >/dev/null 2>&1; then
    fi_err "install-codex-hooks: jq is required to edit Codex's hooks.json — install jq and re-run."
    return 1
  fi

  mkdir -p "$codex_home"
  local hooks_file="$codex_home/hooks.json"

  # Empty, whitespace-only, or missing content is treated identically:
  # seed the minimal skeleton. Without this, feeding an empty/whitespace
  # file straight to the merge below would silently produce zero jq
  # output (see fi_codex_hooks_is_valid_json) while still reporting
  # success — the bug this hardening pass fixes.
  local existing_content
  existing_content="$(cat "$hooks_file" 2>/dev/null || true)"
  if [[ ! "$existing_content" =~ [^[:space:]] ]]; then
    fi_codex_hooks_atomic_write "$hooks_file" '{"hooks":{}}' || {
      fi_err "install-codex-hooks: could not seed $hooks_file — leaving it untouched."
      return 5
    }
  fi

  local new_entries merged
  new_entries="$(fi_codex_hooks_new_entries_json)"
  merged="$(jq --argjson new "$new_entries" --arg sentinel "$FI_CODEX_HOOKS_SENTINEL" "
    ${FI_CODEX_HOOKS_STRIP_JQ}
    | .hooks.SessionStart = ((.hooks.SessionStart // []) + (\$new.SessionStart // []))
    | .hooks.PreToolUse   = ((.hooks.PreToolUse   // []) + (\$new.PreToolUse   // []))
    | .hooks.PostToolUse  = ((.hooks.PostToolUse  // []) + (\$new.PostToolUse  // []))
  " "$hooks_file")"

  # Belt-and-braces: never write unless $merged is confirmed non-empty,
  # well-formed JSON. The target file is left completely untouched on
  # failure.
  if ! fi_codex_hooks_is_valid_json "$merged"; then
    fi_err "install-codex-hooks: failed to produce valid JSON for $hooks_file — leaving it untouched."
    return 5
  fi

  fi_codex_hooks_atomic_write "$hooks_file" "$merged" || {
    fi_err "install-codex-hooks: could not write $hooks_file safely — leaving it untouched."
    return 5
  }

  local hooks_dir
  hooks_dir="$(fi_codex_hooks_dir)"
  cat <<EOF
install-codex-hooks: wrote $hooks_file

  SessionStart                       -> $hooks_dir/session-start.sh
  PreToolUse  (Write|Edit|MultiEdit) -> $hooks_dir/format-enforcer.sh
  PreToolUse  (Bash)                 -> $hooks_dir/pre-branch-delete.sh
  PostToolUse (Bash)                 -> $hooks_dir/post-bash-dispatch.sh

No Stop hook installed — marker-discipline enforcement needs Codex's
transcript rollout format parsed, which isn't wired up yet (deferred,
see docs/found-issues.md).

Re-run \`found-issues install-codex-hooks\` after every \`codex plugin
update\` — the plugin cache path changes on update, and stale entries
would otherwise keep pointing at a removed directory (this command
self-heals that on re-run).
EOF
}

cmd_uninstall_codex_hooks() {
  local codex_home=""
  fi_codex_hooks_parse_args "uninstall-codex-hooks" "$@" || return 1

  local hooks_file="$codex_home/hooks.json"
  if [[ ! -f "$hooks_file" ]]; then
    printf 'uninstall-codex-hooks: nothing to remove (no %s)\n' "$hooks_file"
    return 0
  fi

  local existing_content
  existing_content="$(cat "$hooks_file" 2>/dev/null || true)"
  if [[ ! "$existing_content" =~ [^[:space:]] ]]; then
    printf 'uninstall-codex-hooks: nothing to remove (%s is empty)\n' "$hooks_file"
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    fi_err "uninstall-codex-hooks: jq is required to edit Codex's hooks.json — install jq and re-run."
    return 1
  fi

  local stripped
  stripped="$(jq --arg sentinel "$FI_CODEX_HOOKS_SENTINEL" "$FI_CODEX_HOOKS_STRIP_JQ" "$hooks_file")"

  if ! fi_codex_hooks_is_valid_json "$stripped"; then
    fi_err "uninstall-codex-hooks: failed to produce valid JSON for $hooks_file — leaving it untouched."
    return 5
  fi

  fi_codex_hooks_atomic_write "$hooks_file" "$stripped" || {
    fi_err "uninstall-codex-hooks: could not write $hooks_file safely — leaving it untouched."
    return 5
  }

  printf 'uninstall-codex-hooks: removed hook entries whose command starts with the found-issues sentinel prefix (%s...) from %s\n' \
    "$FI_CODEX_HOOKS_SENTINEL" "$hooks_file"
}

