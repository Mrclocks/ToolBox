#!/usr/bin/env bash
# Module: restore MrClock-managed changes from a backup run
# Restores: DNS / MTU / SSH / UFW / Fail2Ban / sysctl / abuse / related confs
# shellcheck shell=bash

# Files MrClock may create even when no prior copy existed
RESTORE_MANAGED_PATHS=(
  /etc/ssh/sshd_config.d/99-securebox.conf
  /etc/systemd/resolved.conf.d/99-securebox-dns.conf
  /etc/netplan/99-securebox-mtu.yaml
  /etc/netplan/99-securebox-dns.yaml
  /etc/sysctl.d/99-securebox-bbr-network.conf
  /etc/sysctl.d/99-securebox-disable-ipv6.conf
  /etc/fail2ban/jail.d/securebox.conf
  /etc/nftables.d/securebox-abuse.nft
  /etc/apt/apt.conf.d/20auto-upgrades
)
RESTORE_COUNT_RESTORED=0
RESTORE_COUNT_REMOVED=0

_restore_list_runs() {
  # Newest first — print run ids that have a backup directory
  local d
  if [[ -d "$SECUREBOX_BACKUP_ROOT" ]]; then
    # shellcheck disable=SC2012
    ls -1dt "${SECUREBOX_BACKUP_ROOT}"/*/ 2>/dev/null | while read -r d; do
      [[ -d "$d" ]] || continue
      basename "${d%/}"
    done
  fi
}

_restore_pick_default_run() {
  local r
  if [[ -r "${SECUREBOX_STATE_DIR}/last_backup_run" ]]; then
    r="$(tr -d '[:space:]' <"${SECUREBOX_STATE_DIR}/last_backup_run")"
    if [[ -n "$r" && "$r" != "$SECUREBOX_RUN_ID" && -d "${SECUREBOX_BACKUP_ROOT}/${r}" ]]; then
      printf '%s\n' "$r"
      return 0
    fi
  fi
  while IFS= read -r r; do
    [[ -z "$r" || "$r" == "$SECUREBOX_RUN_ID" ]] && continue
    [[ -d "${SECUREBOX_BACKUP_ROOT}/${r}" ]] || continue
    printf '%s\n' "$r"
    return 0
  done < <(_restore_list_runs)
  return 1
}

_restore_file_from_backup() {
  local backup_root="$1"
  local abs="$2"
  local src="${backup_root}${abs}"
  if [[ -e "$src" ]]; then
    mkdir -p "$(dirname "$abs")"
    # Safety copy of current file before overwrite
    if [[ -e "$abs" ]]; then
      backup_file "$abs"
    else
      backup_file "$abs"  # marks REMOVE in safety run if missing — ok
    fi
    cp -a "$src" "$abs"
    log INFO "Restored $abs from backup"
    ui_info "Restored: ${abs}"
    return 0
  fi
  return 1
}

_restore_remove_file() {
  local abs="$1"
  if [[ -e "$abs" ]]; then
    backup_file "$abs"
    rm -f "$abs"
    log INFO "Removed managed file on restore: $abs"
    ui_info "Removed: ${abs}"
  fi
}

_restore_apply_manifest() {
  local backup_root="$1"
  local manifest="${backup_root}/MANIFEST.txt"
  local line op path
  RESTORE_COUNT_RESTORED=0
  RESTORE_COUNT_REMOVED=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    op="${line%%|*}"
    path="${line#*|}"
    [[ -n "$path" ]] || continue
    case "$op" in
      RESTORE)
        if _restore_file_from_backup "$backup_root" "$path"; then
          RESTORE_COUNT_RESTORED=$((RESTORE_COUNT_RESTORED + 1))
        else
          ui_warn "Backup missing file for RESTORE: ${path}"
        fi
        ;;
      REMOVE)
        _restore_remove_file "$path"
        RESTORE_COUNT_REMOVED=$((RESTORE_COUNT_REMOVED + 1))
        ;;
    esac
  done <"$manifest"
}

_restore_apply_legacy_tree() {
  # Backups without MANIFEST: copy every file back, then drop known managed files absent from backup
  local backup_root="$1"
  local f rel abs
  RESTORE_COUNT_RESTORED=0
  RESTORE_COUNT_REMOVED=0

  while IFS= read -r -d '' f; do
    rel="${f#"${backup_root}/"}"
    [[ "$rel" == "MANIFEST.txt" ]] && continue
    abs="/${rel}"
    if _restore_file_from_backup "$backup_root" "$abs"; then
      RESTORE_COUNT_RESTORED=$((RESTORE_COUNT_RESTORED + 1))
    fi
  done < <(find "$backup_root" -type f -print0 2>/dev/null)

  local p
  for p in "${RESTORE_MANAGED_PATHS[@]}"; do
    if [[ -e "$p" && ! -e "${backup_root}${p}" ]]; then
      _restore_remove_file "$p"
      RESTORE_COUNT_REMOVED=$((RESTORE_COUNT_REMOVED + 1))
    fi
  done
  # iface-specific networkd drop-ins / link files
  local nd
  for nd in /etc/systemd/network/10-securebox-*.network /etc/systemd/network/10-securebox-*.link; do
    [[ -e "$nd" ]] || continue
    if [[ ! -e "${backup_root}${nd}" ]]; then
      _restore_remove_file "$nd"
      RESTORE_COUNT_REMOVED=$((RESTORE_COUNT_REMOVED + 1))
    fi
  done
}

_restore_reload_services() {
  ui_info "Reloading services after restore..."

  # sysctl
  sysctl --system >/dev/null 2>&1 || true

  # DNS / network
  if have_cmd netplan; then
    netplan generate >/dev/null 2>&1 || true
    netplan apply >/dev/null 2>&1 || true
  fi
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    systemctl restart systemd-resolved >/dev/null 2>&1 || true
  fi
  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    systemctl reload NetworkManager >/dev/null 2>&1 || true
  fi

  # SSH — only reload if config validates
  mkdir -p /run/sshd 2>/dev/null || true
  if have_cmd sshd && sshd -t 2>/dev/null; then
    if systemctl is-active --quiet ssh 2>/dev/null; then
      systemctl reload ssh >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1 || true
    elif systemctl is-active --quiet sshd 2>/dev/null; then
      systemctl reload sshd >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
    else
      service ssh reload 2>/dev/null || service sshd reload 2>/dev/null || true
    fi
    ui_success "SSH config reloaded"
  else
    ui_warn "sshd -t failed after restore — SSH service not reloaded (check config)"
  fi

  # Fail2Ban
  if [[ -d /etc/fail2ban ]]; then
    systemctl restart fail2ban >/dev/null 2>&1 || true
  fi

  # UFW
  if have_cmd ufw; then
    if [[ -f /etc/ufw/ufw.conf ]] && grep -qiE '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null; then
      ufw reload >/dev/null 2>&1 || true
      ui_info "UFW reloaded"
    fi
  fi

  # GRUB (if restored) — regenerate if update-grub exists
  if have_cmd update-grub; then
    update-grub >/dev/null 2>&1 || true
  elif have_cmd grub-mkconfig && [[ -d /boot/grub ]]; then
    grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
  fi
}

_restore_preview() {
  local backup_root="$1"
  local manifest="${backup_root}/MANIFEST.txt"
  ui_box_start "Restore preview — ${backup_root}"
  if [[ -f "$manifest" ]]; then
    local r c
    r="$(grep -c '^RESTORE|' "$manifest" 2>/dev/null || true)"
    c="$(grep -c '^REMOVE|' "$manifest" 2>/dev/null || true)"
    r="${r:-0}"
    c="${c:-0}"
    ui_kv "Files to restore" "$r"
    ui_kv "Managed files to remove" "$c"
    ui_info "Sample:"
    grep -E '^(RESTORE|REMOVE)\|' "$manifest" 2>/dev/null | head -n 12 | while read -r L; do
      printf '   %s\n' "$L"
    done
  else
    local n
    n="$(find "$backup_root" -type f ! -name MANIFEST.txt 2>/dev/null | wc -l | tr -d ' ')"
    ui_kv "Legacy backup files" "$n"
    ui_info "Will copy all backed-up files and remove MrClock drop-ins not in backup"
  fi
  ui_kv "Also" "Remove abuse nft/iptables rules created by MrClock"
  ui_box_end
}

module_restore() {
  ui_step "Restore previous MrClock changes"

  if ! require_answer_yes do_restore restore "restore not explicitly confirmed"; then
    module_skip "restore" "do_restore='${SECUREBOX_ANSWERS[do_restore]:-}'"
    return 0
  fi

  local run_id="${SECUREBOX_ANSWERS[restore_run]:-}"
  if [[ -z "$run_id" ]]; then
    run_id="$(_restore_pick_default_run)"
  fi
  if [[ -z "$run_id" || ! -d "${SECUREBOX_BACKUP_ROOT}/${run_id}" ]]; then
    module_fail "restore" "no backup run found under ${SECUREBOX_BACKUP_ROOT}"
    confirm_continue_on_error "restore" "no backup available" || return 1
    return 0
  fi

  local backup_root="${SECUREBOX_BACKUP_ROOT}/${run_id}"
  ui_info "Using backup run: ${run_id}"
  _restore_preview "$backup_root"

  # Safety: new backup run id for current state before we overwrite
  # (SECUREBOX_RUN_ID already unique for this process)
  record_backup_run
  ui_info "Safety snapshot of current files → ${SECUREBOX_BACKUP_ROOT}/${SECUREBOX_RUN_ID}"

  local restored=0 removed=0
  RESTORE_COUNT_RESTORED=0
  RESTORE_COUNT_REMOVED=0
  if [[ -f "${backup_root}/MANIFEST.txt" ]]; then
    _restore_apply_manifest "$backup_root"
  else
    _restore_apply_legacy_tree "$backup_root"
  fi
  restored="${RESTORE_COUNT_RESTORED:-0}"
  removed="${RESTORE_COUNT_REMOVED:-0}"
  # Force numeric (avoid empty / garbage under set -u)
  [[ "$restored" =~ ^[0-9]+$ ]] || restored=0
  [[ "$removed" =~ ^[0-9]+$ ]] || removed=0

  # Always tear down MrClock abuse table (rules are not plain file restore)
  if declare -F _abuse_remove_all >/dev/null 2>&1; then
    ui_info "Removing MrClock abuse IP block rules..."
    _abuse_remove_all
  fi
  # If nftables.conf was restored, strip stale include if abuse file gone
  if [[ -f /etc/nftables.conf && ! -f /etc/nftables.d/securebox-abuse.nft ]]; then
    if grep -q 'securebox-abuse.nft' /etc/nftables.conf 2>/dev/null; then
      backup_file /etc/nftables.conf
      sed -i '/securebox-abuse\.nft/d' /etc/nftables.conf || true
    fi
  fi

  _restore_reload_services

  # Clear pending SSH cutover state
  rm -f "${SECUREBOX_STATE_DIR}/ssh_cutover" \
        "${SECUREBOX_STATE_DIR}/ssh_old_port" \
        "${SECUREBOX_STATE_DIR}/ssh_new_port" 2>/dev/null || true

  record_backup_run
  module_ok "restore"
  ui_success "Restore complete from ${run_id} — restored ${restored} file(s), removed ${removed}"
  ui_warn "Package upgrades / deleted logs are NOT reverted (by design)."
}
