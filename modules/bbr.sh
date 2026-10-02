#!/usr/bin/env bash
# Module: BBR + VPN-oriented network tuning
# Uses kernel BBR (stable) + fq — lightest reliable combo on Ubuntu/Debian.
# shellcheck shell=bash

module_bbr() {
  ui_step "Enable BBR + low-latency network tuning"
  if ! require_answer_yes do_bbr bbr "BBR tuning not explicitly enabled"; then
    module_skip "bbr" "do_bbr='${SECUREBOX_ANSWERS[do_bbr]:-}'"
    return 0
  fi

  # Ensure sch_fq / tcp_bbr available
  modprobe tcp_bbr >/dev/null 2>&1 || true
  modprobe sch_fq >/dev/null 2>&1 || true

  local cc_available
  cc_available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if [[ " $cc_available " != *" bbr "* ]]; then
    module_fail "bbr" "kernel does not expose bbr (${cc_available})"
    confirm_continue_on_error "bbr" "BBR unavailable on this kernel" || return 1
    return 0
  fi

  write_sysctl_dropin /etc/sysctl.d/99-securebox-bbr-network.conf \
    "net.core.default_qdisc = fq" \
    "net.ipv4.tcp_congestion_control = bbr" \
    "" \
    "# --- latency / throughput balance for VPN endpoints ---" \
    "net.core.rmem_max = 16777216" \
    "net.core.wmem_max = 16777216" \
    "net.core.rmem_default = 1048576" \
    "net.core.wmem_default = 1048576" \
    "net.core.netdev_max_backlog = 16384" \
    "net.core.somaxconn = 4096" \
    "net.core.optmem_max = 65536" \
    "" \
    "net.ipv4.tcp_rmem = 4096 1048576 16777216" \
    "net.ipv4.tcp_wmem = 4096 65536 16777216" \
    "net.ipv4.udp_rmem_min = 8192" \
    "net.ipv4.udp_wmem_min = 8192" \
    "net.ipv4.tcp_fastopen = 3" \
    "net.ipv4.tcp_slow_start_after_idle = 0" \
    "net.ipv4.tcp_mtu_probing = 1" \
    "net.ipv4.tcp_timestamps = 1" \
    "net.ipv4.tcp_sack = 1" \
    "net.ipv4.tcp_window_scaling = 1" \
    "net.ipv4.tcp_keepalive_time = 600" \
    "net.ipv4.tcp_keepalive_intvl = 30" \
    "net.ipv4.tcp_keepalive_probes = 5" \
    "net.ipv4.tcp_fin_timeout = 15" \
    "net.ipv4.tcp_tw_reuse = 1" \
    "net.ipv4.tcp_max_syn_backlog = 8192" \
    "net.ipv4.tcp_max_tw_buckets = 2000000" \
    "net.ipv4.tcp_notsent_lowat = 16384" \
    "" \
    "# --- path / spoof hardening (VPN-safe) ---" \
    "net.ipv4.conf.all.rp_filter = 1" \
    "net.ipv4.conf.default.rp_filter = 1" \
    "net.ipv4.conf.all.accept_redirects = 0" \
    "net.ipv4.conf.default.accept_redirects = 0" \
    "net.ipv4.conf.all.send_redirects = 0" \
    "net.ipv4.conf.default.send_redirects = 0" \
    "net.ipv4.conf.all.accept_source_route = 0" \
    "net.ipv4.conf.default.accept_source_route = 0" \
    "net.ipv4.icmp_echo_ignore_broadcasts = 1" \
    "net.ipv4.icmp_ignore_bogus_error_responses = 1" \
    "net.ipv4.tcp_syncookies = 1" \
    "" \
    "# --- conntrack for many VPN sessions ---" \
    "net.netfilter.nf_conntrack_max = 1048576" \
    "net.netfilter.nf_conntrack_buckets = 262144" \
    "net.netfilter.nf_conntrack_tcp_timeout_established = 600" \
    "net.netfilter.nf_conntrack_udp_timeout = 30" \
    "net.netfilter.nf_conntrack_udp_timeout_stream = 120" \
    "" \
    "# forwarding left enabled for VPN gateways" \
    "net.ipv4.ip_forward = 1"

  # Load conntrack sysctls if module present
  modprobe nf_conntrack >/dev/null 2>&1 || true
  sysctl --system >/dev/null 2>&1 || true

  local active_cc active_qdisc
  active_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  active_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"

  if [[ "$active_cc" != "bbr" ]]; then
    module_fail "bbr" "congestion control is ${active_cc}, expected bbr"
    confirm_continue_on_error "bbr" "failed to activate bbr" || return 1
    return 0
  fi

  # Best-effort: set fq on default iface
  if [[ -n "${NET_DEFAULT_IFACE:-}" ]] && have_cmd tc; then
    tc qdisc replace dev "$NET_DEFAULT_IFACE" root fq 2>/dev/null || true
  fi

  module_ok "bbr"
  ui_success "BBR active (${active_cc} + ${active_qdisc}) with VPN sysctl profile"
}
