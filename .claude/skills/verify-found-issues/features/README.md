# found-issues features

Every user-facing feature, one file each. Find it by the command, the message on screen or the words used for it, open the file, follow **Driving it**. Each `Driving it` block is meant to run as **one** shell call from the repo root.

| Feature | Called | Proven |
|---|---|---|
| [Log an issue](logging.md) | log it, /found-issues:log | 2026-11-27 |
| [Counts and list](counts-and-list.md) | status, the count, list | 2026-11-27 |
| [Sync closes fixed entries](sync.md) | sync, tombstone, held | 2026-11-27 |
| [Link an entry to a PR or commit](annotate.md) | --pick, annotate-pr, unannotate | 2026-11-27 |
| [Suggestions after a commit or PR](commit-pr-hook.md) | commit-auto, PR-auto, post-bash hook | 2026-11-27 |
| [Defer and revive](defer.md) | park it, promote-deferred | 2026-11-27 |
| [Resolve by verification](resolve.md) | close it, verified | 2026-11-27 |
| [Fix tags and the decision queue](tags-and-decisions.md) | tag, hold, decide | 2026-11-27 |
| [Archive old fixed entries](archive.md) | archive | 2026-11-27 |
| [Branch delete guard and promote](branch-guard.md) | deletion blocked, promote | 2026-11-27 |
| [Ledger format guard](format-guard.md) | format violations, pre-commit | 2026-11-27 |
| [Session start context](session-start.md) | SessionStart, the rules | 2026-11-27 |
| [File entries on first touch](first-touch.md) | first-touch | 2026-11-27 |
| [Stop reminder](stop-reminder.md) | the nudge, Stop hook error | 2026-11-27 |
| [Statusline counter](statusline.md) | segment, install-statusline | 2026-11-27 |
| [Health check](doctor.md) | doctor | 2026-11-27 |
| [Auto-fix settings and status](autofix-settings.md) | config, autofix ready | 2026-11-27 |
| [Auto-fix runs and sweeps](autofix-runs.md) | spot fix, sweep | never |
| [Fix the open entries as a batch](fix-batch.md) | /found-issues:fix | never |
| [Codex hook wiring](codex-install.md) | install-codex-hooks | 2026-11-27 |
| [The /fi shortcut and uninstall](alias-and-uninstall.md) | /fi, uninstall | 2026-11-27 |
| [First-run setup](setup.md) | /found-issues:setup | never |
