#!/usr/bin/env bash
# Module: system update
# shellcheck shell=bash

module_update() {
  ui_step "System update & upgrade"
  export DEBIAN_FRONTEND=noninteractive

  if ! apt_update_safe; then
    module_fail "update" "apt-get update failed"
    confirm_continue_on_error "update" "apt-get update failed" || return 1
    return 0
  fi

  if ! retry_cmd 2 5 apt-get -y -o Dpkg::Options::="--force-confdef" \
      -o Dpkg::Options::="--force-confold" full-upgrade; then
    module_fail "update" "full-upgrade failed"
    confirm_continue_on_error "update" "full-upgrade failed" || return 1
    return 0
  fi

  apt-get -y autoremove --purge >/dev/null 2>&1 || true
  apt-get -y autoclean >/dev/null 2>&1 || true

  if [[ -f /var/run/reboot-required ]]; then
    ui_warn "A reboot is required to finish kernel/package upgrades."
    SECUREBOX_ANSWERS[reboot_needed]=yes
  fi

  module_ok "update"
  ui_success "System packages updated"
}
