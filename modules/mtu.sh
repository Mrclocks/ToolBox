#!/usr/bin/env bash
# Module: MTU (+ optional TCP MSS clamping)
# shellcheck shell=bash

_mtu_apply_mss_clamp() {
  # Clamp TCP MSS on FORWARD — alternative to lowering NIC MTU for VPN paths
  local mss="${1:-1360}"
  ui_info "Applying TCP MSS clamping (FORWARD) as MTU alternative..."
  if have_cmd nft; then
    nft list table inet securebox_mss >/dev/null 2>&1 || nft add table inet securebox_mss
    nft list chain inet securebox_mss forward >/dev/null 2>&1 \
      || nft add chain inet securebox_mss forward '{ type filter hook forward priority 0; policy accept; }'
    nft flush chain inet securebox_mss forward 2>/dev/null || true
    nft add rule inet securebox_mss forward tcp flags syn / syn,rst tcp option maxseg size set "$mss" 2>/dev/null \
      || nft add rule inet securebox_mss forward tcp flags syn tcp option maxseg size set "$mss" 2>/dev/null \
      || true
    state_record_once "mss_clamp" "nft:${mss}"
    return 0
  fi
  if have_cmd iptables; then
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss" 2>/dev/null \
      || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss" 2>/dev/null \
      || true
    state_record_once "mss_clamp" "iptables:${mss}"
    return 0
  fi
  return 1
}

module_mtu() {
  ui_step "Configure interface MTU"
  detect_network_stack

  local iface="${NET_DEFAULT_IFACE}"
  local mtu="${SECUREBOX_ANSWERS[mtu]:-}"

  # Optional MSS clamp without changing NIC MTU
  if answered_yes mtu_mss_clamp; then
    if _mtu_apply_mss_clamp 1360; then
      ui_success "TCP MSS clamping enabled (NIC MTU left unchanged)"
      module_ok "mtu"
      return 0
    fi
    ui_warn "MSS clamping failed — continuing with MTU policy"
  fi

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

  if is_true "${SECUREBOX_DRY_RUN:-0}"; then
    ui_info "[dry-run] Would set MTU ${mtu} on ${iface}"
    module_ok "mtu"
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
    # Arm timed rollback if requested
    local rollback_secs="${SECUREBOX_ROLLBACK_SECONDS:-0}"
    if have_cmd systemd-run && is_uint "$rollback_secs" && (( rollback_secs > 0 )); then
      if declare -F schedule_timed_rollback >/dev/null 2>&1; then
        schedule_timed_rollback "mtu" "$rollback_secs" || true
      fi
    fi
    module_ok "mtu"
    ui_success "MTU set to ${now} on ${iface} (addressing untouched)"
  else
    module_fail "mtu" "failed to apply MTU"
    confirm_continue_on_error "mtu" "MTU apply failed" || return 1
  fi
}
