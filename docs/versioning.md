# Versioning

This project follows [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html). Version strings are `MAJOR.MINOR.PATCH` (e.g. `1.1.0`).

Every release commit must update **three places in lockstep**:

1. `FI_VERSION` in `bin/found-issues` (line 9)
2. A new `## [X.Y.Z] — YYYY-MM-DD` section at the top of `CHANGELOG.md` (immediately after `## [Unreleased]`)
3. The "Status & roadmap" header in `README.md`

`scripts/check-version.sh` (run in CI) enforces invariants #1 and #2 plus the bump-classification rule below.

## When to bump which segment

| Segment | Bump when… | Concrete examples from this repo |
|---|---|---|
| **MAJOR** (`X.0.0`) | A change **breaks** existing users. Anyone with shell config, dotfile config, or scripts depending on the prior behavior must update them to keep working. | Renaming a slash command (`/found-issues:log` → `/found-issues:log-entry`). Removing a CLI subcommand. Changing the entry file format incompatibly. Changing an env-var name. Rejecting input that was previously accepted. |
| **MINOR** (`X.Y.0`) | You **add new functionality** that's backward-compatible — existing users can ignore it and nothing they had continues to work the same. | New CLI subcommand (`found-issues doctor`). New flag on an existing command (`defer --mute-until`). New lifecycle state (`[deferred]`). New env-var tunable. New optional annotation form. |
| **PATCH** (`X.Y.Z`) | You **fix a bug** or **polish UX** of existing functionality without adding or removing capability. | Fixing the `pre-branch-delete` false-positive (v1.0.6 #59). Renaming the segment residual label from "issues" to "other" when display rules change. Routing stderr-only feedback to stdout. Documentation-only changes. |

## Decision tree

```
Does the PR break any documented behavior or remove user-visible capability?
├── Yes  → MAJOR bump (X.0.0). Update migration notes in CHANGELOG.
└── No
    ├── Does the PR add a new subcommand, flag, lifecycle state, env-var,
    │   annotation form, or any other user-facing capability?
    │   ├── Yes  → MINOR bump (X.Y+1.0). CHANGELOG section MUST use `### Added`.
    │   └── No
    │       └── PATCH bump (X.Y.Z+1). CHANGELOG section uses `### Fixed`, `### Changed`,
    │           `### Removed` (deprecation only — actual removal is MAJOR), or
    │           `### Security`. **Must NOT contain `### Added`** —
    │           check-version.sh will fail CI.
```

## Pre-1.0 vs post-1.0

This project shipped 1.0.0 on 2026-05-09 (see CHANGELOG). Before that, `0.x.y` numbering was used without strict compatibility promises — that's the SemVer pre-release convention and it's correct.

**After 1.0.0, the rules above are binding.** A "small new feature in a hotfix-style release" is still a MINOR bump, not a PATCH. Mixing both in one release means it's MINOR.

## Historical mis-numbering: v1.0.5

The defer-recurrence-flow release (v1.0.5, 2026-05-10) **should have been v1.1.0** under strict SemVer:

- Added `defer` subcommand
- Added `promote-deferred` subcommand
- Added `[deferred]` lifecycle state
- Added two env-var tunables
- Added the `--reason` flag on defer

All purely additive — textbook MINOR.

The v1.0.5 tag is now permanent (SemVer requires version immutability — going back and renaming would break anyone pinned to `1.0.5`). The recalibration starts at v1.1.0 (today). The next *bug-only* release will be v1.1.1, the next *additive* release v1.2.0, and a hypothetical breaking change v2.0.0.

## What `check-version.sh` enforces

The script runs in CI on every PR and on pushes to `main`. It enforces:

1. **`FI_VERSION` ⟷ CHANGELOG consistency.** The version constant in `bin/found-issues` must equal the top-most `## [X.Y.Z]` section header in `CHANGELOG.md`. Catches "I bumped one but forgot the other" mistakes.
2. **Additive-needs-MINOR rule.** If the bump from the previous CHANGELOG entry is PATCH-only (X and Y unchanged, Z incremented), the latest section must NOT contain an `### Added` heading. Forces a MINOR bump for any release that adds capability.

The check intentionally does NOT verify MAJOR bumps for "breaking" changes — that classification requires human judgment ("is this breaking for *real* users?") that a script can't make. The decision tree above is the operator's responsibility.

## Working with the check

| Scenario | What to do |
|---|---|
| You bumped FI_VERSION but forgot the CHANGELOG entry | Add the `## [X.Y.Z] — YYYY-MM-DD` header (and section content) at the top of CHANGELOG. |
| Your release adds a new flag but you bumped PATCH | Either bump MINOR (`X.Y.Z` → `X.Y+1.0`) **or** split the PR — ship the feature in a MINOR-bump PR and ship the unrelated fixes in a PATCH-bump PR. |
| The previous release was mis-numbered (e.g. additive features under a PATCH bump in the past) | The check looks only at the **current** bump, not history. Mis-numbered past releases don't propagate failures forward. |
| You're adding `### Added` content but the new functionality is actually a bug fix (e.g. "Added: workaround for X bug") | Rename the section to `### Fixed`. `### Added` is reserved for genuinely new capability. |

## Release checklist

When opening a release PR:

1. [ ] Edit `FI_VERSION` in `bin/found-issues`
2. [ ] Add a `## [X.Y.Z] — YYYY-MM-DD` section in `CHANGELOG.md` with the right `### Added` / `### Changed` / `### Fixed` / `### Removed` / `### Security` subsections
3. [ ] Update the `## Status & roadmap` header in `README.md`
4. [ ] Run `bash scripts/check-version.sh` locally — must pass before push
5. [ ] PR title: `release: vX.Y.Z`
6. [ ] After merge: `git tag -a vX.Y.Z -m "vX.Y.Z" <merge_sha> && git push origin vX.Y.Z`
