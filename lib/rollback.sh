#!/usr/bin/env bash
# Timed auto-rollback via systemd-run (SSH/UFW/DNS/MTU)
# shellcheck shell=bash

SECUREBOX_ROLLBACK_DIR="${SECUREBOX_STATE_DIR}/rollback"

# Default armed window (seconds). 0 = disabled.
SECUREBOX_ROLLBACK_SECONDS="${SECUREBOX_ROLLBACK_SECONDS:-120}"

_rollback_disarm_prior() {
  # Stop any previous timer/unit for this kind. Does NOT touch a script path
  # that the caller is about to publish (pass keep_script to preserve it).
  local kind="$1"
  local keep_script="${2:-}"
  mkdir -p "$SECUREBOX_ROLLBACK_DIR"

  local unit=""
  if [[ -f "${SECUREBOX_ROLLBACK_DIR}/${kind}.unit" ]]; then
    unit="$(tr -d '[:space:]' <"${SECUREBOX_ROLLBACK_DIR}/${kind}.unit")"
  fi
  if [[ -n "$unit" ]] && have_cmd systemctl; then
    systemctl stop "${unit}.timer" >/dev/null 2>&1 || true
    systemctl stop "$unit" >/dev/null 2>&1 || true
    systemctl reset-failed "$unit" >/dev/null 2>&1 || true
    systemctl reset-failed "${unit}.timer" >/dev/null 2>&1 || true
  fi
  rm -f "${SECUREBOX_ROLLBACK_DIR}/${kind}.unit" \
        "${SECUREBOX_ROLLBACK_DIR}/${kind}.script" \
        "${SECUREBOX_ROLLBACK_DIR}/${kind}.confirmed" 2>/dev/null || true

  local f
  for f in "${SECUREBOX_ROLLBACK_DIR}/${kind}"-*.sh; do
    [[ -e "$f" ]] || continue
    if [[ -n "$keep_script" && "$f" == "$keep_script" ]]; then
      continue
    fi
    rm -f "$f"
  done
}

schedule_timed_rollback() {
  local kind="$1"
  local seconds="${2:-${SECUREBOX_ROLLBACK_SECONDS:-120}}"
  is_uint "$seconds" || return 1
  (( seconds > 0 )) || return 0

  # Without a TTY the operator cannot confirm — arming would auto-revert
  # one-click / curl|bash runs (e.g. UFW disable after 120s). Refuse.
  if ! have_tty; then
    ui_info "Timed rollback skipped for ${kind}: no TTY to confirm within ${seconds}s"
    return 0
  fi

  have_cmd systemd-run || {
    ui_warn "systemd-run unavailable — timed rollback not armed for ${kind}"
    return 1
  }

  mkdir -p "$SECUREBOX_ROLLBACK_DIR"
  local stamp unit script
  stamp="$(date +%s)"
  unit="securebox-rollback-${kind}-${stamp}"
  script="${SECUREBOX_ROLLBACK_DIR}/${kind}-${stamp}.sh"

  # Disarm ANY prior rollback for this kind BEFORE writing the new script
  _rollback_disarm_prior "$kind"

  local run_id="$SECUREBOX_RUN_ID"
  local backup_root="${SECUREBOX_BACKUP_ROOT}/${run_id}"
  local state_dir="$SECUREBOX_STATE_DIR"

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
        mkdir -p /etc/ssh/sshd_config.d
        cp -a "${backup_root}/etc/ssh/sshd_config.d/00-securebox.conf" /etc/ssh/sshd_config.d/00-securebox.conf
      else
        rm -f /etc/ssh/sshd_config.d/00-securebox.conf
      fi
      # Legacy drop-in
      if [[ -f "${backup_root}/etc/ssh/sshd_config.d/99-securebox.conf" ]]; then
        cp -a "${backup_root}/etc/ssh/sshd_config.d/99-securebox.conf" /etc/ssh/sshd_config.d/99-securebox.conf
      else
        rm -f /etc/ssh/sshd_config.d/99-securebox.conf
      fi
    fi
    # Restore ssh.socket drop-in (Ubuntu 24.04+)
    sock_dropin="/etc/systemd/system/ssh.socket.d/00-securebox.conf"
    sock_bak="${backup_root}/etc/systemd/system/ssh.socket.d/00-securebox.conf"
    if [[ -f "\$sock_bak" ]]; then
      mkdir -p /etc/systemd/system/ssh.socket.d
      cp -a "\$sock_bak" "\$sock_dropin"
    else
      rm -f "\$sock_dropin"
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    mkdir -p /run/sshd
    if systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
      systemctl restart ssh.socket >/dev/null 2>&1 || true
      systemctl try-reload-or-restart ssh >/dev/null 2>&1 || true
    elif sshd -t 2>/dev/null; then
      systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    fi
    # Clear cutover state so re-runs do not keep dual-port intent
    rm -f "${state_dir}/ssh_cutover" "${state_dir}/ssh_old_port" "${state_dir}/ssh_new_port" 2>/dev/null || true
    ;;
  ufw)
    if [[ -f "${state_dir}/ufw_was_enabled" ]] && grep -qx no "${state_dir}/ufw_was_enabled"; then
      ufw --force disable 2>/dev/null || true
    fi
    ;;
  dns)
    rm -f /etc/systemd/resolved.conf.d/99-securebox-dns.conf 2>/dev/null || true
    systemctl restart systemd-resolved 2>/dev/null || true
    ;;
  mtu)
    iface=\$(cat "${state_dir}/mtu_iface" 2>/dev/null || true)
    old=\$(cat "${state_dir}/mtu_\${iface}" 2>/dev/null || true)
    if [[ -n "\$iface" && -n "\$old" ]]; then
      ip link set dev "\$iface" mtu "\$old" 2>/dev/null || true
    fi
    ;;
esac
rm -f "$script" "${SECUREBOX_ROLLBACK_DIR}/${kind}.unit" "${SECUREBOX_ROLLBACK_DIR}/${kind}.script"
EOF
  chmod 700 "$script"

  if systemd-run --unit="$unit" --on-active="${seconds}s" --timer-property=AccuracySec=1s \
      /bin/bash "$script" >/dev/null 2>&1; then
    printf '%s\n' "$unit" >"${SECUREBOX_ROLLBACK_DIR}/${kind}.unit"
    printf '%s\n' "$script" >"${SECUREBOX_ROLLBACK_DIR}/${kind}.script"
    # Sanity: script must still exist after arming (regression guard)
    if [[ ! -f "$script" ]]; then
      ui_error "Timed rollback for ${kind}: script missing after arm — not advertising rollback"
      return 1
    fi
    ui_warn "Timed rollback armed for ${kind}: reverts in ${seconds}s unless you confirm"
    return 0
  fi
  rm -f "$script"
  ui_warn "Failed to arm timed rollback for ${kind}"
  return 1
}

cancel_timed_rollback() {
  local kind="$1"
  mkdir -p "$SECUREBOX_ROLLBACK_DIR"
  # Marker first so a race with the timer is a no-op
  touch "${SECUREBOX_ROLLBACK_DIR}/${kind}.confirmed"
  _rollback_disarm_prior "$kind"
  # Keep confirmed marker so a late-firing copy still exits
  touch "${SECUREBOX_ROLLBACK_DIR}/${kind}.confirmed"
  return 0
}

confirm_timed_changes() {
  local kind
  for kind in ssh ufw dns mtu; do
    cancel_timed_rollback "$kind" >/dev/null 2>&1 || true
  done
  ui_success "Timed rollbacks cancelled — changes kept"
}

# True when a rollback script+unit are actually armed for kind
rollback_is_armed() {
  local kind="$1"
  local script=""
  [[ -f "${SECUREBOX_ROLLBACK_DIR}/${kind}.script" ]] || return 1
  script="$(tr -d '[:space:]' <"${SECUREBOX_ROLLBACK_DIR}/${kind}.script")"
  [[ -n "$script" && -f "$script" ]]
}
