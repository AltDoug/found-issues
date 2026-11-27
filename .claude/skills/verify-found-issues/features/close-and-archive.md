---
feature: Resolve by hand and archive
also-called: resolve, archive, /found-issues:archive, fi-archive
sources:
  - lib/resolve.sh
  - lib/archive.sh
  - commands/archive.md
  - codex-skills/fi-archive/
proven: 2026-11-27
proven-hash: e7f42c2a7ed2
---

## What it is

`resolve` closes one entry because someone read the code and confirmed it is fixed: the only supported hand-close. `archive` moves old `[fixed]` entries into `docs/found-issues-archive.md` so the active ledger stays short.

## Parts

| What you see | What it does | Drive it by |
|---|---|---|
| `Resolved 1 entry. (verified: review, fixed: DATE)` | Closes the one match | `resolve MATCH --verified ai`, `review` or `human` |
| `no [open] entries match` (exit 1), `ambiguous match` (exit 2) | Refusals | a fragment that matches none, or two |
| `entry is on hold` (exit 2) | `ai` cannot close a held entry | `--verified ai` on a `(hold: ...)` entry |
| A deferred entry closed | | `resolve MATCH --deferred --verified review` |
| `archive (dry-run): would move N entries to ...` | Reports, writes nothing | `archive --dry-run` |
| `archive: moved N entries from ... to ...` | The move | `archive`; thresholds `--days N` (30), `--count N` (50) |

## How to get to it

The sync command's AI pass and a person who checked the code use `resolve`. `/found-issues:archive` moves old entries; an explicit sync also does it when a threshold is passed.

## Driving it

Resolve: a held entry, a miss, an ambiguous match, then the close.

```bash
set -eo pipefail
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new resolve)"; trap '$F rm "$SB"' EXIT
L=docs/found-issues.md
$F run "$SB" "found-issues log 'src/util.py:6 — first() raises on empty' && found-issues tag 'raises on empty' --hold 'needs a human'"
$F run "$SB" "found-issues resolve 'raises on empty' --verified ai" || true
$F rc "$SB" 2
$F has "$SB" 'entry is on hold'
$F run "$SB" "found-issues resolve 'nothing like this' --verified review" || true
$F rc "$SB" 1
$F has "$SB" 'no [open] entries match'
$F has "$SB" '- [open] ' "$L"
$F run "$SB" "found-issues log 'src/app.sh:2 — raises on empty name' && found-issues resolve 'raises on empty' --verified review" || true
$F rc "$SB" 2
$F has "$SB" 'ambiguous match'
$F count "$SB" 2 '- [open] ' "$L"
$F run "$SB" "found-issues resolve 'first() raises' --verified review && found-issues list --status=all"
$F has "$SB" 'Resolved 1 entry. (verified: review'
$F match "$SB" '^- \[fixed\] .*first\(\) raises on empty \(verified: review\) \(fixed: [0-9-]+\)$' "$L"
$F count "$SB" 1 '- [open] ' "$L"
$F snap "$SB" final
```

Archive: the dry run writes nothing, the real run moves the one `[fixed]` entry.

```bash
set -eo pipefail
F=.claude/skills/verify-found-issues/scripts/fi-sandbox.sh; export FOUND_ISSUES_AUTOFIX=off
eval "$($F new archive)"; trap '$F rm "$SB"' EXIT
L=docs/found-issues.md; A=docs/found-issues-archive.md
$F run "$SB" "found-issues log 'src/util.py:2 — one' && found-issues log 'src/util.py:6 — two' && found-issues resolve 'one' --verified review"
$F snap "$SB" before
$F run "$SB" 'found-issues archive --dry-run --count=0'
$F has "$SB" 'would move 1 entries'
$F has "$SB" 'src/util.py:2 — one' "$L"
$F gone "$SB" "$A"
$F run "$SB" 'found-issues archive --count=0'
$F has "$SB" 'archive: moved 1 entries'
$F snap "$SB" after
$F has "$SB" 'src/util.py:2 — one' "$A"
$F lacks "$SB" 'src/util.py:2 — one' "$L"
$F has "$SB" 'src/util.py:6 — two' "$L"
```

## What proves it works

- The held, missing and ambiguous cases exit 2, 1 and 2 and change nothing.
- The `review` close flips the line to `[fixed]`, drops `(hold: ...)` and appends `(verified: review) (fixed: date)`.
- The dry run says it would move 1 entry and writes no archive; the real run moves that line and keeps the open one.

## Gotchas

- An entry with an active `(PR: ...)` is refused too (exit 4 in `lib/resolve.sh`), because sync closes it.
- A `[fixed]` entry cannot be reopened.
- Not driven: that PR refusal, `--deferred`, the `--days` threshold and the refusal on merge-conflict markers.
