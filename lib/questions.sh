#!/usr/bin/env bash
# SecureBox — questionnaires (all questions first, then execute)
# shellcheck shell=bash

declare -A SECUREBOX_ANSWERS=()

recommend_mtu() {
  # Prefer VPN-friendly default slightly under 1500 to reduce fragmentation
  local cur="${NET_DEFAULT_MTU:-1500}"
  if (( cur > 1500 )); then
    echo 1500
  elif (( cur == 1500 )); then
    echo 1400
  else
    echo "$cur"
  fi
}

recommend_ssh_port() {
  # High random-ish but stable suggestion in private range
  echo $(( 20000 + RANDOM % 20000 ))
}

questionnaire_common_safety() {
  # Reserved for shared defaults. continue_on_error is set by Apply All / one-click.
  :
}

ask_dns() {
  local labels=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && labels+=("$line")
  done < <(dns_preset_labels)

  local choice
  ui_menu choice "Choose DNS resolver" "${labels[@]}"
  SECUREBOX_ANSWERS[dns_choice]="$choice"

  local id label primary secondary
  IFS='|' read -r id label primary secondary <<<"${DNS_PRESETS[$((choice - 1))]}"
  SECUREBOX_ANSWERS[dns_id]="$id"

  case "$id" in
    custom)
      local p s
      while true; do
        ui_ask p "Primary DNS (IPv4)"
        is_ipv4 "$p" && break
        ui_warn "Enter a valid IPv4 address."
      done
      ui_ask s "Secondary DNS (optional IPv4)" ""
      if [[ -n "$s" ]] && ! is_ipv4 "$s"; then
        ui_warn "Ignoring invalid secondary DNS."
        s=""
      fi
      SECUREBOX_ANSWERS[dns_primary]="$p"
      SECUREBOX_ANSWERS[dns_secondary]="$s"
      ui_info "Custom DNS: ${p}${s:+ / $s}"
      ;;
    keep)
      SECUREBOX_ANSWERS[dns_primary]="${DNS_CURRENT[0]:-}"
      SECUREBOX_ANSWERS[dns_secondary]="${DNS_CURRENT[1]:-}"
      ui_info "Keeping current DNS: ${DNS_CURRENT[*]:-(none)}"
      ;;
    *)
      # Preset selected — fill automatically, never ask again
      SECUREBOX_ANSWERS[dns_primary]="$primary"
      SECUREBOX_ANSWERS[dns_secondary]="$secondary"
      ui_success "DNS auto-selected: ${primary} / ${secondary}"
      ;;
  esac
}

ask_mtu() {
  local rec
  rec="$(recommend_mtu)"
  echo
  ui_info "Default interface: ${NET_DEFAULT_IFACE:-unknown} (current MTU ${NET_DEFAULT_MTU:-?})"
  local choice
  ui_menu choice "MTU policy" \
    "Recommended VPN-friendly (${rec})" \
    "Standard Ethernet (1500)" \
    "WireGuard-ish (1420)" \
    "Conservative (1400)" \
    "Safe minimum (1280)" \
    "Keep current MTU" \
    "Custom value"
  case "$choice" in
    1) SECUREBOX_ANSWERS[mtu]="$rec" ;;
    2) SECUREBOX_ANSWERS[mtu]=1500 ;;
    3) SECUREBOX_ANSWERS[mtu]=1420 ;;
    4) SECUREBOX_ANSWERS[mtu]=1400 ;;
    5) SECUREBOX_ANSWERS[mtu]=1280 ;;
    6) SECUREBOX_ANSWERS[mtu]=keep ;;
    7)
      local m
      ui_ask_mtu m "Enter MTU" "$rec"
      SECUREBOX_ANSWERS[mtu]="$m"
      ;;
  esac
}

ask_ssh() {
  local current
  current="$(_ssh_current_port 2>/dev/null || echo 22)"
  SECUREBOX_ANSWERS[ssh_current_port]="$current"
  local suggestion
  suggestion="$(recommend_ssh_port)"

  echo
  ui_info "Current SSH port: ${current}"
  local choice
  ui_menu choice "SSH port action" \
    "Change to recommended (${suggestion})" \
    "Change to custom port" \
    "Keep current port (${current})"
  case "$choice" in
    1) SECUREBOX_ANSWERS[ssh_port]="$suggestion" ;;
    2)
      local p
      ui_ask_port p "New SSH port" "$suggestion"
      SECUREBOX_ANSWERS[ssh_port]="$p"
      ;;
    3) SECUREBOX_ANSWERS[ssh_port]="$current" ;;
  esac

  SECUREBOX_ANSWERS[ssh_wait_confirm]=yes

  # Password auth
  local has_key=0
  if [[ -s /root/.ssh/authorized_keys ]] || find /home -maxdepth 3 -path '*/.ssh/authorized_keys' -size +0 2>/dev/null | grep -q .; then
    has_key=1
  fi
  if (( has_key )); then
    if ui_confirm "SSH keys detected. Disable password authentication?" "N"; then
      SECUREBOX_ANSWERS[ssh_password_auth]=no
    else
      SECUREBOX_ANSWERS[ssh_password_auth]=keep
    fi
  else
    ui_warn "No SSH keys detected — password authentication will stay enabled."
    SECUREBOX_ANSWERS[ssh_password_auth]=keep
  fi

  local root_choice
  ui_menu root_choice "Root SSH login policy" \
    "Keep distribution default" \
    "prohibit-password (keys only for root)" \
    "Disable root login" \
    "Allow root login"
  case "$root_choice" in
    1) SECUREBOX_ANSWERS[ssh_permit_root]=keep ;;
    2) SECUREBOX_ANSWERS[ssh_permit_root]=prohibit-password ;;
    3) SECUREBOX_ANSWERS[ssh_permit_root]=no ;;
    4) SECUREBOX_ANSWERS[ssh_permit_root]=yes ;;
  esac
}

ask_ufw() {
  echo
  ui_info "Discovering listening ports..."
  local discovered
  discovered="$(discover_public_ports | awk '{printf "%s/%s ", $2, $1}')"
  discovered="$(trim "$discovered")"
  [[ -n "$discovered" ]] && ui_info "Discovered: ${discovered}" || ui_info "No public listeners found (besides what appears later)."

  if ui_confirm "Enable UFW after applying rules?" "Y"; then
    SECUREBOX_ANSWERS[ufw_enable]=yes
  else
    SECUREBOX_ANSWERS[ufw_enable]=no
  fi

  if ui_confirm "Auto-allow all currently discovered public ports?" "Y"; then
    SECUREBOX_ANSWERS[ufw_auto_discover]=yes
  else
    SECUREBOX_ANSWERS[ufw_auto_discover]=no
  fi

  local extra
  ui_ask extra "Extra ports to allow (e.g. 443 51820/udp 80/tcp) — empty to skip" ""
  SECUREBOX_ANSWERS[ufw_ports]="$extra"
  SECUREBOX_ANSWERS[ufw_reset]=yes
}

ask_ipv6() {
  if ui_confirm "Fully disable IPv6 on this server?" "N"; then
    SECUREBOX_ANSWERS[disable_ipv6]=yes
  else
    SECUREBOX_ANSWERS[disable_ipv6]=no
  fi
}

ask_abuse() {
  if ui_confirm "Block curated abuse/scanner IP ranges (full CIDR block in+out)?" "Y"; then
    SECUREBOX_ANSWERS[block_abuse]=yes
  else
    SECUREBOX_ANSWERS[block_abuse]=no
  fi
}

ask_unattended() {
  if ui_confirm "Enable automatic security updates (unattended-upgrades)?" "Y"; then
    SECUREBOX_ANSWERS[unattended]=yes
  else
    SECUREBOX_ANSWERS[unattended]=no
  fi
  SECUREBOX_ANSWERS[unattended_reboot]=no
}

ask_services() {
  if ui_confirm "Disable common unused services (avahi/cups/bluetooth/...)?" "Y"; then
    SECUREBOX_ANSWERS[disable_unused]=yes
  else
    SECUREBOX_ANSWERS[disable_unused]=no
  fi
  SECUREBOX_ANSWERS[disable_snapd]=no
}

ask_fail2ban_params() {
  SECUREBOX_ANSWERS[f2b_bantime]=1h
  SECUREBOX_ANSWERS[f2b_findtime]=10m
  SECUREBOX_ANSWERS[f2b_maxretry]=4
}

review_answers() {
  ui_box_start "Review your choices"
  local dns_show="${SECUREBOX_ANSWERS[dns_id]:-#${SECUREBOX_ANSWERS[dns_choice]:-}}"
  if [[ -n "${SECUREBOX_ANSWERS[dns_primary]:-}" ]]; then
    dns_show="${dns_show} (${SECUREBOX_ANSWERS[dns_primary]}${SECUREBOX_ANSWERS[dns_secondary]:+ / ${SECUREBOX_ANSWERS[dns_secondary]}})"
  fi
  ui_kv "DNS" "$dns_show"
  ui_kv "MTU" "${SECUREBOX_ANSWERS[mtu]:-}"
  ui_kv "SSH port" "${SECUREBOX_ANSWERS[ssh_current_port]:-?} → ${SECUREBOX_ANSWERS[ssh_port]:-?}"
  ui_kv "SSH password" "${SECUREBOX_ANSWERS[ssh_password_auth]:-}"
  ui_kv "Root login" "${SECUREBOX_ANSWERS[ssh_permit_root]:-}"
  ui_kv "Disable IPv6" "${SECUREBOX_ANSWERS[disable_ipv6]:-}"
  ui_kv "Block abuse ranges" "${SECUREBOX_ANSWERS[block_abuse]:-}"
  ui_kv "UFW enable" "${SECUREBOX_ANSWERS[ufw_enable]:-}"
  ui_kv "UFW auto ports" "${SECUREBOX_ANSWERS[ufw_auto_discover]:-}"
  ui_kv "UFW extra" "${SECUREBOX_ANSWERS[ufw_ports]:-(none)}"
  ui_kv "Unattended upgrades" "${SECUREBOX_ANSWERS[unattended]:-}"
  ui_kv "Disable unused svcs" "${SECUREBOX_ANSWERS[disable_unused]:-}"
  ui_box_end
}

questionnaire_all() {
  SECUREBOX_ANSWERS[continue_on_error]=yes
  ui_clear
  ui_step "Questions first — then everything will be applied"
  ask_dns
  ask_mtu
  ask_ssh
  ask_ipv6
  ask_abuse
  ask_ufw
  ask_fail2ban_params
  ask_unattended
  ask_services
  review_answers
  if ! ui_confirm "Proceed with Apply All using these answers?" "Y"; then
    ui_warn "Cancelled by user."
    return 1
  fi
  return 0
}

# Per-feature questionnaires (only what that feature needs)
questionnaire_dns_only() { questionnaire_common_safety; ask_dns; review_answers; ui_confirm "Apply DNS now?" "Y"; }
questionnaire_mtu_only() { questionnaire_common_safety; ask_mtu; review_answers; ui_confirm "Apply MTU now?" "Y"; }
questionnaire_ssh_only() { questionnaire_common_safety; ask_ssh; review_answers; ui_confirm "Apply SSH changes now?" "Y"; }
questionnaire_ufw_only() {
  questionnaire_common_safety
  # Need ssh ports for safety
  SECUREBOX_ANSWERS[ssh_current_port]="$(_ssh_current_port 2>/dev/null || echo 22)"
  SECUREBOX_ANSWERS[ssh_port]="${SECUREBOX_ANSWERS[ssh_current_port]}"
  ask_ufw
  ask_ipv6
  review_answers
  ui_confirm "Apply UFW now?" "Y"
}
questionnaire_abuse_only() { questionnaire_common_safety; ask_abuse; review_answers; ui_confirm "Apply abuse blocking now?" "Y"; }
questionnaire_ipv6_only() { questionnaire_common_safety; ask_ipv6; review_answers; ui_confirm "Apply IPv6 policy now?" "Y"; }
questionnaire_unattended_only() { questionnaire_common_safety; ask_unattended; review_answers; ui_confirm "Apply unattended-upgrades now?" "Y"; }
questionnaire_services_only() { questionnaire_common_safety; ask_services; review_answers; ui_confirm "Apply service cleanup now?" "Y"; }
questionnaire_fail2ban_only() {
  questionnaire_common_safety
  SECUREBOX_ANSWERS[ssh_current_port]="$(_ssh_current_port 2>/dev/null || echo 22)"
  SECUREBOX_ANSWERS[ssh_port]="${SECUREBOX_ANSWERS[ssh_current_port]}"
  ask_fail2ban_params
  ui_confirm "Enable Fail2Ban now?" "Y"
}
questionnaire_bbr_only() { questionnaire_common_safety; ui_confirm "Apply BBR + network tuning now?" "Y"; }
questionnaire_update_only() { questionnaire_common_safety; ui_confirm "Run system update & upgrade now?" "Y"; }
