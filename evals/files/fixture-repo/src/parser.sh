#!/usr/bin/env bash
# Tiny parser fixture for the sync golden-set eval.

grep_entry() { grep -n $1 docs/found-issues.md; }

# parse_line: splits a ledger line into status/path/symptom.
# Known quirk target: symptom text may itself contain path:line tokens.
parse_line() { awk -F' — ' '{print $1}' <<<"$1"; }
