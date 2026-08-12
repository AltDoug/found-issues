#!/usr/bin/env bash
# doctor.sh — doctor — environment, mode, hooks and ledger health report
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Extracted verbatim from bin/found-issues in v2.2.6 (the tracked §12 split);
# see the [open] loc-validator entry in docs/found-issues.md.
#
# Functions:
#   fi_doctor_plugin_version <ok> <warn>
#   cmd_doctor [...]

# === Subcommand: doctor ===
#
# Compare the RUNNING CLI's version against the INSTALLED plugin's and report
# a divergence (#135).
#
# Claude Code injects a version-pinned plugin bin dir into the environment at
# session start, so a session started before a release keeps resolving the old
# version for its entire life — installed_plugins.json said installPath=2.2.2
# while $PATH still had .../found-issues/2.2.0/bin. Two concurrent sessions ran
# 2.2.0 for hours after v2.2.1 shipped a data-loss fix, including 2.2.0's
# SessionStart auto-sync, and doctor printed a bare "CLI: <path>" and called it
# healthy. The version dirs accumulate rather than prune, which is why a stale
# path resolves quietly instead of failing loudly.
#
# Silent no-op without a plugin manifest (CI, non-plugin installs) or without
# jq — matching every other jq-dependent probe in this file. A missing manifest
# is not a health finding.
fi_doctor_plugin_version() {
  local ok="$1" warn="$2"
  local manifest="$HOME/.claude/plugins/installed_plugins.json"
  [[ -f "$manifest" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local row
  row="$(jq -r '
    (.plugins // {}) | to_entries[]
    | select(.key | startswith("found-issues@"))
    | (.value | if type == "array" then .[0] else . end)
    | [(.installPath // ""), (.version // "")] | @tsv
  ' "$manifest" 2>/dev/null | head -1 || true)"
  [[ -n "$row" ]] || return 0

  local install_path installed_ver
  install_path="${row%%$'\t'*}"
  installed_ver="${row#*$'\t'}"

  # plugin.json inside installPath is the on-disk truth; the manifest's own
  # version field is the fallback when that directory was pruned.
  if [[ -f "$install_path/.claude-plugin/plugin.json" ]]; then
    local pj_ver
    pj_ver="$(jq -r '.version // ""' "$install_path/.claude-plugin/plugin.json" 2>/dev/null || true)"
    [[ -n "$pj_ver" ]] && installed_ver="$pj_ver"
  fi
  [[ -n "$installed_ver" ]] || return 0

  if [[ "$FI_VERSION" == "$installed_ver" ]]; then
    printf '%s Plugin version: v%s matches the installed plugin.\n' "$ok" "$FI_VERSION"
    return 0
  fi

  printf '%s CLI version v%s does not match the installed plugin v%s.\n' \
    "$warn" "$FI_VERSION" "$installed_ver"
  printf '   Installed at: %s\n' "$install_path"
  # Direction matters: a cache-resident CLI on the wrong version is the stale
  # session this check exists for, but a dev checkout is legitimately ahead of
  # (or behind) the installed plugin and must not be told to restart.
  #
  # FI_BIN_DIR comes from fi_script_dir's `cd -P`, so it is PHYSICAL, while
  # $HOME stays logical. On macOS a temp/symlinked home makes the two forms
  # differ (/var/... vs /private/var/...) and a plain prefix test misfires,
  # handing a genuinely stale session the "dev checkout" message. Compare
  # against both forms.
  local cache_root="$HOME/.claude/plugins/cache"
  local cache_root_phys="$cache_root"
  if [[ -d "$cache_root" ]]; then
    cache_root_phys="$(cd -P "$cache_root" 2>/dev/null && pwd || printf '%s' "$cache_root")"
  fi
  if [[ "$FI_BIN_DIR" == "$cache_root"/* || "$FI_BIN_DIR" == "$cache_root_phys"/* ]]; then
    printf '   This session resolved a stale version-pinned plugin bin dir; restart your session to pick up v%s.\n' "$installed_ver"
  else
    printf '   The running CLI is outside the plugin cache (dev checkout), so this is expected.\n'
  fi
}

# General-purpose health diagnostic — aggregates statusline state, gh auth,
# mode detection, hook opt-outs, and issues-file state into a single
# printable report. Read-only (no file modifications). Always exits 0.
#
# Composes existing subdiagnostics rather than duplicating logic — calls
# fi_statusline_state, fi_detect_mode, fi_find_issues_file, fi_count*.
# Added 2026-05-10 UX audit (surfaces 5.2 + 6.2 fast-follow).
cmd_doctor() {
  local section_pass="✓"
  local section_warn="!"
  local section_fail="✗"

  # Resolve a portable "section" prefix without unicode — older terminals
  # render "✓" as a tofu box. Fall back to ASCII when LC_ALL doesn't claim UTF-8.
  if ! locale 2>/dev/null | grep -qi 'utf-8\|utf8'; then
    section_pass="OK"
    section_warn="!!"
    section_fail="FAIL"
  fi

  printf 'found-issues doctor — v%s\n\n' "$FI_VERSION"

  # --- Source file health (NEW) ---
  printf '== Source file health ==\n'
  local issues_file_health
  issues_file_health="$(fi_find_issues_file 2>/dev/null || true)"
  if [[ -n "$issues_file_health" && -f "$issues_file_health" ]]; then
    if fi_has_conflict_markers "$issues_file_health"; then
      printf '%s Source file has merge conflict markers: %s\n' "$section_fail" "$issues_file_health"
      local conflict_lines
      conflict_lines="$(LC_ALL=C grep -nE '^(<<<<<<< |=======$|>>>>>>> )' "$issues_file_health" | head -10 | sed 's/^/   /')"
      printf '%s\n' "$conflict_lines"
      printf '   Resolve the conflict (git status, then manual edit) before trusting any counts.\n'
      printf '   Counts in the statusline below skip lines inside conflict regions, so they\n'
      printf '   may differ from what you expect during a merge.\n'
    else
      printf '%s Source file: %s (no conflict markers)\n' "$section_pass" "$issues_file_health"
    fi
  else
    printf '%s No issues file found in current dir or its parents.\n' "$section_warn"
  fi
  printf '\n'

  # --- Plugin runtime ---
  printf '== Plugin runtime ==\n'
  printf '%s CLI: %s\n' "$section_pass" "${FI_BIN_DIR}/found-issues"
  fi_doctor_plugin_version "$section_pass" "$section_warn"
  printf '%s lib dir: %s\n' "$section_pass" "$FI_LIB_DIR"
  if [[ -d "$HOME/.claude/found-issues" ]]; then
    if [[ -f "$HOME/.claude/found-issues/.onboarded" ]]; then
      printf '%s Onboarding marker present (setup ran at least once).\n' "$section_pass"
    else
      printf '%s Onboarding marker dir exists but `.onboarded` is missing — first-run SessionStart hint may fire again.\n' "$section_warn"
    fi
  else
    printf '%s No onboarding marker — first-run SessionStart hint will fire on next session start.\n' "$section_warn"
  fi
  printf '\n'

  # --- Statusline (extended for custom targets) ---
  printf '== Statusline ==\n'
  local settings_file="$HOME/.claude/settings.json"
  local custom_target="" custom_language=""
  if [[ -f "$settings_file" ]] && command -v jq >/dev/null 2>&1; then
    local cmd
    cmd="$(jq -r '.statusLine.command // ""' "$settings_file" 2>/dev/null || true)"
    if [[ -n "$cmd" ]]; then
      printf '%s settings.json statusLine.command: %s\n' "$section_pass" "$cmd"
      custom_target="$(printf '%s' "$cmd" | LC_ALL=C awk '{print $NF}' | sed "s|\${HOME}|$HOME|g; s|^~|$HOME|")"
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
    printf '   Resolved target: %s (language: %s)\n' "$statusline_target" "$statusline_language"
  else
    statusline_target="$FI_STATUSLINE_FILE"
    statusline_language="bash"
  fi

  if [[ -f "$statusline_target" ]]; then
    local statusline_state
    statusline_state="$(fi_statusline_state "$statusline_target" "$statusline_language")"
    case "$statusline_state" in
      installed-fixed)
        printf '%s State: installed-fixed (canonical block).\n' "$section_pass"
        ;;
      installed-broken-posix)
        printf '%s State: installed-broken-posix — v1.4.x POSIX-only shim.\n' "$section_fail"
        printf '   Symptom: empty segment on Windows OR on multi-branch statuslines.\n'
        printf '   Fix: found-issues install-statusline --target %s --apply   (auto-migrates)\n' "$statusline_target"
        ;;
      installed-broken|legacy-handwritten|legacy-and-installed)
        printf '%s State: %s — counter renders empty silently.\n' "$section_fail" "$statusline_state"
        printf '   Fix: found-issues install-statusline   (auto-migrates with timestamped backup)\n'
        ;;
      none)
        printf '%s State: none — statusline exists but no found-issues segment.\n' "$section_warn"
        if [[ -n "$custom_target" ]]; then
          printf '   Install: found-issues install-statusline --target %s --apply\n' "$statusline_target"
        else
          printf '   Install: found-issues install-statusline\n'
        fi
        ;;
      no-file)
        printf '%s State: no-file.\n' "$section_warn"
        ;;
    esac
  else
    printf '%s Statusline target file not found: %s\n' "$section_warn" "$statusline_target"
  fi
  printf '\n'

  # --- Statusline runtime probe ---
  fi_run_statusline_runtime_probe "$section_pass" "$section_warn" "$section_fail"

  # --- gh CLI auth (only relevant in github-* modes) ---
  printf '== gh CLI ==\n'
  if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
      local gh_user
      gh_user="$(gh api user --jq '.login' 2>/dev/null || echo unknown)"
      printf '%s gh authenticated as %s.\n' "$section_pass" "$gh_user"
    else
      printf '%s gh installed but not authenticated. `gh auth login` to enable PR-related features.\n' "$section_warn"
    fi
  else
    printf '%s gh CLI not on PATH. PR-related features (annotate-pr, sync against PR merges) are disabled.\n' "$section_warn"
  fi

  # origin/HEAD symref (5.2: default-branch detection for PR-state sync).
  # When unset, fi_default_branch falls back to `gh repo view` then literal "main".
  if git rev-parse --git-dir >/dev/null 2>&1; then
    if git symbolic-ref refs/remotes/origin/HEAD >/dev/null 2>&1; then
      local origin_head
      origin_head="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo unknown)"
      printf '%s origin/HEAD: set (%s)\n' "$section_pass" "$origin_head"
    else
      if git remote get-url origin >/dev/null 2>&1; then
        printf '%s origin/HEAD: unset. Sync falls back to `gh repo view`, then literal "main".\n' "$section_warn"
        printf '   Fix: git remote set-head origin --auto\n'
      else
        printf '%s origin/HEAD: no `origin` remote — default-branch detection skipped.\n' "$section_warn"
      fi
    fi
  fi
  printf '\n'

  # --- Mode detection + cache ---
  printf '== Mode detection ==\n'
  local mode
  mode="$(fi_detect_mode)"
  printf '%s Detected mode: %s\n' "$section_pass" "$mode"
  if [[ -n "${FOUND_ISSUES_MODE:-}" ]]; then
    printf '   (env override active: FOUND_ISSUES_MODE=%s)\n' "$FOUND_ISSUES_MODE"
  fi
  if [[ -d "$HOME/.cache/found-issues" ]]; then
    local cache_count
    cache_count="$(find "$HOME/.cache/found-issues" -type f -name 'mode_*' 2>/dev/null | wc -l | tr -d ' ')"
    printf '%s Mode cache: %s/.cache/found-issues/ (%s cached repos)\n' "$section_pass" "$HOME" "$cache_count"
  else
    printf '%s Mode cache directory not present yet — will be created on first GitHub-mode detection.\n' "$section_warn"
  fi
  printf '\n'

  # --- Hook opt-outs ---
  printf '== Hook opt-outs ==\n'
  local any_off=0
  local v
  for v in FOUND_ISSUES_STOP_REMINDER FOUND_ISSUES_PROMOTE_GUARD FOUND_ISSUES_FORMAT_ENFORCER FOUND_ISSUES_PRE_COMMIT FOUND_ISSUES_AUTO_ARCHIVE; do
    local val="${!v:-}"
    if [[ "$val" == "off" ]]; then
      printf '%s %s=off  (hook disabled)\n' "$section_warn" "$v"
      any_off=1
    fi
  done
  if (( any_off == 0 )); then
    printf '%s All hooks default-active. See docs/configuration.md for the opt-out list.\n' "$section_pass"
  fi
  printf '\n'

  # --- Defer-flow tunables (only print if non-default) ---
  if [[ -n "${FOUND_ISSUES_DEFER_TOUCH_THRESHOLD:-}" ]] || [[ -n "${FOUND_ISSUES_DEFER_ESCALATION_FACTOR:-}" ]] || [[ -n "${FOUND_ISSUES_STALE_DAYS:-}" ]]; then
    printf '== Tunables (non-default) ==\n'
    [[ -n "${FOUND_ISSUES_DEFER_TOUCH_THRESHOLD:-}" ]] && printf '   FOUND_ISSUES_DEFER_TOUCH_THRESHOLD=%s (default 3)\n' "$FOUND_ISSUES_DEFER_TOUCH_THRESHOLD"
    [[ -n "${FOUND_ISSUES_DEFER_ESCALATION_FACTOR:-}" ]] && printf '   FOUND_ISSUES_DEFER_ESCALATION_FACTOR=%s (default 2)\n' "$FOUND_ISSUES_DEFER_ESCALATION_FACTOR"
    [[ -n "${FOUND_ISSUES_STALE_DAYS:-}" ]] && printf '   FOUND_ISSUES_STALE_DAYS=%s (default 30)\n' "$FOUND_ISSUES_STALE_DAYS"
    printf '\n'
  fi

  # --- Issues file ---
  printf '== Issues file ==\n'
  local issues_file
  issues_file="$(fi_find_issues_file 2>/dev/null || true)"
  if [[ -n "$issues_file" && -f "$issues_file" ]]; then
    local total_open critical in_pr stale deferred fixed
    total_open="$(fi_count "$issues_file" open)"
    critical="$(fi_count_critical "$issues_file")"
    in_pr="$(fi_count_in_pr "$issues_file")"
    stale="$(fi_count_stale "$issues_file" "${FOUND_ISSUES_STALE_DAYS:-30}")"
    deferred="$(fi_count "$issues_file" deferred)"
    fixed="$(fi_count "$issues_file" fixed)"
    printf '%s Path: %s\n' "$section_pass" "$issues_file"
    printf '   open: %s (critical: %s, in PR: %s, stale: %s)\n' "$total_open" "$critical" "$in_pr" "$stale"
    printf '   deferred: %s\n' "$deferred"
    printf '   fixed: %s\n' "$fixed"

    # Suspicious entry checks. grep -c can return non-zero when no match,
    # so wrap each command substitution with `|| true` (set -e+pipefail at
    # the top of this script would otherwise exit on no-match) and strip
    # whitespace via tr.
    local susp_count=0
    local bad_open
    bad_open="$(grep -cE '^- \[open\].*\(fixed:' "$issues_file" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -z "$bad_open" || ! "$bad_open" =~ ^[0-9]+$ ]] && bad_open=0
    if (( bad_open > 0 )); then
      printf '%s %s [open] entries with stray (fixed: ...) annotation — sync didn'\''t flip them yet, or annotation is malformed.\n' "$section_warn" "$bad_open"
      susp_count=$((susp_count + bad_open))
    fi

    local bad_fixed with_anno
    bad_fixed="$(grep -cE '^- \[fixed\]' "$issues_file" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -z "$bad_fixed" || ! "$bad_fixed" =~ ^[0-9]+$ ]] && bad_fixed=0
    with_anno="$(grep -cE '^- \[fixed\].*\(fixed: [0-9]{4}-[0-9]{2}-[0-9]{2}\)' "$issues_file" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -z "$with_anno" || ! "$with_anno" =~ ^[0-9]+$ ]] && with_anno=0
    if (( bad_fixed > with_anno )); then
      local missing=$((bad_fixed - with_anno))
      printf '%s %s [fixed] entries without (fixed: YYYY-MM-DD) annotation — closure date unknown.\n' "$section_warn" "$missing"
      susp_count=$((susp_count + missing))
    fi

    if (( susp_count == 0 )); then
      printf '%s No suspicious entries detected.\n' "$section_pass"
    fi
  else
    printf '%s No issues file found in this directory or any ancestor.\n' "$section_warn"
    printf '   First `found-issues log` will create %s\n' "docs/found-issues.md (or .found-issues.md in local mode)"
  fi
  printf '\n'

  # --- Recommended next actions ---
  printf '== Recommended next ==\n'
  case "$(fi_statusline_state 2>/dev/null)" in
    installed-broken|legacy-handwritten|legacy-and-installed)
      printf '   - Run `found-issues install-statusline` to fix the broken counter.\n'
      ;;
  esac
  if [[ -n "$issues_file" && -f "$issues_file" ]]; then
    if [[ "$(fi_count "$issues_file" open)" -gt 0 ]]; then
      printf '   - Run `/found-issues:sync` to reconcile open entries against PR/commit history.\n'
    fi
  fi
  printf '   - See docs/configuration.md for env-var opt-outs and tunables.\n'

  return 0
}

