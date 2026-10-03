#!/bin/bash
cp -r /src /w; export CLAUDE_PLUGIN_ROOT=/w HOME=/home/r PATH=/w/tests/bin-shims:/w/bin:$PATH FOUND_ISSUES_MODE=github-pr; mkdir -p $HOME
mkdir -p /t && cd /t && git init -q -b main && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init && git remote add origin https://github.com/o/r.git
mkdir -p docs; printf '# f\n\n- [open] 2026-10-01 lib/foo.sh:900 — unrelated race at line 900\n' > docs/found-issues.md
export GH_MOCK_REPO_VIEW='{"nameWithOwner":"o/r"}' GH_MOCK_PR_VIEW=$'7\tlib/foo.sh' GH_MOCK_PR_DIFF=$'diff --git a/lib/foo.sh b/lib/foo.sh\n--- a/lib/foo.sh\n+++ b/lib/foo.sh\n@@ -12,1 +12,1 @@\n-old\n+new'
echo "bare:      $(found-issues annotate-pr 7 2>&1 | head -1)"; grep -o '(PR[^)]*)' docs/found-issues.md
printf '# f\n\n- [open] 2026-10-01 lib/foo.sh:900 — unrelated race at line 900\n' > docs/found-issues.md
echo "hook-auto: $(found-issues annotate-pr 7 --hook-auto 2>&1 | head -1)"; grep -o '(PR[^)]*)' docs/found-issues.md || echo "(no annotation)"
