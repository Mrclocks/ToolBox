#!/usr/bin/env bats
# shellcheck shell=bats

load helpers

@test "gen-checksums packs ToolBox-<tag>/ prefix (one-liner layout)" {
  tag="$(tr -d '[:space:]' <"${REPO_ROOT}/VERSION")"
  run bash "${REPO_ROOT}/scripts/gen-checksums.sh"
  [ "$status" -eq 0 ]
  archive="${REPO_ROOT}/dist/ToolBox-${tag}.tar.gz"
  [ -f "$archive" ]
  listing="$(tar -tzf "$archive")"
  grep -qx "ToolBox-${tag}/lib/common.sh" <<<"$listing"
  grep -q "ToolBox-${tag}/modules/" <<<"$listing"
  # Must NOT be flat at archive root (the 0.2.1 bug)
  ! grep -qx 'lib/common.sh' <<<"$listing"
}

@test "packed archive extracts to a usable tree" {
  tag="$(tr -d '[:space:]' <"${REPO_ROOT}/VERSION")"
  bash "${REPO_ROOT}/scripts/gen-checksums.sh" >/dev/null
  tmp="$(mktemp -d)"
  tar -xzf "${REPO_ROOT}/dist/ToolBox-${tag}.tar.gz" -C "$tmp"
  root="${tmp}/ToolBox-${tag}"
  [ -f "${root}/lib/common.sh" ]
  [ -f "${root}/lib/runner.sh" ]
  [ -d "${root}/modules" ]
  [ -d "${root}/data" ]
  [ -f "${root}/install.sh" ]
  rm -rf "$tmp"
}
