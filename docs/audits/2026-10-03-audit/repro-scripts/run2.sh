#!/bin/bash
set -u
cp -r /src /w && cd /w && rm -f .git && git init -q -b main && git config user.email t@t && git config user.name t && git add -A && git commit -qm init
export HOME=/home/m; mkdir -p $HOME; export PATH=/w/bin:$PATH FOUND_ISSUES_CACHE_DIR=/tmp/fic FOUND_ISSUES_SEGMENT_CACHE=off FOUND_ISSUES_SEGMENT_AUTOSYNC=off
c(){ local l=$1; shift; strace -f -qq -o /tmp/st -e trace=clone,clone3,fork,vfork,execve "$@" </dev/null >/dev/null 2>&1; printf '%-40s forks=%s\n' "$l" "$(grep -cE '(clone|clone3|fork|vfork)\(.*= [0-9]+$' /tmp/st)"; }
echo "entries(open/total): $(grep -c '^- \[open\]' docs/found-issues.md)/$(grep -c '^- \[' docs/found-issues.md)"
c "sync (AUTO_ARCHIVE=off)" env FOUND_ISSUES_AUTO_ARCHIVE=off bash bin/found-issues sync
c "status plain" bash bin/found-issues status
c "status segment (cache off)" bash bin/found-issues status --format=segment --cwd /w
c "list --json" bash bin/found-issues list --json
for n in 0 10 40 80; do
  { printf '# found-issues\n\n'; for i in $(seq 1 $n); do printf -- '- [open] 2026-10-01 src/f%d.py:%d — bug %d\n' $i $i $i; done; } > docs/found-issues.md
  c "segment, $n open entries" bash bin/found-issues status --format=segment --cwd /w
  c "sync, $n open entries" env FOUND_ISSUES_AUTO_ARCHIVE=off bash bin/found-issues sync
done
