#!/usr/bin/env bash
# Timed auto-rollback via systemd-run (SSH/UFW/DNS/MTU)
# shellcheck shell=bash

SECUREBOX_ROLLBACK_DIR="${SECUREBOX_STATE_DIR}/rollback"

schedule_timed_rollback() {
  local kind="$1"
  local seconds="${2:-120}"
  is_uint "$seconds" || return 1
  (( seconds > 0 )) || return 0
  have_cmd systemd-run || {
    ui_warn "systemd-run unavailable — timed rollback not armed for ${kind}"
    return 1
  }

  mkdir -p "$SECUREBOX_ROLLBACK_DIR"
  local stamp unit script
  stamp="$(date +%s)"
  unit="securebox-rollback-${kind}-${stamp}"
  script="${SECUREBOX_ROLLBACK_DIR}/${kind}-${stamp}.sh"

  local run_id="$SECUREBOX_RUN_ID"
  local backup_root="${SECUREBOX_BACKUP_ROOT}/${run_id}"

  cat >"$script" <<EOF
#!/usr/bin/env bash
# Auto-generated MrClock timed rollback for ${kind}
set -euo pipefail
MARKER="${SECUREBOX_ROLLBACK_DIR}/${kind}.confirmed"
if [[ -f "\$MARKER" ]]; then
  exit 0
fi
logger -t mrclock "Timed rollback firing for ${kind} (run ${run_id})"
case "${kind}" in
  ssh)
    if [[ -d "${backup_root}/etc/ssh" ]]; then
      cp -a "${backup_root}/etc/ssh/sshd_config" /etc/ssh/sshd_config 2>/dev/null || true
      if [[ -f "${backup_root}/etc/ssh/sshd_config.d/00-securebox.conf" ]]; then
        cp -a "${backup_root}/etc/ssh/sshd_config.d/00-securebox.conf" /etc/ssh/sshd_config.d/00-securebox.conf
      else
        rm -f /etc/ssh/sshd_config.d/00-securebox.conf
      fi
      mkdir -p /run/sshd
      sshd -t 2>/dev/null && (systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true)
    fi
    ;;
  ufw)
    if [[ -f "${SECUREBOX_STATE_DIR}/ufw_was_enabled" ]] && grep -qx no "${SECUREBOX_STATE_DIR}/ufw_was_enabled"; then
      ufw --force disable 2>/dev/null || true
    fi
    ;;
  dns)
    rm -f /etc/systemd/resolved.conf.d/99-securebox-dns.conf 2>/dev/null || true
    systemctl restart systemd-resolved 2>/dev/null || true
    ;;
  mtu)
    iface=\$(cat "${SECUREBOX_STATE_DIR}/mtu_iface" 2>/dev/null || true)
    old=\$(cat "${SECUREBOX_STATE_DIR}/mtu_\${iface}" 2>/dev/null || true)
    if [[ -n "\$iface" && -n "\$old" ]]; then
      ip link set dev "\$iface" mtu "\$old" 2>/dev/null || true
    fi
    ;;
esac
rm -f "$script"
EOF
  chmod 700 "$script"

  # Cancel any prior pending unit for this kind
  cancel_timed_rollback "$kind" >/dev/null 2>&1 || true
  rm -f "${SECUREBOX_ROLLBACK_DIR}/${kind}.confirmed"

  if systemd-run --unit="$unit" --on-active="${seconds}s" --timer-property=AccuracySec=1s \
      /bin/bash "$script" >/dev/null 2>&1; then
    printf '%s\n' "$unit" >"${SECUREBOX_ROLLBACK_DIR}/${kind}.unit"
    ui_warn "Timed rollback armed for ${kind}: reverts in ${seconds}s unless confirmed"
    return 0
  fi
  ui_warn "Failed to arm timed rollback for ${kind}"
  return 1
}

cancel_timed_rollback() {
  local kind="$1"
  mkdir -p "$SECUREBOX_ROLLBACK_DIR"
  touch "${SECUREBOX_ROLLBACK_DIR}/${kind}.confirmed"
  local unit=""
  if [[ -f "${SECUREBOX_ROLLBACK_DIR}/${kind}.unit" ]]; then
    unit="$(tr -d '[:space:]' <"${SECUREBOX_ROLLBACK_DIR}/${kind}.unit")"
  fi
  if [[ -n "$unit" ]] && have_cmd systemctl; then
    systemctl stop "${unit}.timer" >/dev/null 2>&1 || true
    systemctl stop "$unit" >/dev/null 2>&1 || true
    systemctl reset-failed "$unit" >/dev/null 2>&1 || true
  fi
  # Remove pending scripts for this kind
  rm -f "${SECUREBOX_ROLLBACK_DIR}/${kind}"-*.sh 2>/dev/null || true
  return 0
}

confirm_timed_changes() {
  # Call after user confirms connectivity still works
  local kind
  for kind in ssh ufw dns mtu; do
    cancel_timed_rollback "$kind" >/dev/null 2>&1 || true
  done
  ui_success "Timed rollbacks cancelled — changes kept"
}
