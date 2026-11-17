#!/usr/bin/env bats
# shellcheck shell=bats

load helpers

setup() {
  # Real helper from install.sh (guard stops before bootstrap)
  # shellcheck disable=SC1091
  PGCTB_INSTALL_LIB_ONLY=1 source "${REPO_ROOT}/install.sh"
}

@test "have_tree accepts full repo tree" {
  _pgctb_have_tree "$REPO_ROOT"
}

@test "have_tree rejects empty data/ directory" {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/lib" "$tmp/modules" "$tmp/data"
  cp "$REPO_ROOT/lib/common.sh" "$tmp/lib/"
  cp "$REPO_ROOT/lib/runner.sh" "$tmp/lib/"
  # data/ exists but ranges missing
  run _pgctb_have_tree "$tmp"
  [ "$status" -ne 0 ]
  rm -rf "$tmp"
}

@test "have_tree rejects missing aggressive ranges" {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/lib" "$tmp/modules" "$tmp/data"
  cp "$REPO_ROOT/lib/common.sh" "$tmp/lib/"
  cp "$REPO_ROOT/lib/runner.sh" "$tmp/lib/"
  cp "$REPO_ROOT/data/abuse-ranges.txt" "$tmp/data/"
  run _pgctb_have_tree "$tmp"
  [ "$status" -ne 0 ]
  rm -rf "$tmp"
}

@test "abuse resolve uses PGCTB_DATA at call time" {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/modules/abuse.sh"
  export PGCTB_DATA="${REPO_ROOT}/data"
  file="$(_abuse_resolve_file)"
  [ -r "$file" ]
  [[ "$file" == *"/abuse-ranges.txt" ]]
}
