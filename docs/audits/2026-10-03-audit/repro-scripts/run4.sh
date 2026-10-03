#!/bin/bash
cp -r /src /w && cd /w && rm -f .git && git init -q -b main && git config user.email t@t && git config user.name t && git add -A && git commit -qm init
export HOME=/home/m; mkdir -p $HOME; export PATH=/w/bin:$PATH FOUND_ISSUES_AUTO_ARCHIVE=off
for n in 10 20; do
  { printf '# found-issues\n\n'; for i in $(seq 1 $n); do printf -- '- [open] 2026-10-01 lib/sync.sh:%d — bug %d (suggested: x)\n' $i $i; done; } > docs/found-issues.md
  strace -f -qq -o /tmp/st$n -e trace=clone,clone3,fork,vfork,execve bash bin/found-issues sync </dev/null >/dev/null 2>&1
  grep -E 'execve\(.*= 0$' /tmp/st$n | sed -E 's/.*execve\("([^"]+)".*/\1/' | sort | uniq -c | awk '{print $2, $1}' | sort > /tmp/h$n
  echo "n=$n forks=$(grep -cE '(clone|clone3|fork|vfork)\(.*= [0-9]+$' /tmp/st$n) execs=$(grep -cE 'execve\(.*= 0$' /tmp/st$n)"
done
paste /tmp/h10 /tmp/h20 | awk '{printf "%4d per 10 entries  %s\n", $4-$2, $1}' | sort -rn | head -12
