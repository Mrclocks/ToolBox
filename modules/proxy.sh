#!/usr/bin/env bash
# Module: Reverse proxy menu (HAProxy / Nginx / Caddy) — Phase 2 scaffold
# shellcheck shell=bash

proxy_menu_loop() {
  while true; do
    ui_clear
    ui_banner
    printf '%sReverse Proxy%s\n' "$C_BOLD$C_ORANGE" "$C_RESET"
    ui_line 56 '-'
    printf '  %s 1)%s Setup HAProxy (recommended) — coming next\n' "$C_GREEN" "$C_RESET"
    printf '  %s 2)%s Setup Caddy — coming next\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 3)%s Setup Nginx — coming next\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 4)%s Status / Remove — coming next\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 0)%s Back\n' "$C_YELLOW" "$C_RESET"
    ui_line 56 '-'
    local choice
    printf '%sSelect%s: ' "$C_ORANGE" "$C_RESET"
    ui_read choice
    choice="$(trim "${choice:-0}")"
    case "$choice" in
      1|2|3|4)
        ui_clear
        ui_step "Reverse Proxy"
        ui_info "This menu is reserved for single-port / TLS proxy setup."
        ui_info "HAProxy (recommended), Caddy, and Nginx land in the next update."
        ui_info "Tip: issue certificates under SSL Certificates first."
        ui_pause
        ;;
      0|b|B) return 0 ;;
      *) ui_warn "Invalid selection."; sleep 1 ;;
    esac
  done
}

module_proxy() {
  proxy_menu_loop
}
