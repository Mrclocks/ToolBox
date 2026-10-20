#!/usr/bin/env bash
# Module: Backup — ToolBox UI bridge to PGClockBackup (PGClockMG)
# shellcheck shell=bash

pgbackup_install() {
  ui_step "Install / Update PGClockBackup"
  ui_info "Upstream: ${PGCLOCKMG_REPO_URL:-https://github.com/Mrclocks/PGClockMG}"
  local port
  local default_port="$PG_BACKUP_DEFAULT_PORT"
  if _pgmg_backup_installed; then
    default_port="$(_pgmg_backup_port)"
    ui_info "Existing install detected at ${PG_BACKUP_DIR} (update will re-run installer)"
  fi
  ui_ask_port port "Backup panel port" "$default_port"

  if ! ui_confirm "Install / update PGClockBackup on port ${port}?" "Y"; then
    ui_warn "Cancelled."
    return 0
  fi

  if _pgmg_run_installer install-backup "$port"; then
    ui_success "PGClockBackup installer finished"
    _pgmg_print_backup_access
    return 0
  fi
  ui_error "Installer reported failure — check output above"
  return 1
}

pgbackup_open() {
  ui_step "Open PGClockBackup"
  if ! _pgmg_backup_installed; then
    ui_warn "PGClockBackup is not installed."
    if ui_confirm "Install it now?" "Y"; then
      pgbackup_install
    fi
    return 0
  fi
  _pgmg_ensure_service "$PG_BACKUP_SERVICE" || true
  _pgmg_print_backup_access
}

pgbackup_status() {
  ui_step "Backup — Status"
  local port
  port="$(_pgmg_backup_port)"
  _pgmg_status_line "PGClockBackup" "$PG_BACKUP_DIR" "$PG_BACKUP_SERVICE" "$port"
  if _pgmg_backup_installed; then
    _pgmg_print_backup_access
  fi
  ui_info "Full project: ${PGCLOCKMG_REPO_URL:-https://github.com/Mrclocks/PGClockMG}"
}

pgbackup_uninstall() {
  ui_step "Uninstall PGClockBackup"
  if ! _pgmg_backup_installed; then
    ui_warn "PGClockBackup does not appear to be installed."
    return 0
  fi
  ui_warn "This removes the backup panel service (installer may keep archive data)."
  if ! ui_confirm "Uninstall PGClockBackup now?" "N"; then
    ui_warn "Cancelled."
    return 0
  fi
  if _pgmg_run_installer uninstall-backup; then
    ui_success "Uninstall finished"
  else
    ui_error "Uninstall reported failure"
    return 1
  fi
}

pgbackup_menu_loop() {
  while true; do
    ui_clear
    ui_banner
    printf '%sBackup%s\n' "$C_BOLD$C_ORANGE" "$C_RESET"
    ui_line 56 '-'
    if _pgmg_backup_installed; then
      printf '  %s    %sPGClockBackup detected%s\n' "$C_DIM" "$C_GREEN" "$C_RESET"
    else
      printf '  %s    PGClockBackup not installed%s\n' "$C_DIM" "$C_RESET"
    fi
    ui_line 56 '-'
    printf '  %s 1)%s Install / Update PGClockBackup\n' "$C_GREEN" "$C_RESET"
    printf '  %s 2)%s Open / Show access URL\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 3)%s Status\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 4)%s Uninstall\n' "$C_ORANGE" "$C_RESET"
    printf '  %s 0)%s Back\n' "$C_YELLOW" "$C_RESET"
    ui_line 56 '-'
    local choice
    printf '%sSelect%s: ' "$C_ORANGE" "$C_RESET"
    ui_read choice
    choice="$(trim "${choice:-0}")"
    case "$choice" in
      1) ui_clear; pgbackup_install; ui_pause ;;
      2) ui_clear; pgbackup_open; ui_pause ;;
      3) ui_clear; pgbackup_status; ui_pause ;;
      4) ui_clear; pgbackup_uninstall; ui_pause ;;
      0|b|B) return 0 ;;
      *) ui_warn "Invalid selection."; sleep 1 ;;
    esac
  done
}

module_pgbackup() {
  pgbackup_menu_loop
}
