#!/usr/bin/env bash
# Module: UFW autopilot — only when user explicitly enabled UFW
# shellcheck shell=bash

module_ufw() {
  ui_step "UFW firewall"

  # STRICT: do nothing unless user explicitly said enable UFW
  if ! require_answer_yes ufw_enable ufw "UFW enable not explicitly yes"; then
    module_skip "ufw" "ufw_enable='${SECUREBOX_ANSWERS[ufw_enable]:-}' — firewall left untouched"
    return 0
  fi

  if ! apt_install_safe ufw; then
    module_fail "ufw" "failed to install ufw"
    confirm_continue_on_error "ufw" "ufw install failed" || return 1
    return 0
  fi

  backup_file /etc/ufw/ufw.conf
  backup_file /etc/default/ufw
  # Rulesets — needed for accurate restore
  backup_file /etc/ufw/user.rules
  backup_file /etc/ufw/user6.rules
  backup_file /etc/ufw/before.rules
  backup_file /etc/ufw/after.rules
  backup_file /etc/ufw/before6.rules
  backup_file /etc/ufw/after6.rules

  if answered_yes disable_ipv6; then
    sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw || true
  else
    sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw || true
  fi

  # Reset only when explicitly requested
  if answered_yes ufw_reset; then
    ufw --force reset >/dev/null 2>&1 || true
  fi

  ufw default deny incoming >/dev/null 2>&1 || true
  ufw default allow outgoing >/dev/null 2>&1 || true

  local ssh_current ssh_new
  ssh_current="${SECUREBOX_ANSWERS[ssh_current_port]:-22}"
  ssh_new="${SECUREBOX_ANSWERS[ssh_port]:-$ssh_current}"

  ufw allow "${ssh_current}/tcp" comment 'MrClock SSH current' >/dev/null 2>&1 || true
  if [[ "$ssh_new" != "$ssh_current" ]]; then
    ufw allow "${ssh_new}/tcp" comment 'MrClock SSH new' >/dev/null 2>&1 || true
  fi

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
    ufw allow "${port}/${proto}" comment "MrClock allow" >/dev/null 2>&1 || true
  done

  if answered_yes ufw_auto_discover; then
    while read -r proto port; do
      [[ -z "$port" ]] && continue
      if [[ "$port" == "$ssh_current" || "$port" == "$ssh_new" ]]; then
        continue
      fi
      ufw allow "${port}/${proto}" comment "MrClock discovered" >/dev/null 2>&1 || true
    done < <(discover_public_ports)
  fi

  if ! ufw status | grep -Eq "${ssh_current}/tcp|${ssh_new}/tcp"; then
    module_fail "ufw" "refusing to enable UFW without SSH allow rules"
    confirm_continue_on_error "ufw" "SSH rules missing — UFW not enabled" || return 1
    return 0
  fi

  ufw --force enable >/dev/null 2>&1 || true
  systemctl enable ufw >/dev/null 2>&1 || true
  module_ok "ufw"
  ui_success "UFW enabled with SSH and approved ports"
}
