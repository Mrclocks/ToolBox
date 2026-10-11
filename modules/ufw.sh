#!/usr/bin/env bash
# Module: UFW autopilot — only when user explicitly enabled UFW
# shellcheck shell=bash

_ufw_parse_port_item() {
  # Sets _ufw_port and _ufw_proto from item like "443", "51820/udp", "1000:2000/tcp"
  local item="$1"
  _ufw_proto="tcp"
  _ufw_port=""
  if [[ "$item" == */* ]]; then
    _ufw_proto="${item##*/}"
    _ufw_port="${item%/*}"
  else
    _ufw_port="$item"
  fi
  case "${_ufw_proto,,}" in
    tcp|udp|any) _ufw_proto="${_ufw_proto,,}" ;;
    *) return 1 ;;
  esac
  is_port_spec "$_ufw_port"
}

_ufw_collect_ssh_ports() {
  # Populate UFW_SSH_PORTS array from answers + live detection
  UFW_SSH_PORTS=()
  local -A seen=()
  local p

  p="${SECUREBOX_ANSWERS[ssh_current_port]:-}"
  if is_port "$p"; then seen["$p"]=1; fi
  p="${SECUREBOX_ANSWERS[ssh_port]:-}"
  if is_port "$p"; then seen["$p"]=1; fi

  while read -r p; do
    is_port "$p" && seen["$p"]=1
  done < <(detect_live_ssh_ports)

  if ((${#seen[@]} == 0)); then
    seen[22]=1
  fi
  for p in "${!seen[@]}"; do
    UFW_SSH_PORTS+=("$p")
  done
  # Stable order
  local sorted
  sorted="$(printf '%s\n' "${UFW_SSH_PORTS[@]}" | sort -n)"
  mapfile -t UFW_SSH_PORTS <<<"$sorted"
}

_ufw_ssh_rules_present() {
  # ufw status only prints "inactive" when disabled — use show added
  local added ports
  added="$(ufw show added 2>/dev/null || true)"
  [[ -z "$added" ]] && return 1
  local p
  for p in "${UFW_SSH_PORTS[@]}"; do
    if grep -Eq "(^|[[:space:]])${p}/tcp|[[:space:]]${p}[[:space:]]|allow[[:space:]]+${p}/tcp" <<<"$added"; then
      return 0
    fi
    # Also match bare port allow lines
    if grep -Eq "allow[[:space:]]+${p}([[:space:]]|$)" <<<"$added"; then
      return 0
    fi
  done
  return 1
}

_ufw_warn_reset_side_effects() {
  ui_warn "ufw reset wipes custom before.rules / after.rules (including NAT/MASQUERADE for WireGuard/OpenVPN)."
  if [[ -f /etc/default/ufw ]]; then
    local fwd
    fwd="$(awk -F= '/^DEFAULT_FORWARD_POLICY=/{gsub(/"/,"",$2); print $2; exit}' /etc/default/ufw)"
    if [[ "${fwd^^}" == "DROP" ]]; then
      ui_warn "DEFAULT_FORWARD_POLICY=DROP — VPN forwarding (WireGuard/OpenVPN) will break unless you allow FORWARD / set ACCEPT."
    fi
  fi
}

module_ufw() {
  ui_step "UFW firewall"

  # STRICT: do nothing unless user explicitly said enable UFW
  if ! require_answer_yes ufw_enable ufw "UFW enable not explicitly yes"; then
    module_skip "ufw" "ufw_enable='${SECUREBOX_ANSWERS[ufw_enable]:-}' — firewall left untouched"
    return 0
  fi

  if is_dry_run; then
    _ufw_collect_ssh_ports
    ui_info "[dry-run] Would install ufw, allow SSH ports: ${UFW_SSH_PORTS[*]:-22}"
    ui_info "[dry-run] Would allow extra: ${SECUREBOX_ANSWERS[ufw_ports]:-(none)}; discover=${SECUREBOX_ANSWERS[ufw_auto_discover]:-no}"
    ui_info "[dry-run] Would verify via 'ufw show added' then enable"
    module_ok "ufw"
    return 0
  fi

  if ! apt_install_safe ufw; then
    module_fail "ufw" "failed to install ufw"
    confirm_continue_on_error "ufw" "ufw install failed" || return 1
    return 0
  fi

  # Record whether UFW was enabled before we touch it (for live restore)
  mkdir -p "$SECUREBOX_STATE_DIR"
  if [[ ! -f "${SECUREBOX_STATE_DIR}/ufw_was_enabled" ]]; then
    if ufw status 2>/dev/null | grep -qi 'Status: active'; then
      echo "yes" >"${SECUREBOX_STATE_DIR}/ufw_was_enabled"
    else
      echo "no" >"${SECUREBOX_STATE_DIR}/ufw_was_enabled"
    fi
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
    _ufw_warn_reset_side_effects
    if have_tty; then
      if ! ui_confirm "Proceed with ufw reset? This destroys NAT/custom before.rules." "N"; then
        ui_warn "UFW reset skipped by user"
        SECUREBOX_ANSWERS["ufw_reset"]=no
      fi
    fi
  fi
  if answered_yes ufw_reset; then
    ufw --force reset >/dev/null 2>&1 || true
  fi

  ufw default deny incoming >/dev/null 2>&1 || true
  ufw default allow outgoing >/dev/null 2>&1 || true

  _ufw_collect_ssh_ports
  ui_info "SSH ports to protect: ${UFW_SSH_PORTS[*]}"

  local p
  for p in "${UFW_SSH_PORTS[@]}"; do
    ufw allow "${p}/tcp" comment 'MrClock SSH' >/dev/null 2>&1 || true
  done
  # Keep answer fields in sync for other modules
  SECUREBOX_ANSWERS[ssh_current_port]="${UFW_SSH_PORTS[0]}"
  if [[ -z "${SECUREBOX_ANSWERS[ssh_port]:-}" ]]; then
    SECUREBOX_ANSWERS[ssh_port]="${UFW_SSH_PORTS[0]}"
  fi

  local ports="${SECUREBOX_ANSWERS[ufw_ports]:-}"
  local item _ufw_port _ufw_proto
  local -a skipped=()
  for item in $ports; do
    [[ -z "$item" ]] && continue
    if ! _ufw_parse_port_item "$item"; then
      skipped+=("$item")
      continue
    fi
    ufw allow "${_ufw_port}/${_ufw_proto}" comment "MrClock allow" >/dev/null 2>&1 || true
  done
  if ((${#skipped[@]})); then
    ui_warn "Skipped invalid UFW port specs: ${skipped[*]}"
  fi

  if answered_yes ufw_auto_discover; then
    local proto port
    while read -r proto port; do
      [[ -z "$port" ]] && continue
      local skip=0
      for p in "${UFW_SSH_PORTS[@]}"; do
        [[ "$port" == "$p" ]] && skip=1 && break
      done
      (( skip )) && continue
      ufw allow "${port}/${proto}" comment "MrClock discovered" >/dev/null 2>&1 || true
    done < <(discover_public_ports)
  fi

  # Print rules BEFORE enable — critical for admin visibility
  ui_box_start "UFW rules that will be active (ufw show added)"
  ufw show added 2>/dev/null | while IFS= read -r line; do
    printf '   %s\n' "$line"
  done || true
  ui_box_end

  if ! _ufw_ssh_rules_present; then
    module_fail "ufw" "refusing to enable UFW without SSH allow rules (checked via ufw show added)"
    confirm_continue_on_error "ufw" "SSH rules missing — UFW not enabled" || return 1
    return 0
  fi

  # Warn about forward policy before enabling
  if [[ -f /etc/default/ufw ]]; then
    local fwd
    fwd="$(awk -F= '/^DEFAULT_FORWARD_POLICY=/{gsub(/"/,"",$2); print $2; exit}' /etc/default/ufw)"
    if [[ "${fwd^^}" == "DROP" ]]; then
      ui_warn "DEFAULT_FORWARD_POLICY=DROP — WireGuard/OpenVPN forwarded traffic may be blocked."
    fi
  fi

  ufw --force enable >/dev/null 2>&1 || true
  systemctl enable ufw >/dev/null 2>&1 || true

  local rollback_secs="${SECUREBOX_ROLLBACK_SECONDS:-120}"
  if have_cmd systemd-run && is_uint "$rollback_secs" && (( rollback_secs > 0 )); then
    if declare -F schedule_timed_rollback >/dev/null 2>&1; then
      schedule_timed_rollback "ufw" "$rollback_secs" || true
    fi
    if have_tty; then
      if ui_confirm "UFW is enabled — confirm you still have access (cancel auto-rollback)?" "Y"; then
        cancel_timed_rollback "ufw" || true
      fi
    fi
  fi

  module_ok "ufw"
  ui_success "UFW enabled with SSH and approved ports"
}
