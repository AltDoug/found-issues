#!/bin/bash
set -u
cp -r /src /w; R=/w; export CLAUDE_PLUGIN_ROOT=/w HOME=/home/r PATH=/w/bin:$PATH CLAUDE_CODE_ENTRYPOINT=cli FOUND_ISSUES_SEGMENT_AUTOSYNC=off; mkdir -p $HOME
newrepo(){ rm -rf /t && mkdir -p /t && cd /t && git init -q -b main && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init; }
pre(){ jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | bash $R/hooks/pre-branch-delete.sh >/tmp/o 2>&1; echo "rc=$?"; }
echo "### hook-2/3/4 pre-branch-delete bypasses"
newrepo; mkdir -p docs; printf '# f\n\n' > docs/found-issues.md; git add -A; git commit -qm l
git checkout -q -b feat/x; printf -- '- [open] 2026-10-01 a.sh:1 — branch only issue\n' >> docs/found-issues.md; git commit -qam e; git checkout -q main
for c in 'git branch -D feat/x' 'git -C /t branch -D feat/x' 'git branch -D "feat/x"' 'git branch -df feat/x'; do printf '%-34s ' "$c"; pre "$c"; done
echo "### hook-5 format-enforcer sub-line [open]->[fixed]"
fe(){ jq -nc --arg o "$1" --arg n "$2" '{tool_name:"Edit",tool_input:{file_path:"/t/docs/found-issues.md",old_string:$o,new_string:$n}}' | FOUND_ISSUES_MODE=github-pr bash $R/hooks/format-enforcer.sh >/dev/null 2>&1; echo "rc=$?"; }
printf 'full-line flip:  '; fe '- [open] 2026-10-01 a.sh:1 — x' '- [fixed] 2026-10-01 a.sh:1 — x'
printf 'sub-line flip:   '; fe '[open] 2026-10-01 a.sh:1' '[fixed] 2026-10-01 a.sh:1'
echo "### hook-8 stop-reminder no transcript_path"
echo '{"session_id":"x1"}' | bash $R/hooks/stop-reminder.sh >/dev/null 2>&1; echo "rc=$?"
echo "### cli-4 log symptom ending in (commit: <sha on main>)"
newrepo; sha=$(git rev-parse --short HEAD); found-issues log "a.sh:5 — regression from (commit: $sha)" >/dev/null 2>&1; FOUND_ISSUES_AUTO_ARCHIVE=off found-issues sync 2>&1 | head -1; grep -c '^- \[fixed\]' docs/found-issues.md
echo "### cli-5 uninstall --help"
mkdir -p $HOME/.claude/found-issues $HOME/.cache/found-issues; found-issues uninstall --help >/dev/null 2>&1; ls -d $HOME/.claude/found-issues $HOME/.cache/found-issues 2>&1 | sed 's/^/  /'
echo "### cli-2 log path with space twice"
newrepo; found-issues log 'docs/my notes.md:12 — stale' >/dev/null 2>&1; found-issues log 'docs/my notes.md:12 — stale' 2>&1 | head -1; grep -c 'my notes' docs/found-issues.md
echo "### cli-3 parse() collision"
newrepo; found-issues log 'src/a.py:10 — parse() returns None' >/dev/null; found-issues log 'src/a.py:10 — parse() raises on unicode' 2>&1 | head -1
echo "### status-5 uninstall --target node concat form"
printf 'const dir="/t";\nconsole.log("x");\n' > /tmp/s.js; found-issues install-statusline --target /tmp/s.js --apply >/dev/null 2>&1; found-issues uninstall-statusline --target /tmp/s.js >/dev/null 2>&1; grep -c '__fiSeg' /tmp/s.js; command -v node >/dev/null && node /tmp/s.js 2>&1 | head -1 || echo "(no node) remaining: $(grep __fiSeg /tmp/s.js | head -1 | cut -c1-80)"
echo "### status-6 start marker w/o end marker"
mkdir -p $HOME/.claude; printf '#!/bin/bash\n# === found-issues plugin segment ===\nFI=1\necho keep-me-1\necho keep-me-2\n' > $HOME/.claude/statusline.sh; found-issues install-statusline >/dev/null 2>&1; grep -c keep-me $HOME/.claude/statusline.sh; ls $HOME/.claude/ | grep -c fi-bak
echo "### status-8 install-statusline --dry-run (canonical)"
printf '#!/bin/bash\nprintf "a\\n"\nprintf "b\\n"\n' > $HOME/.claude/statusline.sh; found-issues install-statusline --dry-run >/dev/null 2>&1; grep -c 'found-issues plugin segment' $HOME/.claude/statusline.sh
