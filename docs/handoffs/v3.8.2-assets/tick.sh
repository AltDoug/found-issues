#!/usr/bin/env bash
# found-issues auto-fix watch tick (recreated 2026-10-10 from v3.6.2 handoff Watch recipe)
here="$(cd "$(dirname "$0")" && pwd)"
last="$here/tick.last"
since=$(cat "$last" 2>/dev/null || echo $(( $(date +%s) - 1800 )))
echo "=== tick $(date '+%F %T %Z') since=$since ==="
echo "--- dougstation fi-health ---"
ssh -o ConnectTimeout=15 -o BatchMode=yes silva@100.98.153.101 "& 'C:\Program Files\Git\bin\bash.exe' -lc 'bash ~/.cache/fi-health.sh $since'" 2>&1 | tail -80
for r in AltDoug/kh2-midgar AltDoug/dougstation AltDoug/lumiplat-forms AltDoug/found-issues; do
  echo "--- $r open fi/* PRs ---"
  gh pr list --repo "$r" --state open --json number,headRefName,title,mergeable,statusCheckRollup 2>&1 \
    | jq -r '.[]? | select(.headRefName|startswith("fi/")) | "#\(.number) \(.headRefName) mergeable=\(.mergeable) checks=\([.statusCheckRollup[]? | (.conclusion // .status)] | group_by(.) | map("\(.[0]):\(length)") | join(","))  \(.title)"' 2>&1
done
date +%s > "$last"
