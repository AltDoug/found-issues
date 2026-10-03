#!/usr/bin/env bats
# Stable Codex hook shims (2026-10-03). Codex's plugin cache path embeds the
# version (…/found-issues/2.10.0/), deletes the old version's dir on update,
# and pins hook TRUST to the hooks.json entry text. Entries pointing straight
# into the cache therefore went stale on every update, and re-wiring them
# changed the entry text and voided trust — a /hooks review per release.
# hooks.json now points at shims under $CODEX_HOME/found-issues/hooks/ that
# resolve the newest cached version at run time.

load 'helpers'

setup() {
  fi_setup_tmp
  CODEX_HOME="$TMP/codex-home"
  mkdir -p "$CODEX_HOME"
}
teardown() { fi_teardown_tmp; }

# A fake cached plugin version whose hooks print "<version> <hook>".
fake_version() {
  local v="$1" root="$CODEX_HOME/plugins/cache/altdoug-plugins/found-issues/$1"
  mkdir -p "$root/hooks" "$root/bin" "$root/lib"
  cp "$TEST_REPO_ROOT/bin/found-issues" "$root/bin/"
  cp "$TEST_REPO_ROOT"/lib/*.sh "$root/lib/"
  local h
  for h in session-start format-enforcer pre-branch-delete post-bash-dispatch stop-reminder; do
    printf '#!/usr/bin/env bash\ncat >/dev/null\necho "%s %s harness=$FOUND_ISSUES_HARNESS"\n' "$v" "$h" > "$root/hooks/$h.sh"
  done
  printf '%s' "$root"
}

shim_cmd() { jq -r ".hooks.$1[0].hooks[0].command" "$CODEX_HOME/hooks.json"; }

@test "install-codex-hooks: hooks.json points at stable shims, not the versioned cache" {
  root="$(fake_version 2.9.3)"
  run bash "$root/bin/found-issues" install-codex-hooks --codex-home "$CODEX_HOME"
  [ "$status" -eq 0 ]
  [[ "$(shim_cmd SessionStart)" == *"$CODEX_HOME/found-issues/hooks/session-start.sh'" ]]
  [[ "$(shim_cmd Stop)" != *"/2.9.3/"* ]]
  [ -x "$CODEX_HOME/found-issues/hooks/stop-reminder.sh" ]
}

@test "shim: runs the NEWEST cached version (numeric, not lexical), stdin and env intact" {
  root="$(fake_version 2.9.3)"
  bash "$root/bin/found-issues" install-codex-hooks --codex-home "$CODEX_HOME" >/dev/null
  fake_version 2.10.0 >/dev/null
  run bash -c "echo '{}' | env FOUND_ISSUES_HARNESS=codex bash '$CODEX_HOME/found-issues/hooks/session-start.sh'"
  [ "$status" -eq 0 ]
  [ "$output" = "2.10.0 session-start harness=codex" ]
}

@test "re-install from a newer version leaves every hooks.json entry byte-identical (trust survives)" {
  root="$(fake_version 2.9.3)"
  bash "$root/bin/found-issues" install-codex-hooks --codex-home "$CODEX_HOME" >/dev/null
  cp "$CODEX_HOME/hooks.json" "$TMP/before.json"
  root2="$(fake_version 2.10.0)"
  rm -rf "$root"   # Codex deletes the old version's dir on update
  bash "$root2/bin/found-issues" install-codex-hooks --codex-home "$CODEX_HOME" >/dev/null
  cmp "$TMP/before.json" "$CODEX_HOME/hooks.json"
}

@test "shim: after the old version dir is deleted it follows the update without re-install" {
  root="$(fake_version 2.9.3)"
  bash "$root/bin/found-issues" install-codex-hooks --codex-home "$CODEX_HOME" >/dev/null
  fake_version 2.10.0 >/dev/null
  rm -rf "$root"
  run bash -c "echo '{}' | bash '$CODEX_HOME/found-issues/hooks/stop-reminder.sh'"
  [ "$output" = "2.10.0 stop-reminder harness=" ]
}

@test "shim: installed from a checkout outside the cache, it runs that checkout" {
  fi_run install-codex-hooks --codex-home "$CODEX_HOME"
  [ "$status" -eq 0 ]
  run env FOUND_ISSUES_SHIM_RESOLVE=1 bash "$CODEX_HOME/found-issues/hooks/session-start.sh"
  [ "$output" = "$(cd "$TEST_REPO_ROOT" && pwd -P)" ]
}

@test "shim: a missing target fails open with one stderr line" {
  root="$(fake_version 2.9.3)"
  bash "$root/bin/found-issues" install-codex-hooks --codex-home "$CODEX_HOME" >/dev/null
  rm -rf "$CODEX_HOME/plugins"
  run bash -c "echo '{}' | bash '$CODEX_HOME/found-issues/hooks/pre-branch-delete.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"install-codex-hooks"* ]]
}

@test "doctor: a shim that resolves to nothing is reported stale" {
  root="$(fake_version 2.9.3)"
  bash "$root/bin/found-issues" install-codex-hooks --codex-home "$CODEX_HOME" >/dev/null
  rm -rf "$CODEX_HOME/plugins/cache/altdoug-plugins/found-issues/2.9.3"
  mkdir -p "$CODEX_HOME/plugins/cache/altdoug-plugins/found-issues"   # plugin still "installed"
  run env FOUND_ISSUES_CODEX_HOME="$CODEX_HOME" HOME="$TMP" bash "$FI_BIN" doctor
  [[ "$output" == *"no longer exist"* ]]
}

@test "uninstall-codex-hooks removes the shims too" {
  fi_run install-codex-hooks --codex-home "$CODEX_HOME"
  [ -d "$CODEX_HOME/found-issues/hooks" ]
  fi_run uninstall-codex-hooks --codex-home "$CODEX_HOME"
  [ "$status" -eq 0 ]
  [ ! -e "$CODEX_HOME/found-issues/hooks" ]
}
