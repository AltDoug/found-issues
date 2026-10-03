#!/bin/bash
cp -r /src /w; export CLAUDE_PLUGIN_ROOT=/w HOME=/home/r PATH=/w/bin:$PATH; mkdir -p $HOME /stub
cat > /stub/gh <<'G'
#!/bin/bash
case "$*" in *"pr view"*) sleep 4; echo '{"state":"OPEN","baseRefName":"main","mergedAt":null,"isDraft":false}';; *"auth status"*) exit 0;; *) echo '{}';; esac
G
chmod +x /stub/gh; export PATH=/stub:$PATH FOUND_ISSUES_MODE=github-pr FOUND_ISSUES_AUTO_ARCHIVE=off
mkdir -p /t && cd /t && git init -q -b main && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init && git remote add origin https://github.com/o/r.git && git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
mkdir -p docs; printf '# f\n\n- [open] 2026-10-01 c.sh:3 — unrelated entry\n- [open] 2026-10-01 a.sh:1 — in flight (PR: o/r#1)\n' > docs/found-issues.md
found-issues sync >/dev/null 2>&1 & sleep 1
found-issues defer c.sh:3 --reason waiting 2>&1 | head -1
echo "before sync finishes: $(grep -c '\[deferred\]' docs/found-issues.md)"; wait
echo "after sync finishes:  $(grep -c '\[deferred\]' docs/found-issues.md)"
