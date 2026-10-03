#!/usr/bin/env bash
# Module: MTU
# shellcheck shell=bash

module_mtu() {
  ui_step "Configure interface MTU"
  detect_network_stack

  local iface="${NET_DEFAULT_IFACE}"
  local mtu="${SECUREBOX_ANSWERS[mtu]:-}"

  # Honor keep / unset before requiring a detected interface
  if [[ -z "$mtu" || "$mtu" == "keep" ]]; then
    module_skip "mtu" "kept current MTU"
    ui_info "MTU unchanged${iface:+ on ${iface}} (${NET_DEFAULT_MTU:-unknown})"
    return 0
  fi

  if [[ -z "$iface" ]]; then
    module_fail "mtu" "could not detect default interface"
    confirm_continue_on_error "mtu" "no default interface" || return 1
    return 0
  fi

  if ! is_uint "$mtu" || (( mtu < 1280 || mtu > 9000 )); then
    module_fail "mtu" "invalid MTU ${mtu}"
    confirm_continue_on_error "mtu" "invalid MTU" || return 1
    return 0
  fi

  ui_info "Interface ${iface}: ${NET_DEFAULT_MTU:-?} → ${mtu} (stack: ${NET_STACK})"
  if ! network_has_default_route; then
    module_fail "mtu" "no default route — refusing MTU change"
    confirm_continue_on_error "mtu" "no default route" || return 1
    return 0
  fi
  if apply_persistent_mtu "$iface" "$mtu"; then
    local now
    now="$(iface_mtu "$iface" || echo "?")"
    if ! network_has_default_route; then
      module_fail "mtu" "default route lost after MTU change"
      confirm_continue_on_error "mtu" "gateway lost" || return 1
      return 0
    fi
    module_ok "mtu"
    ui_success "MTU set to ${now} on ${iface} (addressing untouched)"
  else
    module_fail "mtu" "failed to apply MTU"
    confirm_continue_on_error "mtu" "MTU apply failed" || return 1
  fi
}
