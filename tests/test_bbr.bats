#!/usr/bin/env bats
# shellcheck shell=bats

load helpers

setup() {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/modules/bbr.sh"
}

@test "_bbr_sysctl_writable rejects nf_conntrack_buckets" {
  run _bbr_sysctl_writable net.netfilter.nf_conntrack_buckets
  [ "$status" -ne 0 ]
}

@test "module_bbr dry-run mentions modules-load and tc" {
  declare -gA SECUREBOX_ANSWERS=([do_bbr]=yes)
  SECUREBOX_DRY_RUN=1
  msgs=()
  ui_info() { msgs+=("$*"); }
  module_ok() { :; }
  module_bbr
  local joined="${msgs[*]}"
  [[ "$joined" == *"modules-load"* ]]
  [[ "$joined" == *"tc qdisc"* ]]
}
