---
feature: Statusline counter
also-called: install-statusline, uninstall-statusline, doctor-statusline, segment
sources:
  - lib/statusline-core.sh
  - lib/statusline-target.sh
  - lib/statusline-install.sh
  - lib/statusline-uninstall.sh
  - lib/segment-cache.sh
proven-with: hand-built statusline stdin and small host scripts (not Claude Code)
proven: 2026-11-27
---

## What it is

Adds the open-issue count to the user's statusline, either appended to `~/.claude/statusline.sh` or spliced into a custom bash, node or python statusline script.

## Parts

| What you see | What it does | Drive it by |
|---|---|---|
| A block appended to `~/.claude/statusline.sh` | The default install | `found-issues install-statusline` |
| A diff, and the file unchanged | Preview of a splice | `install-statusline --target FILE` |
| Patched lines marked `found-issues:seg`, plus a `FILE.fi-bak-...` backup | Splice into a custom `.sh`, `.js` or `.py` host | `install-statusline --target FILE --apply` |
| The default script without the block, plus a backup | Removal, default target | `uninstall-statusline` |
| The custom script as it was before | Removal, custom target | `uninstall-statusline --target FILE` |
| ` \| 1 issue`, colored; nothing at `0 open` | The text the spliced script appends | `status --format=segment` |
| `State: installed-fixed`, `OK — statusline integration is current` | Static check | `doctor-statusline` |
| `✓ Segment rendered` | Runs the statusline with made-up stdin | `doctor-statusline-runtime` |

## How to get to it

`/found-issues:setup` offers it. Claude Code runs the script with JSON on stdin holding `workspace.current_dir`.

## Driving it

Splice into three custom hosts, then **execute** each. Hosts must read the workspace folder from stdin; node and python hosts must hold it in a variable named `dir` or `cwd`; a bash host must quote what it prints. `CLAUDE_PROJECT_DIR=/nonexistent` is deliberate: the folder taken from stdin must win over it. In order: a preview that writes nothing, the splice, a control with an empty ledger, the render with one entry, removal, and a target that does not exist.

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new statusline-shims)"; trap '$F rm "$SB"' EXIT
cat > "$SB/make-hosts.sh" <<'EOF'
printf '#!/usr/bin/env bash\ninput="$(cat)"\nprintf "host-bash"\n' > "$SB/sl.sh"
printf '#!/usr/bin/env node\nconst input = require("fs").readFileSync(0, "utf8");\nconst dir = JSON.parse(input).workspace.current_dir;\nprocess.stdout.write("host-node");\n' > "$SB/sl.js"
printf '#!/usr/bin/env python3\nimport json, sys\ncwd = json.loads(sys.stdin.read())["workspace"]["current_dir"]\nsys.stdout.write("host-py")\n' > "$SB/sl.py"
for f in sl.sh sl.js sl.py; do cp "$SB/$f" "$SB/$f.orig"; done
EOF
$F run "$SB" '. "$SB/make-hosts.sh" && for f in sl.sh sl.js sl.py; do found-issues install-statusline --target "$SB/$f" || exit 1; cmp "$SB/$f" "$SB/$f.orig" || exit 1; done && echo previews-wrote-nothing'
$F has "$SB" 'previews-wrote-nothing'
$F run "$SB" 'for f in sl.sh sl.js sl.py; do found-issues install-statusline --target "$SB/$f" --apply || exit 1; grep -q "found-issues:seg" "$SB/$f" || exit 1; cmp "$SB/$f.orig" "$SB/$f".fi-bak-* || exit 1; cp "$SB/$f" "$EVIDENCE/patched-$f"; done && echo marked-and-backed-up'
$F has "$SB" 'marked-and-backed-up'
$F run "$SB" 'bash -n "$SB/sl.sh" && node --check "$SB/sl.js" && python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$SB/sl.py" && echo all-three-parse'
$F is "$SB" 'all-three-parse'
RENDER='J="{\"workspace\":{\"current_dir\":\"$REPO\"}}"; rc=0; for pair in "bash sl.sh" "node sl.js" "python3 sl.py"; do set -- $pair; printf %s "$J" | CLAUDE_PROJECT_DIR=/nonexistent "$1" "$SB/$2" > "$EVIDENCE/shim-$2.out" || rc=1; printf "%s -> " "$2"; cat -v "$EVIDENCE/shim-$2.out"; echo; done; exit $rc'
$F run "$SB" "$RENDER"
$F match "$SB" '^sl\.sh -> host-bash$'
$F match "$SB" '^sl\.js -> host-node$'
$F match "$SB" '^sl\.py -> host-py$'
$F run "$SB" "found-issues log 'src/util.py:2 — divide has no zero check'"
$F snap "$SB" one-entry
$F run "$SB" "$RENDER"
$F match "$SB" '^sl\.sh -> host-bash ?\| \^\[\[31m1 issue\^\[\[0m$'
$F match "$SB" '^sl\.js -> host-node ?\| \^\[\[31m1 issue\^\[\[0m$'
$F match "$SB" '^sl\.py -> host-py ?\| \^\[\[31m1 issue\^\[\[0m$'
$F run "$SB" 'for f in sl.sh sl.js sl.py; do found-issues uninstall-statusline --target "$SB/$f" || exit 1; cmp "$SB/$f" "$SB/$f.orig" || exit 1; done && echo all-three-restored'
$F has "$SB" 'all-three-restored'
$F run "$SB" 'found-issues install-statusline --target "$SB/missing.sh" --apply' || true
$F rc "$SB" 12
$F has "$SB" 'missing.sh does not exist'
$F gone "$SB" "$SB/missing.sh"
```

The default target (its block is appended, not spliced, so the host's own line is left alone): install, execute, both checks, then uninstall and execute again.

```bash
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new statusline-default)"; trap '$F rm "$SB"' EXIT
$F run "$SB" "found-issues log 'src/util.py:2 — divide has no zero check'"
$F run "$SB" 'mkdir -p "$HOME/.claude" && printf "#!/usr/bin/env bash\ninput=\"\$(cat)\"\nprintf host\n" > "$HOME/.claude/statusline.sh" && found-issues install-statusline'
$F has "$SB" 'appended standalone segment'
RENDER='printf "{\"workspace\":{\"current_dir\":\"%s\"}}" "$REPO" | CLAUDE_PROJECT_DIR=/nonexistent bash "$HOME/.claude/statusline.sh" | cat -v'
$F run "$SB" "$RENDER"
$F match "$SB" '^host \| \^\[\[31m1 issue\^\[\[0m$'
$F run "$SB" 'found-issues doctor-statusline'
$F has "$SB" 'State: installed-fixed'
$F run "$SB" 'cd "$REPO" && found-issues doctor-statusline-runtime'
$F has "$SB" '✓ Segment rendered'
$F has "$SB" '1 issue'
$F run "$SB" 'found-issues uninstall-statusline'
$F has "$SB" 'removed found-issues segment'
$F run "$SB" "$RENDER"
$F is "$SB" 'host'
```

## What proves it works

- With an empty ledger each custom host prints only its own text; with one entry, its text and then the segment: ` | ` and a red `1 issue` under `cat -v`. All three rewritten files parse, carry the marker, and removal restores each byte for byte. Evidence: `patched-sl.*`, `shim-sl.*.out` and `transcript.txt`.
- Default target: the script prints `host | 1 issue` (colored); `doctor-statusline` says it is current; `doctor-statusline-runtime` prints `✓ Segment rendered` (the cause line after it is the broken part, see Gotchas); after uninstall the script prints `host` alone.

## Gotchas

- Broken: a bash host that prints an unquoted word (`printf host`, as an argument of its own with no quotes) gets `printf host${__FI_SEG}`; the segment then splits into extra `printf` arguments and **no counter shows**, while the install says `applied` and exits 0. Not in the ledger yet. The default install is not affected.
- A node or python host without a `dir` or `cwd` variable shows no segment when `CLAUDE_PROJECT_DIR` points elsewhere, though the install exits 0. That is the fixture's fault, not a failed splice.
- Broken: after a good default install, `doctor-statusline-runtime` prints `✓ Segment rendered` and then `cause: splice gap`, advising a `--target ... --apply` re-run. The splice check in `lib/statusline-install.sh` runs even for the default block. Not in the ledger yet. The block checks only the `✓` line.
- Broken: the node and python splices drop the segment's leading space (`host-node| 1 issue`, bash shows `host-bash | 1 issue`). Not in the ledger yet. The checks accept both, so a fix does not fail them.
- Not driven: Claude Code rendering it, the Windows branches, and migration of old marker blocks.
