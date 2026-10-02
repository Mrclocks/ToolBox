#!/usr/bin/env bash
# Module: disable unused / noisy services (safe list)
# shellcheck shell=bash

module_services() {
  ui_step "Disable unused services"

  if ! is_true "${SECUREBOX_ANSWERS[disable_unused]:-yes}"; then
    module_skip "services" "user declined"
    return 0
  fi

  # Conservative list — only common desktop/noise services on VPS images
  local -a candidates=(
    avahi-daemon
    cups
    cupsd
    bluetooth
    ModemManager
    whoopsie
    snapd
  )

  # Do NOT disable snapd on Ubuntu by default if snap is heavily used — ask via answer
  if ! is_true "${SECUREBOX_ANSWERS[disable_snapd]:-no}"; then
    candidates=( "${candidates[@]/snapd}" )
  fi

  local svc disabled=0
  for svc in "${candidates[@]}"; do
    if systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -qx "${svc}.service"; then
      if systemctl is-enabled --quiet "${svc}.service" 2>/dev/null \
         || systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
        ui_info "Disabling ${svc}"
        service_disable_stop "$svc"
        ((disabled++)) || true
      fi
    fi
  done

  module_ok "services"
  ui_success "Reviewed unused services (${disabled} disabled)"
}
