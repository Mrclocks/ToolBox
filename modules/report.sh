#!/usr/bin/env bash
# Module: final report
# shellcheck shell=bash

module_report() {
  ui_step "Final report"
  detect_network_stack
  detect_dns_manager

  local cc qdisc iface mtu ufw_st f2b_st ssh_ports ipv6_st
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo n/a)"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo n/a)"
  iface="${NET_DEFAULT_IFACE:-n/a}"
  mtu="$(iface_mtu "$iface" 2>/dev/null || echo n/a)"
  if have_cmd ufw; then
    ufw_st="$(ufw status 2>/dev/null | head -n1)"
  else
    ufw_st="not installed"
  fi
  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    f2b_st="active"
  else
    f2b_st="inactive"
  fi
  ssh_ports="$(grep -hE '^[Pp]ort ' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}' | sort -u | tr '\n' ' ')"
  ssh_ports="$(trim "$ssh_ports")"
  [[ -n "$ssh_ports" ]] || ssh_ports="22 (default)"

  if [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)" == "1" ]]; then
    ipv6_st="disabled"
  else
    ipv6_st="enabled"
  fi

  echo
  ui_line 72
  printf '%s%s  MrClock — completion report%s\n' "$C_BOLD" "$C_ORANGE" "$C_RESET"
  ui_line 72
  ui_kv "OS" "$OS_PRETTY"
  ui_kv "Log file" "$SECUREBOX_LOG"
  ui_kv "Backup dir" "${SECUREBOX_BACKUP_ROOT}/${SECUREBOX_RUN_ID}"
  ui_kv "Network stack" "$NET_STACK"
  ui_kv "DNS manager" "$DNS_MANAGER"
  ui_kv "DNS now" "${DNS_CURRENT[*]:-unknown}"
  ui_kv "Interface / MTU" "${iface} / ${mtu}"
  ui_kv "BBR / qdisc" "${cc} / ${qdisc}"
  ui_kv "UFW" "$ufw_st"
  ui_kv "SSH ports" "$ssh_ports"
  ui_kv "Fail2Ban" "$f2b_st"
  ui_kv "IPv6" "$ipv6_st"
  ui_kv "Modules OK" "${SECUREBOX_OK_MODULES[*]:-none}"
  if ((${#SECUREBOX_SKIPPED_MODULES[@]})); then
    ui_kv "Skipped" "${SECUREBOX_SKIPPED_MODULES[*]}"
  fi
  if ((${#SECUREBOX_FAILED_MODULES[@]})); then
    ui_kv "Failed" "${SECUREBOX_FAILED_MODULES[*]}"
  fi
  if is_true "${SECUREBOX_ANSWERS[reboot_needed]:-no}" || [[ -f /var/run/reboot-required ]]; then
    ui_warn "Reboot recommended to finalize kernel/IPv6/network changes."
  fi
  if [[ -f "${SECUREBOX_STATE_DIR}/ssh_cutover" && "$(cat "${SECUREBOX_STATE_DIR}/ssh_cutover")" == "pending" ]]; then
    ui_warn "SSH cutover still PENDING — both old and new ports are listening."
    ui_info "New terminal test: ssh -p $(cat "${SECUREBOX_STATE_DIR}/ssh_new_port") USER@HOST"
  fi
  ui_line 72
  echo
}
