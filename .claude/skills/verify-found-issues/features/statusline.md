---
feature: Statusline counter
also-called: the statusline, the counter, install-statusline, segment, doctor-statusline
sources:
  - lib/statusline-core.sh
  - lib/statusline-target.sh
  - lib/statusline-install.sh
  - lib/statusline-uninstall.sh
  - lib/segment-cache.sh
proven: 2026-11-27
---

## What it is

Adds the open-issue count to the user's statusline, either appended to `~/.claude/statusline.sh` or spliced into a custom bash, node or python statusline script.

## Parts

| What you see | What it does | Handle |
|---|---|---|
| `install-statusline` | Appends a block to `~/.claude/statusline.sh` | `cmd_install_statusline` |
| `install-statusline --target FILE --apply` | Splices into a custom `.sh`, `.js` or `.py` host, with a backup; patched lines are marked `found-issues:seg` | `lib/statusline-target.sh` |
| `uninstall-statusline` | Removes the block, keeps a backup | `lib/statusline-uninstall.sh` |
| `doctor-statusline`, `doctor-statusline-runtime` | Static check; runs the statusline with synthetic stdin | `cmd_doctor_statusline`, `cmd_doctor_statusline_runtime` |

## How to get to it

`/found-issues:setup` offers it. Claude Code runs the script with JSON on stdin holding `workspace.current_dir`.

## Driving it

Install, then **execute** the shims. Hosts must read the workspace folder from stdin; node and python hosts must hold it in a variable named `dir` or `cwd`.

Run the whole block as one shell call:

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new statusline-shims)"
$F run "$SB" "found-issues log 'src/util.py:2 — divide has no zero check'"
cat > "$SB/make-hosts.sh" <<'EOF'
printf '#!/usr/bin/env bash\ninput="$(cat)"\nprintf "host-bash"\n' > "$SB/sl.sh"
printf '#!/usr/bin/env node\nconst input = require("fs").readFileSync(0, "utf8");\nconst dir = JSON.parse(input).workspace.current_dir;\nprocess.stdout.write("host-node");\n' > "$SB/sl.js"
printf '#!/usr/bin/env python3\nimport json, sys\ncwd = json.loads(sys.stdin.read())["workspace"]["current_dir"]\nsys.stdout.write("host-py")\n' > "$SB/sl.py"
EOF
$F run "$SB" '. "$SB/make-hosts.sh" && for f in sl.sh sl.js sl.py; do found-issues install-statusline --target "$SB/$f" --apply || exit 1; done'
$F run "$SB" 'J="{\"workspace\":{\"current_dir\":\"$REPO\"}}"; rc=0; for pair in "bash sl.sh" "node sl.js" "python3 sl.py"; do set -- $pair; printf %s "$J" | CLAUDE_PROJECT_DIR=/nonexistent "$1" "$SB/$2" > "$EVIDENCE/shim-$2.out" || rc=1; printf "%s -> " "$2"; cat -v "$EVIDENCE/shim-$2.out"; echo; done; exit $rc'
$F run "$SB" 'bash -n "$SB/sl.sh" && node --check "$SB/sl.js" && python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$SB/sl.py" && echo all-three-parse'
$F rm "$SB"
```

Default target: write a small `$HOME/.claude/statusline.sh` inside a `run`, then `found-issues install-statusline`, feed it the same JSON, then `doctor-statusline-runtime` and `uninstall-statusline`.

## What proves it works

- Each output is the host's text followed by the segment: ` | ` (node and python: no leading space) then a red `1 issue` under `cat -v`.
- `CLAUDE_PROJECT_DIR=/nonexistent` is deliberate: the `--cwd` taken from stdin must win over it.
- All three rewritten files parse. The `shim-*.out` files are the evidence.

## Gotchas

A node or python host without `dir` or `cwd` shows no segment under the hostile variable, though the install exits 0. After a default install, `doctor-statusline-runtime` printed `✓ Segment rendered` followed by a `cause: splice gap` line (seen 2026-11-27, a product defect, not a failed drive). Not covered: Claude Code rendering it, Windows branches of the shims, and migration of old marker blocks.
