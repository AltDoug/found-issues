#!/usr/bin/env bash
# fi-sandbox.sh — drive THIS checkout of found-issues in a throwaway world.
#
# Every command runs under `env -i`: a temp HOME, a scratch git repo, this
# checkout's bin/ first on PATH, the repo's own gh mock (tests/bin-shims/gh),
# refusing stand-ins for claude and codex, auto-fix off, network git blocked.
# Each call is appended with its exit code to the run's evidence transcript.
set -euo pipefail

KIT_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FI_ROOT="$(git -C "$KIT_SCRIPTS" rev-parse --show-toplevel)"
MARKER=".fi-sandbox"

usage() {
  cat <<'EOF'
fi-sandbox.sh new <slug> [--github | --local] [--keep]
                                                make a sandbox; prints SB= and EVIDENCE=. --keep also
                                                records it, so later calls can name it <slug> instead of <sb>
fi-sandbox.sh doctor [<sb>]                     read-only health check (checkout, or one sandbox)
fi-sandbox.sh run  <sb> '<shell command>'       run it in the sandbox repo; recorded
fi-sandbox.sh hook <sb> [VAR=x ...] <hook-name> '<json>'
                                                pipe it to hooks/<hook-name>.sh; fills __REPO__ __SB__ __HEAD__
fi-sandbox.sh snap <sb> <label>                 copy the ledger and git state into the evidence folder
fi-sandbox.sh rm   <sb>                         delete the sandbox (never the evidence)

Checks on the last run or hook (its stdout and stderr, not the command line), or, with
<file> (relative to the sandbox repo, or absolute), on that file. Each exits 1 and says why.
fi-sandbox.sh has    <sb> '<text>' [<file>]     the text is there
fi-sandbox.sh lacks  <sb> '<text>' [<file>]     the text is not there (a missing file fails)
fi-sandbox.sh match  <sb> '<regex>' [<file>]    a line matches the extended regular expression
fi-sandbox.sh count  <sb> <n> '<text>' [<file>] exactly n lines hold the text
fi-sandbox.sh is     <sb> '<whole output>'      the output is exactly this
fi-sandbox.sh rc     <sb> <n>                   the exit code was n
fi-sandbox.sh silent <sb>                       exit 0 and no output at all

Checks that need no earlier run:
fi-sandbox.sh exists|executable|gone <sb> <file> the file or folder is there / can be run / is not there
fi-sandbox.sh registered <sb> <event> <hook-name> [<tool>]
                                                hooks/hooks.json names the hook for that event (and tool)
EOF
}

die() { printf 'fi-sandbox: %s\n' "$*" >&2; exit 2; }

# Where `new --keep` records a sandbox, so a command pasted into a new shell can
# name it by slug. One file per slug, holding the sandbox path.
KEEP_DIR="$FI_ROOT/.verify/kept"

# Load SB, REPO, EVIDENCE from a sandbox this script made (a path, or a kept slug).
load() {
  SB="${1:-}"
  if [[ "$SB" =~ ^[a-z0-9][a-z0-9-]*$ && -f "$KEEP_DIR/$SB" ]]; then SB="$(cat "$KEEP_DIR/$SB")"; fi
  [[ -n "$SB" && -f "$SB/$MARKER" ]] || die "not a sandbox made by this script: ${SB:-<none given>}"
  SB="$(cd "$SB" && pwd -P)"
  REPO="$SB/repo"
  EVIDENCE="$(sed -n 's/^evidence=//p' "$SB/$MARKER")"
  [[ -d "$EVIDENCE" ]] || die "evidence folder is gone: $EVIDENCE"
}

tool_dir() {
  local p
  p="$(command -v "$1")" || die "needed tool not found: $1"
  dirname "$p"
}

# The whole environment of a sandboxed command. Nothing is inherited.
sandbox_env() {
  local path="$SB/shims:$FI_ROOT/bin" t
  for t in bash jq git node python3; do
    command -v "$t" >/dev/null 2>&1 && path="$path:$(tool_dir "$t")"
  done
  ENV_ARGS=(
    "HOME=$SB/home" "TMPDIR=$SB/tmp" "PATH=$path:/usr/bin:/bin:/usr/sbin:/sbin"
    "LANG=en_US.UTF-8" "TERM=dumb" "USER=fi-sandbox"
    "SB=$SB" "REPO=$REPO" "FI_ROOT=$FI_ROOT" "EVIDENCE=$EVIDENCE"
    "FOUND_ISSUES_BIN=$FI_ROOT/bin/found-issues" "FOUND_ISSUES_LIB_DIR=$FI_ROOT/lib"
    "FOUND_ISSUES_AUTOFIX=off" "FOUND_ISSUES_SEGMENT_AUTOSYNC=off"
    "GIT_CONFIG_NOSYSTEM=1" "GIT_ALLOW_PROTOCOL=file" "GH_MOCK_TRACE=$SB/gh-calls.log"
  )
}

refusing_stub() {
  printf '#!/bin/sh\necho "fi-sandbox: refusing to run %s (paid engine)" >&2\nexit 97\n' "$1" > "$SB/shims/$1"
  chmod +x "$SB/shims/$1"
}

make_repo() {
  local kind="$1"
  mkdir -p "$REPO/src"
  printf '#!/usr/bin/env bash\nname="$1"\necho "hello $name"\n# end\n' > "$REPO/src/app.sh"
  printf 'def divide(a, b):\n    return a / b\n\n\ndef first(items):\n    return items[0]\n' > "$REPO/src/util.py"
  [[ "$kind" == local ]] && return 0
  env -i "${ENV_ARGS[@]}" bash -c '
    cd "$REPO" && git init -q -b main && git add -A && git commit -q -m "init"'
  [[ "$kind" == github ]] || return 0
  env -i "${ENV_ARGS[@]}" bash -c '
    cd "$REPO" && git remote add origin https://github.com/fi-sandbox/demo.git \
      && git update-ref refs/remotes/origin/main HEAD \
      && git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main'
}

cmd_new() {
  local slug="${1:-}" kind=git keep=0 stamp base n=2 opt old
  [[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "new: give a slug (lower-case, hyphens)"
  shift
  for opt in "$@"; do
    case "$opt" in
      --github) kind=github ;;
      --local) kind=local ;;
      --keep) keep=1 ;;
      *) die "new: unknown option $opt" ;;
    esac
  done
  if (( keep )) && [[ -f "$KEEP_DIR/$slug" ]]; then
    old="$(cat "$KEEP_DIR/$slug")"
    [[ -f "$old/$MARKER" ]] && die "new: '$slug' is already kept at $old (rm it, or pick another slug)"
  fi
  stamp="$(date +%Y-%m-%d-%H%M%S)"
  base="$FI_ROOT/.verify/evidence/$stamp-$slug"
  EVIDENCE="$base"
  while [[ -e "$EVIDENCE" ]]; do EVIDENCE="$base-$n"; n=$((n + 1)); done
  mkdir -p "$EVIDENCE"
  SB="$(mktemp -d "${TMPDIR:-/tmp}/fi-sandbox.XXXXXX")"
  SB="$(cd "$SB" && pwd -P)"
  REPO="$SB/repo"
  mkdir -p "$SB/home" "$SB/tmp" "$SB/shims" "$REPO"
  printf 'evidence=%s\n' "$EVIDENCE" > "$SB/$MARKER"
  printf '[user]\n\tname = Sandbox\n\temail = sandbox@example.com\n[commit]\n\tgpgsign = false\n' > "$SB/home/.gitconfig"
  ln -s "$FI_ROOT/tests/bin-shims/gh" "$SB/shims/gh"
  refusing_stub claude
  refusing_stub codex
  sandbox_env
  make_repo "$kind"
  printf 'checkout %s @ %s (dirty files: %s)\nsandbox kind: %s\n' "$FI_ROOT" \
    "$(git -C "$FI_ROOT" rev-parse --short HEAD)" \
    "$(git -C "$FI_ROOT" status --porcelain -- bin lib hooks | wc -l | tr -d ' ')" "$kind" \
    > "$EVIDENCE/transcript.txt"
  if (( keep )); then mkdir -p "$KEEP_DIR"; printf '%s' "$SB" > "$KEEP_DIR/$slug"; fi
  printf 'SB=%s\nEVIDENCE=%s\n' "$SB" "$EVIDENCE"
  # stderr too, so the paths show even under eval "$(fi-sandbox.sh new ...)".
  printf 'sandbox ready: SB=%s EVIDENCE=%s\n' "$SB" "$EVIDENCE" >&2
}

# record <title> <stdin-file> <command string>
# The title (the command line) goes to stderr and the transcript, never to stdout:
# a check on captured output must not be able to match the command that made it.
record() {
  local title="$1" input="$2" command="$3" rc=0 out err
  out="$SB/tmp/.out"; err="$SB/tmp/.err"
  env -i "${ENV_ARGS[@]}" bash -c 'cd "$REPO" || exit 98; eval "$1"' fi-sandbox "$command" \
    < "$input" > "$out" 2> "$err" || rc=$?
  cat "$out" "$err" > "$SB/tmp/.last"
  printf '%s' "$rc" > "$SB/tmp/.rc"
  printf '\n$ %s\n' "$title" | tee -a "$EVIDENCE/transcript.txt" >&2
  {
    cat "$out"
    if [[ -s "$err" ]]; then printf '[stderr]\n'; cat "$err"; fi
    printf '[exit %d]\n' "$rc"
  } | tee -a "$EVIDENCE/transcript.txt"
  return "$rc"
}

# A run that never starts must not leave the previous result for a check to read.
forget_last() { rm -f "$SB/tmp/.last" "$SB/tmp/.rc"; }

# expect <kind> <sb> [args...]: one assertion, recorded in the transcript.
cmd_expect() {
  local kind="$1" target what ok=0 n="" text="" file=""
  shift
  load "${1:-}"; shift
  [[ -f "$SB/tmp/.rc" ]] || die "$kind: no run or hook recorded in this sandbox yet"
  case "$kind" in
    has|lacks|match) text="${1:-}"; file="${2:-}"; [[ -n "$text" ]] || die "$kind: give the text" ;;
    count) n="${1:-}"; text="${2:-}"; file="${3:-}"; [[ "$n" =~ ^[0-9]+$ && -n "$text" ]] || die "count: <sb> <n> <text> [file]" ;;
    is) text="${1-}" ;;
    rc) n="${1:-}"; [[ "$n" =~ ^[0-9]+$ ]] || die "rc: give a number" ;;
  esac
  target="$SB/tmp/.last"
  case "$file" in
    "") ;;
    /*) target="$file" ;;
    *) target="$REPO/$file" ;;
  esac
  what="${file:-last output}"
  if [[ -f "$target" ]]; then
    case "$kind" in
      has) grep -qF -- "$text" "$target" && ok=1 ;;
      lacks) grep -qF -- "$text" "$target" || ok=1 ;;
      match) grep -qE -- "$text" "$target" && ok=1 ;;
      count) [[ "$(grep -cF -- "$text" "$target" || true)" == "$n" ]] && ok=1 ;;
      is) [[ "$(cat "$target")" == "$text" ]] && ok=1 ;;
      rc) [[ "$(cat "$SB/tmp/.rc")" == "$n" ]] && ok=1 ;;
      silent) [[ ! -s "$target" && "$(cat "$SB/tmp/.rc")" == 0 ]] && ok=1 ;;
    esac
  fi
  local desc="$kind${n:+ $n}${text:+ '$text'} ($what)"
  if (( ok )); then
    printf 'check ok: %s\n' "$desc" | tee -a "$EVIDENCE/transcript.txt"
    return 0
  fi
  {
    printf 'CHECK FAILED: %s\n' "$desc"
    if [[ -f "$target" ]]; then
      printf -- '--- exit %s, and %s holds:\n' "$(cat "$SB/tmp/.rc")" "$what"
      tail -n 20 "$target"
    else
      printf -- '--- no such file: %s\n' "$what"
    fi
  } | tee -a "$EVIDENCE/transcript.txt"
  return 1
}

verdict() {
  local ok="$1" desc="$2"
  if (( ok )); then printf 'check ok: %s\n' "$desc" | tee -a "$EVIDENCE/transcript.txt"; return 0; fi
  printf 'CHECK FAILED: %s\n' "$desc" | tee -a "$EVIDENCE/transcript.txt"
  return 1
}

cmd_path_check() {
  local kind="$1" file target ok=0
  load "${2:-}"; file="${3:-}"
  [[ -n "$file" ]] || die "$kind: give a path"
  case "$file" in /*) target="$file" ;; *) target="$REPO/$file" ;; esac
  case "$kind" in
    exists) [[ -e "$target" ]] && ok=1 ;;
    executable) [[ -f "$target" && -x "$target" ]] && ok=1 ;;
    gone) [[ -e "$target" || -L "$target" ]] || ok=1 ;;
  esac
  verdict "$ok" "$kind $target"
}

# The hooks a drive pipes payloads to are only live if the manifest names them.
cmd_registered() {
  load "${1:-}"
  local event="${2:-}" name="${3:-}" tool="${4:-}" ok=0
  [[ -n "$event" && -n "$name" ]] || die "registered: <sb> <event> <hook-name> [<tool>]"
  if jq -e --arg e "$event" --arg h "/hooks/$name.sh" --arg t "$tool" '
      [ .hooks[$e][]? | select($t == "" or ((.matcher // "") | split("|") | index($t)))
        | .hooks[].command | select(contains($h)) ] | length > 0
    ' "$FI_ROOT/hooks/hooks.json" >/dev/null 2>&1; then ok=1; fi
  verdict "$ok" "hooks.json registers hooks/$name.sh for $event${tool:+ ($tool)}"
}

cmd_run() {
  load "${1:-}"; sandbox_env; forget_last
  [[ -n "${2:-}" ]] || die "run: give one quoted shell command"
  [[ $# -eq 2 ]] || die "run: quote the whole command as ONE argument"
  record "$2" /dev/null "$2"
}

cmd_hook() {
  load "${1:-}"; sandbox_env; forget_last
  shift
  local shown="" v
  # Hooks read their switches at fire time: hook <sb> NAME=value ... <hook> '<json>'
  while [[ "${1:-}" =~ ^[A-Z_][A-Z0-9_]*= ]]; do
    v="$1"; shift
    [[ "$v" != FOUND_ISSUES_AUTOFIX=* && "$v" != HOME=* && "$v" != PATH=* ]] || die "hook: $v is fixed by the sandbox"
    ENV_ARGS+=("$v"); shown="$shown$v "
  done
  local name="${1:-}" payload="${2:-}"
  [[ -f "$FI_ROOT/hooks/$name.sh" ]] || die "hook: no such hook: hooks/$name.sh"
  [[ -n "$payload" ]] || die "hook: give the JSON payload (use '{}' for none)"
  payload="${payload//__REPO__/$REPO}"
  payload="${payload//__SB__/$SB}"
  if [[ "$payload" == *__HEAD__* ]]; then
    payload="${payload//__HEAD__/$(git -C "$REPO" rev-parse --short HEAD)}"
  fi
  printf '%s' "$payload" | jq -e . >/dev/null 2>&1 || die "hook: payload is not valid JSON"
  printf '%s' "$payload" > "$SB/tmp/.payload.json"
  record "${shown}hooks/$name.sh  <<<  $payload" "$SB/tmp/.payload.json" "\"\$FI_ROOT/hooks/$name.sh\""
}

cmd_snap() {
  load "${1:-}"
  local label="${2:-}" f
  [[ "$label" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "snap: give a label (lower-case, hyphens)"
  for f in docs/found-issues.md docs/found-issues-archive.md .found-issues.md; do
    [[ -f "$REPO/$f" ]] && cp "$REPO/$f" "$EVIDENCE/$label.$(basename "$f" | sed 's/^\.//')"
  done
  if [[ -d "$REPO/.git" ]]; then
    { git -C "$REPO" status --short; git -C "$REPO" log --oneline -10; git -C "$REPO" branch -a; } \
      > "$EVIDENCE/$label.git.txt"
  fi
  [[ -f "$SB/gh-calls.log" ]] && cp "$SB/gh-calls.log" "$EVIDENCE/$label.gh-calls.log"
  printf 'snapshot %s -> %s\n' "$label" "$EVIDENCE"
  local found=0
  for f in "$EVIDENCE/$label".*; do
    [[ -e "$f" ]] && { printf '%s\n' "${f##*/}"; found=1; }
  done
  (( found )) || printf '  (nothing to copy: no ledger, no git repo, no gh calls)\n'
}

# check <label> <detail> <test command...>. The test runs inside the `if`, so a
# failing one prints FAIL instead of ending the script under set -e.
check() {
  local label="$1" detail="$2"
  shift 2
  if "$@" >/dev/null 2>&1; then
    printf 'ok    %s: %s\n' "$label" "$detail"
  else
    printf 'FAIL  %s: %s\n' "$label" "$detail"
    DOCTOR_FAIL=1
  fi
}

is_mock() { [[ "$1" == "$2" && -x "$1" ]]; }
remote_is_safe() { [[ -z "$1" || "$1" == https://github.com/fi-sandbox/demo.git ]]; }

doctor_checkout() {
  local t v pv stray="" f
  for t in jq git awk; do
    check "tool $t" "$(command -v "$t" || echo missing)" command -v "$t"
  done
  check "bash (4+ needed)" "$BASH_VERSION" test "${BASH_VERSINFO[0]}" -ge 4
  check "checkout CLI" "$FI_ROOT/bin/found-issues" test -x "$FI_ROOT/bin/found-issues"
  # Stray files in bin/ (e.g. a left-behind bin/awk) shadow real tools.
  for f in "$FI_ROOT"/bin/* "$FI_ROOT"/bin/.[!.]*; do
    [[ -e "$f" && "${f##*/}" != found-issues ]] && stray="$stray${f##*/} "
  done
  check "bin/ is clean" "${stray:-only found-issues}" test -z "$stray"
  v="$(sed -n 's/^readonly FI_VERSION="\(.*\)"$/\1/p' "$FI_ROOT/bin/found-issues")"
  pv="$(jq -r .version "$FI_ROOT/.claude-plugin/plugin.json" 2>/dev/null || true)"
  check "version" "FI_VERSION=$v plugin.json=$pv" test -n "$v" -a "$v" = "$pv"
  printf 'info  checkout: %s %s\n' "$(git -C "$FI_ROOT" branch --show-current)" "$(git -C "$FI_ROOT" log -1 --oneline)"
  printf 'info  found-issues on YOUR PATH (not what the sandbox runs): %s\n' "$(command -v found-issues || echo none)"
}

doctor_sandbox() {
  local got t
  sandbox_env
  probe() { env -i "${ENV_ARGS[@]}" bash -c 'cd "$REPO" && eval "$1"' probe "$1" 2>/dev/null || true; }
  got="$(probe 'command -v found-issues')"
  check "sandbox CLI is this checkout" "$got" test "$got" = "$FI_ROOT/bin/found-issues"
  got="$(probe 'command -v gh')"
  check "gh is the mock" "${got:-none}" is_mock "$got" "$SB/shims/gh"
  for t in claude codex; do
    got="$(probe "command -v $t")"
    check "$t is refused" "${got:-none}" is_mock "$got" "$SB/shims/$t"
  done
  got="$(probe 'printf %s "$HOME"')"
  check "HOME is in the sandbox" "$got" test "$got" = "$SB/home"
  got="$(probe 'printf %s "$FOUND_ISSUES_AUTOFIX"')"
  check "auto-fix off" "$got" test "$got" = off
  got="$(probe 'env | grep -c -E "^(CLAUDE|CODEX|XDG)_" ')"
  check "no CLAUDE_/CODEX_/XDG_ variables" "count=$got" test "$got" = 0
  if [[ -d "$REPO/.git" ]]; then
    got="$(probe 'git rev-parse --show-toplevel')"
    check "git root is the scratch repo" "$got" test "$got" = "$REPO"
    got="$(probe 'git remote get-url origin')"
    check "remote is fake or absent" "${got:-none}" remote_is_safe "$got"
  else
    got="$(probe 'git rev-parse --show-toplevel')"
    check "no git repo (local mode)" "${got:-none}" test -z "$got"
  fi
}

cmd_doctor() {
  DOCTOR_FAIL=0
  doctor_checkout
  if [[ -n "${1:-}" ]]; then load "$1"; doctor_sandbox; fi
  if (( DOCTOR_FAIL )); then echo "DOCTOR: NOT worth driving"; return 1; fi
  echo "DOCTOR: ok"
}

# Processes still using the sandbox: working folder inside it (a background sync
# names only the checkout on its command line), or the path on the command line.
users_of_sandbox() {
  local pids=""
  if command -v lsof >/dev/null 2>&1; then
    pids="$(lsof -a -d cwd -Fpn 2>/dev/null | awk -v sb="n$SB" '
      /^p/ { pid = substr($0, 2) }
      /^n/ { if ($0 == sb || index($0, sb "/") == 1) print pid }' || true)"
  fi
  pids="$pids $(ps -axo pid=,command= | grep -F -- "$SB" | grep -v -e 'grep -F' -e 'fi-sandbox.sh' | awk '{print $1}' || true)"
  printf '%s\n' $pids | sort -u | grep -E '^[0-9]+$' || true
}

cmd_rm() {
  load "${1:-}"
  local left p try
  # Report only, never stop anything. A short background sync gets 10 s.
  for try in 1 2 3 4 5 6 7 8 9 10 11; do
    left="$(users_of_sandbox)"
    [[ -z "$left" ]] && break
    (( try == 11 )) || sleep 1
  done
  if [[ -n "$left" ]]; then
    printf 'fi-sandbox: processes still using this sandbox (wait, then re-run rm):\n' >&2
    for p in $left; do ps -o pid=,command= -p "$p" >&2 || true; done
    return 1
  fi
  rm -rf "$SB"
  for p in "$KEEP_DIR"/*; do
    if [[ -f "$p" && "$(cat "$p")" == "$SB" ]]; then rm -f "$p"; fi
  done
  printf 'removed %s\nevidence kept: %s\n' "$SB" "$EVIDENCE"
}

main() {
  local sub="${1:-}"
  [[ -n "$sub" ]] || { usage; return 2; }
  shift
  case "$sub" in
    new) cmd_new "$@" ;;
    doctor) cmd_doctor "$@" ;;
    run) cmd_run "$@" ;;
    hook) cmd_hook "$@" ;;
    snap) cmd_snap "$@" ;;
    has|lacks|match|count|is|rc|silent) cmd_expect "$sub" "$@" ;;
    exists|executable|gone) cmd_path_check "$sub" "$@" ;;
    registered) cmd_registered "$@" ;;
    rm) cmd_rm "$@" ;;
    -h|--help|help) usage ;;
    *) usage; die "unknown subcommand: $sub" ;;
  esac
}

main "$@"
