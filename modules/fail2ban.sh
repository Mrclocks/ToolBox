#!/usr/bin/env bash
# Module: Fail2Ban — only when explicitly enabled
# shellcheck shell=bash

_fail2ban_admin_ips() {
  # Space-separated admin IPs (SSH sessions + PGCTB_ADMIN_IPS) — never banned
  local -a ips=()
  if declare -F pgctb_admin_ips >/dev/null 2>&1; then
    mapfile -t ips < <(pgctb_admin_ips)
  elif [[ -n "${SSH_CONNECTION:-}" ]]; then
    ips=("${SSH_CONNECTION%% *}")
  fi
  printf '%s\n' "${ips[*]}"
}

module_fail2ban() {
  ui_step "Fail2Ban"

  if ! require_answer_yes enable_fail2ban fail2ban "Fail2Ban not explicitly enabled"; then
    module_skip "fail2ban" "enable_fail2ban='${PGCTB_ANSWERS[enable_fail2ban]:-}'"
    return 0
  fi

  local ssh_port new_port ports
  ssh_port="${PGCTB_ANSWERS[ssh_current_port]:-22}"
  new_port="${PGCTB_ANSWERS[ssh_port]:-$ssh_port}"
  if [[ "$new_port" != "$ssh_port" ]]; then
    ports="${ssh_port},${new_port}"
  else
    ports="${ssh_port}"
  fi

  local bantime findtime maxretry
  bantime="${PGCTB_ANSWERS[f2b_bantime]:-1h}"
  findtime="${PGCTB_ANSWERS[f2b_findtime]:-10m}"
  maxretry="${PGCTB_ANSWERS[f2b_maxretry]:-4}"

  local backend="auto"
  if [[ ! -f /var/log/auth.log ]]; then
    backend="systemd"
    ui_info "No /var/log/auth.log — using Fail2Ban backend=systemd"
  fi

  local admin_ip ignore
  admin_ip="$(_fail2ban_admin_ips)"
  ignore="127.0.0.1/8 ::1"
  if [[ -n "$admin_ip" ]]; then
    ignore="${ignore} ${admin_ip}"
    ui_info "Adding admin IPs to Fail2Ban ignoreip: ${admin_ip}"
  fi

  if is_dry_run; then
    ui_info "[dry-run] Would configure Fail2Ban (ports=${ports} backend=${backend} ignoreip+=${admin_ip:-none})"
    module_ok "fail2ban"
    return 0
  fi

  if ! apt_install_safe fail2ban; then
    module_fail "fail2ban" "install failed"
    confirm_continue_on_error "fail2ban" "install failed" || return 1
    return 0
  fi

  mkdir -p /etc/fail2ban/jail.d
  backup_file /etc/fail2ban/jail.d/securebox.conf

  cat >/etc/fail2ban/jail.d/securebox.conf <<EOF
# Managed by PGClockTB ${PGCTB_VERSION}
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
