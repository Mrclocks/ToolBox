#!/usr/bin/env bash
# Module: unattended-upgrades
# shellcheck shell=bash

module_unattended() {
  ui_step "Automatic security updates"

  if ! is_true "${SECUREBOX_ANSWERS[unattended]:-yes}"; then
    module_skip "unattended" "user declined"
    return 0
  fi

  if ! apt_install_safe unattended-upgrades apt-listchanges; then
    module_fail "unattended" "install failed"
    confirm_continue_on_error "unattended" "install failed" || return 1
    return 0
  fi

  backup_file /etc/apt/apt.conf.d/20auto-upgrades
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<EOF
// Managed by SecureBox ${SECUREBOX_VERSION}
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

  backup_file /etc/apt/apt.conf.d/50unattended-upgrades
  # Enable security origins; keep reboots manual unless user asked
  if [[ -f /etc/apt/apt.conf.d/50unattended-upgrades ]]; then
    sed -i 's#//\s*"\${distro_id}:\${distro_codename}-security";#        "${distro_id}:${distro_codename}-security";#' \
      /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null || true
  fi

  if is_true "${SECUREBOX_ANSWERS[unattended_reboot]:-no}"; then
    sed -i 's#//Unattended-Upgrade::Automatic-Reboot "false";#Unattended-Upgrade::Automatic-Reboot "true";#' \
      /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null || true
  fi

  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
  module_ok "unattended"
  ui_success "Unattended security upgrades enabled"
}
