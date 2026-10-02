#!/usr/bin/env bash
# SecureBox — module runner / orchestration
# shellcheck shell=bash

source_modules() {
  # shellcheck disable=SC1091
  source "${SECUREBOX_ROOT}/modules/update.sh"
  # shellcheck disable=SC1091
  source "${SECUREBOX_ROOT}/modules/timesync.sh"
  # shellcheck disable=SC1091
  source "${SECUREBOX_ROOT}/modules/dns.sh"
  # shellcheck disable=SC1091
  source "${SECUREBOX_ROOT}/modules/mtu.sh"
  # shellcheck disable=SC1091
  source "${SECUREBOX_ROOT}/modules/bbr.sh"
  # shellcheck disable=SC1091
  source "${SECUREBOX_ROOT}/modules/abuse.sh"
  # shellcheck disable=SC1091
  source "${SECUREBOX_ROOT}/modules/ufw.sh"
  # shellcheck disable=SC1091
  source "${SECUREBOX_ROOT}/modules/ssh.sh"
  # shellcheck disable=SC1091
  source "${SECUREBOX_ROOT}/modules/fail2ban.sh"
  # shellcheck disable=SC1091
  source "${SECUREBOX_ROOT}/modules/ipv6.sh"
  # shellcheck disable=SC1091
  source "${SECUREBOX_ROOT}/modules/unattended.sh"
  # shellcheck disable=SC1091
  source "${SECUREBOX_ROOT}/modules/services.sh"
  # shellcheck disable=SC1091
  source "${SECUREBOX_ROOT}/modules/report.sh"
}

run_pipeline_all() {
  ui_box_start "Applying only your answers"
  local k
  for k in dns_id dns_primary mtu ssh_port block_abuse ufw_enable enable_fail2ban disable_ipv6 unattended disable_unused do_update do_bbr do_ssh; do
    ui_kv "$k" "${SECUREBOX_ANSWERS[$k]:-(unset)}"
  done
  ui_box_end

  local -a steps=(
    module_update
    module_timesync
    module_dns
    module_mtu
    module_bbr
    module_ipv6
    module_abuse
    module_ufw
    module_ssh
    module_fail2ban
    module_unattended
    module_services
    module_report
  )
  local total="${#steps[@]}"
  local i=0
  local step
  for step in "${steps[@]}"; do
    ((i++)) || true
    ui_progress "$i" "$total" "$step"
    if ! "$step"; then
      ui_error "Pipeline stopped at ${step} by user choice or critical failure."
      module_report || true
      return 1
    fi
  done
  return 0
}

run_single() {
  local name="$1"
  case "$name" in
    update) module_update ;;
    timesync) module_timesync ;;
    dns) module_dns ;;
    mtu) module_mtu ;;
    bbr) module_bbr ;;
    abuse) module_abuse ;;
    ufw) module_ufw ;;
    ssh) module_ssh ;;
    fail2ban) module_fail2ban ;;
    ipv6) module_ipv6 ;;
    unattended) module_unattended ;;
    services) module_services ;;
    report) module_report ;;
    *) ui_error "Unknown module: $name"; return 1 ;;
  esac
}
