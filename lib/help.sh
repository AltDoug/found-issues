#!/usr/bin/env bash
# help.sh — help and version output, plus the deferred-touch nudge
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Extracted verbatim from bin/found-issues in v2.2.7 (the tracked §12 split);
# see the [open] loc-validator entry in docs/found-issues.md.
#
# Functions:
#   cmd_help
#   cmd_version
#   fi_handle_deferred_touch <file> <path>

# === Subcommand: help ===

cmd_help() {
  cat <<EOF
found-issues v$FI_VERSION — markdown-based issue tracker for AI agents

USAGE
  found-issues <command> [options]

COMMANDS
  log <location> — <symptom>            Append an [open] entry
                                        (Claude runs /found-issues:log for you;
                                        /fi is available via install-fi-alias)
  sync                                  Annotation-driven flip + tombstone close
  list [--status=open|deferred|fixed|all] [--json] [--cwd PATH]
                                        Print ledger entries (default: open).
                                        --json emits structured entries for tooling
                                        (used by /found-issues:fix). Resolves the
                                        ledger like status: --cwd, else
                                        \$CLAUDE_PROJECT_DIR, else \$PWD (walk-up).
  status [--format=segment|plain|json] [--cwd PATH]
                                        Print counts (for statusline integration).
                                        --cwd overrides where to look for the issues file
                                        (defaults to \$CLAUDE_PROJECT_DIR or \$PWD).
  annotate-pr <N> [--pick <loc>,...] [--all] [--hook-auto]
                                        Annotate matching [open] entries with PR.
                                        Files cited by several entries need an explicit
                                        --pick (path:line list) or --all — file-level
                                        auto-match alone would over-annotate. A pick can
                                        carry a symptom fragment ("path:line — fragment")
                                        to select between co-located entries.
                                        --hook-auto  stricter auto mode used by the
                                        PostToolUse hook (line-matched only, capped);
                                        exits 3 when candidates need --pick.
  annotate-commit [<sha>] [--pick <loc>,...] [--all] [--hook-auto]
                                        Annotate matching [open] entries with commit.
                                        Same selection rules as annotate-pr.
                                        --hook-auto  stricter auto mode used by the
                                        PostToolUse hook (line-matched only, capped);
                                        exits 3 when candidates need --pick.
  promote                               List entries that need promotion to main
  archive [--dry-run] [--days=N] [--count=N]
                                        Move old [fixed] entries to docs/found-issues-archive.md
                                        (defaults: count=50 OR days=30, whichever first)
  defer <match> [--reason "..."]        Flip [open] → [deferred]. On re-defer
                                        (entry has prior touch history),
                                        increments defer-cycle and appends ';'
                                        to touched annotation.
  promote-deferred <match>              Flip [deferred] → [open], preserving all
                                        annotations as evidence of recurrence.
  resolve <match> [--verified ai|human] Flip [open] → [fixed], appending
                                        (verified: ...) (fixed: <today>). Use this
                                        instead of editing the ledger by hand.
                                        Refuses entries with an active (PR: ...).
  install-statusline [--no-migrate]     Append the counter segment to ~/.claude/statusline.sh.
                                        Self-healing: auto-rewrites broken v1.0.0/1.0.1 marker blocks
                                        AND auto-migrates pre-v0.1.7 handwritten snippets (with a
                                        timestamped backup). Pass --no-migrate to refuse touching
                                        legacy lines (v1.0.3 strict behavior).
  uninstall-statusline                  Remove the counter segment block
  doctor                                General health check (CLI, statusline, gh, mode, hooks, issues file)
  doctor-statusline                     Diagnose the current statusline integration (no changes)
  doctor-statusline-runtime             Runtime probe only (synthetic stdin → segment assert)
  install-fi-alias                      Create the /fi shortcut at ~/.claude/commands/fi.md
  uninstall-fi-alias                    Remove the /fi shortcut (only if it's ours)
  install-codex-hooks [--codex-home PATH]
                                        Wire found-issues hooks into Codex's user-level
                                        \$CODEX_HOME/hooks.json (Codex 0.144.5 removed
                                        plugin-bundled hooks). Idempotent; re-run after
                                        \`codex plugin update\`. --codex-home overrides
                                        \$FOUND_ISSUES_CODEX_HOME / \$HOME/.codex.
  uninstall-codex-hooks [--codex-home PATH]
                                        Remove only found-issues' own entries from that file
  uninstall                             Wipe plugin-private state (run before /plugin uninstall)

  --version                             Print version
  --help                                Print this help

OPTIONS for log
  --critical                            Mark entry as critical ([!] flag)

EXAMPLES
  found-issues log src/foo.py:42 — null check missing (suggested: add guard)
  found-issues log --critical src/auth.ts:88 — leaks session token in error
  found-issues status --format=json
  found-issues annotate-pr 42
  found-issues annotate-commit HEAD

DOCS
  https://github.com/AltDoug/found-issues
EOF
}

cmd_version() { printf 'found-issues version %s\n' "$FI_VERSION"; }

# Handle a `log` invocation that matched a [deferred] entry's dedup key.
# Appends today's date to the (touched: ...) annotation, then checks
# count vs threshold and prints brief feedback (or nudge/auto-promote).
fi_handle_deferred_touch() {
  local file="$1"
  local matched_entry="$2"
  local today
  today="$(fi_today)"

  # Append today's date FIRST so the count reflects this touch.
  # Even when muted, we still record the touch for history — the mute
  # only suppresses the nudge / auto-promote, not the audit trail.
  fi_append_touch "$file" "$matched_entry" "$today"

  # Re-read the updated entry to compute current count + threshold.
  # The entry's path may have changed (annotation appended), so match by
  # the original entry's dedup-stable prefix.
  local updated_entry=""
  local prefix="${matched_entry%% (touched:*}"
  prefix="${prefix%% (defer-cycle:*}"  # be defensive about ordering
  while IFS= read -r line; do
    if [[ "$line" == "$prefix"* ]]; then
      updated_entry="$line"
      break
    fi
  done < <(fi_entries "$file" deferred 2>/dev/null || true)

  if [[ -z "$updated_entry" ]]; then
    # Should not happen if append succeeded; fail soft.
    printf 'Touched deferred entry: %s\n' "$matched_entry" >&2
    return 0
  fi

  local cycle count threshold
  cycle="$(fi_extract_defer_cycle "$updated_entry")"
  count="$(fi_current_cycle_touch_count "$updated_entry")"
  threshold="$(fi_compute_threshold "$cycle")"

  # Compute a hint for the user (path:line if available)
  local hint
  hint="${matched_entry#*\] }"
  hint="${hint#* }"  # strip date
  hint="${hint%% — *}"

  # Mute-until short-circuit. If the entry has an active (mute-until: ...)
  # annotation and today is before that date, suppress nudge + auto-promote
  # entirely. Touch is still recorded above. See 2026-05-10 UX audit
  # surface 4.4.
  if fi_is_muted "$updated_entry" "$today"; then
    local mute_date
    mute_date="$(fi_extract_mute_until "$updated_entry")"
    printf 'Touched deferred entry (muted until %s): %s\n' "$mute_date" "$hint" >&2
    printf 'Touched [deferred] (muted until %s): %s (cycle %d, %dx of %d)\n' \
      "$mute_date" "$hint" "$cycle" "$count" "$threshold"
    cmd_status plain
    return 0
  fi

  if (( count < threshold )); then
    printf 'Touched deferred entry (%dx of %d for promotion): %s\n' "$count" "$threshold" "$hint" >&2
  fi

  # Determine criticality
  local is_critical=0
  if [[ "$updated_entry" == *"[!]"* ]]; then
    is_critical=1
  fi

  # Stderr nudge: fires on count >= threshold (both at-threshold and overshoot).
  # Overshoot wording surfaces how many touches the user has accumulated past
  # the threshold — useful when they've been ignoring the nudge and want to
  # gauge whether the entry warrants promotion now.
  if (( count >= threshold )) && (( is_critical == 0 )); then
    if (( count == threshold )); then
      printf 'Touched deferred entry (now %dx, threshold %d): %s\n' "$count" "$threshold" "$hint" >&2
    else
      printf 'Touched deferred entry (now %dx, %d past threshold of %d): %s\n' \
        "$count" "$((count - threshold))" "$threshold" "$hint" >&2
    fi
    printf 'Consider: found-issues promote-deferred --match %s\n' "$hint" >&2
  fi

  if (( count >= threshold )) && (( is_critical == 1 )); then
    fi_promote_entry_to_open "$file" "$updated_entry"
    printf 'Touched [!] critical deferred entry — auto-promoted to [open] (%dx in cycle %d): %s\n' "$count" "$cycle" "$hint" >&2
  fi

  # Stdout summary — emitted for every deferred-touch case so wrappers that
  # swallow stderr still surface the event. The stderr lines above remain
  # the canonical user-facing detail; stdout is a single parseable line.
  # See 2026-05-10 UX audit, surfaces 3.3 + 4.2.
  if (( count >= threshold )) && (( is_critical == 1 )); then
    printf 'Touched [deferred] (auto-promoted to [open]): %s (cycle %d, %dx of %d)\n' \
      "$hint" "$cycle" "$count" "$threshold"
  elif (( count == threshold )); then
    printf 'Touched [deferred] (at threshold): %s (cycle %d, %dx of %d) — consider promote-deferred\n' \
      "$hint" "$cycle" "$count" "$threshold"
  elif (( count > threshold )); then
    printf 'Touched [deferred] (past threshold by %d): %s (cycle %d, %dx of %d) — consider promote-deferred\n' \
      "$((count - threshold))" "$hint" "$cycle" "$count" "$threshold"
  else
    printf 'Touched [deferred]: %s (cycle %d, %dx of %d)\n' \
      "$hint" "$cycle" "$count" "$threshold"
  fi

  # Echo updated counter state so callers always see a tail line consistent
  # with the open-match and new-entry log paths.
  cmd_status plain

  return 0
}

