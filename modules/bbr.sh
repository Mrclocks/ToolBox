#!/usr/bin/env bash
# Module: BBR + VPN-oriented network tuning
# Uses kernel BBR (stable) + fq — lightest reliable combo on Ubuntu/Debian.
# shellcheck shell=bash

_bbr_need_ip_forward() {
  # Auto-detect WireGuard / TUN VPN interfaces
  local n
  n="$(ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^(wg|tun|tap)/{c++} END{print c+0}')"
  (( n > 0 )) && return 0
  answered_yes bbr_ip_forward
}

_bbr_sysctl_writable() {
  local key="$1"
  # Skip keys that are read-only on this kernel/build
  if ! sysctl -n "$key" >/dev/null 2>&1; then
    return 1
  fi
  # nf_conntrack_buckets is often read-only after module load
  case "$key" in
    net.netfilter.nf_conntrack_buckets) return 1 ;;
  esac
  return 0
}

_bbr_write_sysctl_filtered() {
  local file="$1"
  shift
  local -a lines=("$@")
  local -a out=()
  local line key
  for line in "${lines[@]}"; do
    if [[ -z "$line" || "$line" == \#* ]]; then
      out+=("$line")
      continue
    fi
    key="$(awk -F= '{gsub(/ /,"",$1); print $1}' <<<"$line")"
    if [[ -n "$key" ]] && ! _bbr_sysctl_writable "$key"; then
      ui_info "Skipping read-only/unavailable sysctl: ${key}"
      continue
    fi
    out+=("$line")
  done
  write_sysctl_dropin "$file" "${out[@]}"
}

module_bbr() {
  ui_step "Enable BBR + low-latency network tuning"
  if ! require_answer_yes do_bbr bbr "BBR tuning not explicitly enabled"; then
    module_skip "bbr" "do_bbr='${SECUREBOX_ANSWERS[do_bbr]:-}'"
    return 0
  fi

  if is_dry_run; then
    ui_info "[dry-run] Would load nf_conntrack via /etc/modules-load.d, write BBR sysctl (skip read-only nf_conntrack_buckets), enable ip_forward only if wg*/tun*"
    ui_info "[dry-run] Would report real qdisc via: tc qdisc show"
    module_ok "bbr"
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

  state_record_sysctl_baseline

  # Load nf_conntrack persistently (NOT via sysctl alone — module must exist at boot)
  mkdir -p /etc/modules-load.d
  backup_file /etc/modules-load.d/securebox-nf-conntrack.conf
  printf 'nf_conntrack\n' >/etc/modules-load.d/securebox-nf-conntrack.conf
  modprobe nf_conntrack >/dev/null 2>&1 || true

  local -a sysctl_lines=(
    "net.core.default_qdisc = fq"
    "net.ipv4.tcp_congestion_control = bbr"
    ""
    "# --- latency / throughput balance for VPN endpoints ---"
    "net.core.rmem_max = 16777216"
    "net.core.wmem_max = 16777216"
    "net.core.rmem_default = 1048576"
    "net.core.wmem_default = 1048576"
    "net.core.netdev_max_backlog = 16384"
    "net.core.somaxconn = 4096"
    "net.core.optmem_max = 65536"
    ""
    "net.ipv4.tcp_rmem = 4096 1048576 16777216"
    "net.ipv4.tcp_wmem = 4096 65536 16777216"
    "net.ipv4.udp_rmem_min = 8192"
    "net.ipv4.udp_wmem_min = 8192"
    "net.ipv4.tcp_fastopen = 3"
    "net.ipv4.tcp_slow_start_after_idle = 0"
    "net.ipv4.tcp_mtu_probing = 1"
    "net.ipv4.tcp_timestamps = 1"
    "net.ipv4.tcp_sack = 1"
    "net.ipv4.tcp_window_scaling = 1"
    "net.ipv4.tcp_keepalive_time = 600"
    "net.ipv4.tcp_keepalive_intvl = 30"
    "net.ipv4.tcp_keepalive_probes = 5"
    "net.ipv4.tcp_fin_timeout = 15"
    "net.ipv4.tcp_tw_reuse = 1"
    "net.ipv4.tcp_max_syn_backlog = 8192"
    "net.ipv4.tcp_max_tw_buckets = 2000000"
    "net.ipv4.tcp_notsent_lowat = 16384"
    ""
    "# --- path / spoof hardening (VPN/cloud safe) ---"
    "# rp_filter=2 (loose) — strict(1) breaks many VPS/floating-IP setups"
    "net.ipv4.conf.all.rp_filter = 2"
    "net.ipv4.conf.default.rp_filter = 2"
    "net.ipv4.conf.all.accept_redirects = 0"
    "net.ipv4.conf.default.accept_redirects = 0"
    "net.ipv4.conf.all.send_redirects = 0"
    "net.ipv4.conf.default.send_redirects = 0"
    "net.ipv4.conf.all.accept_source_route = 0"
    "net.ipv4.conf.default.accept_source_route = 0"
    "net.ipv4.icmp_echo_ignore_broadcasts = 1"
    "net.ipv4.icmp_ignore_bogus_error_responses = 1"
    "net.ipv4.tcp_syncookies = 1"
    ""
    "# --- conntrack for many VPN sessions ---"
    "net.netfilter.nf_conntrack_max = 1048576"
    "net.netfilter.nf_conntrack_tcp_timeout_established = 600"
    "net.netfilter.nf_conntrack_udp_timeout = 30"
    "net.netfilter.nf_conntrack_udp_timeout_stream = 120"
  )

  # ip_forward is OPT-IN (auto when wg*/tun* present, or explicit answer)
  if _bbr_need_ip_forward; then
    ui_info "Enabling net.ipv4.ip_forward (VPN interfaces detected or opted in)"
    sysctl_lines+=("" "# forwarding enabled for VPN gateways" "net.ipv4.ip_forward = 1")
  else
    ui_info "Leaving net.ipv4.ip_forward unchanged (no wg*/tun* detected; opt-in via bbr_ip_forward=yes)"
  fi

  _bbr_write_sysctl_filtered /etc/sysctl.d/99-securebox-bbr-network.conf "${sysctl_lines[@]}"
  sysctl --system >/dev/null 2>&1 || true

  local active_cc active_qdisc real_qdisc
  active_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  active_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
  # Report the REAL interface qdisc (not only the sysctl default for new ifaces)
  if have_cmd tc; then
    real_qdisc="$(tc qdisc show 2>/dev/null | tr '\n' ' | ' || echo n/a)"
  else
    real_qdisc="tc unavailable"
  fi

  if [[ "$active_cc" != "bbr" ]]; then
    module_fail "bbr" "congestion control is ${active_cc}, expected bbr"
    confirm_continue_on_error "bbr" "failed to activate bbr" || return 1
    return 0
  fi

  module_ok "bbr"
  ui_success "BBR active (${active_cc}; default_qdisc=${active_qdisc})"
  ui_info "Real qdisc (tc qdisc show): ${real_qdisc}"
}
