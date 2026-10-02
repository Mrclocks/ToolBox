#!/usr/bin/env bash
# Module: Fail2Ban
# shellcheck shell=bash

module_fail2ban() {
  ui_step "Fail2Ban"
  if ! apt_install_safe fail2ban; then
    module_fail "fail2ban" "install failed"
    confirm_continue_on_error "fail2ban" "install failed" || return 1
    return 0
  fi

  mkdir -p /etc/fail2ban/jail.d
  backup_file /etc/fail2ban/jail.d/securebox.conf

  local ssh_port new_port ports
  ssh_port="${SECUREBOX_ANSWERS[ssh_current_port]:-22}"
  new_port="${SECUREBOX_ANSWERS[ssh_port]:-$ssh_port}"
  if [[ "$new_port" != "$ssh_port" ]]; then
    ports="${ssh_port},${new_port}"
  else
    ports="${ssh_port}"
  fi

  local bantime findtime maxretry
  bantime="${SECUREBOX_ANSWERS[f2b_bantime]:-1h}"
  findtime="${SECUREBOX_ANSWERS[f2b_findtime]:-10m}"
  maxretry="${SECUREBOX_ANSWERS[f2b_maxretry]:-4}"

  cat >/etc/fail2ban/jail.d/securebox.conf <<EOF
# Managed by SecureBox ${SECUREBOX_VERSION}
[DEFAULT]
bantime  = ${bantime}
findtime = ${findtime}
maxretry = ${maxretry}
backend  = systemd
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port    = ${ports}
filter  = sshd
mode    = normal
EOF

  service_enable_start fail2ban
  systemctl restart fail2ban >/dev/null 2>&1 || true

  if systemctl is-active --quiet fail2ban; then
    module_ok "fail2ban"
    ui_success "Fail2Ban active (sshd ports: ${ports})"
  else
    module_fail "fail2ban" "service not active"
    confirm_continue_on_error "fail2ban" "service failed to start" || return 1
  fi
}
