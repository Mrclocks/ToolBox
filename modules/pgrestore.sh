#!/usr/bin/env bash
# Module: Restore & Migrate — ToolBox UI bridge to PGClockMG wizard
# shellcheck shell=bash

pgrestore_install() {
  ui_step "Install / Update PGClockMG wizard"
  ui_info "Upstream: ${PGCLOCKMG_REPO_URL:-https://github.com/Mrclocks/PGClockMG}"
  ui_info "Use this wizard to restore PasarGuard backups or migrate from Marzban / 3x-ui / Hiddify."
  local port
  local default_port="$PG_WIZARD_DEFAULT_PORT"
  if _pgmg_wizard_installed; then
    default_port="$(_pgmg_wizard_port)"
    ui_info "Existing install detected at ${PG_WIZARD_DIR} (update will re-run installer)"
  fi
  ui_ask_port port "Wizard web port" "$default_port"

  if ! ui_confirm "Install / update PGClockMG wizard on port ${port}?" "Y"; then
    ui_warn "Cancelled."
    return 0
  fi

  if _pgmg_run_installer install-wizard "$port"; then
    ui_success "PGClockMG wizard installer finished"
    _pgmg_print_wizard_access
    if [[ ! -d /opt/pasarguard ]]; then
      ui_warn "PasarGuard panel not found — install the panel before restoring into it."
    fi
    return 0
  fi
  ui_error "Installer reported failure — check output above"
  return 1
}

pgrestore_open() {
  ui_step "Open PGClockMG wizard"
  if ! _pgmg_wizard_installed; then
    ui_warn "PGClockMG wizard is not installed."
    if ui_confirm "Install it now?" "Y"; then
      pgrestore_install
    fi
    return 0
  fi
  _pgmg_ensure_service "$PG_WIZARD_SERVICE" || true
  _pgmg_print_wizard_access
}

pgrestore_status() {
  ui_step "Restore & Migrate — Status"
  local wport bport
  wport="$(_pgmg_wizard_port)"
  bport="$(_pgmg_backup_port)"
  _pgmg_status_line "PGClockMG wizard" "$PG_WIZARD_DIR" "$PG_WIZARD_SERVICE" "$wport"
  _pgmg_status_line "PGClockBackup" "$PG_BACKUP_DIR" "$PG_BACKUP_SERVICE" "$bport"
  if [[ -d /opt/pasarguard ]]; then
    ui_success "PasarGuard panel path present: /opt/pasarguard"
  else
    ui_warn "PasarGuard panel not detected at /opt/pasarguard"
  fi
  if _pgmg_wizard_installed; then
    _pgmg_print_wizard_access
  fi
  ui_info "Full project: ${PGCLOCKMG_REPO_URL:-https://github.com/Mrclocks/PGClockMG}"
}

pgrestore_uninstall() {
  ui_step "Uninstall PGClockMG wizard"
  if ! _pgmg_wizard_installed; then
    ui_warn "Wizard does not appear to be installed."
    return 0
  fi
  ui_warn "This removes the restore/migrate wizard only (PGClockBackup stays if installed)."
  if ! ui_confirm "Uninstall PGClockMG wizard now?" "N"; then
    ui_warn "Cancelled."
    return 0
  fi
  if _pgmg_run_installer uninstall-wizard; then
    ui_success "Uninstall finished"
  else
    ui_error "Uninstall reported failure"
    return 1
  fi
}

pgrestore_redirect() {
  ui_step "Redirect server (3x-ui / Hiddify)"
  ui_info "Delegates to PGClockMG redirect helpers."
  if ! ui_confirm "Run redirect-restart via PGClockMG installer?" "N"; then
    ui_warn "Cancelled."
    return 0
  fi
  _pgmg_run_installer redirect-restart || ui_warn "Redirect action finished with errors (see above)"
}

pgrestore_menu_loop() {
  while true; do
    ui_clear
    ui_banner
    ui_menu_title "Restore & Migrate"
    if _pgmg_wizard_installed; then
      printf '  %s    %sPGClockMG wizard detected%s\n' "$C_DIM" "$C_GREEN" "$C_RESET"
    else
      printf '  %s    PGClockMG wizard not installed%s\n' "$C_DIM" "$C_RESET"
    fi
    ui_line 56 '-'
    printf '  %s 1)%s Install / Update PGClockMG wizard\n' "$C_GREEN" "$C_RESET"
    printf '  %s 2)%s Open / Show access URL\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 3)%s Status\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 4)%s Uninstall\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 5)%s Redirect server (3x-ui / Hiddify)\n' "$C_ORANGE" "$C_RESET"
    ui_menu_back_line
    local choice
    printf '%sSelect%s [0-5]: ' "$C_ORANGE" "$C_RESET"
    ui_read choice
    choice="$(trim "${choice:-}")"
    case "$choice" in
      1) ui_clear; pgrestore_install; ui_pause ;;
      2) ui_clear; pgrestore_open; ui_pause ;;
      3) ui_clear; pgrestore_status; ui_pause ;;
      4) ui_clear; pgrestore_uninstall; ui_pause ;;
      5) ui_clear; pgrestore_redirect; ui_pause ;;
      0|b|B|back|Back) return 0 ;;
      *) ui_warn "Invalid selection."; sleep 1 ;;
    esac
  done
}

module_pgrestore() {
  pgrestore_menu_loop
}
