#!/usr/bin/env bash
# Module: time sync
# shellcheck shell=bash

module_timesync() {
  ui_step "Time synchronization"
  if ! apt_install_safe chrony; then
    # fallback
    if systemctl list-unit-files | grep -q systemd-timesyncd; then
      systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
      module_ok "timesync"
      ui_success "Enabled systemd-timesyncd"
      return 0
    fi
    module_fail "timesync" "could not install chrony"
    confirm_continue_on_error "timesync" "chrony install failed" || return 1
    return 0
  fi

  # Prefer chrony; disable timesyncd to avoid conflict
  systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true
  service_enable_start chrony
  # Debian package may use chrony.service
  systemctl enable --now chrony >/dev/null 2>&1 || systemctl enable --now chronyd >/dev/null 2>&1 || true

  if have_cmd chronyc; then
    chronyc waitsync 3 0.1 0.1 >/dev/null 2>&1 || chronyc makestep >/dev/null 2>&1 || true
  fi

  module_ok "timesync"
  ui_success "Chrony time sync enabled"
}
