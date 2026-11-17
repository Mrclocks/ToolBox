#!/usr/bin/env bash
# PGClockTB — questionnaires (all questions first, then execute)
# shellcheck shell=bash

declare -A PGCTB_ANSWERS=()

recommend_mtu() {
  # Default recommendation = keep current (safest for connectivity)
  local cur="${NET_DEFAULT_MTU:-1500}"
  echo "keep:${cur}"
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
  detect_dns_manager
  echo
  # Live benchmark so the user sees which resolver is best HERE
  dns_run_benchmark || true

  local labels=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && labels+=("$line")
  done < <(dns_preset_labels_with_bench)

  if ((${#labels[@]} == 0)); then
    ui_error "DNS preset list is empty"
    return 1
  fi

  local choice=""
  ui_menu choice "Choose DNS resolver (★ = fastest on this server)" "${labels[@]}" || return 1
  choice="$(trim "$choice")"
  if ! is_uint "$choice" || (( choice < 1 || choice > ${#DNS_PRESETS[@]} )); then
    ui_error "Invalid DNS selection: '${choice}'"
    return 1
  fi
  PGCTB_ANSWERS[dns_choice]="$choice"

  local preset id label primary secondary
  preset="${DNS_PRESETS[$((choice - 1))]}"
  IFS='|' read -r id label primary secondary <<<"$preset"
  id="$(trim "$id")"
  primary="$(trim "$primary")"
  secondary="$(trim "$secondary")"
  PGCTB_ANSWERS[dns_id]="$id"

  case "$id" in
    custom)
      local p="" s=""
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
      PGCTB_ANSWERS[dns_primary]="$p"
      PGCTB_ANSWERS[dns_secondary]="$s"
      ui_info "Custom DNS: ${p}${s:+ / $s}"
      ;;
    keep)
      PGCTB_ANSWERS[dns_primary]="${DNS_CURRENT[0]:-}"
      PGCTB_ANSWERS[dns_secondary]="${DNS_CURRENT[1]:-}"
      ui_info "Keeping current DNS: ${DNS_CURRENT[*]:-(none)}"
      ;;
    cloudflare|google|quad9|opendns|adguard)
      PGCTB_ANSWERS[dns_primary]="$primary"
      PGCTB_ANSWERS[dns_secondary]="$secondary"
      ui_success "Selected ${label}"
      ui_success "DNS: ${primary} / ${secondary}"
      ;;
    *)
      if [[ -n "$primary" ]] && is_ipv4 "$primary"; then
        PGCTB_ANSWERS[dns_primary]="$primary"
        PGCTB_ANSWERS[dns_secondary]="$secondary"
        ui_success "DNS: ${primary} / ${secondary}"
      else
        ui_error "Unknown DNS preset id '${id}' — not applying"
        return 1
      fi
      ;;
  esac
}

ask_logs() {
  if ui_confirm "Clean Ubuntu journal/rotated logs + Docker JSON logs to free disk?" "N"; then
    PGCTB_ANSWERS[do_logs]=yes
    if ui_confirm "Also truncate large active logs (auth.log/syslog/fail2ban.log)?" "N"; then
      PGCTB_ANSWERS[logs_truncate_active]=yes
    else
      PGCTB_ANSWERS[logs_truncate_active]=no
    fi
    if ui_confirm "Also run docker system prune -f (removes stopped containers)?" "N"; then
      PGCTB_ANSWERS[logs_docker_prune]=yes
    else
      PGCTB_ANSWERS[logs_docker_prune]=no
    fi
  else
    PGCTB_ANSWERS[do_logs]=no
    PGCTB_ANSWERS[logs_truncate_active]=no
    PGCTB_ANSWERS[logs_docker_prune]=no
  fi
}

ask_mtu() {
  local cur="${NET_DEFAULT_MTU:-1500}"
  echo
  ui_info "Default interface: ${NET_DEFAULT_IFACE:-unknown} (current MTU ${cur})"
  local choice
  ui_menu choice "MTU policy" \
    "Keep current MTU (recommended)" \
    "Standard Ethernet (1500)" \
    "WireGuard-ish (1420)" \
    "Conservative (1400)" \
    "Safe minimum (1280)" \
    "Custom MTU value" \
    "Keep MTU + enable TCP MSS clamping (iptables/nft alternative)" || return 1
  PGCTB_ANSWERS[mtu_mss_clamp]=no
  case "$choice" in
    1) PGCTB_ANSWERS[mtu]=keep ;;
    2) PGCTB_ANSWERS[mtu]=1500 ;;
    3) PGCTB_ANSWERS[mtu]=1420 ;;
    4) PGCTB_ANSWERS[mtu]=1400 ;;
    5) PGCTB_ANSWERS[mtu]=1280 ;;
    6)
      local m
      ui_ask_mtu m "Enter MTU" "$cur"
      PGCTB_ANSWERS[mtu]="$m"
      ;;
    7)
      PGCTB_ANSWERS[mtu]=keep
      PGCTB_ANSWERS[mtu_mss_clamp]=yes
      ;;
  esac
}

ask_update() {
  if ui_confirm "Run system update & upgrade?" "Y"; then
    PGCTB_ANSWERS[do_update]=yes
  else
    PGCTB_ANSWERS[do_update]=no
  fi
}

ask_timesync() {
  if ui_confirm "Enable chrony time sync?" "Y"; then
    PGCTB_ANSWERS[do_timesync]=yes
  else
    PGCTB_ANSWERS[do_timesync]=no
  fi
}

ask_bbr() {
  if ui_confirm "Apply BBR + network tuning?" "Y"; then
    PGCTB_ANSWERS[do_bbr]=yes
    local has_vpn=0
    if ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^(wg|tun|tap)/{found=1} END{exit found?0:1}'; then
      has_vpn=1
    fi
    if (( has_vpn )); then
      ui_info "VPN interfaces (wg*/tun*) detected — ip_forward will be enabled automatically."
      PGCTB_ANSWERS[bbr_ip_forward]=yes
    elif ui_confirm "Also enable IPv4 forwarding (needed for VPN gateways)?" "N"; then
      PGCTB_ANSWERS[bbr_ip_forward]=yes
    else
      PGCTB_ANSWERS[bbr_ip_forward]=no
    fi
  else
    PGCTB_ANSWERS[do_bbr]=no
    PGCTB_ANSWERS[bbr_ip_forward]=no
  fi
}

ask_ssh() {
  local current
  current="$(_ssh_current_port 2>/dev/null || echo 22)"
  PGCTB_ANSWERS[ssh_current_port]="$current"
  PGCTB_ANSWERS[ssh_port]="$current"

  echo
  if ! ui_confirm "Configure SSH port & hardening?" "Y"; then
    PGCTB_ANSWERS[do_ssh]=no
    PGCTB_ANSWERS[ssh_password_auth]=keep
    PGCTB_ANSWERS[ssh_permit_root]=keep
    PGCTB_ANSWERS[ssh_wait_confirm]=no
    ui_info "SSH left unchanged"
    return 0
  fi
  PGCTB_ANSWERS[do_ssh]=yes

  local suggestion
  suggestion="$(recommend_ssh_port)"

  ui_info "Current SSH port: ${current}"
  local choice
  ui_menu choice "SSH port action" \
    "Change to recommended (${suggestion})" \
    "Change to custom port" \
    "Keep current port (${current})" || return 1
  case "$choice" in
    1) PGCTB_ANSWERS[ssh_port]="$suggestion" ;;
    2)
      local p
      ui_ask_port p "New SSH port" "$suggestion"
      PGCTB_ANSWERS[ssh_port]="$p"
      ;;
    3) PGCTB_ANSWERS[ssh_port]="$current" ;;
  esac

  PGCTB_ANSWERS[ssh_wait_confirm]=yes

  local max_tries
  ui_ask max_tries "MaxAuthTries (login attempts before disconnect)" "5"
  if is_uint "$max_tries" && (( max_tries >= 1 && max_tries <= 20 )); then
    PGCTB_ANSWERS[ssh_max_auth_tries]="$max_tries"
  else
    PGCTB_ANSWERS[ssh_max_auth_tries]=5
  fi

  # Password auth — only offer disable if CURRENT login user has a usable key
  local has_key=0
  if declare -F _ssh_user_has_usable_key >/dev/null 2>&1 && _ssh_user_has_usable_key; then
    has_key=1
  fi
  if (( has_key )); then
    if ui_confirm "Usable SSH key found for current login user. Disable password authentication?" "N"; then
      PGCTB_ANSWERS[ssh_password_auth]=no
    else
      PGCTB_ANSWERS[ssh_password_auth]=keep
    fi
  else
    ui_warn "No usable SSH key for current login user — password authentication will stay enabled."
    PGCTB_ANSWERS[ssh_password_auth]=keep
  fi

  local root_choice
  ui_menu root_choice "Root SSH login policy" \
    "Keep distribution default" \
    "prohibit-password (keys only for root)" \
    "Disable root login" \
    "Allow root login" || return 1
  case "$root_choice" in
    1) PGCTB_ANSWERS[ssh_permit_root]=keep ;;
    2) PGCTB_ANSWERS[ssh_permit_root]=prohibit-password ;;
    3) PGCTB_ANSWERS[ssh_permit_root]=no ;;
    4) PGCTB_ANSWERS[ssh_permit_root]=yes ;;
  esac
}

ask_abuse() {
  if ui_confirm "Block curated abuse/scanner IP ranges (inbound)?" "N"; then
    PGCTB_ANSWERS[block_abuse]=yes
    local profile_choice
    ui_menu profile_choice "Abuse block profile" \
      "minimal — known bad / bulletproof hosting only (recommended)" \
      "aggressive — also noisy VPS hosting slices (may block cloud clients)" || return 1
    case "$profile_choice" in
      2) PGCTB_ANSWERS[abuse_profile]=aggressive ;;
      *) PGCTB_ANSWERS[abuse_profile]=minimal ;;
    esac
    ui_info "Abuse profile: ${PGCTB_ANSWERS[abuse_profile]}"
  else
    PGCTB_ANSWERS[block_abuse]=no
    PGCTB_ANSWERS[abuse_profile]=minimal
  fi
}

ask_ipv6() {
  if ui_confirm "Fully disable IPv6 on this server?" "N"; then
    PGCTB_ANSWERS[disable_ipv6]=yes
  else
    PGCTB_ANSWERS[disable_ipv6]=no
  fi
}

ask_unattended() {
  if ui_confirm "Enable automatic security updates (unattended-upgrades)?" "N"; then
    PGCTB_ANSWERS[unattended]=yes
  else
    PGCTB_ANSWERS[unattended]=no
  fi
  PGCTB_ANSWERS[unattended_reboot]=no
}

ask_services() {
  if ui_confirm "Disable common unused services (avahi/cups/bluetooth/...)?" "N"; then
    PGCTB_ANSWERS[disable_unused]=yes
  else
    PGCTB_ANSWERS[disable_unused]=no
  fi
  PGCTB_ANSWERS[disable_snapd]=no
}

ask_fail2ban() {
  if ui_confirm "Enable Fail2Ban for SSH brute-force protection?" "N"; then
    PGCTB_ANSWERS[enable_fail2ban]=yes
  else
    PGCTB_ANSWERS[enable_fail2ban]=no
  fi
  PGCTB_ANSWERS[f2b_bantime]=1h
  PGCTB_ANSWERS[f2b_findtime]=10m
  PGCTB_ANSWERS[f2b_maxretry]=4
}

ask_fail2ban_params() {
  # Back-compat alias
  ask_fail2ban
}

ask_ufw() {
  echo
  ui_info "Discovering listening ports..."
  local discovered
  discovered="$(discover_public_ports | awk '{printf "%s/%s ", $2, $1}')"
  discovered="$(trim "$discovered")"
  [[ -n "$discovered" ]] && ui_info "Discovered: ${discovered}" || ui_info "No public listeners found (besides what appears later)."

  if ui_confirm "Enable UFW after applying rules?" "N"; then
    PGCTB_ANSWERS[ufw_enable]=yes
    if ui_confirm "Reset existing UFW rules before applying?" "N"; then
      PGCTB_ANSWERS[ufw_reset]=yes
    else
      PGCTB_ANSWERS[ufw_reset]=no
    fi
    if ui_confirm "Auto-allow all currently discovered public ports?" "N"; then
      PGCTB_ANSWERS[ufw_auto_discover]=yes
    else
      PGCTB_ANSWERS[ufw_auto_discover]=no
    fi
    local extra
    ui_ask extra "Extra ports to allow (e.g. 443 51820/udp 80/tcp) — empty to skip" ""
    PGCTB_ANSWERS[ufw_ports]="$extra"
  else
    PGCTB_ANSWERS[ufw_enable]=no
    PGCTB_ANSWERS[ufw_reset]=no
    PGCTB_ANSWERS[ufw_auto_discover]=no
    PGCTB_ANSWERS[ufw_ports]=""
  fi
}

review_answers() {
  ui_box_start "Review your choices"
  local dns_show="${PGCTB_ANSWERS[dns_id]:-#${PGCTB_ANSWERS[dns_choice]:-}}"
  if [[ -n "${PGCTB_ANSWERS[dns_primary]:-}" ]]; then
    dns_show="${dns_show} (${PGCTB_ANSWERS[dns_primary]}${PGCTB_ANSWERS[dns_secondary]:+ / ${PGCTB_ANSWERS[dns_secondary]}})"
  fi
  ui_kv "Mode" "${PGCTB_ANSWERS[apply_mode]:-custom}"
  ui_kv "System update" "${PGCTB_ANSWERS[do_update]:-}"
  ui_kv "Time sync" "${PGCTB_ANSWERS[do_timesync]:-}"
  ui_kv "DNS" "$dns_show"
  ui_kv "MTU" "${PGCTB_ANSWERS[mtu]:-}"
  ui_kv "BBR tuning" "${PGCTB_ANSWERS[do_bbr]:-}"
  ui_kv "SSH changes" "${PGCTB_ANSWERS[do_ssh]:-}"
  ui_kv "SSH port" "${PGCTB_ANSWERS[ssh_current_port]:-?} → ${PGCTB_ANSWERS[ssh_port]:-?}"
  ui_kv "SSH password" "${PGCTB_ANSWERS[ssh_password_auth]:-}"
  ui_kv "Root login" "${PGCTB_ANSWERS[ssh_permit_root]:-}"
  ui_kv "Disable IPv6" "${PGCTB_ANSWERS[disable_ipv6]:-}"
  ui_kv "Block abuse ranges" "${PGCTB_ANSWERS[block_abuse]:-} (${PGCTB_ANSWERS[abuse_profile]:-minimal})"
  ui_kv "UFW enable" "${PGCTB_ANSWERS[ufw_enable]:-}"
  ui_kv "UFW reset" "${PGCTB_ANSWERS[ufw_reset]:-}"
  ui_kv "UFW auto ports" "${PGCTB_ANSWERS[ufw_auto_discover]:-}"
  ui_kv "UFW extra" "${PGCTB_ANSWERS[ufw_ports]:-(none)}"
  ui_kv "Fail2Ban" "${PGCTB_ANSWERS[enable_fail2ban]:-}"
  ui_kv "Unattended upgrades" "${PGCTB_ANSWERS[unattended]:-}"
  ui_kv "Disable unused svcs" "${PGCTB_ANSWERS[disable_unused]:-}"
  ui_kv "Clean logs/disk" "${PGCTB_ANSWERS[do_logs]:-}"
  ui_box_end
}

# Automatic profile — LOW RISK only. Anything that can cut network stays off or asked.
defaults_auto_all() {
  detect_network_stack
  detect_dns_manager
  PGCTB_ANSWERS[apply_mode]=auto
  PGCTB_ANSWERS[continue_on_error]=yes

  # Truly low-risk defaults — ask or skip higher-impact steps
  PGCTB_ANSWERS[do_update]=no
  PGCTB_ANSWERS[do_timesync]=yes
  PGCTB_ANSWERS[do_bbr]=yes
  PGCTB_ANSWERS[do_logs]=no
  PGCTB_ANSWERS[logs_truncate_active]=no
  PGCTB_ANSWERS[logs_docker_prune]=no
  PGCTB_ANSWERS[enable_fail2ban]=yes
  PGCTB_ANSWERS[f2b_bantime]=1h
  PGCTB_ANSWERS[f2b_findtime]=10m
  PGCTB_ANSWERS[f2b_maxretry]=4
  PGCTB_ANSWERS[unattended]=yes
  PGCTB_ANSWERS[unattended_reboot]=no
  # Masking services is not low-risk — skip unless Customize
  PGCTB_ANSWERS[disable_unused]=no
  PGCTB_ANSWERS[disable_snapd]=no

  # Keep current DNS/MTU — changing them has cut connectivity on some VPS
  PGCTB_ANSWERS[dns_choice]=6
  PGCTB_ANSWERS[dns_id]=keep
  PGCTB_ANSWERS[mtu]=keep
  ui_info "Auto: keeping current DNS and MTU (safest for connectivity)"

  # SSH harden lightly, port unchanged
  local cur
  cur="$(_ssh_current_port 2>/dev/null || echo 22)"
  PGCTB_ANSWERS[do_ssh]=yes
  PGCTB_ANSWERS[ssh_current_port]="$cur"
  PGCTB_ANSWERS[ssh_port]="$cur"
  PGCTB_ANSWERS[ssh_wait_confirm]=no
  PGCTB_ANSWERS[ssh_password_auth]=keep
  PGCTB_ANSWERS[ssh_permit_root]=keep
  PGCTB_ANSWERS[ssh_max_auth_tries]=5

  # High-risk — NEVER auto-enable (UFW/IPv6 still asked below)
  PGCTB_ANSWERS[block_abuse]=no
  PGCTB_ANSWERS[abuse_profile]=minimal
  PGCTB_ANSWERS[disable_ipv6]=no
  PGCTB_ANSWERS[ufw_enable]=no
  PGCTB_ANSWERS[ufw_reset]=no
  PGCTB_ANSWERS[ufw_auto_discover]=no
  PGCTB_ANSWERS[ufw_ports]=""
}

questionnaire_all() {
  PGCTB_ANSWERS=()
  PGCTB_ANSWERS[continue_on_error]=yes
  ui_clear
  ui_step "Apply All — how should we proceed?"
  local mode
  ui_menu mode "Apply All mode" \
    "Automatic — low-risk only (asks UFW & IPv6; keeps DNS/MTU/SSH port; no abuse block)" \
    "Customize — ask me every option" || return 1
  case "$mode" in
    1)
      defaults_auto_all
      ui_step "Automatic — optional higher-impact steps (default skip)"
      if ui_confirm "Run apt full-upgrade as part of Automatic?" "N"; then
        PGCTB_ANSWERS[do_update]=yes
      fi
      if ui_confirm "Clean journal/rotated logs (never docker prune / never truncate auth.log)?" "N"; then
        PGCTB_ANSWERS[do_logs]=yes
        PGCTB_ANSWERS[logs_truncate_active]=no
        PGCTB_ANSWERS[logs_docker_prune]=no
      fi
      if ui_confirm "Disable unused services (avahi/cups/… — masks units)?" "N"; then
        PGCTB_ANSWERS[disable_unused]=yes
      fi
      ui_step "Automatic needs two decisions (can cut access if wrong)"
      ask_ipv6
      ask_ufw
      if declare -F show_plan_screen >/dev/null 2>&1; then
        show_plan_screen
      else
        review_answers
      fi
      if ! ui_confirm "Run LOW-RISK automatic Apply All with these choices?" "Y"; then
        ui_warn "Cancelled by user."
        return 1
      fi
      return 0
      ;;
    2)
      PGCTB_ANSWERS[apply_mode]=custom
      ui_step "Customize — only your yes answers will run"
      ask_update
      ask_timesync
      ask_dns || return 1
      ask_mtu || return 1
      ask_bbr
      ask_ssh || return 1
      ask_ipv6
      ask_abuse || return 1
      ask_ufw
      ask_fail2ban
      ask_unattended
      ask_services
      ask_logs
      if declare -F show_plan_screen >/dev/null 2>&1; then
        show_plan_screen
      else
        review_answers
      fi
      if ! ui_confirm "Proceed using ONLY these answers (nothing else will be forced)?" "Y"; then
        ui_warn "Cancelled by user."
        return 1
      fi
      return 0
      ;;
    *)
      ui_warn "Cancelled."
      return 1
      ;;
  esac
}

# Per-feature questionnaires (only what that feature needs)
questionnaire_dns_only() { questionnaire_common_safety; ask_dns || return 1; review_answers; ui_confirm "Apply DNS now?" "Y"; }
questionnaire_mtu_only() { questionnaire_common_safety; ask_mtu || return 1; review_answers; ui_confirm "Apply MTU now?" "Y"; }
questionnaire_logs_only() {
  questionnaire_common_safety
  ask_logs
  review_answers
  answered_yes do_logs && ui_confirm "Clean logs now?" "Y"
}
questionnaire_ssh_only() {
  questionnaire_common_safety
  ask_ssh || return 1
  review_answers
  # ask_ssh already sets do_ssh from the user's yes/no
  if answered_yes do_ssh; then
    ui_confirm "Apply SSH changes now?" "Y"
  else
    return 1
  fi
}
questionnaire_ufw_only() {
  questionnaire_common_safety
  PGCTB_ANSWERS[ssh_current_port]="$(_ssh_current_port 2>/dev/null || echo 22)"
  PGCTB_ANSWERS[ssh_port]="${PGCTB_ANSWERS[ssh_current_port]}"
  ask_ufw
  ask_ipv6
  review_answers
  ui_confirm "Apply UFW now?" "Y"
}
questionnaire_abuse_only() { questionnaire_common_safety; ask_abuse || return 1; review_answers; ui_confirm "Apply abuse policy now?" "Y"; }
questionnaire_ipv6_only() { questionnaire_common_safety; ask_ipv6; review_answers; ui_confirm "Apply IPv6 policy now?" "Y"; }
questionnaire_unattended_only() { questionnaire_common_safety; ask_unattended; review_answers; ui_confirm "Apply unattended-upgrades now?" "Y"; }
questionnaire_services_only() { questionnaire_common_safety; ask_services; review_answers; ui_confirm "Apply service cleanup now?" "Y"; }
questionnaire_fail2ban_only() {
  questionnaire_common_safety
  PGCTB_ANSWERS[ssh_current_port]="$(_ssh_current_port 2>/dev/null || echo 22)"
  PGCTB_ANSWERS[ssh_port]="${PGCTB_ANSWERS[ssh_current_port]}"
  ask_fail2ban
  review_answers
  ui_confirm "Apply Fail2Ban setting now?" "Y"
}
questionnaire_bbr_only() {
  questionnaire_common_safety
  ask_bbr
  review_answers
  answered_yes do_bbr && ui_confirm "Apply BBR now?" "Y"
}
questionnaire_update_only() {
  questionnaire_common_safety
  ask_update
  if answered_yes do_update; then
    if ui_confirm "Safe upgrade only? (apt-get upgrade — never removes packages)" "Y"; then
      PGCTB_ANSWERS[update_mode]=safe
    else
      PGCTB_ANSWERS[update_mode]=full
    fi
    ask_update_docker_policy
  fi
  review_answers
  answered_yes do_update && ui_confirm "Run update now?" "Y"
}
questionnaire_timesync_only() {
  questionnaire_common_safety
  ask_timesync
  review_answers
  answered_yes do_timesync && ui_confirm "Apply time sync now?" "Y"
}

ask_restore() {
  local -a runs=()
  local r
  while IFS= read -r r; do
    [[ -n "$r" ]] && runs+=("$r")
  done < <(_restore_list_runs | head -n 12)

  if ((${#runs[@]} == 0)); then
    ui_error "No PGClockTB backups found in ${PGCTB_BACKUP_ROOT}"
    ui_info "Run some features first — configs are snapshotted before changes."
    PGCTB_ANSWERS[do_restore]=no
    return 1
  fi

  local default
  default="$(_restore_pick_default_run || true)"
  local -a labels=()
  local n mark
  for r in "${runs[@]}"; do
    n="$(find "${PGCTB_BACKUP_ROOT}/${r}" -type f 2>/dev/null | wc -l | tr -d ' ')"
    mark=""
    [[ "$r" == "$default" ]] && mark=" ★ recommended"
    if [[ -f "${PGCTB_BACKUP_ROOT}/${r}/MANIFEST.txt" ]]; then
      labels+=("${r}  (${n} files, manifest)${mark}")
    else
      labels+=("${r}  (${n} files, legacy)${mark}")
    fi
  done

  echo
  ui_warn "This restores DNS / MTU / SSH / UFW / Fail2Ban / sysctl / abuse configs."
  ui_warn "Does NOT undo apt upgrades or deleted logs."
  local choice
  ui_menu choice "Select backup run to restore" "${labels[@]}" || return 1
  if ! is_uint "$choice" || (( choice < 1 || choice > ${#runs[@]} )); then
    ui_error "Invalid selection"
    PGCTB_ANSWERS[do_restore]=no
    return 1
  fi
  PGCTB_ANSWERS[restore_run]="${runs[$((choice - 1))]}"
  _restore_preview "${PGCTB_BACKUP_ROOT}/${PGCTB_ANSWERS[restore_run]}"

  if ui_confirm "Restore these files and remove PGClockTB drop-ins from that run?" "N"; then
    PGCTB_ANSWERS[do_restore]=yes
    return 0
  fi
  PGCTB_ANSWERS[do_restore]=no
  return 1
}

questionnaire_restore_only() {
  questionnaire_common_safety
  ask_restore || return 1
  answered_yes do_restore
}
