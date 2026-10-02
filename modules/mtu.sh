#!/usr/bin/env bash
# Module: MTU
# shellcheck shell=bash

module_mtu() {
  ui_step "Configure interface MTU"
  detect_network_stack

  local iface="${NET_DEFAULT_IFACE}"
  local mtu="${SECUREBOX_ANSWERS[mtu]:-}"

  if [[ -z "$iface" ]]; then
    module_fail "mtu" "could not detect default interface"
    confirm_continue_on_error "mtu" "no default interface" || return 1
    return 0
  fi

  if [[ -z "$mtu" || "$mtu" == "keep" ]]; then
    module_skip "mtu" "kept current MTU"
    ui_info "MTU unchanged on ${iface} (${NET_DEFAULT_MTU:-unknown})"
    return 0
  fi

  if ! is_uint "$mtu" || (( mtu < 1280 || mtu > 9000 )); then
    module_fail "mtu" "invalid MTU ${mtu}"
    confirm_continue_on_error "mtu" "invalid MTU" || return 1
    return 0
  fi

  ui_info "Interface ${iface}: ${NET_DEFAULT_MTU:-?} → ${mtu} (stack: ${NET_STACK})"
  if apply_persistent_mtu "$iface" "$mtu"; then
    local now
    now="$(iface_mtu "$iface" || echo "?")"
    module_ok "mtu"
    ui_success "MTU set to ${now} on ${iface}"
  else
    module_fail "mtu" "failed to apply MTU"
    confirm_continue_on_error "mtu" "MTU apply failed" || return 1
  fi
}
