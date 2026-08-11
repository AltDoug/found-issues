# Validation sweep — deferred ledger entries, open issues, open PR

Date: 2026-08-10
Scope: `docs/found-issues.md` deferred entries + `AltDoug/found-issues` open issues/PRs
Baseline: main @ `7513d1d`, v2.1.1 (installed marketplace copy is byte-identical)
Method: read-only parser probes, sandboxed end-to-end repro, full bats suite

---

## 1. Working tree — uncommitted archive move

`docs/found-issues.md` and `docs/found-issues-archive.md` carried uncommitted changes
at session start: 34 lines moved out of the ledger into the archive.

**Verified lossless.** All 34 removed lines are `[fixed]`; sorted byte-diff of
removed-vs-added is empty. This matters because `cmd_archive` previously had a
substring-match data-loss bug (fixed in v1.5.x), so "34 out / 34 in" alone is not proof.

Ledger now: **0 open, 5 deferred, 13 fixed** (13 recent `[fixed]` entries retained
under the archive retention window).

Status: completed housekeeping, safe to commit.

---

## 2. Deferred entries — all 5 still true

| # | Entry (cited location) | Verdict | Fresh citation |
|---|---|---|---|
| D1 | `hooks/stop-reminder.sh:46` — stop-marker discipline is Claude-only on Codex | **Still true, by design** | `hooks/stop-reminder.sh:46-47`; documented at `AGENTS.md:124`, `docs/faq.md:112` |
| D2 | `docs/found-issues.md:53` — loc-validator tag parses as the path | **Still true** | probe: `path=(loc-validator)`, `line=` |
| D3 | `bin/found-issues:3650` — numeric-or-zero guard duplicated | **Still true, drifted worse** | 10 sites, 3 spellings; no `fi_to_int` |
| D4 | `tests/helpers.bash:62` — no negation assertion helper | **Still true, grew** | 37 sites / 13 files; no `fi_refute_*` |
| D5 | `hooks/post-bash-dispatch.sh:232` — rc=2 swallowed, PATH-preferring FI_BIN | **Still true (code); trigger resolved** | `:52-57`, `:232-244`, `:261-272` |

### Detail

**D1** — the comment at `hooks/stop-reminder.sh:46-47` still states the Codex rollout
format is unparsed by the smart-fire parser. The defer reason claimed this is documented
in AGENTS.md/FAQ; both confirmed. No action — this is a recorded v1 design decision.

**D2** — reproduces exactly:

```
input:  - [open] 2026-07-10 (loc-validator) skills/rules/SKILL.md:204 (...) — exceeds refactor signal
output: path=(loc-validator)   line=
```

*New finding:* the entry's own cited location `docs/found-issues.md:53` is now
out of range — the ledger is 24 lines after the archive move. `sync` does not
tombstone `[deferred]` entries (verified in sandbox), so it is safe today. But an
`[open]` control with the identical out-of-range citation **was** tombstoned in the
same run. So promoting D2 back to `[open]` makes it a false-closure candidate on the
next sync. Re-log with a current citation rather than promoting in place.

**D3** — counts drifted from the entry's record, and the drift got worse. Now **10** guard
sites in `bin/found-issues` plus `lib/detect-mode.sh:133`. The entry recorded *two* drifted
spellings; there are now **three**:

| Spelling | Sites |
|---|---|
| `[[ "$v" =~ ^[0-9]+$ ]] \|\| v=0` | 1042, 1930, 2027, 3687, 3806, 3807 (6) |
| `[[ -z "$v" \|\| ! "$v" =~ ^[0-9]+$ ]] && v=0` | 4092, 4100, 4102 (3) |
| `if [[ -z "$v" \|\| ! "$v" =~ ^[0-9]+$ ]]; then` (fallback branch) | 4143 (1) |

The `tr -d` whitespace workaround now appears at 5 sites (entry said 3): 2266, 4036, 4091,
4099, 4101. No `fi_to_int` exists.

**D4** — the hand-rolled `run` + `[ "$status" -ne 0 ]` idiom is now at **37** sites across
13 files (entry recorded 34+). `tests/helpers.bash` is 119 lines with no `fi_refute_match` /
`fi_refute_exists`.

**D5** — two independent halves:
- *Resolved:* the version skew that triggered it. Marketplace cache is now 2.1.1, byte-identical to main.
- *Still live:* the code defect. `FI_BIN` at `:52-57` still resolves PATH first and only falls back to
  `CLAUDE_PLUGIN_ROOT` when nothing is on PATH. At `:232-244` and `:261-272` only `rc=0` (with
  `Annotated`) and `rc=3` are handled — **rc=2 falls through with no ctx and no legacy fallback**,
  so auto-annotation dies silently against any older CLI on PATH.

---

## 3. Open issues

### #121 — sync false-closes spaced paths — **CONFIRMED, highest severity**

Reproduced end-to-end in a sandbox git repo against v2.1.1, both cited files present on disk:

```
BEFORE  - [open] 2026-08-10 src/config.ts:88 — control, normal path
        - [open] 2026-08-10 docs/handoff/HO production env setup.md:88 — token in plaintext
sync →  Synced. Closed: 1 (0 PR + 0 commit + 1 tombstone).
AFTER   - [open]  ... src/config.ts:88 — control, normal path
        - [fixed] ... docs/handoff/HO production env setup.md:88 — token in plaintext (closure: tombstone) (fixed: 2026-08-10)
```

The only difference between the two entries is the space in the filename, and the file
still exists. Parser probe confirms the root cause: `path=docs/handoff/HO`, `line=` (empty)
vs the hyphenated control's `path=docs/handoff/HO-production-env-setup.md`, `line=88`.

The reporter's line citations (`lib/parse-entries.sh:125`, `bin/found-issues:1908-1922`)
are accurate against main. `[!]` is confirmed ungated in the tombstone path.

### #123 — legacy colon-shaped locations — **CONFIRMED**

```
LendMatrix-svc:node_modules/dotenv (17.4.2)  → path=  line=
LendMatrix-svc:src/services/foo.ts:42        → path=  line=
CONTROL src/foo/bar.ts:42                    → path=src/foo/bar.ts  line=42
```

`fi_entry_loc` (`bin/found-issues:1154-1166`) does `[[ -z "$e_path" ]] && return 1`, and
`:1216` does `loc="$(fi_entry_loc "$line")" || continue` — so these entries never enter the
`--pick` candidate list. Impact claim holds.

*Silver lining:* an empty `path` also means the tombstone probe never runs, so unlike #121
these entries fail **open**. Nuisance, not data loss.

### #124 — command docs bypass the CLI — **PARTIALLY TRUE; premise is wrong**

Confirmed true:
- `commands/sync.md:4` ships `Edit` in `allowed-tools`.
- `commands/sync.md:47` instructs "edit the file: change `[open]` → `[fixed]` and append `(verified: ai) (fixed: YYYY-MM-DD)`".
- `commands/promote.md:4` ships `Edit, Write`; `:50` instructs "Append the entries to `docs/found-issues.md` (use `Edit` or `Write` …)".

**Confirmed false — the load-bearing premise:** `resolve` and `reopen` **do not exist**.

- No `cmd_resolve` / `cmd_reopen` defined anywhere.
- No `resolve)` / `reopen)` in the dispatch table.
- No usage text mentioning `found-issues resolve`.
- `bin/found-issues` is **4773 lines** — the cited `:5110`, `:5111`, `:2341` are past EOF.
- The installed cache copy is byte-identical to main, so this is not a source-vs-release skew.
- `promote)` is at `:4746`, not the cited `:5131`.

So the *impact* stands (shipped docs do instruct unserialized direct ledger writes), but the
*suggested fix* — "rewrite sync.md step 4 to call `found-issues resolve`" — is not actionable
as written. `resolve` would have to be built first. This reads as a fabricated-citation report
whose headline symptom happens to be real; the fix scope is materially larger than stated.

---

## 4. Open PR #122 — verified, but CI has never run

Fixes #121. Cross-repo from `jbelmana`, single commit `798b49b`, +83/−5, bumps 2.1.1 → 2.1.2.

**Freshness:** merge-base is `7513d1d` = current main HEAD. **0 commits behind.** No rebase needed.

**Verification performed locally:**

| Check | Result |
|---|---|
| Full suite, PR branch (bats 1.14.0, macOS) | **678 passing, 0 failing, exit 0** |
| PR's 3 new tests vs main's `bin/found-issues` | tests 20 and 22 **fail** — genuine regression tests |
| No-regression control (test 21, genuinely-missing spaced path still tombstones) | passes on both |
| bash 3.2 compat (macOS CI parity) | fix logic correct under `/bin/bash 3.2.57` |
| `path symbol ~1982-1989` form does not engage the guard | confirmed — `recovered_loc` empty, falls through |

**Design review:** the guard only engages when the parsed path has no spaces *and* the raw
location does, so every existing path is untouched. The parser is deliberately not widened,
which preserves dedup keys and the `path symbol ~range` forms. Scope is appropriately narrow —
the author explicitly held back issue #121's suggestions 2 and 3 (never auto-tombstone `[!]`,
fail-open on unresolvable paths) as policy changes.

**Why it is BLOCKED:** `0` check runs and `0` workflow runs against `798b49b`. Fork PR from a
first-time contributor, so workflows sit at the maintainer approval gate. Nothing has been
evaluated by CI.

**Note on coverage if approved:** per the two-tier matrix (`.github/workflows/test.yml`), a PR
run is **ubuntu-only**; the macos + windows + ubuntu matrix runs on push-to-main. Windows parity
for these tests — which create files and directories with spaces in their names — is unproven
either way. That is the residual risk.

**Recommendation:** approve workflows and merge, but not blind. The two-repo release coupling
applies (source PR, then marketplace PR in `AltDoug/claude-plugins`), and the version bump to
2.1.2 makes this a release.

---

## 5. Cross-check against recent merges

None of #116–#120 addressed D1–D5:

| PR | Scope | Touches a deferred entry? |
|---|---|---|
| #116 (v2.0.1) | `~`/`$VAR` tombstones, mid-symptom annotation tokens | No |
| #117 | CI two-tier OS matrix | No |
| #118 (v2.0.2) | `status` clean-ledger output | No |
| #119 (v2.1.0) | `annotate-pr` cross-repo refs | No |
| #120 (v2.1.1) | directory-path tombstones | No |

#116, #120 and PR #122 are all members of the same false-tombstone family
(`~`/`$VAR`, glob/brace, directory, whitespace). #121's framing — *never probe a
path you may have mangled* — is the accurate generalization.

---

## 6. Open items not tracked in the ledger

The three open GitHub issues have no corresponding `[open]` entries in
`docs/found-issues.md`. The ledger reads 0 open while three confirmed defects are
live. Worth deciding whether this repo dogfoods its own tracker for its own issues.
