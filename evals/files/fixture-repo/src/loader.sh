#!/usr/bin/env bash
# Config loader fixture for the sync golden-set eval.
CONFIG_PATH="${1:-./config.env}"

load_config() {
  # Existence guard — added AFTER the ledger entry describing its absence
  # was written; phase-2 AI verification should see it and flip that entry.
  [ -f "$CONFIG_PATH" ] || return 1
  . "$CONFIG_PATH"
}
