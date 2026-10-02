#!/usr/bin/env bash
# Module: UFW autopilot
# shellcheck shell=bash

module_ufw() {
  ui_step "UFW firewall autopilot"

  if ! apt_install_safe ufw; then
    module_fail "ufw" "failed to install ufw"
    confirm_continue_on_error "ufw" "ufw install failed" || return 1
    return 0
  fi

  backup_file /etc/ufw/ufw.conf
  backup_file /etc/default/ufw

  # IPv6 UFW toggle based on answer (actual disable module may come later)
  if is_true "${SECUREBOX_ANSWERS[disable_ipv6]:-no}"; then
    sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw || true
  else
    sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw || true
  fi

  # Reset rules if requested (default for apply-all: soft reset to known-good)
  if is_true "${SECUREBOX_ANSWERS[ufw_reset]:-yes}"; then
    ufw --force reset >/dev/null 2>&1 || true
  fi

  ufw default deny incoming >/dev/null 2>&1 || true
  ufw default allow outgoing >/dev/null 2>&1 || true

  # Always allow SSH ports (current + new) BEFORE enable
  local ssh_current ssh_new
  ssh_current="${SECUREBOX_ANSWERS[ssh_current_port]:-22}"
  ssh_new="${SECUREBOX_ANSWERS[ssh_port]:-$ssh_current}"

  ufw allow "${ssh_current}/tcp" comment 'SecureBox SSH current' >/dev/null 2>&1 || true
  if [[ "$ssh_new" != "$ssh_current" ]]; then
    ufw allow "${ssh_new}/tcp" comment 'SecureBox SSH new' >/dev/null 2>&1 || true
  fi

  # User-approved ports from questionnaire (space-separated "proto/port" or just port=>tcp)
  local ports="${SECUREBOX_ANSWERS[ufw_ports]:-}"
  local item proto port
  for item in $ports; do
    if [[ "$item" == */* ]]; then
      proto="${item##*/}"
      port="${item%/*}"
    else
      port="$item"
      proto="tcp"
    fi
    is_port "$port" || continue
    ufw allow "${port}/${proto}" comment "SecureBox auto" >/dev/null 2>&1 || true
  done

  # Also auto-add discovered public listeners if user approved auto_discover
  if is_true "${SECUREBOX_ANSWERS[ufw_auto_discover]:-yes}"; then
    while read -r proto port; do
      [[ -z "$port" ]] && continue
      # skip ssh already handled
      if [[ "$port" == "$ssh_current" || "$port" == "$ssh_new" ]]; then
        continue
      fi
      ufw allow "${port}/${proto}" comment "SecureBox discovered" >/dev/null 2>&1 || true
    done < <(discover_public_ports)
  fi

  if is_true "${SECUREBOX_ANSWERS[ufw_enable]:-yes}"; then
    # Safety: ensure at least one SSH allow rule exists
    if ! ufw status | grep -Eq "${ssh_current}/tcp|${ssh_new}/tcp"; then
      module_fail "ufw" "refusing to enable UFW without SSH allow rules"
      confirm_continue_on_error "ufw" "SSH rules missing — UFW not enabled" || return 1
      return 0
    fi
    ufw --force enable >/dev/null 2>&1 || true
    systemctl enable ufw >/dev/null 2>&1 || true
    module_ok "ufw"
    ui_success "UFW enabled with SSH and approved ports"
  else
    ufw --force disable >/dev/null 2>&1 || true
    module_ok "ufw"
    ui_success "UFW rules prepared; UFW left disabled per your choice"
  fi
}
