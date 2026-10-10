#!/usr/bin/env bash
# statusline-install.sh — install-statusline, its splice variants, doctor probes
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Extracted verbatim from bin/found-issues in v2.2.5 (the tracked §12 split);
# see the [open] loc-validator entry in docs/found-issues.md. The inline/append
# splice variants sat below cmd_doctor in the CLI; they keep their relative
# order here.
#
# Functions:
#   cmd_install_statusline [...]
#   fi_run_statusline_runtime_probe <pass> <warn> <fail>
#   cmd_doctor_statusline [...]
#   cmd_doctor_statusline_runtime [...]
#   cmd_install_statusline_inline
#   cmd_install_statusline_append

cmd_install_statusline() {
  # Argument parsing. As of v1.0.4 the default is to auto-migrate legacy
  # handwritten snippets (the 3-line pre-v0.1.7 setup.md template). v1.0.3
  # required `--migrate` for safety, but in practice that opt-in barrier
  # caused the AI-driven setup flow to bail silently and the user to see
  # an empty counter — the symptom v1.0.3 was supposed to fix. The strip
  # heuristic is precise and a timestamped backup is saved before the strip,
  # so reversal is one `mv` away if the user's snippet is custom enough to
  # mismatch.
  #
  # Use `--no-migrate` to opt back into the v1.0.3 strict behavior (refuse
  # to touch legacy lines, print the manual migration command).
  #
  # `--migrate` / `--force` are kept as backwards-compat no-ops — invoking
  # them remains valid and behaves identically to the new default.
  # Parse flags. Custom-target mode: --target <path> [--language=<X>] [--dry-run|--apply]
  local target_path="" target_language="auto" target_mode=""
  local positional_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)
        # A bare `--target` crashed on the unset $2 under set -u, and
        # `--target --apply` took "--apply" as the path (audit status-17).
        fi_need_value install-statusline --target $# "${2:-}" || return 2
        target_path="$2"
        shift 2
        ;;
      --target=*)
        target_path="${1#--target=}"
        shift
        ;;
      --language=*)
        target_language="${1#--language=}"
        shift
        ;;
      --dry-run)
        target_mode="dry-run"
        shift
        ;;
      --apply)
        target_mode="apply"
        shift
        ;;
      --no-migrate|--migrate)
        # Canonical-path migration flags — leave for existing code path below
        positional_args+=("$1")
        shift
        ;;
      --force)
        positional_args+=("$1")
        shift
        ;;
      -h|--help)
        printf 'Usage: found-issues install-statusline [--no-migrate]\n'
        printf '       found-issues install-statusline --target <path> [--language=<bash|node|python>] [--dry-run|--apply]\n'
        return 0
        ;;
      # It rewrites the user's statusline and settings.json: refuse what it
      # does not understand (ledger entry lib/archive.sh:36).
      *) fi_unknown_arg install-statusline "$1"; return 2 ;;
    esac
  done

  # --dry-run / --apply / --language only exist in --target mode. Without
  # --target they were ignored and the canonical path WROTE the marker block
  # — a dry run that mutated (audit status-8).
  if [[ -z "$target_path" && ( -n "$target_mode" || "$target_language" != "auto" ) ]]; then
    fi_err "install-statusline: --dry-run, --apply and --language need --target <path>"
    return 2
  fi

  # --target mode dispatches to custom-target handler; otherwise fall through
  # to the existing canonical-path logic.
  if [[ -n "$target_path" ]]; then
    cmd_install_statusline_custom_target "$target_path" "$target_language" "$target_mode"
    return $?
  fi

  # Re-set positional args for the rest of the function (existing canonical-path code).
  # Bash 3.2 (macOS default) under `set -u` treats `"${arr[@]}"` of an empty array
  # as unbound — branch on size to stay portable.
  if [[ ${#positional_args[@]} -gt 0 ]]; then
    set -- "${positional_args[@]}"
  else
    set --
  fi

  local migrate=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --migrate|--force) migrate=1; shift ;;
      --no-migrate) migrate=0; shift ;;
      *) shift ;;
    esac
  done

  if [[ ! -f "$FI_STATUSLINE_FILE" ]]; then
    fi_err "install-statusline: $FI_STATUSLINE_FILE does not exist"
    fi_err ""
    fi_err "You don't have a Claude Code statusline configured. Either:"
    fi_err "  1. Create $FI_STATUSLINE_FILE first, then re-run this"
    fi_err "  2. Or skip statusline integration — the SessionStart hook"
    fi_err "     prints the count once per session regardless"
    return 1
  fi

  # Every rewrite below strips from a start marker to an exact end marker; an
  # unbalanced pair deleted the user's lines to EOF (audit status-6).
  if grep -Fq "$FI_STATUSLINE_START_MARKER" "$FI_STATUSLINE_FILE" \
     && ! fi_markers_balanced "$FI_STATUSLINE_FILE" "^${FI_STATUSLINE_START_MARKER}\$" "^${FI_STATUSLINE_END_MARKER}\$"; then
    fi_err "install-statusline: unbalanced found-issues markers in $FI_STATUSLINE_FILE — refusing"
    fi_err "  Restore the missing start/end marker line by hand, then re-run."
    return 1
  fi

  local state
  state="$(fi_statusline_state)"

  case "$state" in
    installed-fixed)
      printf 'install-statusline: already installed (and current) in %s\n' "$FI_STATUSLINE_FILE"
      return 0
      ;;
    installed-broken)
      # Outdated marker-bracketed segment: either v1.0.0/1.0.1 (no cwd
      # handling at all) or v1.0.2–v1.5.5 (cd-only, defeated by inherited
      # CLAUDE_PROJECT_DIR — no explicit --cwd). Both are silent breakage.
      # Auto-migrate: the markers give us safe block boundaries, and the
      # rewrite is a strict upgrade.
      printf 'install-statusline: detected outdated marker-bracketed segment (missing cwd/--cwd handling) — rewriting in place.\n'
      cmd_uninstall_statusline >/dev/null || return 1
      ;;
    legacy-handwritten)
      if (( migrate == 0 )); then
        fi_err "install-statusline: detected pre-v0.1.7 handwritten snippet in $FI_STATUSLINE_FILE"
        fi_err ""
        fi_err "Lines matching the handwritten setup.md template were found OUTSIDE our marker block."
        fi_err "These call \`found-issues status\` from the wrong cwd → empty segment (silent breakage)."
        fi_err ""
        fi_err "Auto-migration was explicitly disabled via --no-migrate. To migrate, drop the flag:"
        fi_err "  found-issues install-statusline"
        fi_err ""
        fi_err "Or inspect first:"
        fi_err "  found-issues doctor-statusline"
        return 1
      fi
      local fi_backup_path=""
      fi_backup_path="$(fi_save_statusline_backup "$FI_STATUSLINE_FILE" || true)"
      fi_err "install-statusline: detected pre-v0.1.7 handwritten snippet — auto-migrating."
      fi_err "  Removing the 3-line snippet (\`# found-issues plugin segment\` comment, the"
      fi_err "  \`FI_SEG=\$(found-issues status --format=segment ...)\` line, and the"
      fi_err "  \`\$FI_SEG\`-using LINE1 follow-up) and inserting the canonical marker-bracketed"
      fi_err "  block with cwd handling."
      [[ -n "$fi_backup_path" ]] && fi_err "  Backup of pre-migration file: $fi_backup_path"
      fi_err "  Opt out with: found-issues install-statusline --no-migrate"
      printf 'install-statusline: migrating pre-v0.1.7 handwritten snippet in %s\n' "$FI_STATUSLINE_FILE"
      fi_strip_legacy_handwritten "$FI_STATUSLINE_FILE"
      ;;
    legacy-and-installed)
      if (( migrate == 0 )); then
        fi_err "install-statusline: $FI_STATUSLINE_FILE has BOTH a marker block AND a stray legacy line."
        fi_err "This would render the counter twice."
        fi_err ""
        fi_err "Auto-migration was explicitly disabled via --no-migrate. To migrate, drop the flag:"
        fi_err "  found-issues install-statusline"
        return 1
      fi
      local fi_backup_path=""
      fi_backup_path="$(fi_save_statusline_backup "$FI_STATUSLINE_FILE" || true)"
      fi_err "install-statusline: detected stray legacy snippet alongside marker block — auto-migrating."
      fi_err "  Removing the legacy 3-line handwritten snippet AND the existing (likely broken)"
      fi_err "  marker-bracketed block, then re-inserting the canonical block."
      [[ -n "$fi_backup_path" ]] && fi_err "  Backup of pre-migration file: $fi_backup_path"
      fi_err "  Opt out with: found-issues install-statusline --no-migrate"
      printf 'install-statusline: removing stray legacy snippet AND broken/duplicate marker block in %s\n' "$FI_STATUSLINE_FILE"
      cmd_uninstall_statusline >/dev/null
      fi_strip_legacy_handwritten "$FI_STATUSLINE_FILE"
      ;;
    none)
      : # fall through to install
      ;;
    no-file)
      fi_err "install-statusline: $FI_STATUSLINE_FILE does not exist"
      return 1
      ;;
    *)
      fi_err "install-statusline: unexpected state: $state"
      return 1
      ;;
  esac

  # Detect a LINE1-assembly pattern. Most multi-line statuslines build a
  # LINE1 variable then printf/echo it. If that pattern exists, we insert
  # inline — the segment appears next to repo/branch on the same line. If
  # not, we fall back to append (segment becomes its own standalone line).
  local line1_assignments
  line1_assignments=$(grep -cE '^[[:space:]]*LINE1[[:space:]]*=|LINE1="\$LINE1' "$FI_STATUSLINE_FILE" 2>/dev/null || true)
  [[ "$line1_assignments" =~ ^[0-9]+$ ]] || line1_assignments=0

  if (( line1_assignments >= 2 )); then
    cmd_install_statusline_inline
  else
    cmd_install_statusline_append
  fi
}

# fi_statusline_command_path <command-string>
# Resolve the statusline script path out of settings.json statusLine.command.
# Takes the final argument (a trailing quoted argument may contain spaces),
# strips its surrounding quotes, and expands ${HOME}, $HOME and a leading ~.
# Prints the path; prints nothing for an empty command. Shared by the
# runtime probe and `doctor`.
fi_statusline_command_path() {
  local cmd="$1" tok q h="$HOME"
  cmd="${cmd%"${cmd##*[![:space:]]}"}"
  [[ -n "$cmd" ]] || return 0
  q="${cmd: -1}"
  if [[ "$q" == '"' || "$q" == "'" ]]; then
    tok="${cmd%?}"
    tok="${tok##*"$q"}"
  else
    tok="${cmd##*[[:space:]]}"
  fi
  tok=${tok//'${HOME}'/$h}
  tok=${tok//'$HOME'/$h}
  if [[ "$tok" == "~" || "$tok" == "~/"* ]]; then
    tok="$h${tok#\~}"
  fi
  printf '%s' "$tok"
}

# Diagnostic dry-run: print the current state of the statusline integration
# and the recommended action. No file modifications.
# fi_run_statusline_runtime_probe: reusable runtime probe body.
# Called by cmd_doctor and cmd_doctor_statusline_runtime.
# $1=section_pass  $2=section_warn  $3=section_fail
fi_run_statusline_runtime_probe() {
  local section_pass="$1" section_warn="$2" section_fail="$3"

  # Re-resolve statusline target (same logic as cmd_doctor's Statusline section).
  local settings_file="$HOME/.claude/settings.json"
  local custom_target="" custom_language=""
  if [[ -f "$settings_file" ]] && command -v jq >/dev/null 2>&1; then
    local cmd
    cmd="$(jq -r '.statusLine.command // ""' "$settings_file" 2>/dev/null || true)"
    if [[ -n "$cmd" ]]; then
      custom_target="$(fi_statusline_command_path "$cmd")"
      case "$custom_target" in
        *.js|*.mjs|*.cjs) custom_language=node ;;
        *.py)             custom_language=python ;;
        *.sh|*.bash)      custom_language=bash ;;
      esac
    fi
  fi

  local statusline_target statusline_language
  if [[ -n "$custom_target" && -f "$custom_target" ]]; then
    statusline_target="$custom_target"
    statusline_language="$custom_language"
  else
    statusline_target="$FI_STATUSLINE_FILE"
    statusline_language="bash"
  fi

  printf '== Runtime probe ==\n'
  # Path-shaped tokens only: `npx -y pkg@latest` ends in a package spec.
  if [[ "$custom_target" == */* && ! -f "$custom_target" ]]; then
    printf '%s settings.json statusLine.command path is not a file: %s — probing the default statusline instead.\n' "$section_warn" "$custom_target"
  fi
  if [[ -z "$statusline_target" || ! -f "$statusline_target" ]]; then
    printf '%s Skipped — no statusline target file to probe.\n' "$section_warn"
  elif [[ -n "${custom_target}" && -z "$custom_language" ]]; then
    printf '%s Skipped — unrecognized statusline language for %s.\n' "$section_warn" "$custom_target"
  else
    local probe_cwd probe_cwd_json probe_stdin probe_output probe_stderr
    probe_cwd="$(pwd)"
    # JSON-escape via the shared helper so paths with backslash, quote, or
    # a tab (legal on macOS) don't produce malformed stdin and false-FAIL a
    # working integration — the inline two-expansion copy this replaces
    # silently diverged from fi_json_escape's coverage.
    probe_cwd_json="$(fi_json_escape "$probe_cwd")"
    probe_stdin="$(printf '{"model":{"display_name":"Test"},"workspace":{"current_dir":"%s"},"session_id":"t","context_window":{"remaining_percentage":50}}' "$probe_cwd_json")"

    local executor
    case "$statusline_language" in
      bash)   executor=(bash "$statusline_target") ;;
      node)   executor=(node "$statusline_target") ;;
      python) executor=(python3 "$statusline_target") ;;
    esac

    # Capture stderr separately so runtime-error detection scans stderr only
    # — stdout is the segment and may legitimately contain keywords like
    # "undefined" (e.g. detached HEAD) or path tokens like "cannot-wait".
    local probe_stderr_tmp
    probe_stderr_tmp="$(mktemp -t fi-probe-stderr.XXXXXX)"
    if command -v perl >/dev/null 2>&1; then
      probe_output="$(printf '%s' "$probe_stdin" | perl -e 'alarm(5); exec @ARGV' -- "${executor[@]}" 2>"$probe_stderr_tmp" || true)"
    elif command -v timeout >/dev/null 2>&1; then
      probe_output="$(printf '%s' "$probe_stdin" | timeout 5 "${executor[@]}" 2>"$probe_stderr_tmp" || true)"
    else
      probe_output="$(printf '%s' "$probe_stdin" | "${executor[@]}" 2>"$probe_stderr_tmp" || true)"
    fi
    probe_stderr="$(cat "$probe_stderr_tmp" 2>/dev/null || true)"
    rm -f "$probe_stderr_tmp"

    # Probe success: script ran and produced non-empty output without runtime errors.
    local probe_has_error=0
    if [[ -n "$probe_stderr" ]]; then
      printf '%s' "$probe_stderr" | LC_ALL=C grep -qiE '(error|exception|traceback|undefined|cannot|not found)' && probe_has_error=1 || true
    fi

    # The found-issues segment the CLI would print for the probe cwd. When it
    # is non-empty the statusline output must show it: any other output is a
    # statusline that runs but never shows the counter. Colors are stripped on
    # both sides, and the first "<count> <bucket>" pair is enough, because the
    # statusline's own shim may run another found-issues version, or restyle it.
    local expected_seg seg_plain out_plain seg_key="" seg_found=0
    expected_seg="$("${FI_BIN_DIR}/found-issues" status --format=segment --cwd "$probe_cwd" 2>/dev/null || true)"
    if [[ -n "$expected_seg" ]]; then
      seg_plain="$(printf '%s' "$expected_seg" | LC_ALL=C sed $'s/\x1b\\[[0-9;]*m//g')"
      out_plain="$(printf '%s' "$probe_output" | LC_ALL=C sed $'s/\x1b\\[[0-9;]*m//g')"
      seg_plain="${seg_plain#"${seg_plain%%[![:space:]|]*}"}"
      [[ "$seg_plain" =~ [0-9]+\ [A-Za-z]+ ]] && seg_key="${BASH_REMATCH[0]}"
      if [[ -n "$seg_plain" && "$out_plain" == *"$seg_plain"* ]] \
         || [[ -n "$seg_key" && "$out_plain" == *"$seg_key"* ]]; then
        seg_found=1
      fi
    fi

    if [[ -n "$probe_output" && "$probe_has_error" -eq 0 && ( -z "$expected_seg" || "$seg_found" -eq 1 ) ]]; then
      if fi_has_conflict_markers "${issues_file_health:-}" 2>/dev/null; then
        printf '%s INCONCLUSIVE — segment rendered, but source file has conflict markers.\n' "$section_warn"
      elif [[ -z "$expected_seg" ]]; then
        printf '%s Ledger is clean — no segment expected; statusline ran without errors: %s\n' "$section_pass" "$(echo "$probe_output" | head -1)"
      else
        printf '%s Segment rendered: %s\n' "$section_pass" "$(echo "$probe_output" | head -1)"
      fi
    else
      printf '%s FAIL — segment did NOT render in probe output.\n' "$section_fail"
      printf '   Probe output: %s\n' "$(echo "$probe_output" | head -1)"

      # Sub-probe (a): binary cwd resolution
      if "${FI_BIN_DIR}/found-issues" status --format=segment 2>/dev/null | LC_ALL=C grep -qE ' \| '; then
        :
      else
        printf '   - cause: binary resolution / cwd — `found-issues status --format=segment` is empty from %s\n' "$probe_cwd"
      fi

      # Sub-probe (c): runtime exception
      if [[ "$probe_has_error" -eq 1 ]]; then
        printf '   - cause: runtime error in statusline script (see probe output above).\n'
      fi
    fi

    # Sub-probe (b): splice gap detection — always run as a static analysis.
    local output_count seg_count
    # grep -c prints 0 on its own when nothing matches (while exiting 1), so
    # an `|| echo 0` fallback would double it into "0\n0" and break the
    # arithmetic below — fall back only when the value is not a number.
    case "$statusline_language" in
      node)   output_count="$(LC_ALL=C grep -cE 'console\.log|process\.stdout\.write' "$statusline_target" 2>/dev/null || true)" ;;
      python) output_count="$(LC_ALL=C grep -cE '^[[:space:]]*print[[:space:]]*\(|sys\.stdout\.write' "$statusline_target" 2>/dev/null || true)" ;;
      bash)   output_count="$(LC_ALL=C grep -cE '^[[:space:]]*echo[[:space:]]|^[[:space:]]*printf[[:space:]]' "$statusline_target" 2>/dev/null || true)" ;;
    esac
    seg_count="$(LC_ALL=C grep -c 'found-issues:seg' "$statusline_target" 2>/dev/null || true)"
    [[ "$output_count" =~ ^[0-9]+$ ]] || output_count=0
    [[ "$seg_count" =~ ^[0-9]+$ ]] || seg_count=0
    if (( seg_count < output_count )); then
      printf '   - cause: splice gap — %s output statements, only %s patched with `found-issues:seg`.\n' "$output_count" "$seg_count"
      printf '     Re-run: found-issues install-statusline --target %s --apply\n' "$statusline_target"
    fi
  fi
  printf '\n'
}

cmd_doctor_statusline() {
  if [[ ! -f "$FI_STATUSLINE_FILE" ]]; then
    printf 'doctor-statusline: %s does not exist.\n' "$FI_STATUSLINE_FILE"
    printf 'Status: NO STATUSLINE — Claude Code uses the default statusline.\n'
    printf 'Action: create %s, then run `found-issues install-statusline`.\n' "$FI_STATUSLINE_FILE"
    return 0
  fi

  local state
  state="$(fi_statusline_state)"
  printf 'doctor-statusline: %s\n' "$FI_STATUSLINE_FILE"
  printf 'State: %s\n\n' "$state"

  case "$state" in
    installed-fixed)
      printf 'OK — statusline integration is current (cwd handling present).\n'
      printf 'No action needed.\n'
      ;;
    installed-broken)
      printf 'BROKEN — marker-bracketed segment is missing cwd handling (v1.0.0/1.0.1 bug).\n'
      printf 'Symptom: counter renders empty even though the block is installed.\n'
      printf 'Fix: found-issues install-statusline   (auto-rewrites the broken block)\n'
      ;;
    legacy-handwritten)
      printf 'BROKEN — pre-v0.1.7 handwritten snippet found (no markers, no cwd handling).\n'
      printf 'Symptom: counter renders empty regardless of which repo you'\''re in.\n'
      printf 'Fix: found-issues install-statusline   (auto-migrates as of v1.0.4: strips legacy lines, inserts canonical block, saves a timestamped backup)\n'
      ;;
    legacy-and-installed)
      printf 'CONFLICTED — both a marker block AND a stray legacy line are present.\n'
      printf 'Symptom: counter may render twice or render empty depending on order.\n'
      printf 'Fix: found-issues install-statusline   (auto-migrates as of v1.0.4: cleans up both, reinstalls canonical, saves a timestamped backup)\n'
      ;;
    none)
      printf 'NOT INSTALLED — no found-issues integration in this statusline.\n'
      printf 'Install: found-issues install-statusline\n'
      ;;
    no-file)
      printf 'NO STATUSLINE FILE.\n'
      ;;
  esac
}

cmd_doctor_statusline_runtime() {
  # Standalone runtime probe. Reuses fi_run_statusline_runtime_probe.
  # Useful for AI agents and iterative debugging — emits only the probe
  # section, not the full doctor report.
  local section_pass="✓" section_warn="!" section_fail="✗"
  if ! locale 2>/dev/null | grep -qi 'utf-8\|utf8'; then
    section_pass="OK"; section_warn="!!"; section_fail="FAIL"
  fi
  fi_run_statusline_runtime_probe "$section_pass" "$section_warn" "$section_fail"
}
# Insert the segment block right after the LAST LINE1= assignment, so the
# segment is appended to LINE1 inline (next to repo/branch), not echoed as
# its own line at the end.
cmd_install_statusline_inline() {
  local last_line1
  last_line1=$(grep -nE '^[[:space:]]*LINE1[[:space:]]*=|LINE1="\$LINE1' "$FI_STATUSLINE_FILE" \
    | tail -1 | cut -d: -f1)

  if [[ -z "$last_line1" || ! "$last_line1" =~ ^[0-9]+$ ]]; then
    # Couldn't pinpoint — fall back to append
    cmd_install_statusline_append
    return
  fi

  local original_mode tmp
  original_mode=$(fi_capture_mode "$FI_STATUSLINE_FILE")
  tmp="$(mktemp -t found-issues-statusline.XXXXXX)"
  awk -v insert_after="$last_line1" \
      -v start="$FI_STATUSLINE_START_MARKER" \
      -v endm="$FI_STATUSLINE_END_MARKER" '
    {
      print
      if (NR == insert_after) {
        print start
        print "# Inline-appended to LINE1 by `found-issues install-statusline`."
        print "# Robust against PATH variability — statusline runs in a raw shell exec"
        print "# context where the plugin'"'"'s auto-PATH may not apply. Tries"
        print "# `found-issues` on PATH first; falls back to globbing the plugin cache"
        print "# for the latest installed binary."
        print "__FI_CLI=\"\""
        print "if command -v found-issues >/dev/null 2>&1; then"
        print "  __FI_CLI=found-issues"
        print "else"
        print "  # sort -V handles semver correctly (0.1.10 > 0.1.9, unlike byte-wise glob order)"
        print "  # `|| true` is critical: with `set -o pipefail` (common in statuslines), ls"
        print "  # returns non-zero when glob has no matches and that propagates through the pipe"
        print "  __FI_CLI=$(ls -d \"$HOME\"/.claude/plugins/cache/*/found-issues/*/bin/found-issues 2>/dev/null | sort -V | tail -1 || true)"
        print "  [[ -x \"$__FI_CLI\" ]] || __FI_CLI=\"\""
        print "fi"
        print "# Extract workspace dir from the conventional `$input` variable. The"
        print "# statusline subprocess'"'"'s cwd is NOT the workspace dir, so without this"
        print "# `found-issues status` runs from $HOME and finds nothing."
        print "__FI_DIR=\"\""
        print "if [[ -n \"${input:-}\" ]] && command -v jq >/dev/null 2>&1; then"
        print "  __FI_DIR=$(echo \"$input\" | jq -r '"'"'.workspace.current_dir // \"\"'"'"' 2>/dev/null || true)"
        print "fi"
        print "__FI_SEG=\"\""
        print "if [[ -n \"$__FI_CLI\" ]]; then"
        print "  if [[ -n \"$__FI_DIR\" ]]; then"
        print "    # --cwd is load-bearing: the CLI prefers inherited CLAUDE_PROJECT_DIR"
        print "    # (where the session STARTED) over PWD, so `cd` alone is silently"
        print "    # overridden. cd kept so background autosync inherits the workspace."
        print "    __FI_SEG=$( cd \"$__FI_DIR\" 2>/dev/null && \"$__FI_CLI\" status --format=segment --cwd \"$__FI_DIR\" 2>/dev/null || true )"
        print "  else"
        print "    __FI_SEG=$(\"$__FI_CLI\" status --format=segment 2>/dev/null || true)"
        print "  fi"
        print "fi"
        print "[[ -n \"$__FI_SEG\" ]] && LINE1=\"$LINE1$__FI_SEG\""
        print endm
      }
    }
  ' "$FI_STATUSLINE_FILE" >"$tmp"

  # Rename onto the resolved file so a symlinked statusline keeps its link
  # (audit status-7).
  mv "$tmp" "$(fi_resolve_link "$FI_STATUSLINE_FILE")"
  # Restore original mode — mktemp creates files at 0600, so without this
  # the statusline loses its execute bit and Claude Code silently can't run it.
  chmod "$original_mode" "$FI_STATUSLINE_FILE" 2>/dev/null \
    || chmod +x "$FI_STATUSLINE_FILE"
  printf 'install-statusline: inserted inline LINE1 segment in %s (after line %d)\n' \
    "$FI_STATUSLINE_FILE" "$last_line1"
  printf 'Restart your Claude Code session to see the segment render.\n'
}

# Append the block at end-of-file. Segment renders as its own standalone line.
# Used when no LINE1 pattern is detected (simple printf-based statuslines).
cmd_install_statusline_append() {
  # A script whose last command is an unindented `exit` / `exec` never reaches
  # a block appended after it, so the block goes immediately above that line.
  local last_cmd_line="" last_cmd_text insert_at=""
  last_cmd_line="$(LC_ALL=C awk '!/^[[:space:]]*(#|$)/ { n = NR } END { if (n) print n }' "$FI_STATUSLINE_FILE")"
  if [[ -n "$last_cmd_line" ]]; then
    last_cmd_text="$(sed -n "${last_cmd_line}p" "$FI_STATUSLINE_FILE")"
    if [[ "$last_cmd_text" =~ ^(exit|exec)([[:space:]]|\;|$) ]]; then
      insert_at="$last_cmd_line"
    fi
  fi

  local block_file
  block_file="$(mktemp -t fi-sl-block.XXXXXX)"
  cat >"$block_file" <<EOF
$FI_STATUSLINE_START_MARKER
# Appended by \`found-issues install-statusline\`. Remove this entire block
# to disable. Robust against PATH variability — statusline runs in a raw
# shell exec context where the plugin's auto-PATH may not apply. Tries
# \`found-issues\` on PATH first; falls back to globbing the plugin cache
# for the latest installed binary.
__FI_CLI=""
if command -v found-issues >/dev/null 2>&1; then
  __FI_CLI=found-issues
else
  # sort -V handles semver correctly (0.1.10 > 0.1.9, unlike byte-wise glob order).
  # \`|| true\` is critical: with \`set -o pipefail\` (common in statuslines), ls
  # returns non-zero when glob has no matches and that propagates through the pipe.
  __FI_CLI=\$(ls -d "\$HOME"/.claude/plugins/cache/*/found-issues/*/bin/found-issues 2>/dev/null | sort -V | tail -1 || true)
  [[ -x "\$__FI_CLI" ]] || __FI_CLI=""
fi
# Extract workspace dir from the conventional \`\$input\` variable. The
# statusline subprocess's cwd is NOT the workspace dir, so without this
# \`found-issues status\` runs from \$HOME and finds nothing.
__FI_DIR=""
if [[ -n "\${input:-}" ]] && command -v jq >/dev/null 2>&1; then
  __FI_DIR=\$(echo "\$input" | jq -r '.workspace.current_dir // ""' 2>/dev/null || true)
fi
__FI_SEG=""
if [[ -n "\$__FI_CLI" ]]; then
  if [[ -n "\$__FI_DIR" ]]; then
    # --cwd is load-bearing: the CLI prefers inherited CLAUDE_PROJECT_DIR
    # (where the session STARTED) over PWD, so \`cd\` alone is silently
    # overridden. cd kept so background autosync inherits the workspace.
    __FI_SEG=\$( cd "\$__FI_DIR" 2>/dev/null && "\$__FI_CLI" status --format=segment --cwd "\$__FI_DIR" 2>/dev/null || true )
  else
    __FI_SEG=\$("\$__FI_CLI" status --format=segment 2>/dev/null || true)
  fi
fi
if [[ -n "\$__FI_SEG" ]]; then echo "\$__FI_SEG"; fi
$FI_STATUSLINE_END_MARKER
EOF

  if [[ -n "$insert_at" ]]; then
    local merged_file
    merged_file="$(mktemp -t fi-sl-merged.XXXXXX)"
    {
      head -n "$((insert_at - 1))" "$FI_STATUSLINE_FILE"
      cat "$block_file"
      tail -n "+${insert_at}" "$FI_STATUSLINE_FILE"
    } >"$merged_file"
    cat "$merged_file" >"$FI_STATUSLINE_FILE"
    rm -f "${merged_file:?}"
  else
    if [[ -n "$(tail -c 1 "$FI_STATUSLINE_FILE")" ]]; then
      printf '\n' >>"$FI_STATUSLINE_FILE"
    fi
    cat "$block_file" >>"$FI_STATUSLINE_FILE"
  fi
  rm -f "${block_file:?}"

  printf 'install-statusline: appended standalone segment to %s\n' "$FI_STATUSLINE_FILE"
  printf 'Restart your Claude Code session to see the segment render.\n'
}
