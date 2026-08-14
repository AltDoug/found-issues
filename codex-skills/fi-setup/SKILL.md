---
name: fi-setup
description: First-run orientation — explains the system, surfaces optional config, offers the statusline integration and the fi alias. Run once after installing; safe to re-run. Logging itself is zero-config and does not need this.
---
<!-- loc-override: generated 1:1 from commands/setup.md by scripts/gen-codex-skills.sh; length is owned by the source command file -->

> **Note on the Edit permission (v1.4.0+):** Used ONLY when CLI returns an AI-fallback exit code (11 splice_point_not_found, 16 multiple_splices_detected, 17 markers_missing_but_invocation_present) during custom-statusline auto-integration. Never used in the happy path — `found-issues install-statusline --target --apply` does the file write deterministically.

Walk the user through what `found-issues` does and the few optional things
they can enable. The plugin is already fully active — they don't need to
do anything for it to work. This command exists for orientation and
optional polish.

## What to tell the user

Print a short, friendly intro along these lines (adapt tone to the user):

> **found-issues is now active.**
>
> When I notice a bug, error, or warning outside the task we're working on,
> I'll log it to `docs/found-issues.md` automatically. Entries flip to
> `[fixed]` when a PR or commit addresses them. The count shows up at session
> start so we always know the open queue.
>
> You don't need to do anything — the system runs on its own. Below are a
> few optional polish items if you want them.

Then check the user's environment and surface the relevant options.

## Codex users: hooks require a separate one-time step

Everything above (rules injection, ledger tracking) works the same on
Codex — but Codex CLI 0.144.5 removed the `plugin_hooks` feature, so a
plugin's own `hooks.json` manifest pointer never loads there (skills
still load fine). If this session is running under Codex, tell the user
to run this once, right after `codex plugin add`:

```
found-issues install-codex-hooks
```

This wires SessionStart, the format enforcer, the branch-delete guard,
and the PostToolUse annotator into Codex's own `$CODEX_HOME/hooks.json`
(default `~/.codex/hooks.json`). It's idempotent — safe to re-run — and
**must be re-run after every `codex plugin update`** (the plugin cache
path changes on update, and the installer self-heals stale paths on
re-run). There is no Stop-hook marker discipline on Codex yet (deferred —
the transcript rollout format isn't parsed).

The statusline picker and per-repo pre-commit hook below are Claude Code
concepts with no Codex equivalent — skip straight to the reporting step
for Codex users once `install-codex-hooks` is confirmed.

## How to present the optional integrations

Use a **single multi-select picker** (Claude Code's `AskUserQuestion` tool
with `multiSelect: true`) — not sequential one-by-one prompts. This lets the
user see all options at once, pick what they want, and submit in one step.

**Picker order and labels (this matters):**

1. `Statusline segment (Recommended)` — list FIRST, with the `(Recommended)`
   suffix exactly as written. Without it users habitually tab through the
   picker and miss the highest-signal integration. Per Claude Code
   convention, recommended options go first with `(Recommended)` appended
   to the label.
2. `/fi short alias` — list second. Pure ergonomics; the recommendation
   doesn't apply.

**Pre-flight checks** — omit options already installed so the picker only
shows actionable items:

- `~/.claude/statusline.sh` contains `# === found-issues plugin segment ===` → omit option 1
- `~/.claude/settings.json` has `statusLine.command` set to a path OTHER than `~/.claude/statusline.sh` → omit option 1 (user has a custom statusline our `install-statusline` can't safely modify; surface the manual-integration message instead, see Optional 1 below)
- `~/.claude/commands/fi.md` contains `Run /found-issues:<the user-provided arguments>` → omit option 2

**Doctor pass before the picker (informational, v1.0.4+):** running
`found-issues doctor-statusline` before the picker is no longer required
for correctness — `install-statusline` self-heals every broken state on
its own (auto-migrates legacy snippets with a timestamped backup as of
v1.0.4). It's still useful for *transparency*: if the user has a broken
state, surface it so they know what's about to be fixed. Recommended:

```bash
found-issues doctor-statusline
```

If the output contains `BROKEN` or `CONFLICTED`, mention it briefly
before the picker:

> _Heads up: your statusline integration is in a broken state
> (`<state from doctor>`). Picking the statusline option below will
> fix it (a timestamped backup is saved automatically)._

Then continue with the picker as normal — `install-statusline` (no flags)
handles every broken state. No conditional flag-passing or branching by
state required from you.

If **both** are already installed (and statusline is `installed-fixed`),
do not show the picker at all. Tell the user "all polish items already
done" and skip to the reporting step. This is what users see when
re-running setup after an upgrade.

The detailed install mechanics for each option are below — those describe
the CLI subcommand to invoke once the user picks.

## Optional 1 — Statusline integration

The plugin offers a counter segment for the user's Claude Code statusline
showing `N critical · N other · N in PR · N stale` (each shown only when
> 0; the residual bucket is labeled "issue/issues" when it's the only
counter on display, and "other" when alongside any of the other three).

**Use the deterministic CLI subcommand — do NOT edit the file yourself.**
The plugin ships `found-issues install-statusline` for this. It's
idempotent (marker-based), uses `|| true` so it's safe under `set -e`,
and adds a clearly-bracketed block that's trivially removable.

Flow:

1. **Detect where the user's statusline lives.** Claude Code supports two locations:
   - The convention path: `~/.claude/statusline.sh` (what `install-statusline` writes to)
   - A custom path set in `~/.claude/settings.json` under `statusLine.command`

   Run this single check:

   ```bash
   # Resolve where the statusline (if any) actually lives
   custom_cmd=""
   if [[ -f "$HOME/.claude/settings.json" ]] && command -v jq >/dev/null 2>&1; then
     custom_cmd="$(jq -r '.statusLine.command // empty' "$HOME/.claude/settings.json" 2>/dev/null || true)"
   fi
   custom_cmd_local=""
   if [[ -f "$HOME/.claude/settings.local.json" ]] && command -v jq >/dev/null 2>&1; then
     custom_cmd_local="$(jq -r '.statusLine.command // empty' "$HOME/.claude/settings.local.json" 2>/dev/null || true)"
   fi
   # settings.local.json takes precedence over settings.json (per-machine override)
   [[ -n "$custom_cmd_local" ]] && custom_cmd="$custom_cmd_local"

   # Normalize ~ → $HOME for comparison
   custom_cmd_expanded="${custom_cmd/#\~/$HOME}"

   convention="$HOME/.claude/statusline.sh"

   if [[ -n "$custom_cmd_expanded" && "$custom_cmd_expanded" != "$convention" ]]; then
     echo "STATUSLINE_CUSTOM_ELSEWHERE: $custom_cmd_expanded"
   elif [[ -f "$convention" ]]; then
     echo "STATUSLINE_AT_CONVENTION"
   else
     echo "STATUSLINE_DEFAULT"
   fi
   ```

2. **Branch on the result:**

   - **`STATUSLINE_CUSTOM_ELSEWHERE: <path>`** — the user has a custom statusline at a path our default `install-statusline` doesn't manage. **Auto-integration is now available** via `install-statusline --target` (v1.4.0+).

     **Step 1 — Detect language + identify splice point:**

     ```bash
     # Try to produce a dry-run diff for the custom statusline.
     # CLI auto-detects language from extension + shebang and identifies splice point.
     found-issues install-statusline --target "<path>" --dry-run >/tmp/fi-dry-run.diff 2>/tmp/fi-dry-run.err
     dry_status=$?
     ```

     Branch on `dry_status`:
     - **0** — language detected, splice point found, diff written to `/tmp/fi-dry-run.diff`. **Continue to Step 2 (offer the picker).**
     - **10** (`unsupported_language`) — fall through to the legacy manual-instructions message below; omit the picker option.
     - **11** (`splice_point_not_found`) — language detected but CLI couldn't identify a clean splice point. **Continue to Step 3 (AI-mediated fallback).**
     - **12** / **13** / **14** (`target_not_found` / `target_unreadable` / `target_unwritable`) — print the CLI's stderr output (from `/tmp/fi-dry-run.err`); abort the picker.

     **Step 2 — Picker option (when dry-run returned exit 0):**

     Add this option to the multi-select picker, FIRST, with the `(Recommended)` suffix:

     - **`Statusline integration (custom path) (Recommended)`** — _Splices the found-issues counter into your custom statusline at `<path>`. Reversible via `found-issues uninstall-statusline --target <path>`._

     On user yes, show the diff before applying:

     > _Here's what I'd add to `<path>` (a timestamped backup will be saved before any change):_
     >
     > ```diff
     > <paste contents of /tmp/fi-dry-run.diff>
     > ```

     Then `AskUserQuestion`: **"Apply this edit?"** → yes / no.

     On yes:
     ```bash
     found-issues install-statusline --target "<path>" --apply
     ```
     Report success. Tell the user to restart their Claude Code session.

     If `--apply` returns exit **16** (`multiple_splices_detected` — rare race condition where a second installation got partially inserted): fall through to Step 3 (AI-mediated repair).

     **Step 3 — AI-mediated fallback (only when CLI returns exit 11 or 16):**

     ```bash
     # Show the user what the CLI tried, so they understand why fallback is needed
     cat /tmp/fi-dry-run.err
     ```

     Tell the user: _"My deterministic splice couldn't find a clean insertion point in `<path>` (or detected conflicting markers from a prior partial install). Want me to read the file and propose an Edit manually?"_

     On yes:
     1. Use the `Read` tool on `<path>` to load the user's statusline script
     2. Identify where their statusline emits its first stdout line (the line that produces the visible statusline content)
     3. Compose an `Edit` that:
        - Inserts the language-appropriate marker block. The canonical snippet content lives in `bin/found-issues` (the `fi_generate_bash_marker_block` / `fi_generate_node_marker_block` / `fi_generate_python_marker_block` helpers); the design spec at `docs/superpowers/specs/2026-05-12-custom-statusline-auto-integration-design.md` has the same snippets in its "Per-language splice mechanics" section if copying from prose is easier
        - Appends the variable reference (`${__FI_SEG}` / `${__fiSeg}` / `{_fi_seg}`) to the first stdout line
        - Adds the `# found-issues:seg` (or `// found-issues:seg`) trailing comment on the modified line — **critical for uninstall to find it**
     4. Show the diff via Edit's normal preview; apply on user confirm.

     **Step 4 — Markers-stripped repair path (only when invocation is present but markers are missing):**

     If the detection at the top of this branch finds `found-issues status --format=segment` invoked in the user's statusline file but **no marker comments**, the file was previously integrated and then hand-edited to remove the markers. Without markers, the pure-CLI uninstall can't find the splice cleanly (exits 17).

     Detect this state explicitly. If `grep -F "found-issues status --format=segment" "<path>"` matches AND `grep -F "# === found-issues plugin segment ===" "<path>"` does NOT match AND `grep -F "// === found-issues plugin segment ===" "<path>"` does NOT match, surface it:

     > _Your statusline at `<path>` calls `found-issues status --format=segment` but the marker comments are missing — likely a manual edit. Want me to read the file and propose a clean Edit to add the markers back?_

     On yes: Use `Read` + `Edit` to:
     1. Locate the invocation line and any nearby setup of the `__FI_SEG` / `__fiSeg` / `_fi_seg` variable
     2. Wrap them in the language-appropriate marker block (`# === found-issues plugin segment ===` / `# === end ... ===` for bash & python; `// ===` for node)
     3. Add the `# found-issues:seg` / `// found-issues:seg` trailing comment to the reference splice line
     4. After this, `uninstall-statusline --target <path>` will work cleanly via the CLI.

     **Legacy manual-instructions message (only fired when dry-run returns exit 10 `unsupported_language`):**

     > _You have a custom statusline at `<path>` in a language we don't yet auto-integrate (currently supported: bash/sh, Node, Python). To add the counter manually, insert this call wherever your statusline assembles its first-line output:_
     >
     > ```bash
     > found-issues status --format=segment 2>/dev/null
     > ```
     >
     > _The output is empty when counts are zero and colorized when non-zero. The SessionStart hook still prints the open count once per session regardless._

   - **`STATUSLINE_AT_CONVENTION`** — user has `~/.claude/statusline.sh`. Continue with the normal flow:

     **Check if the segment is already installed.** Use the marker grep (NOT a generic "found-issues" string match — comments and other references can produce false positives):

     ```bash
     grep -Fq "# === found-issues plugin segment ===" ~/.claude/statusline.sh && echo INSTALLED || echo NOT_INSTALLED
     ```

     If NOT installed, ask: *"Want me to add the found-issues counter segment to your statusline? It inserts a small marker-bracketed block — fully reversible with `found-issues uninstall-statusline`."*

     On yes, run `found-issues install-statusline`. The command auto-detects whether the user's statusline has a LINE1 assembly pattern:
     - **LINE1 pattern detected** (multi-line statuslines): inserts the segment inline so it appears next to repo/branch on the same line
     - **No LINE1 pattern** (simple printf statuslines): appends the segment as a standalone new line
     - Either way: idempotent (marker prevents double-install), reversible (`uninstall-statusline`), guarded against `set -e`

     Tell the user to restart their session to see the segment render.

   - **`STATUSLINE_DEFAULT`** — no custom statusline anywhere. Tell them: *"You'll see the count via the SessionStart hook on session start regardless. If you want a custom statusline with the counter inline, create `~/.claude/statusline.sh` first, then run `found-issues install-statusline`."*

If the user has **claude-hud** or another statusline tool that owns the slot (and configures via `settings.json`), the `STATUSLINE_CUSTOM_ELSEWHERE` branch handles them — they get the manual-integration message above. The SessionStart hook still prints the count once per session.

To uninstall later: `found-issues uninstall-statusline` removes the
block cleanly without touching the rest of the file.

**Self-heal for legacy installs (v1.0.4+):** `install-statusline` is now
fully self-healing for every broken state. Upgrading from v1.0.0/v1.0.1
(marker block missing cwd handling) or pre-v0.1.7 dogfood era
(handwritten 3-line snippet, no markers) — both cases auto-migrate on a
plain `install-statusline` call. Legacy snippets are stripped surgically
and a timestamped backup of the pre-migration file is saved at
`~/.claude/statusline.sh.fi-bak-<ts>` for one-`mv` recovery if needed.
Pass `--no-migrate` to opt back into v1.0.3 strict behavior (refuse to
touch legacy lines). Run `found-issues doctor-statusline` first if you
want to inspect without modifying anything.

## Optional 2 — Per-repo pre-commit hook

If the user works in a team where multiple people might edit `docs/found-issues.md`
manually (outside Claude Code), they can install a per-repo git pre-commit
hook that validates entries at commit time. There is no installer
subcommand — copy the hook script out of the plugin:

```bash
cd <their-repo>
cp "$CLAUDE_PLUGIN_ROOT/hooks/pre-commit.sh" .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

(Outside a hook context where `$CLAUDE_PLUGIN_ROOT` isn't set, the plugin
lives under `~/.claude/plugins/cache/*/found-issues/*/`.) Uninstall with
`rm .git/hooks/pre-commit`; skip once with `git commit --no-verify`.

## Optional 3 — Short alias

Plugin commands are namespaced as `$fi-log`, `$fi-sync`,
etc. Users who want shorter typing can install a personal alias.

**Use the deterministic CLI subcommand — do NOT write the file yourself.**
The plugin ships `found-issues install-fi-alias` for this. It writes
`~/.claude/commands/fi.md` with the literal `<the user-provided arguments>` placeholder
intact, refuses to overwrite a pre-existing user-authored `/fi` command,
and is fully reversible via `found-issues uninstall-fi-alias`.

Flow:

1. Check if the user already has a `/fi` command:
   ```bash
   ls ~/.claude/commands/fi.md 2>/dev/null
   ```
2. If absent, ask: *"Want me to install the `/fi` shortcut so `/fi log
   ...` expands to `$fi-log ...`?"*
3. On yes, run `found-issues install-fi-alias`. The CLI is idempotent
   (running twice no-ops) and won't trample a user's own `/fi.md`.

To uninstall later: `found-issues uninstall-fi-alias` removes the file
only if it's ours.

## Reporting

Show the user the current state:

```bash
found-issues status --format=plain
```

Tell them the rules file is auto-loaded into context (no further action
needed) and that the system is ready.

If they want to read more, point them at the project README:
<https://github.com/AltDoug/found-issues>.

## Mark onboarding complete

After walking the user through setup, write the onboarding marker so the
first-run SessionStart nudge stops firing:

```bash
mkdir -p "$HOME/.claude/found-issues" && touch "$HOME/.claude/found-issues/.onboarded"
```

This is also touched automatically on first SessionStart — running setup
just makes it explicit.
