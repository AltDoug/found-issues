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
# Stop entry (2.10.0): Codex's Stop payload carries last_assistant_message,
# so the marker check needs no rollout parsing — see the Codex branch at the
# top of hooks/stop-reminder.sh. The format enforcer also matches apply_patch:
# Codex edits files through it (tool_input.command holds the patch envelope,
# no file_path), so a Write|Edit-only matcher never saw a Codex ledger edit.

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
# fi_script_dir in bin/found-issues, follows symlinks, always
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

# === Stable shims (2.10.3) ===
#
# hooks.json entries point at $CODEX_HOME/found-issues/hooks/<hook>.sh, never
# into the plugin cache. Codex's cache path embeds the version and the old
# version's dir is deleted on update, and Codex pins hook TRUST to the entry
# text — so cache paths went stale on every update and re-wiring them voided
# trust (a /hooks review per release). The shim resolves the newest cached
# found-issues at run time, so the entries never change.
fi_codex_shim_dir() { printf '%s/found-issues/hooks' "$1"; }

# fi_codex_write_shims <codex_home> — (re)write the six shims. Content may
# change freely: trust pins the hooks.json entry, not the script it runs.
fi_codex_write_shims() {
  local home="$1" dir root h q_home q_root
  dir="$(fi_codex_shim_dir "$home")"
  mkdir -p "$dir" || return 1
  # Physical paths on both sides: the "installed from the cache?" test below
  # compares them, and /var vs /private/var (macOS) would never match.
  home="$(cd "$home" && pwd -P)"
  root="$(cd "$FI_BIN_DIR/.." && pwd -P)"
  q_home="$(fi_shell_quote "$home")"
  q_root="$(fi_shell_quote "$root")"
  for h in session-start format-enforcer pre-branch-delete post-bash-dispatch first-touch stop-reminder; do
    cat > "$dir/$h.sh.tmp" <<EOF || return 1
#!/usr/bin/env bash
# found-issues stable Codex hook shim — written by \`found-issues install-codex-hooks\`.
# hooks.json points HERE, so its entries (and Codex's trust in them) survive
# plugin updates. Runs the newest found-issues in Codex's plugin cache when it
# was installed from there, otherwise the checkout it was installed from.
fi_hook=$h.sh
fi_codex_home=$q_home
fi_baked=$q_root
fi_root=""
case "\$fi_baked" in
  "\$fi_codex_home"/plugins/cache/*)
    fi_best=""
    for d in "\$fi_codex_home"/plugins/cache/*/found-issues/*/; do
      [ -f "\${d}hooks/\$fi_hook" ] || continue
      v="\${d%/}"; v="\${v##*/}"
      if [ -z "\$fi_best" ]; then fi_best="\$v"; fi_root="\${d%/}"; continue; fi
      # numeric dotted-version compare: 2.10.0 > 2.9.3
      a="\$v." b="\$fi_best." newer=0
      while [ -n "\$a\$b" ]; do
        x="\${a%%.*}"; y="\${b%%.*}"; a="\${a#*.}"; b="\${b#*.}"
        case "\$x\$y" in *[!0-9]*) break ;; esac
        if [ "\${x:-0}" -gt "\${y:-0}" ]; then newer=1; break; fi
        if [ "\${x:-0}" -lt "\${y:-0}" ]; then break; fi
      done
      if [ "\$newer" = 1 ]; then fi_best="\$v"; fi_root="\${d%/}"; fi
    done
    ;;
esac
[ -n "\$fi_root" ] || fi_root="\$fi_baked"
if [ "\${FOUND_ISSUES_SHIM_RESOLVE:-}" = 1 ]; then printf '%s\n' "\$fi_root"; exit 0; fi
if [ ! -f "\$fi_root/hooks/\$fi_hook" ]; then
  echo "found-issues: \$fi_hook not found under \$fi_codex_home/plugins/cache or \$fi_baked — run found-issues install-codex-hooks" >&2
  exit 0
fi
exec bash "\$fi_root/hooks/\$fi_hook"
EOF
    chmod +x "$dir/$h.sh.tmp" && mv "$dir/$h.sh.tmp" "$dir/$h.sh" || return 1
  done
}

# Build the JSON object of found-issues' own hook entries (4 events, 6
# command entries), commands resolved to the current install
# root. Each script path is single-quoted (fi_shell_quote) so the
# generated command string is safe if the install root ever contains a
# space or other shell-special character.
fi_codex_hooks_new_entries_json() {
  local hooks_dir
  hooks_dir="$(fi_codex_shim_dir "$1")"
  local q_session q_fmt q_preb q_postb q_stop q_ft
  q_session="$(fi_shell_quote "$hooks_dir/session-start.sh")"
  q_fmt="$(fi_shell_quote "$hooks_dir/format-enforcer.sh")"
  q_preb="$(fi_shell_quote "$hooks_dir/pre-branch-delete.sh")"
  q_postb="$(fi_shell_quote "$hooks_dir/post-bash-dispatch.sh")"
  q_stop="$(fi_shell_quote "$hooks_dir/stop-reminder.sh")"
  q_ft="$(fi_shell_quote "$hooks_dir/first-touch.sh")"
  jq -n \
    --arg session_cmd "env FOUND_ISSUES_HARNESS=codex $q_session" \
    --arg fmt_cmd "env FOUND_ISSUES_HARNESS=codex $q_fmt" \
    --arg preb_cmd "env FOUND_ISSUES_HARNESS=codex $q_preb" \
    --arg postb_cmd "env FOUND_ISSUES_HARNESS=codex $q_postb" \
    --arg stop_cmd "env FOUND_ISSUES_HARNESS=codex $q_stop" \
    --arg ft_cmd "env FOUND_ISSUES_HARNESS=codex $q_ft" \
    '{
      SessionStart: [ { hooks: [ { type: "command", command: $session_cmd } ] } ],
      PreToolUse: [
        { matcher: "Write|Edit|MultiEdit|apply_patch", hooks: [ { type: "command", command: $fmt_cmd } ] },
        { matcher: "Bash", hooks: [ { type: "command", command: $preb_cmd } ] }
      ],
      PostToolUse: [
        { matcher: "Bash", hooks: [ { type: "command", command: $postb_cmd } ] },
        { matcher: "apply_patch", hooks: [ { type: "command", command: $ft_cmd } ] }
      ],
      Stop: [ { hooks: [ { type: "command", command: $stop_cmd } ] } ]
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

  # The shims exec these from the install root at run time; a stripped or
  # partial checkout would otherwise be reported as a successful install.
  local fi_h fi_hroot
  fi_hroot="$(cd "$FI_BIN_DIR/.." && pwd -P)/hooks"
  for fi_h in session-start format-enforcer pre-branch-delete post-bash-dispatch first-touch stop-reminder; do
    if [[ ! -f "$fi_hroot/$fi_h.sh" ]]; then
      fi_err "install-codex-hooks: hook script missing: $fi_hroot/$fi_h.sh — reinstall found-issues, then re-run."
      return 1
    fi
  done

  fi_codex_write_shims "$codex_home" || {
    fi_err "install-codex-hooks: could not write the hook shims under $(fi_codex_shim_dir "$codex_home")."
    return 5
  }

  local new_entries merged
  new_entries="$(fi_codex_hooks_new_entries_json "$codex_home")"
  merged="$(jq --argjson new "$new_entries" --arg sentinel "$FI_CODEX_HOOKS_SENTINEL" "
    ${FI_CODEX_HOOKS_STRIP_JQ}
    | .hooks.SessionStart = ((.hooks.SessionStart // []) + (\$new.SessionStart // []))
    | .hooks.PreToolUse   = ((.hooks.PreToolUse   // []) + (\$new.PreToolUse   // []))
    | .hooks.PostToolUse  = ((.hooks.PostToolUse  // []) + (\$new.PostToolUse  // []))
    | .hooks.Stop         = ((.hooks.Stop         // []) + (\$new.Stop         // []))
  " "$hooks_file")" || merged=""

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
  hooks_dir="$(fi_codex_shim_dir "$codex_home")"
  cat <<EOF
install-codex-hooks: wrote $hooks_file
(each entry runs a stable shim that resolves the current found-issues from
$(cd "$FI_BIN_DIR/.." && pwd) — or the newest version in Codex's plugin cache)

  SessionStart                                   -> $hooks_dir/session-start.sh
  PreToolUse  (Write|Edit|MultiEdit|apply_patch) -> $hooks_dir/format-enforcer.sh
  PreToolUse  (Bash)                             -> $hooks_dir/pre-branch-delete.sh
  PostToolUse (Bash)                             -> $hooks_dir/post-bash-dispatch.sh
  PostToolUse (apply_patch)                      -> $hooks_dir/first-touch.sh
  Stop                                           -> $hooks_dir/stop-reminder.sh

NEXT: Codex skips new hook entries until you trust them. Open an
interactive Codex session and run /hooks once to review and trust them.
\`found-issues doctor\` shows whether they are trusted. The entries stay
byte-identical across \`codex plugin\` updates, so this is a one-time step.
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
  stripped="$(jq --arg sentinel "$FI_CODEX_HOOKS_SENTINEL" "$FI_CODEX_HOOKS_STRIP_JQ" "$hooks_file")" || stripped=""

  if ! fi_codex_hooks_is_valid_json "$stripped"; then
    fi_err "uninstall-codex-hooks: failed to produce valid JSON for $hooks_file — leaving it untouched."
    return 5
  fi

  fi_codex_hooks_atomic_write "$hooks_file" "$stripped" || {
    fi_err "uninstall-codex-hooks: could not write $hooks_file safely — leaving it untouched."
    return 5
  }

  rm -rf "$(fi_codex_shim_dir "$codex_home")" 2>/dev/null || true
  rmdir "$codex_home/found-issues" 2>/dev/null || true
  printf 'uninstall-codex-hooks: removed hook entries whose command starts with the found-issues sentinel prefix (%s...) from %s, and the shims\n' \
    "$FI_CODEX_HOOKS_SENTINEL" "$hooks_file"
}


# === Codex wiring check (2.10.0) ===
#
# found-issues can sit installed in Codex for months with no hook ever firing:
# Codex dropped plugin-shipped hooks in 0.144.5, `install-codex-hooks` is a
# manual step, and Codex silently skips hook entries nobody has trusted via
# its /hooks review. Observed 2026-10-03 on the author's own machine (plugin
# 2.8.0 enabled, zero entries in ~/.codex/hooks.json). doctor and the Claude
# SessionStart notice both read this.
#
# fi_codex_wiring_state [<codex_home>] prints one word:
#   absent    found-issues is not installed in Codex — nothing to check
#   unwired   installed, but hooks.json has none of our entries
#   incomplete our entries are wired but the first-touch entry (3.4.0) is
#             missing: an upgrader who has not re-run install-codex-hooks
#   stale     our entries point at scripts that no longer exist (plugin update)
#   untrusted wired, but config.toml has no [hooks.state] record for some entry
#   ok        wired and every entry has a trust record
# Trust records are checked for presence only: the hash is Codex's to compute.
fi_codex_found_issues_installed() {
  local home="$1" d
  for d in "$home"/plugins/cache/*/found-issues; do
    [[ -d "$d" ]] && return 0
  done
  [[ -f "$home/config.toml" ]] && grep -Fq '[plugins."found-issues@' "$home/config.toml" 2>/dev/null
}

fi_codex_wiring_state() {
  local home="${1:-$(fi_codex_home_default)}"
  local hooks_file="$home/hooks.json"
  if ! fi_codex_found_issues_installed "$home"; then
    printf 'absent'; return 0
  fi
  if [[ ! -f "$hooks_file" ]] || ! grep -Fq "$FI_CODEX_HOOKS_SENTINEL" "$hooks_file" 2>/dev/null; then
    printf 'unwired'; return 0
  fi
  if ! grep -Fq 'first-touch.sh' "$hooks_file" 2>/dev/null; then
    printf 'incomplete'; return 0
  fi
  command -v jq >/dev/null 2>&1 || { printf 'ok'; return 0; }
  local abs_file rows row key script missing=0 stale=0
  abs_file="$(cd "$(dirname "$hooks_file")" && pwd)/$(basename "$hooks_file")"
  # One row per entry of ours: <trust key>\t<script path>
  rows="$(jq -r --arg f "$abs_file" --arg s "$FI_CODEX_HOOKS_SENTINEL" '
    (.hooks // {}) | to_entries[] | .key as $ev
    | ($ev | gsub("(?<a>[a-z])(?<b>[A-Z])"; "\(.a)_\(.b)") | ascii_downcase) as $snake
    | (.value // []) | to_entries[] | .key as $g
    | (.value.hooks // []) | to_entries[]
    | select((.value.command // "") | startswith($s))
    | "\($f):\($snake):\($g):\(.key)\t\(.value.command | capture("'"'"'(?<p>.*)'"'"'$").p // "")"
  ' "$hooks_file" 2>/dev/null || true)"
  local target
  while IFS=$'\t' read -r key script; do
    [[ -z "$key" ]] && continue
    [[ -n "$script" && ! -f "$script" ]] && stale=1
    # A stable shim: stale when it no longer resolves to a real hook.
    if [[ -f "$script" && "$script" == "$(fi_codex_shim_dir "$home")"/* ]]; then
      target="$(FOUND_ISSUES_SHIM_RESOLVE=1 bash "$script" 2>/dev/null || true)"
      [[ -f "$target/hooks/${script##*/}" ]] || stale=1
    fi
    grep -Fq "[hooks.state.\"$key\"]" "$home/config.toml" 2>/dev/null || missing=$((missing + 1))
  done <<<"$rows"
  if (( stale )); then printf 'stale'
  elif (( missing > 0 )); then printf 'untrusted'
  else printf 'ok'
  fi
}
