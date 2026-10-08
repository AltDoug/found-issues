#!/usr/bin/env bash
# score.sh -- score the session-start A/B eval (spec section 9).
#
# Usage: score.sh --out DIR [--csv FILE] [--runs N] [--fixtures "calc parser queue"]
#
# Arms come from <out>/manifest.txt (written by run.sh). Per run:
#   logged  planted bugs found among NEW [open] ledger entries: same path as a
#           planted.txt line and the entry's line (or line range) within +-3.
#           Paths are normalised: a leading ./ and an absolute prefix up to the
#           run's repo root are stripped. Each planted bug counts once.
#           Entries come from this checkout's `found-issues list --json`.
#   fmt     every NEW ledger line starting with "- " must be a "- [" entry,
#           pass hooks/format-enforcer.sh (github-direct mode, where it blocks
#           with exit 2) and parse with a date and a path. "-" = nothing new.
#   task    1 when `sh test.sh` exited 0 after the run.
#   tokens  usage.input_tokens + cache_creation_input_tokens + cache_read_input_tokens.
#
# Completeness: every arm must have all fixtures x runs runs complete (JSON with
# a cost, both ledgers, the task file). Otherwise the output says INCOMPLETE,
# lists what is missing, and prints no PASS/FAIL.
#
# Verdict (pre-registered): every non-old arm is compared with `old`; an arm
# PASSES when logged >= old logged - 1 AND task >= old task. One line per arm.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
FI_CLI="$EVAL_REPO/bin/found-issues"
ENFORCER="$EVAL_REPO/hooks/format-enforcer.sh"

csv="" runs=5 fixtures=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) EVAL_OUT="$2"; shift 2 ;;
    --csv) csv="$2"; shift 2 ;;
    --runs) runs="$2"; shift 2 ;;
    --fixtures) fixtures="$2"; shift 2 ;;
    *) fi_eval_die "unknown argument '$1'" ;;
  esac
done
[[ -n "$EVAL_OUT" ]] || fi_eval_die "--out DIR (or EVAL_OUT) is required"
EVAL_OUT="$(cd "$EVAL_OUT" && pwd -P)" || fi_eval_die "no such out dir"
[[ -f "$EVAL_OUT/manifest.txt" ]] || fi_eval_die "no manifest.txt in $EVAL_OUT (run.sh never ran here)"
arms="$(sed -n 's/^arms=//p' "$EVAL_OUT/manifest.txt")"
[[ -n "$arms" ]] || fi_eval_die "manifest lists no arms"
[[ -n "$fixtures" ]] || fixtures="$(cd "$HERE/fixtures" && ls -d */ | tr -d '/' | tr '\n' ' ' | sed 's/ $//')"
out="$EVAL_OUT/runs"
: "${EVAL_COST_FILE:=$EVAL_OUT/cost.txt}"

# new_entries <ledger0> <ledger> -> JSON array of entries whose raw line is new
new_entries() {
  local l0="$1" l1="$2" tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/docs"
  cp "$l1" "$tmp/docs/found-issues.md"
  "$FI_CLI" list --status=all --json --cwd "$tmp" 2>/dev/null \
    | jq -c --rawfile old "$l0" '
        ($old | split("\n")) as $o
        | map(select(.raw as $r | ($o | index($r)) == null))' 2>/dev/null
  rm -rf "${tmp:?}"
}

# planted_hits <planted.txt> <entries-json> <tag> -> count of planted bugs matched
planted_hits() {
  local planted="$1" entries="$2" tag="$3" hits=0 line p n
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    p="${line%:*}"; n="${line##*:}"
    if printf '%s' "$entries" | jq -e --arg p "$p" --argjson n "$n" --arg tag "$tag" '
        def norm: (. // "") | sub("^\\./"; "") | sub("^.*/work/" + $tag + "/"; "");
        any(.[]; .status == "open"
          and (.path | norm) == $p
          and (.line != null)
          and ($n >= (.line - 3))
          and ($n <= ((.line_end // .line) + 3)))' >/dev/null 2>&1; then
      hits=$((hits + 1))
    fi
  done < "$planted"
  printf '%s' "$hits"
}

# fmt_ok <ledger0> <ledger> -> ok | bad | -
fmt_ok() {
  local l0="$1" l1="$2" newlines payload rc bad total want tmp
  newlines="$(grep -vxF -f "$l0" "$l1" | grep -E '^- ' || true)"
  [[ -n "$newlines" ]] || { printf -- '-'; return 0; }
  # a new "- " line that is not a "- [" entry is malformed (the enforcer skips those)
  if printf '%s\n' "$newlines" | grep -qvE '^- \['; then printf 'bad'; return 0; fi
  payload="$(jq -n --arg c "$newlines" \
    '{tool_name:"Write",tool_input:{file_path:"/x/docs/found-issues.md",content:$c}}')"
  printf '%s' "$payload" | FOUND_ISSUES_MODE=github-direct bash "$ENFORCER" >/dev/null 2>&1
  rc=$?
  if (( rc == 2 )); then printf 'bad'; return 0; fi
  # every new entry line must also parse (CLI parser) with a date and a path
  tmp="$(mktemp -d)"; mkdir -p "$tmp/docs"
  { printf '# t\n\n'; printf '%s\n' "$newlines"; } > "$tmp/docs/found-issues.md"
  bad="$("$FI_CLI" list --status=all --json --cwd "$tmp" 2>/dev/null \
    | jq '[.[] | select(.date == null or .path == null)] | length' 2>/dev/null || echo 1)"
  total="$("$FI_CLI" list --status=all --json --cwd "$tmp" 2>/dev/null | jq 'length' 2>/dev/null || echo 0)"
  rm -rf "${tmp:?}"
  want="$(printf '%s\n' "$newlines" | grep -c . || true)"
  if [[ "$bad" == 0 && "$total" == "$want" ]]; then printf 'ok'; else printf 'bad'; fi
}

median() {  # numbers on stdin -> median
  sort -n | awk '{ a[NR] = $1 } END { if (NR == 0) { print 0; exit }
    if (NR % 2) print a[(NR + 1) / 2]; else printf "%d\n", (a[NR / 2] + a[NR / 2 + 1]) / 2 }'
}

run_complete() {  # <tag>
  [[ -s "$out/$1.json" ]] && jq -e '.total_cost_usd != null' "$out/$1.json" >/dev/null 2>&1 \
    && [[ -f "$out/$1.ledger0.md" && -f "$out/$1.ledger.md" && -f "$out/$1.task" ]]
}

# --- completeness gate ----------------------------------------------------------
nfx=$(echo $fixtures | wc -w | tr -d ' ')
expected=$(( nfx * runs ))
incomplete=0
for arm in $arms; do
  have=0 missing=""
  for fx in $fixtures; do
    i=1
    while (( i <= runs )); do
      if run_complete "$arm-$fx-$i"; then have=$((have + 1)); else missing="$missing $arm-$fx-$i"; fi
      i=$((i + 1))
    done
  done
  if (( have != expected )); then
    incomplete=1
    echo "INCOMPLETE: arm $arm has $have of $expected runs; missing:$missing"
  fi
done

[[ -z "$csv" ]] || printf 'arm,fixture,run,logged,fmt,task,tokens,cost,turns,error\n' > "$csv"

printf '%-9s %-7s %-3s %-6s %-4s %-4s %-9s %-7s %-5s\n' arm fixture run logged fmt task tokens cost turns
sums=""
for arm in $arms; do
  logged_total=0 task_total=0 fmt_bad=0 n=0 cost_total=0 toks=""
  for fx in $fixtures; do
    i=1
    while (( i <= runs )); do
      tag="$arm-$fx-$i"; i=$((i + 1))
      run_complete "$tag" || continue
      f="$out/$tag.json"
      l0="$out/$tag.ledger0.md"; l1="$out/$tag.ledger.md"
      entries="$(new_entries "$l0" "$l1")"; [[ -n "$entries" ]] || entries="[]"
      logged="$(planted_hits "$HERE/fixtures/$fx/planted.txt" "$entries" "$tag")"
      fmt="$(fmt_ok "$l0" "$l1")"
      task=0; [[ "$(cat "$out/$tag.task")" == 0 ]] && task=1
      tokens="$(jq -r '(.usage.input_tokens // 0) + (.usage.cache_creation_input_tokens // 0) + (.usage.cache_read_input_tokens // 0)' "$f" 2>/dev/null)"
      cost="$(jq -r '.total_cost_usd // 0' "$f" 2>/dev/null)"
      turns="$(jq -r '.num_turns // 0' "$f" 2>/dev/null)"
      err="$(jq -r '.subtype // "no-json"' "$f" 2>/dev/null)"
      tokens="${tokens:-0}"; cost="${cost:-0}"; turns="${turns:-0}"; err="${err:-no-json}"
      printf '%-9s %-7s %-3s %-6s %-4s %-4s %-9s %-7.3f %-5s %s\n' "$arm" "$fx" "${tag##*-}" "$logged" "$fmt" "$task" "$tokens" "$cost" "$turns" "$err"
      [[ -z "$csv" ]] || printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$arm" "$fx" "${tag##*-}" "$logged" "$fmt" "$task" "$tokens" "$cost" "$turns" "$err" >> "$csv"
      logged_total=$((logged_total + logged)); task_total=$((task_total + task)); n=$((n + 1))
      [[ "$fmt" == bad ]] && fmt_bad=$((fmt_bad + 1))
      cost_total="$(awk -v a="$cost_total" -v b="$cost" 'BEGIN { printf "%.4f", a + b }')"
      toks="$toks$tokens"$'\n'
    done
  done
  med="$(printf '%s' "$toks" | grep . | median)"
  sums="$sums$arm n=$n logged=$logged_total task=$task_total fmt_bad=$fmt_bad median_tokens=$med cost=\$$cost_total"$'\n'
  eval "logged_$arm=$logged_total; task_$arm=$task_total"
done

echo
printf '%s' "$sums"
echo "eval cost file total (probes included): \$$(fi_eval_cost_total)"

if (( incomplete )); then
  echo "VERDICT: INCOMPLETE -- every arm needs all $expected runs (fixtures [$fixtures] x $runs); no PASS/FAIL printed"
  exit 3
fi
if [[ " $arms " != *" old "* ]]; then
  echo "VERDICT: none -- no arm named old to compare against"
  exit 0
fi
for arm in $arms; do
  [[ "$arm" == old ]] && continue
  eval "la=\$logged_$arm; ta=\$task_$arm"
  if (( la >= logged_old - 1 && ta >= task_old )); then v=PASS; else v=FAIL; fi
  echo "VERDICT $arm: $v  (logged $la >= old $logged_old - 1: $(( la >= logged_old - 1 ? 1 : 0 )); task $ta >= old $task_old: $(( ta >= task_old ? 1 : 0 )))"
done
