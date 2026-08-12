#!/usr/bin/env bash
# statusline-core.sh — statusline file constants, state detection, snippet stripping
#
# Sourced by bin/found-issues. Defines functions plus the three
# FI_STATUSLINE_* constants the whole statusline family reads.
# Compatible with bash 3.2+ (macOS system bash).
#
# Extracted verbatim from bin/found-issues in v2.2.5 (the tracked §12 split);
# see the [open] loc-validator entry in docs/found-issues.md.
#
# Functions:
#   fi_capture_mode <file>
#   fi_save_statusline_backup <file>
#   fi_statusline_state [<path>]
#   fi_strip_legacy_handwritten <file>
#   fi_target_is_v14x_broken <file>
#   fi_target_is_v15x_broken <file>
#   fi_strip_target_markers <file>
#   fi_strip_to_scratch <file>

# === Subcommand: install-statusline ===
#
# Append the found-issues counter segment block to ~/.claude/statusline.sh.
# Idempotent: marker comment lets us detect existing installs and skip.
# Safe under set -e: the inserted block uses `|| true` so command-not-found
# from `found-issues` (when the CLI isn't on PATH) won't kill the host
# script. The block adds one new line of statusline output (the counter
# segment), no inline edits to existing logic.

readonly FI_STATUSLINE_FILE="$HOME/.claude/statusline.sh"
readonly FI_STATUSLINE_START_MARKER="# === found-issues plugin segment ==="
readonly FI_STATUSLINE_END_MARKER="# === end found-issues plugin segment ==="

# Capture the mode of a file as octal (e.g. "755"). Cross-platform: BSD stat
# uses -f '%Lp', GNU stat uses -c '%a'. Falls back to 755 if neither works,
# which is correct for executable scripts (the common case for statusline).
fi_capture_mode() {
  stat -f '%Lp' "$1" 2>/dev/null \
    || stat -c '%a' "$1" 2>/dev/null \
    || echo 755
}

# Save a timestamped backup of the statusline file before destructive edits
# (legacy-snippet stripping). Echoes the backup path on stdout. Used by
# install-statusline's auto-migrate path so users can recover by hand if the
# strip heuristic ever mis-matches a custom variant.
#
# Why backup before strip: v1.0.4 flipped --migrate from opt-in to default.
# The strip heuristic is precise (only matches the 3-line handwritten template
# pattern) but auto-acting on user files warrants a recovery path. The backup
# is single-shot per migration (timestamped suffix) — won't accumulate across
# repeated installs because the second install hits installed-fixed and no-ops.
fi_save_statusline_backup() {
  local src="$1"
  local ts backup
  ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo backup)"
  backup="${src}.fi-bak-${ts}"
  cp "$src" "$backup" 2>/dev/null || return 1
  printf '%s' "$backup"
}

# Classify the current state of the user's statusline integration.
# Echoes one of: none, installed-fixed, installed-broken, legacy-handwritten,
# legacy-and-installed, or no-file.
#
# Why this matters: silent breakage. Users with v1.0.0/1.0.1 have a
# marker-bracketed segment that doesn't `cd` into the workspace → empty
# output. Pre-v0.1.7 dogfood users have a 3-line handwritten snippet (no
# markers at all) with the same cwd bug. Both groups installed in good
# faith and see nothing on their statusline. The classifier lets
# install-statusline / doctor-statusline / SessionStart all act on the
# same precise diagnosis.
#
# Heuristics:
#   no-file              — $FI_STATUSLINE_FILE does not exist
#   installed-fixed      — marker block present AND contains `__FI_DIR` + `cd "$__FI_DIR"`
#   installed-broken     — marker block present, missing the cwd handling (v1.0.0/1.0.1)
#   legacy-handwritten   — no markers, but a line matches the handwritten
#                          `FI_SEG=$(found-issues status --format=segment ...)`
#                          pattern from pre-v0.1.7 setup.md
#   legacy-and-installed — both markers AND a stray legacy line outside markers
#                          (would render the count twice — needs cleanup)
#   none                 — no found-issues integration at all (fresh install path)
fi_statusline_state() {
  local file="${1:-$FI_STATUSLINE_FILE}"
  local language="${2:-bash}"
  if [[ ! -f "$file" ]]; then
    printf 'no-file'
    return 0
  fi

  # Node/Python: simpler detection (no legacy migration history).
  if [[ "$language" != "bash" ]]; then
    if fi_target_is_v14x_broken "$file" "$language"; then
      printf 'installed-broken-posix'
      return 0
    fi
    if fi_target_is_v15x_broken "$file" "$language"; then
      printf 'installed-broken-posix'
      return 0
    fi
    if grep -Fq "// === found-issues plugin segment ===" "$file" 2>/dev/null \
       || grep -Fq "# === found-issues plugin segment ===" "$file" 2>/dev/null; then
      printf 'installed-fixed'
      return 0
    fi
    printf 'none'
    return 0
  fi

  local has_marker=0 marker_block_fixed=0 has_legacy=0
  if grep -Fq "$FI_STATUSLINE_START_MARKER" "$file" 2>/dev/null; then
    has_marker=1
    # Inspect block contents — `__FI_DIR` only appears in v1.0.2+ snippets,
    # and `--cwd` only in v1.5.6+ snippets. Both are required for "fixed":
    # v1.0.2–v1.5.5 blocks cd into the workspace but the CLI's search-root
    # priority (--cwd > CLAUDE_PROJECT_DIR > PWD) lets an inherited
    # CLAUDE_PROJECT_DIR (= where the session started, often $HOME) silently
    # override the cd → empty segment. Classifying those as installed-broken
    # routes them through the existing rewrite-in-place migration.
    if awk -v start="$FI_STATUSLINE_START_MARKER" \
           -v endm="$FI_STATUSLINE_END_MARKER" '
        $0 == start { in_block = 1; next }
        $0 == endm { in_block = 0; next }
        in_block { print }
      ' "$file" | grep -F '__FI_DIR' | grep -Fq -- '--cwd'; then
      marker_block_fixed=1
    fi
  fi

  # Detect handwritten legacy lines OUTSIDE any marker block. The pre-v0.1.7
  # setup.md instructed Claude to write a 3-line snippet roughly:
  #   # found-issues plugin segment ...
  #   FI_SEG=$(found-issues status --format=segment 2>/dev/null || true)
  #   [[ -n "$FI_SEG" ]] && LINE1="$LINE1 ... $FI_SEG"
  # The signature line is the `found-issues status --format=segment` invocation
  # NOT bracketed by our markers and NOT prefixed by `__FI_CLI` (which would
  # indicate it's the v1.0.0+ marker form, not handwritten).
  if awk -v start="$FI_STATUSLINE_START_MARKER" \
         -v endm="$FI_STATUSLINE_END_MARKER" '
      $0 == start { in_block = 1; next }
      $0 == endm { in_block = 0; next }
      !in_block && /found-issues[[:space:]]+status[[:space:]]+--format[=[:space:]]+segment/ { found = 1 }
      END { exit (found ? 0 : 1) }
    ' "$file"; then
    has_legacy=1
  fi

  if (( has_marker == 1 && marker_block_fixed == 1 && has_legacy == 0 )); then
    printf 'installed-fixed'
  elif (( has_marker == 1 && marker_block_fixed == 1 && has_legacy == 1 )); then
    printf 'legacy-and-installed'
  elif (( has_marker == 1 && marker_block_fixed == 0 && has_legacy == 0 )); then
    printf 'installed-broken'
  elif (( has_marker == 1 && marker_block_fixed == 0 && has_legacy == 1 )); then
    printf 'legacy-and-installed'
  elif (( has_marker == 0 && has_legacy == 1 )); then
    printf 'legacy-handwritten'
  else
    printf 'none'
  fi
}

# Surgically remove handwritten legacy snippet lines from $FI_STATUSLINE_FILE.
# Identifies a "legacy block" as:
#   - A line containing `found-issues status --format=segment` (or `--format segment`)
#     that is NOT inside our marker block.
#   - PLUS the immediately preceding line if it's a `# ... found-issues ...` comment.
#   - PLUS the immediately following line if it references `$FI_SEG`/`$__FI_SEG`
#     (the LINE1 assembly or echo follow-up).
# Conservative: only deletes contiguous lines matching this signature. Won't
# touch unrelated content. Outside-marker constraint prevents accidental
# damage to installed-fixed/installed-broken blocks (those go through the
# uninstall+install path instead).
fi_strip_legacy_handwritten() {
  local file="$1"
  local tmp original_mode
  original_mode=$(fi_capture_mode "$file")
  tmp="$(mktemp -t found-issues-statusline.XXXXXX)"

  awk -v start="$FI_STATUSLINE_START_MARKER" \
      -v endm="$FI_STATUSLINE_END_MARKER" '
    BEGIN { buf_n = 0; in_block = 0 }
    {
      if ($0 == start) { in_block = 1 }
      if (!in_block && $0 ~ /found-issues[[:space:]]+status[[:space:]]+--format[=[:space:]]+segment/) {
        # This line is the legacy invocation — drop it. Also drop the
        # immediately preceding buffered line if it is a found-issues comment.
        if (buf_n > 0 && buf[buf_n] ~ /^[[:space:]]*#.*found-issues/) {
          buf_n--
        }
        # Set a flag so the NEXT line is also skipped if it references FI_SEG.
        skip_next = 1
        next
      }
      if (skip_next == 1) {
        skip_next = 0
        if ($0 ~ /\$FI_SEG|\$__FI_SEG/) {
          # Drop the LINE1-assembly / echo follow-up.
          next
        }
        # Otherwise fall through and emit normally.
      }
      # Flush the previous buffered line, then buffer the current.
      if (buf_n > 0) { print buf[1] }
      buf[1] = $0
      buf_n = 1
      if ($0 == endm) { in_block = 0 }
    }
    END {
      if (buf_n > 0) { print buf[1] }
    }
  ' "$file" >"$tmp"

  mv "$tmp" "$file"
  chmod "$original_mode" "$file" 2>/dev/null \
    || chmod +x "$file"
}

# Detect whether a custom statusline target contains the v1.4.0/v1.4.1
# POSIX-only marker block. Used by install-statusline --target to trigger
# in-place migration. Signature differs per language:
#   Node:   marker block contains `process.env.HOME` AND NOT `os.homedir` /
#           `function __fiSeg` (the new v1.5.0 discriminators)
#   Python: marker block contains `_fi_os.environ.get('HOME'` AND not `pathlib`
#   Bash:   N/A (bash shim was always correct)
# KEEP IN SYNC with the inline awk discriminators in hooks/session-start.sh
# (~line 158 node, ~line 169 python). The hook cannot source this file
# without re-triggering SessionStart, so the awk programs are duplicated by
# necessity. Any change to v1.4.x detection logic must update both sites.
fi_target_is_v14x_broken() {
  local path="$1"
  local language="$2"
  [[ -f "$path" ]] || return 1
  case "$language" in
    node)
      LC_ALL=C awk '
        /^\/\/ === found-issues plugin segment ===/ { in_block = 1; next }
        /^\/\/ === end found-issues plugin segment ===/ { in_block = 0; next }
        in_block && /process\.env\.HOME/ { has_old = 1 }
        in_block && /os\.homedir/ { has_new = 1 }
        in_block && /function __fiSeg/ { has_new = 1 }
        END { exit (has_old && !has_new ? 0 : 1) }
      ' "$path"
      ;;
    python)
      LC_ALL=C awk '
        /^# === found-issues plugin segment ===/ { in_block = 1; next }
        /^# === end found-issues plugin segment ===/ { in_block = 0; next }
        in_block && /environ\.get\(.HOME./ { has_old = 1 }
        in_block && /pathlib/ { has_new = 1 }
        END { exit (has_old && !has_new ? 0 : 1) }
      ' "$path"
      ;;
    *) return 1 ;;
  esac
}

# Marker block present but its segment invocation lacks the explicit --cwd
# flag (v1.5.0–v1.5.5 templates). Without --cwd, an inherited
# CLAUDE_PROJECT_DIR (= where the session STARTED, often $HOME) overrides
# the block's cd/cwd in the CLI's search-root priority → wrong search root
# → empty or wrong-repo segment. Returns 0 (broken) when the block invokes
# `status --format=segment` without `--cwd`.
fi_target_is_v15x_broken() {
  local path="$1"
  local language="$2"
  [[ -f "$path" ]] || return 1
  local start end
  case "$language" in
    node)
      start='^\/\/ === found-issues plugin segment ==='
      end='^\/\/ === end found-issues plugin segment ==='
      ;;
    python|bash)
      start='^# === found-issues plugin segment ==='
      end='^# === end found-issues plugin segment ==='
      ;;
    *) return 1 ;;
  esac
  LC_ALL=C awk -v s="$start" -v e="$end" '
    $0 ~ s { in_block = 1; next }
    $0 ~ e { in_block = 0; next }
    in_block && /--format=segment/ { has_seg = 1 }
    in_block && /--cwd/ { has_cwd = 1 }
    END { exit (has_seg && !has_cwd ? 0 : 1) }
  ' "$path"
}

# Surgically remove marker block + splice trailer comments from a target file.
# Used by the v1.4.x/v1.5.x migration paths. Mirrors the canonical bash strip
# in fi_strip_legacy_lines but operates on language-specific marker syntax.
# Callers pass a scratch COPY of the target, never the target itself — the
# strip must not touch the user's file before backup/dry-run handling.
fi_strip_target_markers() {
  local path="$1"
  local language="$2"
  local start_marker end_marker trailer_pattern
  case "$language" in
    node)
      start_marker="// === found-issues plugin segment ==="
      end_marker="// === end found-issues plugin segment ==="
      trailer_pattern='[[:space:]]*//[[:space:]]*found-issues:seg[[:space:]]*$'
      ;;
    python|bash)
      start_marker="# === found-issues plugin segment ==="
      end_marker="# === end found-issues plugin segment ==="
      trailer_pattern='[[:space:]]*#[[:space:]]*found-issues:seg[[:space:]]*$'
      ;;
    *) return 1 ;;
  esac

  local tmp
  tmp="$(mktemp -t fi-strip.XXXXXX)"
  # v1.5.x call-form splice fragments are CONSTANT strings emitted by the
  # installers (deferred __fiSeg(dir)/_fi_seg(_dir) with a fixed fallback
  # expression). Their nested parens defeat the ERE `[^)]*` patterns below
  # — sub() either misses or eats the host call's closing paren, corrupting
  # the line so re-splice doubles the injection (found 2026-06-09 while
  # adding the v1.5.x migration). Literal index()/substr surgery is exact.
  # The regex subs are kept as fallback for the older bare-value forms.
  local node_tpl="\${__fiSeg(typeof dir!=='undefined'?dir:(typeof cwd!=='undefined'?cwd:undefined))}"
  local node_cat=" + __fiSeg(typeof dir!=='undefined'?dir:(typeof cwd!=='undefined'?cwd:undefined))"
  local py_fstr="{_fi_seg(locals().get(\"dir\") or locals().get(\"cwd\"))}"
  local bash_seg="\${__FI_SEG}"
  LC_ALL=C awk -v start="$start_marker" -v endm="$end_marker" -v trailer="$trailer_pattern" \
      -v seg_tpl="$node_tpl" -v seg_cat="$node_cat" -v seg_fstr="$py_fstr" -v seg_bash="$bash_seg" \
      -v lang="$language" '
    function strip_lit(line, lit,    idx) {
      while (lit != "" && (idx = index(line, lit)) > 0) {
        line = substr(line, 1, idx - 1) substr(line, idx + length(lit))
      }
      return line
    }
    $0 == start { in_block = 1; next }
    $0 == endm { in_block = 0; next }
    in_block { next }
    {
      line = $0
      # Only touch installer-emitted splice lines — every splice the installer
      # writes carries the found-issues:seg trailer. User-authored lines that
      # reference the segment var elsewhere (extra placements, emitted
      # snippets) must survive migration untouched: the re-added block
      # redefines the var/function for them.
      if (index(line, "found-issues:seg") > 0) {
        # Exact v1.5.x call-form splices (template-literal, concat, f-string,
        # and the constant bash ${__FI_SEG} form).
        line = strip_lit(line, seg_tpl)
        line = strip_lit(line, seg_cat)
        line = strip_lit(line, seg_fstr)
        line = strip_lit(line, seg_bash)
        if (lang == "bash") {
          # Hand-edited bash variants: ${__FI_SEG:-} (set -u style) and the
          # unbraced $__FI_SEG — same references fi_strip_legacy_lines matches.
          gsub(/\$\{__FI_SEG[^}]*\}/, "", line)
          gsub(/\$__FI_SEG/, "", line)
        }
        if (lang == "node") {
          # Hand-edited template-literal variants (arg tweaked away from the
          # exact installer form). Leaving one behind corrupts the re-splice.
          gsub(/\$\{__fiSeg\([^{}]*\)\}/, "", line)
        }
        if (lang == "python") {
          # Hand-edited f-string variants — e.g. quotes switched to single,
          # or a default added. The re-splice inserts at the first `")` on
          # the line, so a leftover call corrupts the line into a
          # SyntaxError.
          gsub(/\{_fi_seg\([^{}]*\)\}/, "", line)
        }
        # Strip the splice injection from the line. v1.4.x migration only ever
        # sees the bare value forms (${__fiSeg} / {_fi_seg}); the call-form
        # variants below handle simple-argument concatenation splices.
        sub(/\$\{__fiSeg\}/, "", line)
        sub(/\{_fi_seg\}/, "", line)
        sub(/[[:space:]]*\+[[:space:]]*__fiSeg\([^)]*\)\)/, "", line)
        sub(/[[:space:]]*\+[[:space:]]*_fi_seg\([^)]*\)\)/, "", line)
        sub(trailer, "", line)
      }
      print line
    }
  ' "$path" > "$tmp"
  cp "$tmp" "$path"
  rm -f "$tmp"
}

# Copy a target to a scratch file and strip its marker block + splices there.
# Echoes the scratch path on success; cleans up and returns 1 on failure.
# This is the ONLY sanctioned way to invoke fi_strip_target_markers from the
# install handlers: the user's file must stay untouched until the apply-mode
# atomic rename, so dry-run never mutates and the backup captures the
# pre-migration original.
fi_strip_to_scratch() {
  local path="$1" language="$2"
  local scratch
  scratch="$(mktemp -t fi-target-migrate.XXXXXX)" || return 1
  cp "$path" "$scratch" || { rm -f "$scratch"; return 1; }
  fi_strip_target_markers "$scratch" "$language" || { rm -f "$scratch"; return 1; }
  printf '%s' "$scratch"
}

