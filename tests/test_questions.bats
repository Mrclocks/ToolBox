#!/usr/bin/env bats
# shellcheck shell=bats

load helpers

setup() {
  pgctb_test_dirs
  # Minimal stubs for ask_* dependencies
  detect_network_stack() { NET_DEFAULT_IFACE=eth0; NET_DEFAULT_MTU=1500; }
  detect_dns_manager() { DNS_MANAGER=static-resolv; DNS_CURRENT=(1.1.1.1); }
  _ssh_current_port() { echo 22; }
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/lib/questions.sh"
}

@test "defaults_auto_all is low-risk" {
  defaults_auto_all
  [ "${PGCTB_ANSWERS[do_update]}" = "no" ]
  [ "${PGCTB_ANSWERS[do_logs]}" = "no" ]
  [ "${PGCTB_ANSWERS[disable_unused]}" = "no" ]
  [ "${PGCTB_ANSWERS[block_abuse]}" = "no" ]
  [ "${PGCTB_ANSWERS[ufw_enable]}" = "no" ]
  [ "${PGCTB_ANSWERS[mtu]}" = "keep" ]
  [ "${PGCTB_ANSWERS[dns_id]}" = "keep" ]
  [ "${PGCTB_ANSWERS[logs_docker_prune]}" = "no" ]
}

@test "recommend_mtu prefers keep" {
  NET_DEFAULT_MTU=1500
  result="$(recommend_mtu)"
  [[ "$result" == keep* ]]
}
