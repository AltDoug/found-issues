#!/usr/bin/env bats
# Tests for lib/canonicalize.sh

load 'helpers'

setup() {
  fi_source_lib canonicalize
}

# === fi_canonicalize_path ===

@test "canonicalize_path: trims whitespace" {
  result="$(fi_canonicalize_path '  src/foo.py  ')"
  [ "$result" = "src/foo.py" ]
}

@test "canonicalize_path: strips leading ./" {
  result="$(fi_canonicalize_path './src/foo.py')"
  [ "$result" = "src/foo.py" ]
}

@test "canonicalize_path: strips multiple leading ./" {
  result="$(fi_canonicalize_path './././src/foo.py')"
  [ "$result" = "src/foo.py" ]
}

@test "canonicalize_path: normalizes Windows separators" {
  # Single quotes preserve backslashes literally; one \ per separator
  result="$(fi_canonicalize_path 'src\foo\bar.py')"
  [ "$result" = "src/foo/bar.py" ]
}

@test "canonicalize_path: makes absolute path repo-relative when given repo_root" {
  result="$(fi_canonicalize_path '/repo/src/foo.py' '/repo')"
  [ "$result" = "src/foo.py" ]
}

@test "canonicalize_path: leaves absolute path alone if not under repo_root" {
  result="$(fi_canonicalize_path '/other/foo.py' '/repo')"
  [ "$result" = "/other/foo.py" ]
}

# === fi_canonicalize_symptom ===

@test "canonicalize_symptom: lowercases" {
  result="$(fi_canonicalize_symptom 'Null Check Missing')"
  [ "$result" = "null check missing" ]
}

@test "canonicalize_symptom: collapses internal whitespace" {
  result="$(fi_canonicalize_symptom 'null   check    missing')"
  [ "$result" = "null check missing" ]
}

@test "canonicalize_symptom: trims leading and trailing whitespace" {
  result="$(fi_canonicalize_symptom '   null check   ')"
  [ "$result" = "null check" ]
}

@test "canonicalize_symptom: truncates to N chars (default 50)" {
  long="this is a very long symptom description that exceeds fifty characters easily"
  result="$(fi_canonicalize_symptom "$long")"
  [ "${#result}" -le 50 ]
}

@test "canonicalize_symptom: truncates to custom N" {
  result="$(fi_canonicalize_symptom 'hello world' 5)"
  [ "$result" = "hello" ]
}

# === fi_strip_parentheticals ===

@test "strip_parentheticals: drops (suggested: ...)" {
  result="$(fi_strip_parentheticals 'null check missing (suggested: add guard)')"
  [ "$result" = "null check missing" ]
}

@test "strip_parentheticals: drops (PR: ...)" {
  result="$(fi_strip_parentheticals 'race on refresh (PR: org/repo#42)')"
  [ "$result" = "race on refresh" ]
}

@test "strip_parentheticals: drops everything from first paren onward" {
  result="$(fi_strip_parentheticals 'a (one) (two) (three)')"
  [ "$result" = "a" ]
}

@test "strip_parentheticals: passes through symptom without parens" {
  result="$(fi_strip_parentheticals 'plain symptom no parens')"
  [ "$result" = "plain symptom no parens" ]
}

# === fi_dedup_key ===

@test "dedup_key: same path:line+symptom produces same key regardless of suggestion" {
  k1="$(fi_dedup_key 'src/foo.py' '42' 'null check missing (suggested: A)')"
  k2="$(fi_dedup_key 'src/foo.py' '42' 'null check missing (suggested: B)')"
  [ "$k1" = "$k2" ]
}

@test "dedup_key: different lines produce different keys" {
  k1="$(fi_dedup_key 'src/foo.py' '42' 'null check')"
  k2="$(fi_dedup_key 'src/foo.py' '43' 'null check')"
  [ "$k1" != "$k2" ]
}

@test "dedup_key: different symptoms produce different keys" {
  k1="$(fi_dedup_key 'src/foo.py' '42' 'null check missing')"
  k2="$(fi_dedup_key 'src/foo.py' '42' 'wrong type cast')"
  [ "$k1" != "$k2" ]
}

@test "dedup_key: case-insensitive symptom match" {
  k1="$(fi_dedup_key 'src/foo.py' '42' 'Null Check Missing')"
  k2="$(fi_dedup_key 'src/foo.py' '42' 'null check missing')"
  [ "$k1" = "$k2" ]
}

# === fi_dedup_key_abstract ===

@test "dedup_key_abstract: stable for same symptom" {
  k1="$(fi_dedup_key_abstract 'workflow shutdown bug')"
  k2="$(fi_dedup_key_abstract 'workflow shutdown bug')"
  [ "$k1" = "$k2" ]
}

@test "dedup_key_abstract: ignores parentheticals" {
  k1="$(fi_dedup_key_abstract 'workflow bug (suggested: fix)')"
  k2="$(fi_dedup_key_abstract 'workflow bug')"
  [ "$k1" = "$k2" ]
}
