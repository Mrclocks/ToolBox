#!/usr/bin/env bash
# Module: IPv6 disable (optional, asked up-front)
# shellcheck shell=bash

module_ipv6() {
  ui_step "IPv6 policy"

  if ! require_answer_yes disable_ipv6 ipv6 "IPv6 disable not explicitly requested"; then
    module_skip "ipv6" "disable_ipv6='${SECUREBOX_ANSWERS[disable_ipv6]:-}' — left unchanged"
    return 0
  fi

  if disable_ipv6_persistent; then
    module_ok "ipv6"
    ui_success "IPv6 disabled (sysctl + UFW IPV6=no; grub flag if available)"
    ui_warn "A reboot may be required for full IPv6 disable on all interfaces."
    SECUREBOX_ANSWERS[reboot_needed]=yes
  else
    module_fail "ipv6" "failed to disable IPv6"
    confirm_continue_on_error "ipv6" "disable failed" || return 1
  fi
}
