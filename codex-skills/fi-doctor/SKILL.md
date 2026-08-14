---
name: fi-doctor
description: Read-only health check of the found-issues installation — CLI version vs installed plugin, statusline wiring, gh auth, mode detection, hook opt-outs, ledger file state. Run when something looks wrong (counter missing, sync not firing, stale CLI after an update) or after install or upgrade. Diagnoses only and changes nothing — follow its printed advice to fix.
---
<!-- loc-override: generated 1:1 from commands/doctor.md by scripts/gen-codex-skills.sh; length is owned by the source command file -->

Run a one-shot health diagnostic on the found-issues plugin in this repo. Read-only — no file modifications. Always exits 0 (informational).

```bash
found-issues doctor
```

## What it reports

Seven sections, one screen of output:

1. **Plugin runtime** — CLI path, lib dir, onboarding marker presence
2. **Statusline** — current state (installed-fixed / installed-broken / legacy-handwritten / legacy-and-installed / none / no-file). Surfaces the same diagnosis `doctor-statusline` would print, abbreviated.
3. **gh CLI** — whether `gh` is on PATH and authenticated. Affects PR-related features.
4. **Mode detection** — auto-detected mode (`local` / `git` / `github-direct` / `github-pr`) and the cache state. Notes if `FOUND_ISSUES_MODE` is overriding detection.
5. **Hook opt-outs** — which of the 5 hook env-vars are set to `off` in the current shell. Default state is "all hooks default-active."
6. **Tunables (non-default)** — only prints if `FOUND_ISSUES_DEFER_TOUCH_THRESHOLD`, `FOUND_ISSUES_DEFER_ESCALATION_FACTOR`, or `FOUND_ISSUES_STALE_DAYS` is set.
7. **Issues file** — path + per-status counts (open / critical / in PR / stale / deferred / fixed). Flags suspicious entries (`[open]` with stray `(fixed: ...)`, `[fixed]` without closure-date annotation).

Ends with a **Recommended next** list — concrete commands to run if anything in the sections above looked off.

## When to invoke

- **First-time setup verification.** Right after `/plugin install found-issues` + restart, run `found-issues doctor` to confirm the plugin's runtime is wired up correctly.
- **Statusline counter looks wrong.** Doctor's "Statusline" section is the fastest path to "what's broken about the counter rendering."
- **Sync isn't closing entries.** Doctor checks gh auth and surfaces suspicious-entry counts — useful pre-`sync` sanity check.
- **Periodic check-in.** Run before opening an issue against the plugin so you can paste the doctor output as part of the report.

## Reporting

Pass the doctor output through verbatim. It's structured plain text with section headers; no further interpretation required.

If a section flags something (statusline `BROKEN`, hook opt-out, suspicious entries), surface the suggested fix command from the "Recommended next" section.

## See also

- `found-issues doctor-statusline` — statusline-specific deep dive (5-state classifier). CLI-only; there is no `$fi-doctor-statusline` slash command.
- [`docs/configuration.md`](../../docs/configuration.md) — full env-var reference referenced by the hook-opt-out + tunables sections.
