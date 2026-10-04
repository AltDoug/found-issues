#!/usr/bin/env bash
# autofix-tags.sh — v3.0.0 fix tags: off-limits classification, tag-text
# sanitizing, and the one string-level writer of an entry's tag groups.
#
# Sourced by bin/found-issues. Defines functions only.
# Compatible with bash 3.2+ (macOS system bash). Builtin-only except
# fi_offlimits_check's single `git ls-files`.
#
# Spec: docs/superpowers/specs/2026-10-03-autofix-v3-design.md §3.
#
# Functions:
#   fi_offlimits_category <path>
#   fi_offlimits_check <path> <repo_root>
#   fi_tag_text <text>
#   fi_tag_resolve <kind> <value> <path> <repo_root>
#   fi_entry_retag <line> <kind> <value>
#   fi_until_due <until-spec> <today>

# shellcheck disable=SC2034,SC2154  # cross-file globals: FI_TAG_* are read by tag.sh/log.sh/decide.sh; _fi_pr_ans is set by sync.sh _fi_pr_info

# Off-limits paths are never auto-fixed, whatever the logging agent tagged:
# a wrong guess there costs a broken pipeline, a leaked secret or a bad
# migration (spec §3.3). Matching is by exact name or whole path segment so
# author.py, clock.py and migrate_helpers.py are not caught.
fi_offlimits_category() {
  local p="$1"
  [[ -z "$p" ]] && return 1
  case "$p" in
    /*|../*|*/../*) printf 'outside-repo'; return 0 ;;
  esac
  case "/$p/" in
    */.github/*|*/.circleci/*) printf 'ci'; return 0 ;;
    */migrations/*|*/db/migrate/*) printf 'migrations'; return 0 ;;
  esac
  local base="${p##*/}"
  case "$base" in
    .gitlab-ci*|Jenkinsfile) printf 'ci'; return 0 ;;
    .env|.env.*|*.pem|*.key) printf 'secrets'; return 0 ;;
    package.json|package-lock.json|yarn.lock|pnpm-lock.yaml|bun.lock|bun.lockb|\
    go.mod|go.sum|Cargo.toml|Cargo.lock|pyproject.toml|poetry.lock|uv.lock|\
    requirements*.txt|Gemfile|Gemfile.lock)
      printf 'dependencies'; return 0 ;;
  esac
  local rest="$p" seg stem
  while [[ -n "$rest" ]]; do
    seg="${rest%%/*}"
    if [[ "$rest" == */* ]]; then rest="${rest#*/}"; else rest=""; fi
    stem="${seg%%.*}"
    case "$stem" in
      auth|secret|secrets|credential|credentials) printf 'secrets'; return 0 ;;
    esac
  done
  return 1
}

# Off-limits plus the two checks that need context: an entry with no file
# cannot be fixed by a worker that starts from the cited file, and a path
# git does not track is generated, ignored or outside the repo.
fi_offlimits_check() {
  local p="$1" root="${2:-}"
  if [[ -z "$p" ]]; then printf 'no-file'; return 0; fi
  fi_offlimits_category "$p" && return 0
  if [[ -n "$root" ]] && ! git -C "$root" ls-files --error-unmatch -- "$p" >/dev/null 2>&1; then
    printf 'untracked'; return 0
  fi
  return 1
}

# Tag values live inside "(key: value)"; the parser reads [^)]*, so a ")"
# would truncate the value and a "(" would confuse the tail scan (audit
# cli-7). Brackets keep the meaning readable.
fi_tag_text() {
  local t="$1"
  [[ "$t" == *$'\n'* || "$t" == *$'\r'* ]] && return 1
  t="${t//(/[}"
  t="${t//)/]}"
  t="${t//$'\t'/ }"
  while [[ "$t" == *"  "* ]]; do t="${t//  / }"; done
  t="${t#"${t%%[![:space:]]*}"}"
  t="${t%"${t##*[![:space:]]}"}"
  [[ -z "$t" ]] && return 1
  FI_TAG_TEXT="$t"
}

# Validate a requested tag and apply the off-limits override. kind=fix with
# an off-limits (or file-less, or untracked) path becomes manual.
fi_tag_resolve() {
  local kind="$1" value="$2" path="${3:-}" root="${4:-}" cat
  case "$kind" in
    fix)
      case "$value" in
        small|medium|large) ;;
        *) fi_err "--fix takes small, medium or large (got: $value)"; return 2 ;;
      esac
      if cat="$(fi_offlimits_check "$path" "$root")"; then
        FI_TAG_KIND="manual"; FI_TAG_VALUE="off-limits: $cat"; return 0
      fi
      FI_TAG_KIND="fix"; FI_TAG_VALUE="$value" ;;
    decide|manual|decided|autofix-failed)
      fi_tag_text "$value" || { fi_err "--$kind needs a one-line, non-empty text"; return 2; }
      FI_TAG_KIND="$kind"; FI_TAG_VALUE="$FI_TAG_TEXT" ;;
    *) fi_err "unknown tag kind: $kind"; return 2 ;;
  esac
}

# Rewrite an entry's annotation tail: drop the groups this kind replaces,
# keep every other group in order, append the new one.
fi_entry_retag() {
  local line="$1" kind="$2" value="$3" drop
  case "$kind" in
    fix|decide|manual) drop='fix|decide|manual' ;;
    decided)           drop='decide|decided' ;;
    autofix-failed)    drop='autofix-failed' ;;
    drop-until)        drop='until' ;;
    *) return 2 ;;
  esac
  fi_annotation_tail_v "$line"
  local tail="$FI_ANN_TAIL" head="${line%"$FI_ANN_TAIL"}"
  head="${head%"${head##*[![:space:]]}"}"
  local re_grp='^[[:space:]]*\(([A-Za-z-]+): [^)]*\)'
  local re_drop="^(${drop})\$" kept="" grp key
  while [[ "$tail" =~ $re_grp ]]; do
    grp="${BASH_REMATCH[0]}"
    key="${BASH_REMATCH[1]}"
    tail="${tail#"$grp"}"
    if [[ ! "$key" =~ $re_drop ]]; then
      grp="${grp#"${grp%%[![:space:]]*}"}"
      kept+=" $grp"
    fi
  done
  FI_RETAGGED="${head}${kept}"
  [[ "$kind" == "drop-until" ]] || FI_RETAGGED+=" ($kind: $value)"
}

# fi_until_due <until-spec> <today> — 0 when a mechanically checkable
# trigger has fired. pr: needs gh and is answered through sync's memoized
# _fi_pr_info; free text is never "due" here (the sweep re-judges it).
fi_until_due() {
  local spec="$1" today="$2"
  case "$spec" in
    date:*)
      local d="${spec#date:}"
      [[ ! "$d" > "$today" ]] ;;
    pr:*)
      declare -F _fi_pr_info >/dev/null 2>&1 || return 1
      command -v gh >/dev/null 2>&1 || return 1
      _fi_pr_info "${spec#pr:}"
      [[ "${_fi_pr_ans%%$'\x1f'*}" == "MERGED" ]] ;;
    *) return 1 ;;
  esac
}
