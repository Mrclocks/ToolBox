#!/usr/bin/env bash
# Module: disable unused services — only when explicitly enabled
# shellcheck shell=bash

module_services() {
  ui_step "Disable unused services"

  if ! require_answer_yes disable_unused services "service cleanup not explicitly enabled"; then
    module_skip "services" "disable_unused='${SECUREBOX_ANSWERS[disable_unused]:-}'"
    return 0
  fi

  local -a candidates=(
    avahi-daemon
    cups
    cupsd
    bluetooth
    ModemManager
    whoopsie
  )
  if answered_yes disable_snapd; then
    candidates+=(snapd)
  fi

  # Record pre-change state for live restore
  mkdir -p "${SECUREBOX_STATE_DIR}/services"
  local svc disabled=0
  for svc in "${candidates[@]}"; do
    [[ -n "$svc" ]] || continue
    if systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -qx "${svc}.service"; then
      if systemctl is-enabled --quiet "${svc}.service" 2>/dev/null \
         || systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
        local was_enabled=no was_active=no was_masked=no
        systemctl is-enabled --quiet "${svc}.service" 2>/dev/null && was_enabled=yes
        systemctl is-active --quiet "${svc}.service" 2>/dev/null && was_active=yes
        systemctl is-enabled "${svc}.service" 2>/dev/null | grep -qi masked && was_masked=yes
        printf '%s\n' "enabled=${was_enabled}" "active=${was_active}" "masked=${was_masked}" \
          >"${SECUREBOX_STATE_DIR}/services/${svc}.state"
        ui_info "Disabling ${svc}"
        service_disable_stop "$svc"
        ((disabled++)) || true
      fi
    fi
  done

  module_ok "services"
  ui_success "Reviewed unused services (${disabled} disabled)"
}
