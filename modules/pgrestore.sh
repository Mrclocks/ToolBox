#!/usr/bin/env bash
# Module: Restore & Migrate menu — bridge to PGClockMG wizard (Phase 3 scaffold)
# shellcheck shell=bash

PGCLOCKMG_INSTALL_URL="${PGCLOCKMG_INSTALL_URL:-https://raw.githubusercontent.com/Mrclocks/PGClockMG/main/install.sh}"

pgrestore_menu_loop() {
  while true; do
    ui_clear
    ui_banner
    printf '%sRestore & Migrate%s\n' "$C_BOLD$C_ORANGE" "$C_RESET"
    ui_line 56 '-'
    printf '  %s 1)%s Install / Open PGClockMG wizard — coming next\n' "$C_GREEN" "$C_RESET"
    printf '  %s 2)%s Status — coming next\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 3)%s Uninstall — coming next\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 0)%s Back\n' "$C_YELLOW" "$C_RESET"
    ui_line 56 '-'
    local choice
    printf '%sSelect%s: ' "$C_ORANGE" "$C_RESET"
    ui_read choice
    choice="$(trim "${choice:-0}")"
    case "$choice" in
      1|2|3)
        ui_clear
        ui_step "Restore & Migrate (PGClockMG)"
        ui_info "This menu will open the PGClockMG restore/migrate wizard with ToolBox UI."
        ui_info "Upstream project: https://github.com/Mrclocks/PGClockMG"
        if [[ -d /opt/pg-migrator ]]; then
          ui_success "Detected existing install at /opt/pg-migrator"
        else
          ui_info "Not installed yet. Manual install:"
          printf '   sudo bash -c "$(curl -fsSL %s)"\n' "$PGCLOCKMG_INSTALL_URL"
        fi
        ui_pause
        ;;
      0|b|B) return 0 ;;
      *) ui_warn "Invalid selection."; sleep 1 ;;
    esac
  done
}

module_pgrestore() {
  pgrestore_menu_loop
}
