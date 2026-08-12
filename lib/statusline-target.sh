#!/usr/bin/env bash
# statusline-target.sh — install-statusline --target <path> (bash/node/python)
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Extracted verbatim from bin/found-issues in v2.2.5 (the tracked §12 split);
# see the [open] loc-validator entry in docs/found-issues.md.
#
# Kept as one file past the 500-line target: it is one dispatcher plus three
# language backends that share fi_detect_target_language and the same
# find-splice-point / generate-block / apply contract. Splitting per language
# would separate cmd_install_statusline_custom_target from the bash helpers
# interleaved directly beneath it.
#
# Functions:
#   fi_detect_target_language <file>
#   cmd_install_statusline_custom_target <path> [...]
#   fi_find_bash_splice_point <file>
#   fi_find_bash_stdin_capture <file>
#   fi_generate_bash_marker_block [...]
#   cmd_install_statusline_target_bash <path> [...]
#   fi_find_node_splice_point <file>
#   fi_generate_node_marker_block [...]
#   cmd_install_statusline_target_node <path> [...]
#   fi_find_python_splice_point <file>
#   fi_generate_python_marker_block [...]
#   cmd_install_statusline_target_python <path> [...]

# === Subcommand: install-statusline --target <path> ===
#
# Custom-statusline integration. Splices the found-issues segment into a
# user's existing statusline script at a non-canonical path. Supports
# bash/sh, Node, Python. See:
#   docs/superpowers/specs/2026-05-12-custom-statusline-auto-integration-design.md
#   docs/statusline-integration-contract.md
#
# Exit codes:
#   0  success or already_installed
#   10 unsupported_language
#   11 splice_point_not_found
#   12 target_not_found
#   13 target_unreadable
#   14 target_unwritable
#   15 backup_failed
#   16 multiple_splices_detected
#   18 json_statusline_unsupported
# Detect language of a target statusline script. Returns "bash"|"node"|"python"
# on stdout, exits 0 if detected; exits 1 if unsupported.
# Strategy: file extension first (cheap, deterministic), shebang fallback
# (handles extensionless scripts).
fi_detect_target_language() {
  local path="$1"
  case "$path" in
    *.sh|*.bash) echo "bash"; return 0 ;;
    *.js|*.mjs|*.cjs) echo "node"; return 0 ;;
    *.py) echo "python"; return 0 ;;
  esac
  # Shebang fallback
  if [[ -r "$path" ]]; then
    local shebang
    shebang="$(head -1 "$path" 2>/dev/null)"
    case "$shebang" in
      *node*) echo "node"; return 0 ;;
      *python*) echo "python"; return 0 ;;
      *bash*|*/sh*|*\ sh) echo "bash"; return 0 ;;
    esac
  fi
  return 1
}

cmd_install_statusline_custom_target() {
  local target_path="$1"
  local target_language="${2:-auto}"
  local target_mode="${3:-dry-run}"

  # Step 1: target must exist + be a regular file
  if [[ ! -e "$target_path" ]]; then
    fi_err "install-statusline --target: $target_path does not exist"
    return 12
  fi
  if [[ ! -f "$target_path" ]]; then
    fi_err "install-statusline --target: $target_path is not a regular file"
    return 12
  fi
  if [[ ! -r "$target_path" ]]; then
    fi_err "install-statusline --target: $target_path is not readable"
    return 13
  fi

  # Step 2: detect language
  local detected_lang
  if [[ "$target_language" == "auto" ]]; then
    detected_lang="$(fi_detect_target_language "$target_path")" || {
      fi_err "install-statusline --target: unsupported language for $target_path (no .sh/.js/.py extension or recognized shebang)"
      return 10
    }
  else
    case "$target_language" in
      bash|sh) detected_lang="bash" ;;
      node|js) detected_lang="node" ;;
      python|py) detected_lang="python" ;;
      *) fi_err "install-statusline --target: --language must be auto|bash|node|python"; return 10 ;;
    esac
  fi

  # Dispatch to per-language handler
  case "$detected_lang" in
    bash)   cmd_install_statusline_target_bash   "$target_path" "$target_mode" ;;
    node)   cmd_install_statusline_target_node   "$target_path" "$target_mode" ;;
    python) cmd_install_statusline_target_python "$target_path" "$target_mode" ;;
  esac
}

# Returns line number of the splice point in a bash statusline, or empty.
# Priority: LINE1= assignment, then first echo, then first printf.
# Lines that already reference __FI_SEG are never splice points — they are
# user placements of the segment, and appending a second ${__FI_SEG} would
# render the counter twice on that line (found during v1.5.7 verify).
fi_find_bash_splice_point() {
  local path="$1"
  local lines
  # Priority 1: LINE1= assignment
  lines="$(LC_ALL=C awk '/^[[:space:]]*LINE1=/ && !/__FI_SEG/ { print NR }' "$path")"
  [[ -n "$lines" ]] && { echo "$lines"; return 0; }
  # Priority 2: echo
  lines="$(LC_ALL=C awk '/^[[:space:]]*echo[[:space:]]/ && !/__FI_SEG/ { print NR }' "$path")"
  [[ -n "$lines" ]] && { echo "$lines"; return 0; }
  # Priority 3: printf
  lines="$(LC_ALL=C awk '/^[[:space:]]*printf[[:space:]]/ && !/__FI_SEG/ { print NR }' "$path")"
  [[ -n "$lines" ]] && { echo "$lines"; return 0; }
  return 1
}

# Find the host script's stdin-capture assignment (`var=$(cat)`, quoted or
# not). Prints "<line_no> <var_name>" for the FIRST match, nothing if none.
# The marker block reads the captured JSON from this variable — placing the
# block above the capture line (or hardcoding the name `input`) silently
# degrades cwd resolution to the CLAUDE_PROJECT_DIR fallback, the exact
# env-first bug the v1.5.6 fix removed (found-issues.md 2026-07-10 entry).
fi_find_bash_stdin_capture() {
  local path="$1"
  LC_ALL=C awk '
    match($0, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=["'\'']?\$\(cat[^)]*\)/) {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      sub(/=.*$/, "", line)
      print NR " " line
      exit
    }
  ' "$path"
}

# Emit the bash marker block (multi-line). Includes PATH-resilience and
# two-tier cwd resolution ($input JSON via jq → CLAUDE_PROJECT_DIR → empty).
# Mirrors the canonical install's robustness; see bin/found-issues:2360+.
#
# v1.5.6 cwd fix (two related bugs, same symptom — empty segment):
#   1. JSON-first, not env-first. CLAUDE_PROJECT_DIR is where the SESSION
#      started (often $HOME), while workspace.current_dir tracks where work
#      is actually happening. A session launched from $HOME that cd's into
#      a repo got the segment scoped to $HOME → no issues file → empty.
#   2. Explicit --cwd on the status call. cmd_status's search-root priority
#      is --cwd > CLAUDE_PROJECT_DIR > PWD, so the block's `cd` alone is
#      silently overridden by the inherited CLAUDE_PROJECT_DIR env var.
#   The `cd` is kept deliberately: the segment-autosync background `$0 sync`
#   dispatched by cmd_status inherits PWD, not --cwd.
# Optional $1: name of the host's stdin-capture variable (default: input).
fi_generate_bash_marker_block() {
  local stdin_var="${1:-input}"
  if [[ "$stdin_var" != "input" ]]; then
    fi_generate_bash_marker_block | LC_ALL=C sed \
      -e "s/\${input:-}/\${${stdin_var}:-}/" \
      -e "s/\"\$input\"/\"\$${stdin_var}\"/"
    return
  fi
  cat <<'BLOCK'
# === found-issues plugin segment ===
# Tries `found-issues` on PATH first; falls back to globbing the plugin cache
# for the latest installed binary (statusline subprocess may not inherit the
# plugin's auto-PATH).
__FI_CLI=""
if command -v found-issues >/dev/null 2>&1; then
  __FI_CLI=found-issues
else
  __FI_CLI=$(ls -d "$HOME"/.claude/plugins/cache/*/found-issues/*/bin/found-issues 2>/dev/null | sort -V | tail -1 || true)
  [[ -x "$__FI_CLI" ]] || __FI_CLI=""
fi
# Cwd resolution: prefer $input JSON workspace.current_dir (tracks the live
# workspace); fall back to CLAUDE_PROJECT_DIR (where the session started).
__FI_DIR=""
if [[ -n "${input:-}" ]] && command -v jq >/dev/null 2>&1; then
  __FI_DIR=$(echo "$input" | jq -r '.workspace.current_dir // ""' 2>/dev/null || true)
fi
[[ -z "$__FI_DIR" ]] && __FI_DIR="${CLAUDE_PROJECT_DIR:-}"
__FI_SEG=""
if [[ -n "$__FI_CLI" ]]; then
  if [[ -n "$__FI_DIR" ]]; then
    # --cwd is load-bearing: cmd_status prefers inherited CLAUDE_PROJECT_DIR
    # over PWD, so `cd` alone is not enough. cd kept for autosync's PWD.
    __FI_SEG=$( cd "$__FI_DIR" 2>/dev/null && "$__FI_CLI" status --format=segment --cwd "$__FI_DIR" 2>/dev/null || true )
  else
    __FI_SEG=$("$__FI_CLI" status --format=segment 2>/dev/null || true)
  fi
fi
# === end found-issues plugin segment ===
BLOCK
}

cmd_install_statusline_target_bash() {
  local path="$1"
  local mode="$2"

  # Idempotency: if v1.5.6+ marker block already present, no-op. If a
  # v1.5.0–v1.5.5 --cwd-less marker block is present, migrate (strip +
  # re-splice). No v1.4.x branch: the bash shim was always POSIX-correct
  # (see fi_target_is_v14x_broken). Migration strips a scratch COPY —
  # $path stays untouched until the apply-mode atomic rename, so dry-run
  # never mutates and the backup captures the user's original.
  local work="$path" work_tmp=""
  if grep -Fq "# === found-issues plugin segment ===" "$path"; then
    if fi_target_is_v15x_broken "$path" bash; then
      printf 'install-statusline --target: migrating v1.5.x marker block without --cwd in %s\n' "$path"
      work_tmp="$(fi_strip_to_scratch "$path" bash)" || {
        fi_err "install-statusline --target: failed to strip v1.5.x marker block"
        return 14
      }
      work="$work_tmp"
    else
      printf 'install-statusline --target: %s already integrated (no-op)\n' "$path"
      return 0
    fi
  fi

  local splice_line
  splice_line="$(fi_find_bash_splice_point "$work")" || {
    fi_err "install-statusline --target: no splice point found in $path"
    fi_err "  Tried: LINE1= assignment, first 'echo', first 'printf'"
    fi_err "  If your statusline uses a different output pattern, an AI-assisted"
    fi_err "  edit can still install the segment manually — re-run /found-issues:setup"
    fi_err "  to be offered the AI fallback."
    if [[ -n "$work_tmp" ]]; then
      rm -f "$work_tmp"
      fi_err "  Note: the existing (broken, --cwd-less) marker block was NOT modified;"
      fi_err "  the file is unchanged. It needs the manual/AI-assisted migration above."
    fi
    return 11
  }

  # Insertion line for the marker block: right before the splice line, but
  # after any leading shebang/set lines. For simplicity, insert at line 2
  # (after shebang); the reference line gets ${__FI_SEG} appended.
  local insert_after
  insert_after="$(awk '
    NR == 1 && /^#!/ { last = 1; next }
    /^[[:space:]]*set[[:space:]]/ { last = NR; next }
    { exit }
    END { print last + 0 }
  ' "$work")"
  [[ -z "$insert_after" || "$insert_after" -eq 0 ]] && insert_after=0

  # If the host captures stdin (`var=$(cat)`), the block MUST land after
  # that line and reference that variable — above it, `${input:-}` is empty
  # at block-execution time and cwd resolution silently degrades to the
  # CLAUDE_PROJECT_DIR fallback (the v1.5.6 env-first bug, reintroduced for
  # custom targets). Only reposition when the capture precedes the first
  # splice line; a script that emits output before reading stdin keeps the
  # preamble placement.
  local stdin_var="input" capture_info capture_ln first_splice
  capture_info="$(fi_find_bash_stdin_capture "$work")"
  if [[ -n "$capture_info" ]]; then
    capture_ln="${capture_info%% *}"
    first_splice="$(printf '%s\n' "$splice_line" | sort -n | head -1)"
    if (( capture_ln > insert_after )) && (( capture_ln < first_splice )); then
      insert_after="$capture_ln"
      stdin_var="${capture_info#* }"
    fi
  fi

  # Generate the modified content into a temp file.
  # Write the marker block to its own temp file so awk can read it via getline
  # rather than via -v (awk -v does not support multi-line values portably).
  # BSD awk on macOS rejects literal newlines in -v values; convert to space.
  local splice_lines_sp
  splice_lines_sp="$(printf '%s' "$splice_line" | tr '\n' ' ')"

  local tmp_block tmp_modified
  tmp_block="$(mktemp -t fi-target-block.XXXXXX)"
  fi_generate_bash_marker_block "$stdin_var" > "$tmp_block"
  tmp_modified="$(mktemp -t fi-target-mod.XXXXXX)"
  LC_ALL=C awk -v insert_after="$insert_after" \
      -v splice_lines="$splice_lines_sp" \
      -v block_file="$tmp_block" '
    BEGIN {
      n = split(splice_lines, arr, " ")
      for (i = 1; i <= n; i++) if (arr[i] != "") splice_set[arr[i]] = 1
    }
    function print_block(    line) {
      while ((getline line < block_file) > 0) print line
      close(block_file)
    }
    # No-preamble file (no shebang/set lines): emit the block above line 1,
    # then FALL THROUGH so a line-1 splice point still gets the segment
    # spliced — with `next` here, a one-line statusline got the splice but
    # never the block that defines __FI_SEG.
    NR == 1 && insert_after == 0 { print_block() }
    NR == insert_after && insert_after > 0 { print; print_block(); next }
    (NR in splice_set) {
      line = $0
      if (match(line, /"[^"]*"$/)) {
        sub(/"$/, "${__FI_SEG}\"  # found-issues:seg", line)
      } else {
        line = line "${__FI_SEG}  # found-issues:seg"
      }
      print line
      next
    }
    { print }
  ' "$work" > "$tmp_modified"
  rm -f "$tmp_block"
  [[ -z "$work_tmp" ]] || rm -f "$work_tmp"

  if [[ "$mode" == "dry-run" || -z "$mode" ]]; then
    # Print unified diff (against the untouched original — for migrations
    # this shows strip + re-splice as one change).
    diff -u "$path" "$tmp_modified" || true
    rm -f "$tmp_modified"
    return 0
  fi

  # Apply mode: backup + atomic write
  local ts backup_path tmp_atomic
  ts="$(date +%Y%m%d-%H%M%S)"
  backup_path="${path}.fi-bak-${ts}"
  cp -p "$path" "$backup_path" || {
    fi_err "install-statusline --target: backup write failed: $backup_path"
    rm -f "$tmp_modified"
    return 15
  }
  # Atomic write: copy modified content to a tmp file alongside the target,
  # then rename. Preserves permissions of the original.
  tmp_atomic="${path}.fi-tmp-${ts}"
  cp "$tmp_modified" "$tmp_atomic" || {
    fi_err "install-statusline --target: tmp write failed: $tmp_atomic"
    rm -f "$tmp_modified" "$tmp_atomic"
    return 14
  }
  # Preserve original mode (including exec bit).
  local original_mode
  original_mode="$(fi_capture_mode "$path")"
  chmod "$original_mode" "$tmp_atomic" 2>/dev/null || chmod +x "$tmp_atomic"
  mv "$tmp_atomic" "$path" || {
    fi_err "install-statusline --target: atomic rename failed"
    rm -f "$tmp_modified" "$tmp_atomic"
    return 14
  }
  rm -f "$tmp_modified"

  # Symlink warning
  if [[ -L "$path" ]]; then
    local real
    real="$(readlink "$path")"
    fi_err "note: $path is a symlink to $real; your sync system may overwrite changes on next render"
  fi

  printf 'install-statusline --target: applied to %s (backup: %s)\n' "$path" "$backup_path"
  printf 'Restart your Claude Code session to see the segment render.\n'
  return 0
}
fi_find_node_splice_point() {
  local path="$1"
  local lines
  # Priority 1: console.log with template literal (backticks)
  lines="$(LC_ALL=C awk '/console\.log[[:space:]]*\(`/ { print NR }' "$path")"
  [[ -n "$lines" ]] && { echo "$lines"; return 0; }
  # Priority 2: console.log with plain string (single or double quote)
  lines="$(LC_ALL=C awk '/console\.log[[:space:]]*\(("|'"'"')/ { print NR }' "$path")"
  [[ -n "$lines" ]] && { echo "$lines"; return 0; }
  # Priority 3: process.stdout.write
  lines="$(LC_ALL=C awk '/process\.stdout\.write[[:space:]]*\(/ { print NR }' "$path")"
  [[ -n "$lines" ]] && { echo "$lines"; return 0; }
  return 1
}

fi_generate_node_marker_block() {
  cat <<'BLOCK'
// === found-issues plugin segment ===
// Cross-platform: POSIX uses PATH; Windows enumerates the plugin cache via fs.
// Invocation is deferred via __fiSeg(dir) so the splice point can pass the
// real workspace dir (parsed from stdin by the host statusline). When dir is
// unavailable, falls back through env (CLAUDE_PROJECT_DIR, PWD) then home.
let __fiCli = null;
function __fiSeg(dir) {
  if (!__fiCli) return '';
  try {
    const { execFileSync } = require('child_process');
    const cwd = dir
      || process.env.CLAUDE_PROJECT_DIR
      || process.env.PWD
      || require('os').homedir();
    if (process.platform === 'win32') {
      const posixPath = __fiCli.replace(/\\/g, '/');
      const posixCwd = cwd.replace(/\\/g, '/');
      // On Windows, Node's cwd option passes to the Windows API which cannot
      // resolve POSIX Git Bash paths (e.g. /d/a/...). Instead, cd inside bash
      // so bash handles the POSIX path resolution natively. Pass cwd + cli
      // as argv positionals so bash doesn't re-parse them — eliminates the
      // need to escape ' or " in either path.
      // --cwd is load-bearing: the CLI prefers inherited CLAUDE_PROJECT_DIR
      // (where the session STARTED) over PWD, so cd/cwd alone is overridden.
      return execFileSync('bash', ['-c', 'cd "$1" && "$2" status --format=segment --cwd "$1"', '_', posixCwd, posixPath],
        { encoding: 'utf8', timeout: 5000 }).trim();
    }
    return execFileSync(__fiCli, ['status', '--format=segment', '--cwd', cwd],
      { cwd, encoding: 'utf8', timeout: 5000 }).trim();
  } catch (e) { return ''; }
}
try {
  const _path = require('path');
  const _fs = require('fs');
  const _os = require('os');
  // FOUND_ISSUES_BIN: explicit override — used by tests and advanced installs.
  // No existsSync check: on Windows, Node.js cannot resolve POSIX Git Bash
  // paths (/d/a/...) via the Windows filesystem API. Trust the caller.
  if (process.env.FOUND_ISSUES_BIN) {
    __fiCli = process.env.FOUND_ISSUES_BIN;
  }
  if (!__fiCli && process.platform !== 'win32') {
    try {
      require('child_process').execSync('command -v found-issues', { stdio: 'ignore' });
      __fiCli = 'found-issues';
    } catch (e) { /* fall through to cache lookup */ }
  }
  if (!__fiCli) {
    const cacheRoot = _path.join(_os.homedir(), '.claude', 'plugins', 'cache');
    if (_fs.existsSync(cacheRoot)) {
      const candidates = [];
      for (const mkt of _fs.readdirSync(cacheRoot)) {
        const fiDir = _path.join(cacheRoot, mkt, 'found-issues');
        if (!_fs.existsSync(fiDir)) continue;
        for (const ver of _fs.readdirSync(fiDir)) {
          const bin = _path.join(fiDir, ver, 'bin', 'found-issues');
          if (_fs.existsSync(bin)) candidates.push({ ver, bin });
        }
      }
      candidates.sort((a, b) => a.ver.localeCompare(b.ver, undefined, { numeric: true }));
      if (candidates.length) __fiCli = candidates[candidates.length - 1].bin;
    }
  }
} catch (e) { /* silent: never break the statusline */ }
// === end found-issues plugin segment ===
BLOCK
}

cmd_install_statusline_target_node() {
  local path="$1"
  local mode="$2"

  # Idempotency: if v1.5.6+ marker block already present, no-op.
  # If v1.4.x POSIX-only or v1.5.0–v1.5.5 --cwd-less marker present,
  # strip + reinstall (migration path). Migration strips a scratch COPY —
  # $path stays untouched until the apply-mode atomic rename, so dry-run
  # never mutates and the backup captures the user's original.
  local work="$path" work_tmp=""
  if grep -Fq "// === found-issues plugin segment ===" "$path"; then
    if fi_target_is_v14x_broken "$path" node; then
      printf 'install-statusline --target: migrating v1.4.x POSIX-only marker block in %s\n' "$path"
      # Strip old marker block + splice trailers (on a scratch copy), then
      # fall through to install.
      work_tmp="$(fi_strip_to_scratch "$path" node)" || {
        fi_err "install-statusline --target: failed to strip v1.4.x marker block"
        return 14
      }
      work="$work_tmp"
    elif fi_target_is_v15x_broken "$path" node; then
      printf 'install-statusline --target: migrating v1.5.x marker block without --cwd in %s\n' "$path"
      work_tmp="$(fi_strip_to_scratch "$path" node)" || {
        fi_err "install-statusline --target: failed to strip v1.5.x marker block"
        return 14
      }
      work="$work_tmp"
    else
      printf 'install-statusline --target: %s already integrated (no-op)\n' "$path"
      return 0
    fi
  fi

  local splice_line
  splice_line="$(fi_find_node_splice_point "$work")" || {
    fi_err "install-statusline --target node: no splice point found in $path"
    fi_err "  Tried: console.log(\`...\`), console.log(\"...\"), process.stdout.write(...)"
    if [[ -n "$work_tmp" ]]; then
      rm -f "$work_tmp"
      fi_err "  Note: the existing (broken) marker block was NOT modified; the file is unchanged."
    fi
    return 11
  }

  # Determine insertion line for marker block: after leading require/import lines.
  local insert_after
  insert_after="$(awk '
    NR == 1 && /^#!/ { last = 1; next }
    /^[[:space:]]*(const|let|var)[[:space:]]+.*=[[:space:]]+require\(/ { last = NR; next }
    /^[[:space:]]*import[[:space:]]+/ { last = NR; next }
    { exit }
    END { print last + 0 }
  ' "$work")"
  [[ -z "$insert_after" || "$insert_after" -eq 0 ]] && insert_after=0

  # Write marker block to tmp file (multi-line awk -v workaround, same as Task 1.4)
  local tmp_block tmp_modified
  tmp_block="$(mktemp -t fi-target-node-block.XXXXXX)"
  fi_generate_node_marker_block > "$tmp_block"

  # splice_line is now a newline-separated list of line numbers; convert to space-separated
  # for awk -v (BSD awk rejects literal newlines in -v values)
  local splice_lines_sp
  splice_lines_sp="$(printf '%s' "$splice_line" | tr '\n' ' ')"
  tmp_modified="$(mktemp -t fi-target-node-mod.XXXXXX)"
  LC_ALL=C awk -v insert_after="$insert_after" \
      -v splice_lines="$splice_lines_sp" \
      -v block_file="$tmp_block" '
    BEGIN {
      n = split(splice_lines, arr, " ")
      for (i = 1; i <= n; i++) if (arr[i] != "") splice_set[arr[i]] = 1
    }
    function print_block(   line) {
      while ((getline line < block_file) > 0) print line
      close(block_file)
    }
    # See the bash twin: block-at-top must fall through so a line-1 splice
    # point still gets spliced.
    NR == 1 && insert_after == 0 { print_block() }
    NR == insert_after && insert_after > 0 { print; print_block(); next }
    (NR in splice_set) {
      line = $0
      if (match(line, /`/)) {
        last_bt = 0
        for (i = length(line); i >= 1; i--) {
          if (substr(line, i, 1) == "`") { last_bt = i; break }
        }
        if (last_bt > 0) {
          line = substr(line, 1, last_bt - 1) "${__fiSeg(typeof dir!=='\''undefined'\''?dir:(typeof cwd!=='\''undefined'\''?cwd:undefined))}" substr(line, last_bt)
        }
        sub(/;[[:space:]]*$/, ";  // found-issues:seg", line)
        if (line !~ /found-issues:seg/) line = line "  // found-issues:seg"
      } else if (match(line, /console\.log\(/) || match(line, /process\.stdout\.write\(/)) {
        sub(/\)/, " + __fiSeg(typeof dir!=='\''undefined'\''?dir:(typeof cwd!=='\''undefined'\''?cwd:undefined)))", line)
        sub(/;[[:space:]]*$/, ";  // found-issues:seg", line)
        if (line !~ /found-issues:seg/) line = line "  // found-issues:seg"
      }
      print line
      next
    }
    { print }
  ' "$work" > "$tmp_modified"
  [[ -z "$work_tmp" ]] || rm -f "$work_tmp"

  if [[ "$mode" == "dry-run" || -z "$mode" ]]; then
    diff -u "$path" "$tmp_modified" || true
    rm -f "$tmp_modified" "$tmp_block"
    return 0
  fi

  # Apply: backup + atomic write
  local ts backup_path tmp_atomic original_mode
  ts="$(date +%Y%m%d-%H%M%S)"
  backup_path="${path}.fi-bak-${ts}"
  cp -p "$path" "$backup_path" || { rm -f "$tmp_modified" "$tmp_block"; return 15; }
  tmp_atomic="${path}.fi-tmp-${ts}"
  cp "$tmp_modified" "$tmp_atomic" || { rm -f "$tmp_modified" "$tmp_atomic" "$tmp_block"; return 14; }
  original_mode="$(fi_capture_mode "$path")"
  chmod "$original_mode" "$tmp_atomic" 2>/dev/null || chmod +x "$tmp_atomic"
  mv "$tmp_atomic" "$path" || {
    fi_err "install-statusline --target: atomic rename failed"
    rm -f "$tmp_modified" "$tmp_atomic" "$tmp_block"
    return 14
  }
  rm -f "$tmp_modified" "$tmp_block"

  if [[ -L "$path" ]]; then
    local real
    real="$(readlink "$path")"
    fi_err "note: $path is a symlink to $real; your sync system may overwrite changes on next render"
  fi

  printf 'install-statusline --target: applied to %s (backup: %s)\n' "$path" "$backup_path"
  printf 'Restart your Claude Code session to see the segment render.\n'
  return 0
}
fi_find_python_splice_point() {
  local path="$1"
  local lines
  # Priority 1: print(f"...") or print(f'...')
  lines="$(LC_ALL=C awk '/^[[:space:]]*print[[:space:]]*\(f["'"'"'][^)]*\)/ { print NR }' "$path")"
  [[ -n "$lines" ]] && { echo "$lines"; return 0; }
  # Priority 2: print("...") or print('...')
  lines="$(LC_ALL=C awk '/^[[:space:]]*print[[:space:]]*\(["'"'"'][^)]*\)/ { print NR }' "$path")"
  [[ -n "$lines" ]] && { echo "$lines"; return 0; }
  # Priority 3: sys.stdout.write(...)
  lines="$(LC_ALL=C awk '/^[[:space:]]*sys\.stdout\.write[[:space:]]*\(/ { print NR }' "$path")"
  [[ -n "$lines" ]] && { echo "$lines"; return 0; }
  return 1
}

fi_generate_python_marker_block() {
  cat <<'BLOCK'
# === found-issues plugin segment ===
# Cross-platform: POSIX uses PATH; Windows invokes via Git Bash (bin/found-issues
# is a bash script). Invocation is deferred via _fi_seg(_dir) so the splice
# point can pass the real workspace dir (parsed from stdin by the host
# statusline). When _dir is unavailable, falls back through env then home.
import subprocess as _fi_subprocess
import shutil as _fi_shutil
import platform as _fi_platform
import os as _fi_os
import pathlib as _fi_pathlib

_fi_cli = None
try:
    # FOUND_ISSUES_BIN: explicit override — used by tests and advanced installs.
    # No is_file() check: on Windows, Python cannot resolve POSIX Git Bash
    # paths (/d/a/...) via the Windows filesystem API. Trust the caller.
    _fi_env_bin = _fi_os.environ.get('FOUND_ISSUES_BIN', '')
    if _fi_env_bin:
        _fi_cli = _fi_env_bin
    if not _fi_cli and _fi_platform.system() != 'Windows':
        _fi_cli = _fi_shutil.which('found-issues')
    if not _fi_cli:
        _fi_cache_root = _fi_pathlib.Path.home() / '.claude' / 'plugins' / 'cache'
        if _fi_cache_root.is_dir():
            _fi_candidates = []
            for _fi_mkt in _fi_cache_root.iterdir():
                _fi_fi_dir = _fi_mkt / 'found-issues'
                if not _fi_fi_dir.is_dir():
                    continue
                for _fi_ver in _fi_fi_dir.iterdir():
                    _fi_bin = _fi_ver / 'bin' / 'found-issues'
                    if _fi_bin.is_file():
                        _fi_candidates.append((_fi_ver.name, str(_fi_bin)))
            _fi_candidates.sort(key=lambda v: [int(x) if x.isdigit() else x for x in v[0].replace('-', '.').split('.')])
            if _fi_candidates:
                _fi_cli = _fi_candidates[-1][1]
except Exception:
    _fi_cli = None

def _fi_seg(_dir=None):
    if not _fi_cli:
        return ''
    try:
        _fi_cwd = (
            _dir
            or _fi_os.environ.get('CLAUDE_PROJECT_DIR')
            or _fi_os.environ.get('PWD')
            or str(_fi_pathlib.Path.home())
        )
        if _fi_platform.system() == 'Windows':
            _fi_posix = _fi_cli.replace('\\', '/')
            # On Windows, Python's cwd arg passes to the Windows API which cannot
            # resolve POSIX Git Bash paths (e.g. /d/a/...). cd inside bash instead.
            # Use FOUND_ISSUES_BASH if set (avoids Windows PATH resolving to WSL
            # bash.exe instead of Git Bash when wsl.exe is earlier in PATH).
            # Fall back to known Git for Windows install paths, then plain 'bash'.
            _fi_bash_env = _fi_os.environ.get('FOUND_ISSUES_BASH', '')
            _fi_bash_bin = _fi_bash_env or 'bash'
            if not _fi_bash_env:
                for _fi_candidate in [
                    r'C:\Program Files\Git\bin\bash.exe',
                    r'C:\Program Files\Git\usr\bin\bash.exe',
                ]:
                    if _fi_pathlib.Path(_fi_candidate).is_file():
                        _fi_bash_bin = _fi_candidate
                        break
            _fi_posix_cwd = _fi_cwd.replace('\\', '/')
            # Pass cwd + cli as argv positionals so bash doesn't re-parse them
            # — eliminates the need to escape ' or " in either path.
            # --cwd is load-bearing: the CLI prefers inherited CLAUDE_PROJECT_DIR
            # (where the session STARTED) over PWD, so cd/cwd alone is overridden.
            _fi_result = _fi_subprocess.run(
                [_fi_bash_bin, '-c', 'cd "$1" && "$2" status --format=segment --cwd "$1"', '_', _fi_posix_cwd, _fi_posix],
                capture_output=True, timeout=5
            )
            return _fi_result.stdout.decode('utf-8', errors='replace').strip()
        return _fi_subprocess.run(
            [_fi_cli, 'status', '--format=segment', '--cwd', _fi_cwd],
            cwd=_fi_cwd, capture_output=True, text=True, timeout=5
        ).stdout.strip()
    except Exception:
        return ''
# === end found-issues plugin segment ===
BLOCK
}

cmd_install_statusline_target_python() {
  local path="$1"
  local mode="$2"

  # Idempotency: if v1.5.6+ marker block already present, no-op.
  # If v1.4.x POSIX-only or v1.5.0–v1.5.5 --cwd-less marker present,
  # strip + reinstall (migration path). Migration strips a scratch COPY —
  # $path stays untouched until the apply-mode atomic rename, so dry-run
  # never mutates and the backup captures the user's original.
  local work="$path" work_tmp=""
  if grep -Fq "# === found-issues plugin segment ===" "$path"; then
    if fi_target_is_v14x_broken "$path" python; then
      printf 'install-statusline --target: migrating v1.4.x POSIX-only marker block in %s\n' "$path"
      work_tmp="$(fi_strip_to_scratch "$path" python)" || {
        fi_err "install-statusline --target: failed to strip v1.4.x marker block"
        return 14
      }
      work="$work_tmp"
    elif fi_target_is_v15x_broken "$path" python; then
      printf 'install-statusline --target: migrating v1.5.x marker block without --cwd in %s\n' "$path"
      work_tmp="$(fi_strip_to_scratch "$path" python)" || {
        fi_err "install-statusline --target: failed to strip v1.5.x marker block"
        return 14
      }
      work="$work_tmp"
    else
      printf 'install-statusline --target: %s already integrated (no-op)\n' "$path"
      return 0
    fi
  fi

  local splice_line
  splice_line="$(fi_find_python_splice_point "$work")" || {
    fi_err "install-statusline --target python: no splice point found in $path"
    fi_err "  Tried: print(f\"...\"), print(\"...\"), sys.stdout.write(...)"
    if [[ -n "$work_tmp" ]]; then
      rm -f "$work_tmp"
      fi_err "  Note: the existing (broken) marker block was NOT modified; the file is unchanged."
    fi
    return 11
  }

  # Find insertion line for marker block: after leading imports
  local insert_after
  insert_after="$(awk '
    NR == 1 && /^#!/ { last = 1; next }
    /^[[:space:]]*import[[:space:]]+/ { last = NR; next }
    /^[[:space:]]*from[[:space:]]+.*import/ { last = NR; next }
    { exit }
    END { print last + 0 }
  ' "$work")"
  [[ -z "$insert_after" || "$insert_after" -eq 0 ]] && insert_after=0

  # Write marker block to tmp file (multi-line awk -v workaround)
  local tmp_block tmp_modified
  tmp_block="$(mktemp -t fi-target-python-block.XXXXXX)"
  fi_generate_python_marker_block > "$tmp_block"

  # BSD awk on macOS rejects literal newlines in -v values; convert to space.
  local splice_lines_sp
  splice_lines_sp="$(printf '%s' "$splice_line" | tr '\n' ' ')"

  tmp_modified="$(mktemp -t fi-target-python-mod.XXXXXX)"
  LC_ALL=C awk -v insert_after="$insert_after" \
      -v splice_lines="$splice_lines_sp" \
      -v block_file="$tmp_block" '
    BEGIN {
      n = split(splice_lines, arr, " ")
      for (i = 1; i <= n; i++) if (arr[i] != "") splice_set[arr[i]] = 1
    }
    function print_block(   line) {
      while ((getline line < block_file) > 0) print line
      close(block_file)
    }
    # See the bash twin: block-at-top must fall through so a line-1 splice
    # point still gets spliced.
    NR == 1 && insert_after == 0 { print_block() }
    NR == insert_after && insert_after > 0 { print; print_block(); next }
    (NR in splice_set) {
      line = $0
      if (match(line, /print[[:space:]]*\(f"/)) {
        idx = index(line, "\")")
        if (idx > 0) {
          line = substr(line, 1, idx-1) "{_fi_seg(locals().get(\"dir\") or locals().get(\"cwd\"))}" substr(line, idx) "  # found-issues:seg"
        }
      } else if (match(line, /print[[:space:]]*\(f'"'"'/)) {
        idx = index(line, "'"'"')")
        if (idx > 0) {
          line = substr(line, 1, idx-1) "{_fi_seg(locals().get(\"dir\") or locals().get(\"cwd\"))}" substr(line, idx) "  # found-issues:seg"
        }
      } else if (match(line, /print[[:space:]]*\(["'"'"']/)) {
        sub(/\)[[:space:]]*$/, " + _fi_seg(locals().get(\"dir\") or locals().get(\"cwd\")))  # found-issues:seg", line)
      } else if (match(line, /sys\.stdout\.write[[:space:]]*\(/)) {
        sub(/\)[[:space:]]*$/, " + _fi_seg(locals().get(\"dir\") or locals().get(\"cwd\")))  # found-issues:seg", line)
      }
      print line
      next
    }
    { print }
  ' "$work" > "$tmp_modified"
  [[ -z "$work_tmp" ]] || rm -f "$work_tmp"

  if [[ "$mode" == "dry-run" || -z "$mode" ]]; then
    diff -u "$path" "$tmp_modified" || true
    rm -f "$tmp_modified" "$tmp_block"
    return 0
  fi

  # Apply: same backup + atomic write as bash/node
  local ts backup_path tmp_atomic original_mode
  ts="$(date +%Y%m%d-%H%M%S)"
  backup_path="${path}.fi-bak-${ts}"
  cp -p "$path" "$backup_path" || { rm -f "$tmp_modified" "$tmp_block"; return 15; }
  tmp_atomic="${path}.fi-tmp-${ts}"
  cp "$tmp_modified" "$tmp_atomic" || { rm -f "$tmp_modified" "$tmp_atomic" "$tmp_block"; return 14; }
  original_mode="$(fi_capture_mode "$path")"
  chmod "$original_mode" "$tmp_atomic" 2>/dev/null || chmod +x "$tmp_atomic"
  mv "$tmp_atomic" "$path" || {
    fi_err "install-statusline --target: atomic rename failed"
    rm -f "$tmp_modified" "$tmp_atomic" "$tmp_block"
    return 14
  }
  rm -f "$tmp_modified" "$tmp_block"

  if [[ -L "$path" ]]; then
    local real
    real="$(readlink "$path")"
    fi_err "note: $path is a symlink to $real; your sync system may overwrite changes on next render"
  fi

  printf 'install-statusline --target: applied to %s (backup: %s)\n' "$path" "$backup_path"
  printf 'Restart your Claude Code session to see the segment render.\n'
  return 0
}

