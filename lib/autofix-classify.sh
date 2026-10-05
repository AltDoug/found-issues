#!/usr/bin/env bash
# autofix-classify.sh — the sweep's classify/wake pass (spec 2026-10-03 §3.1,
# §6 steps 2-3; phase 4 ruling 2): one headless read-only model call tags
# untagged [open] entries and judges free-text (until:) triggers; bash
# validates every answer and writes the ledger.
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash).
#
# Functions:
#   fi_af_classify <ledger> <id>
#   fi_af_classify_apply <ledger> <json> <list-file>
#   _fi_af_classify_mark_offered <list-file>

# shellcheck disable=SC2154  # AFI_*/FE_* come from autofix-queue.sh / parse-entries.sh

FI_AF_CLASSIFY_ENTRY=""

# Numbered work list: U<n> untagged [open] entries (at most 20), W<n>
# [deferred] entries whose (until:) is free text (at most 10).
_fi_af_classify_list() {
  local file="$1" out="$2" entry u=0 w=0
  : >"$out"
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    fi_parse_entry_vars "$entry" || continue
    if [[ "$FE_status" == "open" ]]; then
      [[ -z "$FE_fixtag$FE_decide$FE_decided$FE_manual$FE_autofix_failed$FE_prs$FE_prs_auto$FE_commits$FE_commits_auto" ]] || continue
      (( u < 20 )) || continue
      u=$((u + 1))
      printf 'U%s\t%s\n' "$u" "$entry" >>"$out"
    elif [[ "$FE_status" == "deferred" && -n "$FE_until" ]]; then
      case "$FE_until" in date:*|pr:*) continue ;; esac
      (( w < 10 )) || continue
      w=$((w + 1))
      printf 'W%s\t%s\n' "$w" "$entry" >>"$out"
    fi
  done < <(fi_entries "$file" all 2>/dev/null || true)
}

_fi_af_classify_prompt() {
  cat <<EOF
You are the found-issues classifier. This run is unattended and read-only:
read files in this checkout if you need to, edit nothing, ask nothing.

Tag each U entry with exactly one of:
- {"kind":"fix","value":"small"}: no human decision needed, ready now, a test can prove the fix, a few lines
- {"kind":"fix","value":"medium"}: the same, but a larger change in one area
- {"kind":"fix","value":"large"}: no decision needed, but big
- {"kind":"decide","value":"<the question a human must answer>"}: more than one reasonable fix, an interface others depend on, product taste, anything outside the repo, irreversible actions, or "is this even a bug?"
- {"kind":"manual","value":"<why>"}: no test or build can prove a fix
Leave out any U entry you are unsure about.

For each W entry, wake it only if its (until: ...) trigger has clearly
happened, judged from this checkout.

Entries:
$(cat "$1")

Reply with only a JSON object:
{"tags":[{"n":"U1","kind":"fix","value":"small"}],"wake":["W1"]}
EOF
}

# The listed entry for id <n>, or 1.
_fi_af_classify_entry() {
  local lid lentry
  while IFS=$'\t' read -r lid lentry || [[ -n "$lid" ]]; do
    [[ "$lid" == "$2" ]] && { FI_AF_CLASSIFY_ENTRY="$lentry"; return 0; }
  done <"$1"
  return 1
}

# Every answer is validated: listed ids only, U ids only take tags and W ids
# only wake, known kinds only; fi_tag_resolve checks sizes and texts and
# applies the off-limits override. Writes go through the serialized writers.
fi_af_classify_apply() {
  local file="$1" json="$2" list="$3" rows row n kind value
  rows="$(printf '%s' "$json" | jq -r '
      (if (.tags | type) == "array" then .tags[] else empty end
        | select(type == "object")
        | ["T", (.n | tostring), (.kind | tostring), (.value | tostring)] | @tsv),
      (if (.wake | type) == "array" then .wake[] else empty end
        | ["W", tostring, "-", "-"] | @tsv)' 2>/dev/null)" || return 0
  while IFS=$'\t' read -r row n kind value; do
    [[ -n "$row" ]] || continue
    _fi_af_classify_entry "$list" "$n" || continue
    if [[ "$row" == "T" ]]; then
      [[ "$n" == U* ]] || continue
      case "$kind" in fix|decide|manual) ;; *) continue ;; esac
      fi_parse_entry_vars "$FI_AF_CLASSIFY_ENTRY" || continue
      fi_tag_resolve "$kind" "$value" "$FE_path" "$AFI_root" 2>/dev/null || continue
      fi_tag_apply "$file" "$FI_AF_CLASSIFY_ENTRY" "$FI_TAG_KIND" "$FI_TAG_VALUE" >/dev/null || true
    else
      [[ "$n" == W* ]] || continue
      fi_entry_retag "$FI_AF_CLASSIFY_ENTRY" drop-until "" || continue
      _fi_af_ledger_swap "$file" "$FI_AF_CLASSIFY_ENTRY" "- [open]${FI_RETAGGED#- \[deferred\]}" || true
    fi
  done <<<"$rows"
  return 0
}

# Best effort: any failure just means nothing was classified this sweep.
fi_af_classify() {
  local file="$1" id="$2" list="$FI_AF_RUNS/$2.classify.list" base="$FI_AF_RUNS/$2.classify" engine rc=0 t
  _fi_af_classify_list "$file" "$list"
  [[ -s "$list" ]] || return 0
  engine="$(fi_af_engine "${AFI_engine:-}" 2>/dev/null)" || return 0
  command -v "$engine" >/dev/null 2>&1 || return 0
  if [[ "$engine" == "codex" ]]; then
    printf '%s\n' '{"type":"object","properties":{"tags":{"type":"array","items":{"type":"object","properties":{"n":{"type":"string"},"kind":{"type":"string"},"value":{"type":"string"}},"required":["n","kind","value"],"additionalProperties":false}},"wake":{"type":"array","items":{"type":"string"}}},"required":["tags","wake"],"additionalProperties":false}' >"$base.schema.json"
    FI_AF_CMD=(codex exec --sandbox read-only -C "$AFI_wt" --ephemeral --json
      --output-schema "$base.schema.json" -o "$base.last" "$(_fi_af_classify_prompt "$list")")
  else
    FI_AF_CMD=(claude -p --model sonnet --max-budget-usd "$(fi_af_budget_left || printf '0.10')"
      --max-turns 20 --no-session-persistence
      --permission-mode dontAsk --permission-prompts none
      --allowedTools Read Grep Glob
      --output-format json "$(_fi_af_classify_prompt "$list")")
  fi
  fi_af_child "$base.out" "$base.err" "$AFI_wt" "${FI_AF_CMD[@]}" || rc=$?
  fi_af_collect "$engine" "$base.out" "$base.last"
  if [[ -f "$FI_AF_ST/running/$id" ]]; then
    fi_af_item_set "$FI_AF_ST/running/$id" cost "$FI_AF_COST" || true
    fi_af_item_set "$FI_AF_ST/running/$id" tokens "$FI_AF_TOKENS" || true
  fi
  fi_af_log "$id" "classify: rc=$rc"
  t="$FI_AF_TEXT"
  [[ "$t" == *"{"*"}"* ]] || return 0
  t="{${t#*\{}"
  t="${t%\}*}}"
  _fi_af_classify_mark_offered "$list"
  fi_af_classify_apply "$file" "$t" "$list"
}

# The classifier answered: every U entry it was shown stops counting toward
# the sweep threshold, so entries it leaves out as unsure (or whose tag is
# refused) cannot queue a fresh sweep every day.
_fi_af_classify_mark_offered() {
  local row entry seen="$FI_AF_ST/classify-offered"
  while IFS=$'\t' read -r row entry || [[ -n "$row" ]]; do
    [[ "$row" == U* && -n "$entry" ]] || continue
    fi_entry_dedup_key_v "$entry" "${AFI_root:-}" || continue
    grep -Fqx -- "$FI_KEY" "$seen" 2>/dev/null || printf '%s\n' "$FI_KEY" >>"$seen"
  done <"$1"
}
