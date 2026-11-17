#!/usr/bin/env bats
# Optimization levels, 🔴 risk gate, menus, CLI subcommands (0.6.0)

load helpers

setup() {
  pgctb_test_dirs
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/lib/questions.sh"
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/lib/levels.sh"
  detect_network_stack() { :; }
  detect_dns_manager() { :; }
  _ssh_current_port() { echo 2222; }
  have_tty() { return 1; }
  have_cmd() { [[ "$1" != docker ]] && command -v "$1" >/dev/null 2>&1; }
  dpkg() { return 1; }
  T="${BATS_TEST_TMPDIR}/lv"
  mkdir -p "$T"
}

high_risk_off() {
  [ "${PGCTB_ANSWERS[do_ssh]}" = no ]
  [ "${PGCTB_ANSWERS[ufw_enable]}" = no ]
  [ "${PGCTB_ANSWERS[block_abuse]}" = no ]
}

@test "low level: safe items on, mid items kept, high risk off" {
  defaults_level_low
  [ "${PGCTB_ANSWERS[level]}" = low ]
  [ "${PGCTB_ANSWERS[do_update]}" = yes ]
  [ "${PGCTB_ANSWERS[update_mode]}" = safe ]
  [ "${PGCTB_ANSWERS[do_timesync]}" = yes ]
  [ "${PGCTB_ANSWERS[do_bbr]}" = yes ]
  [ "${PGCTB_ANSWERS[do_logs]}" = yes ]
  [ "${PGCTB_ANSWERS[logs_truncate_active]}" = no ]
  [ "${PGCTB_ANSWERS[logs_docker_prune]}" = no ]
  [ "${PGCTB_ANSWERS[unattended_reboot]}" = no ]
  [ "${PGCTB_ANSWERS[enable_fail2ban]}" = no ]
  [ "${PGCTB_ANSWERS[dns_id]}" = keep ]
  [ -z "${PGCTB_ANSWERS[dns_choice]}" ]
  [ "${PGCTB_ANSWERS[mtu]}" = keep ]
  [ "${PGCTB_ANSWERS[disable_ipv6]}" = no ]
  [ "${PGCTB_ANSWERS[disable_unused]}" = no ]
  high_risk_off
}

@test "mid level without TTY: low + Fail2Ban, network items kept, high risk off" {
  defaults_level_mid
  [ "${PGCTB_ANSWERS[level]}" = mid ]
  [ "${PGCTB_ANSWERS[do_update]}" = yes ]
  [ "${PGCTB_ANSWERS[enable_fail2ban]}" = yes ]
  [ "${PGCTB_ANSWERS[ssh_port]}" = 2222 ]
  [ "${PGCTB_ANSWERS[dns_id]}" = keep ]
  [ "${PGCTB_ANSWERS[mtu]}" = keep ]
  [ "${PGCTB_ANSWERS[disable_ipv6]}" = no ]
  high_risk_off
}

@test "DNS keep from a level never selects a preset" {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/modules/dns.sh"
  defaults_level_low
  dns_resolve_choice
  [ "$DNS_CHOICE_ID" = keep ]
  # Non-numeric index must not wrap to the last preset
  PGCTB_ANSWERS[dns_choice]=keep
  dns_resolve_choice
  [ "$DNS_CHOICE_ID" = keep ]
  [ -z "$DNS_PRIMARY" ]
}

@test "Docker is held by default when installed and no TTY" {
  have_cmd() { [[ "$1" == docker ]] || command -v "$1" >/dev/null 2>&1; }
  ask_update_docker_policy
  [ "${PGCTB_ANSWERS[update_docker]}" = no ]
}

@test "run_level refuses without TTY unless --yes" {
  run_pipeline_all() { touch "${T}/ran"; }
  run run_level low 0
  [ "$status" -ne 0 ]
  [ ! -f "${T}/ran" ]
  run_level low 1
  [ -f "${T}/ran" ]
  run run_level bogus 1
  [ "$status" -ne 0 ]
}

@test "risk gate: refuses without TTY, needs exact YES on a TTY" {
  run ui_risk_gate ssh "SSH"
  [ "$status" -ne 0 ]
  have_tty() { return 0; }
  ui_ask() { printf -v "$1" '%s' "yes"; }
  run ui_risk_gate ufw "UFW"
  [ "$status" -ne 0 ]
  ui_ask() { printf -v "$1" '%s' "YES"; }
  run ui_risk_gate abuse "Abuse"
  [ "$status" -eq 0 ]
}

@test "every 🔴 module has risk text and is high in the risk table" {
  local m
  for m in ssh ufw abuse; do
    [ -n "${PGCTB_RISK_TEXT[$m]}" ]
    [ "$(pgctb_risk "$m")" = high ]
  done
}

@test "update holds Docker during upgrade and always releases the hold" {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/modules/update.sh"
  local log="${T}/apt.log"
  apt-mark() { echo "apt-mark $*" >>"$log"; [[ "$1" == showhold ]] && echo docker-ce-cli; return 0; }
  dpkg() { [[ "$2" == docker-ce || "$2" == docker-ce-cli || "$2" == containerd.io ]]; }
  run _update_hold_docker
  [ "$output" = $'docker-ce\ncontainerd.io' ]          # existing hold untouched
  _update_unhold docker-ce containerd.io
  grep -q 'apt-mark unhold docker-ce containerd.io' "$log"
}

@test "menus: Security uses the risk gate for every 🔴 item; levels exclude 🔴" {
  local m="${REPO_ROOT}/lib/menu.sh"
  grep -q 'ui_risk_gate ssh' "$m"
  grep -q 'ui_risk_gate ufw' "$m"
  grep -q 'ui_risk_gate abuse' "$m"
  # Optimization menu never offers ssh/ufw/abuse
  ! sed -n '/^optimization_menu_loop/,/^}/p' "$m" | grep -qE 'run_single (ssh|ufw|abuse)'
}

@test "CLI: subcommands parse" {
  # shellcheck disable=SC1091
  PGCTB_INSTALL_LIB_ONLY=1 source "${REPO_ROOT}/install.sh"
  eval "$(sed -n '/^parse_args() {/,/^}/p' "${REPO_ROOT}/install.sh")"
  usage() { :; }
  parse_args optimize mid --yes
  [ "$PGCTB_MODE" = level ] && [ "$PGCTB_CMD_ARG" = mid ] && [ "$PGCTB_ASSUME_YES" = 1 ]
  parse_args ssl renew
  [ "$PGCTB_MODE" = ssl ] && [ "$PGCTB_CMD_ARG" = renew ]
  parse_args status
  [ "$PGCTB_MODE" = status ]
  parse_args proxy status
  [ "$PGCTB_MODE" = proxy ]
  run parse_args optimize high
  [ "$status" -ne 0 ]
}
