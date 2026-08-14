#!/usr/bin/env bats
# Static guards over .github/workflows/test.yml.
#
# The workflow is the only thing standing between a broken commit and main, and
# nothing else in the suite asserts on it. These are cheap structural checks of
# the two properties that, when wrong, fail SILENTLY -- CI stays green and the
# absence of verification is what goes unnoticed.

load 'helpers'

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/test.yml"

@test "ci-workflow: the tests workflow exists" {
  [ -f "$WORKFLOW" ]
}

@test "ci-workflow: push-to-main runs are never cancelled by a later push" {
  # With an unconditional `cancel-in-progress: true`, a push landing on main
  # while the previous push's matrix is still running cancels it. The cancelled
  # run's `ci` correctly reports failure, but the NEWER run owns the branch
  # head's status -- and a docs-only push skips every job and reports success.
  # Main then reads green having never run bats on macOS or Windows.
  #
  # Hit for real 2026-08-11: the #130 ledger flip cancelled the v2.2.1 matrix
  # (#129) two minutes after it merged. Recovered by re-running by hand.
  #
  # PR runs SHOULD still cancel -- fix-up commits arrive in quick succession
  # there and stale results are pure waste -- so this asserts the guard is
  # event-conditional, not simply removed.
  local line
  line="$(grep -E '^[[:space:]]*cancel-in-progress:' "$WORKFLOW")"
  [ -n "$line" ]
  if [[ "$line" == *"true"* && "$line" != *"github.event_name"* ]]; then
    printf 'cancel-in-progress is unconditionally true: %s\n' "$line" >&2
    printf 'A push to main can then cancel the previous push matrix and main goes green unverified.\n' >&2
    return 1
  fi
  [[ "$line" == *"github.event_name"* ]]
  [[ "$line" == *"!="* ]]
  [[ "$line" == *"push"* ]]
}

@test "ci-workflow: push runs get a per-SHA concurrency group so a queued run is never displaced" {
  # cancel-in-progress: false protects a RUNNING push matrix but not a PENDING
  # one: GitHub keeps at most ONE queued run per concurrency group, so while
  # run A is in_progress and run B sits queued behind it, a third push CANCELS
  # the queued B before it starts (zero jobs ran). Hit for real 2026-08-12:
  # the docs-only #147 push displaced the queued v2.2.7 matrix outright; the
  # replacement run then skipped every bats job via the path filter while `ci`
  # reported success, so main showed green having never run bats on macOS or
  # Windows for v2.2.7.
  #
  # The fix keys push runs by SHA: every push owns its own group, nothing
  # queues behind anything, and displacement is structurally impossible. The
  # sha suffix must be CONDITIONAL on push -- an unconditional sha would give
  # every PR fix-up commit its own group too, and stale PR runs would pile up
  # instead of cancelling (the waste the PR grouping exists to prevent).
  local line
  line="$(grep -E '^[[:space:]]*group:' "$WORKFLOW")"
  [ -n "$line" ]
  [[ "$line" == *"github.sha"* ]]
  [[ "$line" == *"github.event_name == 'push' && github.sha"* ]]
}

@test "ci-workflow: the ci aggregator still blocks on a cancelled job" {
  # `skipped` is legitimate (the path filter excludes docs-only changes), but
  # `cancelled` must never read as success -- that is the state a cancelled
  # matrix leaves behind, and treating it as passing would hide exactly the
  # failure the guard above prevents.
  grep -Fq 'success|skipped)' "$WORKFLOW"
  grep -Fq 'failed or was cancelled' "$WORKFLOW"
}
