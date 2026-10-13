#!/usr/bin/env bats
# shellcheck shell=bats

load helpers

setup() {
  # Source only the helper from install.sh without running bootstrap
  _securebox_have_tree() {
    local root="$1"
    [[ -n "$root" ]] \
      && [[ -f "${root}/lib/common.sh" ]] \
      && [[ -f "${root}/lib/runner.sh" ]] \
      && [[ -d "${root}/modules" ]] \
      && [[ -d "${root}/data" ]] \
      && [[ -r "${root}/data/abuse-ranges.txt" ]] \
      && [[ -r "${root}/data/abuse-ranges-aggressive.txt" ]]
  }
}

@test "have_tree accepts full repo tree" {
  _securebox_have_tree "$REPO_ROOT"
}

@test "have_tree rejects empty data/ directory" {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/lib" "$tmp/modules" "$tmp/data"
  cp "$REPO_ROOT/lib/common.sh" "$tmp/lib/"
  cp "$REPO_ROOT/lib/runner.sh" "$tmp/lib/"
  # data/ exists but ranges missing
  run _securebox_have_tree "$tmp"
  [ "$status" -ne 0 ]
  rm -rf "$tmp"
}

@test "have_tree rejects missing aggressive ranges" {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/lib" "$tmp/modules" "$tmp/data"
  cp "$REPO_ROOT/lib/common.sh" "$tmp/lib/"
  cp "$REPO_ROOT/lib/runner.sh" "$tmp/lib/"
  cp "$REPO_ROOT/data/abuse-ranges.txt" "$tmp/data/"
  run _securebox_have_tree "$tmp"
  [ "$status" -ne 0 ]
  rm -rf "$tmp"
}

@test "abuse resolve uses SECUREBOX_DATA at call time" {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/modules/abuse.sh"
  export SECUREBOX_DATA="${REPO_ROOT}/data"
  file="$(_abuse_resolve_file)"
  [ -r "$file" ]
  [[ "$file" == *"/abuse-ranges.txt" ]]
}
