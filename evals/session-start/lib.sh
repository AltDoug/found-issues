#!/usr/bin/env bash
# lib.sh -- shared helpers for the session-start A/B eval (sourced; bash 3.2 safe).
#
# Verified flags (3.4.0 Task 1 probe): `claude -p --plugin-dir <arm>
# --setting-sources project,local` loads exactly ONE copy of found-issues, the
# <arm> one. The installed plugin is enabled through USER settings, and
# `--setting-sources project,local` keeps those out (it also keeps out the
# operator's ~/.claude/CLAUDE.md).
#
# Everything lives under one explicit out dir ($EVAL_OUT or --out; there is no
# default, so a re-run can never silently reuse another run's files):
#   <out>/arms/old       v3.3.1 (prepare.sh)
#   <out>/manifest.txt   what built the outputs (run.sh refuses to resume on a mismatch)
#   <out>/cost.txt       cumulative cost: probes + runs
#   <out>/runs/          per-run outputs        <out>/work/   per-run repos
#   <out>/probe/         probe repos

EVAL_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_REPO="$(cd "$EVAL_HERE/../.." && pwd)"

: "${EVAL_OUT:=}"
: "${EVAL_COST_CAP:=18}"
: "${EVAL_RUN_BUDGET:=0.60}"
: "${EVAL_MODEL:=sonnet}"
: "${EVAL_TURNS:=30}"
# Bash and Skill must be allowed: logging is the /found-issues:log skill (it
# runs the CLI) and the task says to run `sh test.sh`; under acceptEdits alone
# headless -p denies every Bash and Skill call. The `=` form matters: the space
# form of the variadic flag swallows the prompt. Same flags for every arm.
: "${EVAL_PERM:=--permission-mode acceptEdits --allowedTools=Bash,Skill}"

EVAL_ARM_TABLE=""        # lines: name|plugin dir|KEY=VAL KEY=VAL
EVAL_ARM_ENV_PENDING=""  # lines: name|KEY=VAL (applied by fi_eval_arms_finalize)

fi_eval_die() { echo "$(basename "$0"): $*" >&2; exit 2; }

# fi_eval_require_out -- the out dir must be given explicitly.
fi_eval_require_out() {
  [[ -n "$EVAL_OUT" ]] || fi_eval_die "--out DIR (or EVAL_OUT) is required; there is no default out dir"
  mkdir -p "$EVAL_OUT" || fi_eval_die "cannot create $EVAL_OUT"
  EVAL_OUT="$(cd "$EVAL_OUT" && pwd -P)"
  : "${EVAL_COST_FILE:=$EVAL_OUT/cost.txt}"
}

# --- arms: name + plugin dir + optional env -------------------------------

fi_eval_arm_add() {  # <name> <dir> [KEY=VAL...]
  local name="$1" dir="$2"; shift 2
  [[ "$name" =~ ^[a-z][a-z0-9_]*$ ]] || fi_eval_die "bad arm name '$name' (lowercase letters, digits, _)"
  [[ -z "$(fi_eval_arm_field "$name" 1)" ]] || fi_eval_die "arm '$name' defined twice"
  EVAL_ARM_TABLE="${EVAL_ARM_TABLE:+$EVAL_ARM_TABLE$'\n'}$name|$dir|$*"
}

fi_eval_arm_env_add() {  # <name> <KEY=VAL>
  EVAL_ARM_ENV_PENDING="${EVAL_ARM_ENV_PENDING:+$EVAL_ARM_ENV_PENDING$'\n'}$1|$2"
}

fi_eval_arm_field() {  # <name> <1=name 2=dir 3=env>
  printf '%s\n' "$EVAL_ARM_TABLE" | awk -F'|' -v n="$1" -v i="$2" '$1 == n { print $i; exit }'
}

fi_eval_arm_names() {
  printf '%s\n' "$EVAL_ARM_TABLE" | awk -F'|' 'NF { printf "%s%s", (c++ ? " " : ""), $1 } END { print "" }'
}

# fi_eval_arm_opt <flag> <value> -- shared CLI parsing; returns 0 when it consumed the flag.
#   --arm NAME=DIR          add an arm
#   --arm-env NAME:KEY=VAL  add an env var to an arm (repeatable)
fi_eval_arm_opt() {
  case "$1" in
    --arm)
      [[ "$2" == *=* ]] || fi_eval_die "--arm wants NAME=DIR"
      fi_eval_arm_add "${2%%=*}" "${2#*=}" ;;
    --arm-env)
      [[ "$2" == *:*=* ]] || fi_eval_die "--arm-env wants NAME:KEY=VAL"
      fi_eval_arm_env_add "${2%%:*}" "${2#*:}" ;;
    *) return 1 ;;
  esac
}

# Default arms for the re-run: old (v3.3.1 from prepare.sh), standard (this
# checkout, build default) and lean (this checkout, lean session context).
fi_eval_arms_finalize() {
  local line name kv
  if [[ -z "$EVAL_ARM_TABLE" ]]; then
    fi_eval_arm_add old "$EVAL_OUT/arms/old"
    fi_eval_arm_add standard "$EVAL_REPO"
    fi_eval_arm_add lean "$EVAL_REPO" FOUND_ISSUES_SESSION_CONTEXT=lean
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    name="${line%%|*}"; kv="${line#*|}"
    [[ -n "$(fi_eval_arm_field "$name" 1)" ]] || fi_eval_die "--arm-env for unknown arm '$name'"
    [[ "$kv" =~ ^[A-Z_][A-Z0-9_]*=[^[:space:]|]*$ ]] || fi_eval_die "bad env '$kv' (KEY=VAL, no spaces)"
    EVAL_ARM_TABLE="$(printf '%s\n' "$EVAL_ARM_TABLE" | awk -F'|' -v OFS='|' -v n="$name" -v kv="$kv" \
      '$1 == n { $3 = ($3 == "" ? kv : $3 " " kv) } { print }')"
  done <<< "$EVAL_ARM_ENV_PENDING"
  for name in $(fi_eval_arm_names); do
    [[ -f "$(fi_eval_arm_field "$name" 2)/hooks/session-start.sh" ]] \
      || fi_eval_die "arm '$name': $(fi_eval_arm_field "$name" 2) is not a plugin checkout (did you run prepare.sh?)"
  done
}

# --- manifest ---------------------------------------------------------------

# Content fingerprint of the files Claude Code loads from a plugin dir (and so
# of the build under test). evals/, tests/ and docs/ are left out on purpose:
# editing the eval scripts or docs must not invalidate finished runs.
fi_eval_fingerprint() {  # <dir> [subdir...]
  local dir="$1"; shift
  local subs=("$@")
  [[ ${#subs[@]} -gt 0 ]] || subs=(.claude-plugin bin hooks lib skills commands agents)
  ( cd "$dir" || exit 1
    for s in "${subs[@]}"; do
      [[ -e "$s" ]] && find "$s" -type f
    done | LC_ALL=C sort | while IFS= read -r f; do shasum "$f"; done | shasum | cut -c1-16 )
}

# Prints the manifest. Informational lines (git_head, git_dirty) are written but
# not compared: HEAD moves when only evals/ or docs change.
fi_eval_manifest() {
  local name dir ver top
  printf 'model=%s\nmax_turns=%s\nrun_budget=%s\nperm=%s\n' "$EVAL_MODEL" "$EVAL_TURNS" "$EVAL_RUN_BUDGET" "$EVAL_PERM"
  printf 'fixtures_fingerprint=%s\n' "$(fi_eval_fingerprint "$EVAL_HERE" fixtures)"
  printf 'arms=%s\n' "$(fi_eval_arm_names)"
  for name in $(fi_eval_arm_names); do
    dir="$(fi_eval_arm_field "$name" 2)"
    ver="$(jq -r '.version // "unknown"' "$dir/.claude-plugin/plugin.json" 2>/dev/null || echo unknown)"
    printf 'arm.%s.dir=%s\n' "$name" "$dir"
    printf 'arm.%s.version=%s\n' "$name" "$ver"
    printf 'arm.%s.fingerprint=%s\n' "$name" "$(fi_eval_fingerprint "$dir")"
    printf 'arm.%s.env=%s\n' "$name" "$(fi_eval_arm_field "$name" 3)"
    top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "$top" && "$(cd "$top" && pwd -P)" == "$(cd "$dir" && pwd -P)" ]]; then
      printf 'arm.%s.git_head=%s\n' "$name" "$(git -C "$dir" rev-parse HEAD)"
      if [[ -n "$(git -C "$dir" status --porcelain -- . ':(exclude)evals' 2>/dev/null)" ]]; then
        printf 'arm.%s.git_dirty=yes\n' "$name"
      else
        printf 'arm.%s.git_dirty=no\n' "$name"
      fi
    else
      printf 'arm.%s.git_head=n/a\narm.%s.git_dirty=n/a\n' "$name" "$name"
    fi
  done
}

# fi_eval_manifest_check -- write the manifest on first use; afterwards refuse
# (return 1, with a diff) when the build, fixtures, flags or arms changed.
fi_eval_manifest_check() {
  local file="$EVAL_OUT/manifest.txt" now
  now="$(mktemp)"
  fi_eval_manifest > "$now"
  if [[ ! -f "$file" ]]; then
    mv "$now" "$file"
    echo "manifest written: $file"
    return 0
  fi
  if diff <(grep -v -e '\.git_head=' -e '\.git_dirty=' "$file") \
          <(grep -v -e '\.git_head=' -e '\.git_dirty=' "$now") > "$now.diff"; then
    rm -f "$now" "$now.diff"
    return 0
  fi
  echo "REFUSING to resume: the manifest in $file differs from the build now on disk (< recorded, > now):" >&2
  cat "$now.diff" >&2
  rm -f "$now" "$now.diff"
  echo "Outputs from a different build must not be reused. Use a new --out dir." >&2
  return 1
}

# --- PATH, cost -----------------------------------------------------------------

# PATH without any installed found-issues plugin bin (*/found-issues/*/bin).
# v3.3.1's session-start hook injects no entries when a bare `found-issues` is
# on PATH, and a machine with the plugin installed carries its bin on PATH.
# Each arm then falls back to its own co-located bin.
fi_eval_clean_path() {
  local out="" d IFS=:
  for d in $PATH; do
    case "$d" in
      */found-issues/*/bin) continue ;;
    esac
    out="${out:+$out:}$d"
  done
  printf '%s' "$out"
}

# Sum of the cost file (lines: "<label> <usd>").
fi_eval_cost_total() {
  [[ -f "${EVAL_COST_FILE:-}" ]] || { printf '0'; return 0; }
  awk '{ s += $2 } END { printf "%.4f", s + 0 }' "$EVAL_COST_FILE"
}

fi_eval_cost_add() {  # <label> <usd>
  local usd
  usd="$(awk -v v="$2" 'BEGIN { printf "%.6f", v + 0 }')"
  [[ "$usd" =~ ^[0-9]+\.[0-9]+$ ]] || { echo "lib.sh: bad cost '$2' for $1" >&2; return 1; }
  mkdir -p "$(dirname "$EVAL_COST_FILE")"
  printf '%s %s\n' "$1" "$usd" >> "$EVAL_COST_FILE"
}

# True (0) when one more run at <budget> (default: the run budget) still fits the cap.
fi_eval_cost_room() {
  awk -v t="$(fi_eval_cost_total)" -v b="${1:-$EVAL_RUN_BUDGET}" -v c="$EVAL_COST_CAP" \
    'BEGIN { exit (t + b > c) ? 1 : 0 }'
}

# --- one headless claude run --------------------------------------------------

# fi_eval_claude <arm> <cwd> <model> <budget> <max-turns> [extra claude args...] -- <prompt>
# Runs one headless claude with only that arm's plugin (and that arm's env);
# JSON on stdout. Wall-clock cap EVAL_RUN_TIMEOUT seconds (default 900): a
# polling watchdog, so nothing is left sleeping behind. Returns 124 on timeout.
fi_eval_claude() {
  local arm="$1" cwd="$2" model="$3" budget="$4" turns="$5"; shift 5
  local extra=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do extra+=("$1"); shift; done
  shift
  local prompt="$1" armdir armenv cp stamp
  armdir="$(fi_eval_arm_field "$arm" 2)"; armenv="$(fi_eval_arm_field "$arm" 3)"
  [[ -n "$armdir" ]] || return 2
  cp="$(fi_eval_clean_path)"
  stamp="$(mktemp)"
  (
    cd "$cwd" || exit 2
    # shellcheck disable=SC2086  # armenv is KEY=VAL words without spaces
    env -u FOUND_ISSUES_SESSION_CONTEXT PATH="$cp" FOUND_ISSUES_AUTOFIX=off $armenv \
      claude -p --plugin-dir "$armdir" --setting-sources project,local \
        --model "$model" --max-budget-usd "$budget" --max-turns "$turns" \
        --no-session-persistence --output-format json \
        ${extra[@]+"${extra[@]}"} "$prompt" &
    pid=$!
    (
      t=0
      while (( t < ${EVAL_RUN_TIMEOUT:-900} )) && kill -0 "$pid" 2>/dev/null; do sleep 1; t=$((t + 1)); done
      if kill -0 "$pid" 2>/dev/null; then echo timeout > "$stamp"; kill "$pid" 2>/dev/null; fi
    ) &
    wd=$!
    wait "$pid"; rc=$?
    wait "$wd" 2>/dev/null
    [[ -s "$stamp" ]] && rc=124
    exit "$rc"
  )
  local rc=$?
  rm -f "$stamp"
  return "$rc"
}
