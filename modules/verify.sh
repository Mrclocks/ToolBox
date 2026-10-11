#!/usr/bin/env bash
# Module: verify — post-change / standalone health check
# shellcheck shell=bash

module_verify() {
  ui_step "Verify system state"
  detect_network_stack
  detect_dns_manager

  ui_box_start "sshd -T (effective)"
  if have_cmd sshd || [[ -x /usr/sbin/sshd ]]; then
    local sshd_bin=sshd
    have_cmd sshd || sshd_bin=/usr/sbin/sshd
    "$sshd_bin" -T 2>/dev/null | awk '
      /^(port|passwordauthentication|permitrootlogin|maxauthtries|pubkeyauthentication) / {print}
    ' | while read -r line; do
      printf '   %s\n' "$line"
    done
  else
    ui_warn "sshd not found"
  fi
  ui_box_end

  ui_box_start "ss -tulpn (listeners)"
  if have_cmd ss; then
    ss -tulpn 2>/dev/null | head -n 40 | while IFS= read -r line; do
      printf '   %s\n' "$line"
    done
  else
    ui_warn "ss not available"
  fi
  ui_box_end

  ui_box_start "resolvectl status"
  if have_cmd resolvectl; then
    resolvectl status 2>/dev/null | head -n 50 | while IFS= read -r line; do
      printf '   %s\n' "$line"
    done
  else
    ui_info "resolvectl not available — resolv.conf:"
    head -n 20 /etc/resolv.conf 2>/dev/null | while IFS= read -r line; do
      printf '   %s\n' "$line"
    done
  fi
  ui_box_end

  ui_box_start "ufw status verbose"
  if have_cmd ufw; then
    ufw status verbose 2>/dev/null | while IFS= read -r line; do
      printf '   %s\n' "$line"
    done
  else
    ui_info "ufw not installed"
  fi
  ui_box_end

  ui_box_start "tc qdisc"
  if have_cmd tc; then
    tc qdisc show 2>/dev/null | while IFS= read -r line; do
      printf '   %s\n' "$line"
    done
  else
    ui_info "tc not available"
  fi
  ui_box_end

  ui_box_start "sysctl summary"
  local key
  for key in \
    net.ipv4.tcp_congestion_control \
    net.core.default_qdisc \
    net.ipv4.ip_forward \
    net.ipv6.conf.all.disable_ipv6 \
    net.netfilter.nf_conntrack_max; do
    local val
    val="$(sysctl -n "$key" 2>/dev/null || echo n/a)"
    ui_kv "$key" "$val"
  done
  ui_box_end

  module_ok "verify"
  ui_success "Verify complete"
}
