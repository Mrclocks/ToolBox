#!/usr/bin/env bash
# PGClockTB — interactive menus
# shellcheck shell=bash

_menu_item() {
  # _menu_item NUM LABEL [COLOR]
  printf '  %s%2s)%s %s\n' "${3:-$C_ORANGE}" "$1" "$C_RESET" "$2"
}

_menu_section() {
  printf '  %s%s%s\n' "$C_DIM" "$1" "$C_RESET"
}

_menu_read() {
  # _menu_read VAR MAX
  local __v="$1" __max="$2" __c
  printf '%sSelect%s [0-%s]: ' "$C_ORANGE" "$C_RESET" "$__max"
  ui_read __c
  printf -v "$__v" '%s' "$(trim "${__c:-}")"
}

_menu_invalid() {
  ui_warn "Invalid selection."
  sleep 1
}

# --- Status -------------------------------------------------------------------

status_menu_loop() {
  local choice
  while true; do
    ui_clear
    ui_banner
    ui_menu_title "Status & Doctor"
    _menu_item 1 "Doctor — full health check (PASS / WARN / FAIL)" "$C_GREEN"
    _menu_item 2 "Doctor — shareable report (IPs / domains masked)"
    _menu_item 3 "External port check (test this server from another one)"
    _menu_item 4 "Check another server's ports from here"
    _menu_item 5 "Status report"
    _menu_item 6 "Verify (sshd / ports / DNS / UFW / qdisc / sysctl)"
    ui_menu_back_line
    _menu_read choice 6
    case "$choice" in
      1) ui_clear; module_doctor || true; ui_pause ;;
      2) ui_clear; module_doctor --share || true; ui_pause ;;
      3) ui_clear; portcheck_guide; ui_pause ;;
      4)
        ui_clear
        local host ports
        ui_ask host "Host (IP or domain) to test" ""
        ui_ask ports "Ports (space-separated)" "443 80"
        # shellcheck disable=SC2086
        portcheck_run "$(trim "$host")" $ports || true
        ui_pause
        ;;
      5) ui_clear; run_single report; ui_pause ;;
      6) ui_clear; run_single verify; ui_pause ;;
      0|b|B|back|Back) return 0 ;;
      *) _menu_invalid ;;
    esac
  done
}

# --- Optimization (🟢 / 🟡) ---------------------------------------------------

optimization_menu_loop() {
  local choice
  while true; do
    ui_clear
    ui_banner
    ui_menu_title "Optimization"
    _menu_item 1 "🟢 Apply Safe level (low risk)" "$C_GREEN"
    _menu_item 2 "🟡 Apply Balanced level (low + mid, asks each network change)" "$C_GREEN"
    _menu_section "── individual ──"
    _menu_item 3 "🟢 System update & upgrade"
    _menu_item 4 "🟢 Time sync (chrony)"
    _menu_item 5 "🟢 BBR + network tuning"
    _menu_item 6 "🟢 Unattended security upgrades"
    _menu_item 7 "🟢 Clean logs (Ubuntu / Docker)"
    _menu_item 8 "🟡 DNS resolver"
    _menu_item 9 "🟡 MTU tuning"
    _menu_item 10 "🟡 IPv6 policy"
    _menu_item 11 "🟡 Disable unused services"
    ui_menu_back_line
    _menu_read choice 11
    case "$choice" in
      1) ui_clear; run_level low; ui_pause ;;
      2) ui_clear; run_level mid; ui_pause ;;
      3) ui_clear; questionnaire_update_only && run_single update && run_single report; ui_pause ;;
      4) ui_clear; questionnaire_timesync_only && run_single timesync && run_single report; ui_pause ;;
      5) ui_clear; questionnaire_bbr_only && run_single bbr && run_single report; ui_pause ;;
      6) ui_clear; questionnaire_unattended_only && run_single unattended && run_single report; ui_pause ;;
      7) ui_clear; questionnaire_logs_only && run_single logs && run_single report; ui_pause ;;
      8) ui_clear; questionnaire_dns_only && run_single dns && run_single report; ui_pause ;;
      9) ui_clear; questionnaire_mtu_only && run_single mtu && run_single report; ui_pause ;;
      10) ui_clear; questionnaire_ipv6_only && run_single ipv6 && run_single report; ui_pause ;;
      11) ui_clear; questionnaire_services_only && run_single services && run_single report; ui_pause ;;
      0|b|B|back|Back) return 0 ;;
      *) _menu_invalid ;;
    esac
  done
}

# --- Security (🔴 one at a time) ----------------------------------------------

security_menu_loop() {
  local choice
  while true; do
    ui_clear
    ui_banner
    ui_menu_title "Security"
    _menu_item 1 "🔴 SSH port & hardening"
    _menu_item 2 "🔴 UFW firewall"
    _menu_item 3 "🔴 Abuse IP range block"
    _menu_item 4 "🟡 Fail2Ban (SSH brute-force)"
    ui_menu_back_line
    _menu_read choice 4
    case "$choice" in
      1)
        ui_clear
        ui_risk_gate ssh "SSH port & hardening" \
          && questionnaire_ssh_only && run_single ssh && run_single report
        ui_pause
        ;;
      2)
        ui_clear
        if ui_risk_gate ufw "UFW firewall" && questionnaire_ufw_only; then
          run_single ufw
          # IPv6 is asked in the UFW questionnaire — honour it
          run_single ipv6
          run_single report
        fi
        ui_pause
        ;;
      3)
        ui_clear
        ui_risk_gate abuse "Abuse IP range block" \
          && questionnaire_abuse_only && run_single abuse && run_single report
        ui_pause
        ;;
      4) ui_clear; questionnaire_fail2ban_only && run_single fail2ban && run_single report; ui_pause ;;
      0|b|B|back|Back) return 0 ;;
      *) _menu_invalid ;;
    esac
  done
}

# --- Backup & Restore ---------------------------------------------------------

backup_restore_menu_loop() {
  local choice
  while true; do
    ui_clear
    ui_banner
    ui_menu_title "Backup & Restore"
    _menu_item 1 "Backup — PGClockBackup panel"
    _menu_item 2 "Restore & Migrate — PGClockMG wizard"
    ui_menu_back_line
    _menu_read choice 2
    case "$choice" in
      1) pgbackup_menu_loop ;;
      2) pgrestore_menu_loop ;;
      0|b|B|back|Back) return 0 ;;
      *) _menu_invalid ;;
    esac
  done
}

# --- Tools --------------------------------------------------------------------

tools_menu_loop() {
  local choice
  while true; do
    ui_clear
    ui_banner
    ui_menu_title "Tools"
    _menu_item 1 "Undo PGClockTB changes (restore a backup run)" "$C_GREEN"
    _menu_item 2 "Full custom wizard (asks every option, includes 🔴 items)"
    ui_menu_back_line
    _menu_read choice 2
    case "$choice" in
      1) ui_clear; questionnaire_restore_only && run_single restore && run_single report; ui_pause ;;
      2)
        ui_clear
        ui_warn "The full wizard can include 🔴 SSH / UFW / abuse changes — each is asked explicitly."
        if questionnaire_all; then
          run_pipeline_all
        fi
        ui_pause
        ;;
      0|b|B|back|Back) return 0 ;;
      *) _menu_invalid ;;
    esac
  done
}

# --- Main ---------------------------------------------------------------------

menu_loop() {
  local choice
  while true; do
    ui_clear
    ui_banner
    ui_menu_title "Main menu"
    _menu_item 1 "Status & Doctor" "$C_GREEN"
    _menu_item 2 "SSL Certificates"
    _menu_item 3 "Reverse Proxy (HAProxy)"
    _menu_item 4 "Optimization  🟢 / 🟡"
    _menu_item 5 "Security      🔴 SSH · UFW · Abuse  🟡 Fail2Ban"
    _menu_item 6 "Backup & Restore"
    _menu_item 7 "Tools (Undo · full wizard)"
    printf '  %s 0)%s Exit\n' "$C_YELLOW" "$C_RESET"
    ui_line 56 '-'
    _menu_read choice 7
    case "$choice" in
      1) status_menu_loop ;;
      2) ssl_menu_loop ;;
      3) proxy_menu_loop ;;
      4) optimization_menu_loop ;;
      5) security_menu_loop ;;
      6) backup_restore_menu_loop ;;
      7) tools_menu_loop ;;
      0|q|Q|exit|Exit)
        ui_info "Goodbye."
        exit 0
        ;;
      *) _menu_invalid ;;
    esac
  done
}
