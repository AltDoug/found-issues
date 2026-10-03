#!/bin/bash
cp -r /src /w; export CLAUDE_PLUGIN_ROOT=/w HOME=/home/r PATH=/w/bin:$PATH; mkdir -p $HOME
nr(){ rm -rf /t; mkdir -p /t/docs && cd /t && git init -q -b main && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init; }
echo "### status-1 unwritable cache dir -> spawn per render"
nr; printf '# f\n\n- [open] 2026-10-01 a.sh:1 — x\n' > docs/found-issues.md; rm -f /tmp/spawns
for i in 1 2 3 4 5; do FOUND_ISSUES_CACHE_DIR=/proc/nope FOUND_ISSUES_AUTOSYNC_CMD='echo x >> /tmp/spawns' found-issues status --format=segment --cwd /t >/dev/null 2>&1; done; sleep 1; echo "spawns over 5 renders: $(wc -l < /tmp/spawns 2>/dev/null || echo 0)"
echo "### status-3 autosync cwd"
rm -f /tmp/p; cd /; FOUND_ISSUES_CACHE_DIR=/tmp/c3 FOUND_ISSUES_AUTOSYNC_CMD='pwd > /tmp/p' found-issues status --format=segment --cwd /t >/dev/null 2>&1; sleep 1; echo "autosync ran in: $(cat /tmp/p)"; cd /; echo "sync from / with CLAUDE_PROJECT_DIR=/t: $(CLAUDE_PROJECT_DIR=/t found-issues sync 2>&1 | head -1)"
echo "### ledger-7 gh present, jq absent -> merged PR never closes"
nr; git remote add origin https://github.com/o/r.git; git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
mkdir -p /nj; for b in /usr/bin/* /bin/*; do n=${b##*/}; [ "$n" = jq ] || ln -sf $b /nj/$n 2>/dev/null; done
printf '#!/bin/bash\ncase "$*" in *"pr view"*) echo "{\\"state\\":\\"MERGED\\",\\"baseRefName\\":\\"main\\",\\"mergedAt\\":\\"2026-10-02T00:00:00Z\\",\\"isDraft\\":false}";; *auth*) exit 0;; esac\n' > /nj/gh; chmod +x /nj/gh
printf '# f\n\n- [open] 2026-10-01 a.sh:1 — x (PR: o/r#3)\n' > docs/found-issues.md
echo "with jq:    $(PATH=/nj:/w/bin:/usr/bin FOUND_ISSUES_MODE=github-pr FOUND_ISSUES_AUTO_ARCHIVE=off found-issues sync 2>&1 | head -1)"
printf '# f\n\n- [open] 2026-10-01 a.sh:1 — x (PR: o/r#3)\n' > docs/found-issues.md
echo "without jq: $(PATH=/nj:/w/bin FOUND_ISSUES_MODE=github-pr FOUND_ISSUES_AUTO_ARCHIVE=off found-issues sync 2>&1 | head -1)"
echo "### ledger-4 mawk interval exprs"; ls -l /usr/bin/awk /etc/alternatives/awk 2>/dev/null | sed 's/.*-> //' ; command -v mawk gawk
echo "### ledger-3 archive with invalid UTF-8 line"
nr; printf -- '# f\n\n- [fixed] 2020-01-01 a.sh:1 — old (verified: ai) (fixed: 2020-01-02)\n- [open] 2026-10-01 b.sh:1 — bad \xff byte\n' > docs/found-issues.md
LANG=C.UTF-8 LC_ALL=C.UTF-8 found-issues archive 2>&1 | head -1; echo "open entries left: $(LC_ALL=C grep -c '^- \[open\]' docs/found-issues.md)"; head -c 200 docs/found-issues.md | LC_ALL=C cat -v | tail -2
