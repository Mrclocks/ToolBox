#!/usr/bin/env bash
# Module: Fail2Ban — only when explicitly enabled
# shellcheck shell=bash

_fail2ban_admin_ip() {
  local ip=""
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    ip="$(awk '{print $1}' <<<"$SSH_CONNECTION")"
  elif [[ -n "${SSH_CLIENT:-}" ]]; then
    ip="$(awk '{print $1}' <<<"$SSH_CLIENT")"
  fi
  # Prefer IPv4 for ignoreip simplicity; still accept IPv6
  if [[ -n "$ip" ]]; then
    printf '%s\n' "$ip"
  fi
}

module_fail2ban() {
  ui_step "Fail2Ban"

  if ! require_answer_yes enable_fail2ban fail2ban "Fail2Ban not explicitly enabled"; then
    module_skip "fail2ban" "enable_fail2ban='${SECUREBOX_ANSWERS[enable_fail2ban]:-}'"
    return 0
  fi

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

  local backend="auto"
  if [[ ! -f /var/log/auth.log ]]; then
    backend="systemd"
    ui_info "No /var/log/auth.log — using Fail2Ban backend=systemd"
  fi

  local admin_ip ignore
  admin_ip="$(_fail2ban_admin_ip)"
  ignore="127.0.0.1/8 ::1"
  if [[ -n "$admin_ip" ]]; then
    ignore="${ignore} ${admin_ip}"
    ui_info "Adding admin IP to Fail2Ban ignoreip: ${admin_ip}"
  fi

  if is_true "${SECUREBOX_DRY_RUN:-0}"; then
    ui_info "[dry-run] Would configure Fail2Ban (ports=${ports} backend=${backend})"
    module_ok "fail2ban"
    return 0
  fi

  cat >/etc/fail2ban/jail.d/securebox.conf <<EOF
# Managed by MrClock ${SECUREBOX_VERSION}
[DEFAULT]
bantime  = ${bantime}
findtime = ${findtime}
maxretry = ${maxretry}
bantime.increment = true
backend  = ${backend}
ignoreip = ${ignore}

[sshd]
enabled = true
port    = ${ports}
filter  = sshd
mode    = normal
EOF

  service_enable_start fail2ban
  systemctl restart fail2ban >/dev/null 2>&1 || true

  if systemctl is-active --quiet fail2ban 2>/dev/null \
     || fail2ban-client ping >/dev/null 2>&1; then
    module_ok "fail2ban"
    ui_success "Fail2Ban active (sshd ports: ${ports}; backend=${backend})"
  elif [[ -f /etc/fail2ban/jail.d/securebox.conf ]]; then
    module_ok "fail2ban"
    ui_success "Fail2Ban configured (sshd ports: ${ports}) — start service when systemd is available"
  else
    module_fail "fail2ban" "service not active"
    confirm_continue_on_error "fail2ban" "service failed to start" || return 1
  fi
}
