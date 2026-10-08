#!/usr/bin/env bash
# score.sh -- score the session-start A/B eval (spec section 9).
#
# Usage: score.sh [--out DIR] [--csv FILE] [--arms "old new"]
#
# Per run:
#   logged  planted bugs found among NEW [open] ledger entries: same path as a
#           planted.txt line and the entry's line (or line range) within +-3.
#           Each planted bug counts once. Entries come from this checkout's
#           `found-issues list --json`, so the parser is the CLI's own.
#   fmt     the NEW ledger lines pass hooks/format-enforcer.sh (run in
#           github-direct mode, where it blocks with exit 2) and parse with a
#           date and a path. "-" when the run logged nothing new.
#   task    1 when `sh test.sh` exited 0 after the run.
#   tokens  usage.input_tokens + cache_creation_input_tokens + cache_read_input_tokens.
# Verdict (spec): PASS when new_logged >= old_logged - 1 and new_task >= old_task.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
FI_CLI="$EVAL_REPO/bin/found-issues"
ENFORCER="$EVAL_REPO/hooks/format-enforcer.sh"

out="$EVAL_SCRATCH/out" csv="" arms="old new"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    --csv) csv="$2"; shift 2 ;;
    --arms) arms="$2"; shift 2 ;;
    *) echo "score.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

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

# planted_hits <planted.txt> <entries-json> -> count of planted bugs matched
planted_hits() {
  local planted="$1" entries="$2" hits=0 line p n
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    p="${line%:*}"; n="${line##*:}"
    if printf '%s' "$entries" | jq -e --arg p "$p" --argjson n "$n" '
        any(.[]; .status == "open"
          and ((.path // "") | sub("^\\./"; "")) == $p
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
  local l0="$1" l1="$2" newlines payload rc
  newlines="$(grep -vxF -f "$l0" "$l1" | grep -E '^- \[' || true)"
  [[ -n "$newlines" ]] || { printf -- '-'; return 0; }
  payload="$(jq -n --arg c "$newlines" \
    '{tool_name:"Write",tool_input:{file_path:"/x/docs/found-issues.md",content:$c}}')"
  printf '%s' "$payload" | FOUND_ISSUES_MODE=github-direct bash "$ENFORCER" >/dev/null 2>&1
  rc=$?
  if (( rc == 2 )); then printf 'bad'; return 0; fi
  # every new entry line must also parse (CLI parser) with a date and a path
  local bad=0 total=0 want=0 tmp
  tmp="$(mktemp -d)"; mkdir -p "$tmp/docs"
  { printf '# t\n\n'; printf '%s\n' "$newlines"; } > "$tmp/docs/found-issues.md"
  bad="$("$FI_CLI" list --status=all --json --cwd "$tmp" 2>/dev/null \
    | jq '[.[] | select(.date == null or .path == null)] | length' 2>/dev/null || echo 1)"
  total="$("$FI_CLI" list --status=all --json --cwd "$tmp" 2>/dev/null | jq 'length' 2>/dev/null || echo 0)"
  rm -rf "${tmp:?}"
  want="$(printf '%s\n' "$newlines" | grep -c . || true)"
  if [[ "$bad" == 0 && "$total" == "$want" ]]; then printf 'ok'; else printf 'bad'; fi
}

[[ -z "$csv" ]] || printf 'arm,fixture,run,logged,fmt,task,tokens,cost,turns,error\n' > "$csv"

median() {  # numbers on stdin -> median
  sort -n | awk '{ a[NR] = $1 } END { if (NR == 0) { print 0; exit }
    if (NR % 2) print a[(NR + 1) / 2]; else printf "%d\n", (a[NR / 2] + a[NR / 2 + 1]) / 2 }'
}

printf '%-4s %-7s %-3s %-6s %-4s %-4s %-9s %-7s %-5s\n' arm fixture run logged fmt task tokens cost turns
sums=""
for arm in $arms; do
  logged_total=0 task_total=0 fmt_bad=0 n=0 cost_total=0 toks=""
  for f in "$out/$arm"-*-*.json; do
    [[ -e "$f" ]] || continue
    tag="$(basename "$f" .json)"
    rest="${tag#"$arm"-}"; fx="${rest%-*}"; i="${rest##*-}"
    l0="$out/$tag.ledger0.md"; l1="$out/$tag.ledger.md"
    [[ -f "$l0" && -f "$l1" && -f "$out/$tag.task" ]] || { echo "skip $tag (incomplete)" >&2; continue; }
    entries="$(new_entries "$l0" "$l1")"; [[ -n "$entries" ]] || entries="[]"
    logged="$(planted_hits "$HERE/fixtures/$fx/planted.txt" "$entries")"
    fmt="$(fmt_ok "$l0" "$l1")"
    task=0; [[ "$(cat "$out/$tag.task")" == 0 ]] && task=1
    tokens="$(jq -r '(.usage.input_tokens // 0) + (.usage.cache_creation_input_tokens // 0) + (.usage.cache_read_input_tokens // 0)' "$f" 2>/dev/null || echo 0)"
    cost="$(jq -r '.total_cost_usd // 0' "$f" 2>/dev/null || echo 0)"
    turns="$(jq -r '.num_turns // 0' "$f" 2>/dev/null || echo 0)"
    tokens="${tokens:-0}"; cost="${cost:-0}"; turns="${turns:-0}"
    err="$(jq -r '.subtype // "no-json"' "$f" 2>/dev/null || echo "no-json")"
    [[ -n "$err" ]] || err="no-json"
    printf '%-4s %-7s %-3s %-6s %-4s %-4s %-9s %-7.3f %-5s %s\n' "$arm" "$fx" "$i" "$logged" "$fmt" "$task" "$tokens" "$cost" "$turns" "$err"
    [[ -z "$csv" ]] || printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$arm" "$fx" "$i" "$logged" "$fmt" "$task" "$tokens" "$cost" "$turns" "$err" >> "$csv"
    logged_total=$((logged_total + logged)); task_total=$((task_total + task)); n=$((n + 1))
    [[ "$fmt" == bad ]] && fmt_bad=$((fmt_bad + 1))
    cost_total="$(awk -v a="$cost_total" -v b="$cost" 'BEGIN { printf "%.4f", a + b }')"
    toks="$toks$tokens"$'\n'
  done
  med="$(printf '%s' "$toks" | grep . | median)"
  sums="$sums$arm n=$n logged=$logged_total task=$task_total fmt_bad=$fmt_bad median_tokens=$med cost=\$$cost_total"$'\n'
  eval "n_$arm=$n; logged_$arm=$logged_total; task_$arm=$task_total"
done

echo
printf '%s' "$sums"
echo "eval cost file total (probes included): \$$(fi_eval_cost_total)"
if [[ " $arms " == *" old "* && " $arms " == *" new "* ]]; then
  if (( logged_new >= logged_old - 1 && task_new >= task_old )); then v=PASS; else v=FAIL; fi
  echo "VERDICT: $v  (new logged $logged_new >= old logged $logged_old - 1 : $(( logged_new >= logged_old - 1 ? 1 : 0 )); new task $task_new >= old task $task_old : $(( task_new >= task_old ? 1 : 0 )))"
fi
