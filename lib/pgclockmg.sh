#!/usr/bin/env bash
# Shared bridge helpers for PGClockMG / PGClockBackup
# shellcheck shell=bash

PGCLOCKMG_INSTALL_URL="${PGCLOCKMG_INSTALL_URL:-https://raw.githubusercontent.com/Mrclocks/PGClockMG/main/install.sh}"
PGCLOCKMG_REPO_URL="${PGCLOCKMG_REPO_URL:-https://github.com/Mrclocks/PGClockMG}"
PG_WIZARD_DIR="${PG_WIZARD_DIR:-/opt/pg-migrator}"
PG_BACKUP_DIR="${PG_BACKUP_DIR:-/opt/pg-backup}"
PG_WIZARD_SERVICE="${PG_WIZARD_SERVICE:-pg-migrator}"
PG_BACKUP_SERVICE="${PG_BACKUP_SERVICE:-pg-backup}"
PG_WIZARD_DEFAULT_PORT="${PG_WIZARD_DEFAULT_PORT:-7000}"
PG_BACKUP_DEFAULT_PORT="${PG_BACKUP_DEFAULT_PORT:-7001}"

_pgmg_server_ip() {
  local ip=""
  if have_cmd hostname; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  if [[ -z "$ip" ]] && have_cmd ip; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  fi
  printf '%s\n' "${ip:-YOUR_SERVER_IP}"
}

_pgmg_detect_service_port() {
  # Parse ExecStart --port from systemd unit; fallback to default
  local unit_file="$1"
  local default_port="$2"
  local p=""
  if [[ -f "$unit_file" ]]; then
    p="$(grep -oE -- '--port[ =]+[0-9]+' "$unit_file" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)"
  fi
  if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )); then
    printf '%s\n' "$p"
  else
    printf '%s\n' "$default_port"
  fi
}

_pgmg_wizard_port() {
  _pgmg_detect_service_port "/etc/systemd/system/${PG_WIZARD_SERVICE}.service" "$PG_WIZARD_DEFAULT_PORT"
}

_pgmg_backup_port() {
  _pgmg_detect_service_port "/etc/systemd/system/${PG_BACKUP_SERVICE}.service" "$PG_BACKUP_DEFAULT_PORT"
}

_pgmg_wizard_installed() {
  [[ -d "$PG_WIZARD_DIR" ]] && [[ -f "/etc/systemd/system/${PG_WIZARD_SERVICE}.service" || -x "${PG_WIZARD_DIR}/.venv/bin/python" || -f "${PG_WIZARD_DIR}/main.py" || -f "${PG_WIZARD_DIR}/app/main.py" ]]
}

_pgmg_backup_installed() {
  [[ -d "$PG_BACKUP_DIR" ]] && [[ -f "/etc/systemd/system/${PG_BACKUP_SERVICE}.service" || -d "${PG_BACKUP_DIR}/backup_panel" ]]
}

_pgmg_service_active() {
  local svc="$1"
  have_cmd systemctl && systemctl is-active --quiet "$svc" 2>/dev/null
}

_pgmg_read_file_token() {
  local f="$1"
  [[ -s "$f" ]] || return 1
  head -n1 "$f" | tr -d '[:space:]'
}

_pgmg_download_installer() {
  # Prints path to downloaded install.sh
  local dest
  dest="$(mktemp /tmp/pgclockmg-install.XXXXXX.sh)"
  if ! curl -fsSL --connect-timeout 20 --retry 2 "$PGCLOCKMG_INSTALL_URL" -o "$dest"; then
    rm -f "$dest"
    ui_error "Failed to download PGClockMG installer"
    ui_info "URL: ${PGCLOCKMG_INSTALL_URL}"
    return 1
  fi
  chmod 700 "$dest"
  printf '%s\n' "$dest"
}

_pgmg_run_installer() {
  # _pgmg_run_installer ACTION [PORT]
  # ACTION: install-wizard|install-backup|uninstall-wizard|uninstall-backup|redirect-restart
  local action="$1"
  local port="${2:-}"
  local script=""
  local rc=0

  if is_dry_run; then
    ui_info "[dry-run] Would run PGClockMG action=${action} port=${port:-default}"
    return 0
  fi

  if ! have_cmd curl; then
    apt_install_safe curl || true
  fi
  if ! have_cmd curl; then
    ui_error "curl is required to fetch PGClockMG"
    return 1
  fi

  script="$(_pgmg_download_installer)" || return 1
  ui_info "Running PGClockMG: ${action}..."

  # Avoid nested curl|bash re-exec surprises: run local file with env action
  case "$action" in
    install-wizard)
      PG_MIGRATOR_ACTION=install-wizard \
      PG_MIGRATOR_PORT="${port:-$PG_WIZARD_DEFAULT_PORT}" \
      PG_MIGRATOR_YES=1 \
      PG_MIGRATOR_FROM_PIPE=0 \
      bash "$script" install-wizard
      rc=$?
      ;;
    install-backup)
      PG_MIGRATOR_ACTION=install-backup \
      PG_BACKUP_PORT="${port:-$PG_BACKUP_DEFAULT_PORT}" \
      PG_MIGRATOR_YES=1 \
      PG_MIGRATOR_FROM_PIPE=0 \
      bash "$script" install-backup
      rc=$?
      ;;
    uninstall-wizard)
      PG_MIGRATOR_ACTION=uninstall-wizard \
      PG_MIGRATOR_YES=1 \
      PG_MIGRATOR_FROM_PIPE=0 \
      bash "$script" uninstall-wizard
      rc=$?
      ;;
    uninstall-backup)
      PG_MIGRATOR_ACTION=uninstall-backup \
      PG_MIGRATOR_YES=1 \
      PG_MIGRATOR_FROM_PIPE=0 \
      bash "$script" uninstall-backup
      rc=$?
      ;;
    redirect-restart)
      PG_MIGRATOR_ACTION=redirect-restart \
      PG_MIGRATOR_YES=1 \
      PG_MIGRATOR_FROM_PIPE=0 \
      bash "$script" redirect-restart
      rc=$?
      ;;
    *)
      ui_error "Unknown PGClockMG action: ${action}"
      rm -f "$script"
      return 1
      ;;
  esac

  rm -f "$script"
  return "$rc"
}

_pgmg_print_wizard_access() {
  local ip port token url
  ip="$(_pgmg_server_ip)"
  port="$(_pgmg_wizard_port)"
  token="$(_pgmg_read_file_token "${PG_WIZARD_DIR}/.access_token" || true)"
  ui_box_start "PGClockMG wizard access"
  ui_kv "Install dir" "$PG_WIZARD_DIR"
  ui_kv "Service" "$PG_WIZARD_SERVICE"
  ui_kv "Port" "$port"
  if [[ -n "$token" ]]; then
    url="http://${ip}:${port}/?token=${token}"
    ui_kv "URL" "$url"
    ui_kv "Token file" "${PG_WIZARD_DIR}/.access_token"
    ui_info "Open the URL above — token is already in the link."
  else
    url="http://${ip}:${port}/"
    ui_kv "URL" "$url"
    ui_warn "Access token missing — cat ${PG_WIZARD_DIR}/.access_token"
  fi
  if _pgmg_service_active "$PG_WIZARD_SERVICE"; then
    ui_success "Service is active"
  else
    ui_warn "Service is not active — try: systemctl start ${PG_WIZARD_SERVICE}"
  fi
  ui_box_end
}

_pgmg_print_backup_access() {
  local ip port token url
  ip="$(_pgmg_server_ip)"
  port="$(_pgmg_backup_port)"
  token="$(_pgmg_read_file_token "${PG_BACKUP_DIR}/backup_panel/.setup_token" || true)"
  ui_box_start "PGClockBackup panel access"
  ui_kv "Install dir" "$PG_BACKUP_DIR"
  ui_kv "Service" "$PG_BACKUP_SERVICE"
  ui_kv "Port" "$port"
  url="http://${ip}:${port}/"
  ui_kv "URL" "$url"
  if [[ -n "$token" ]]; then
    ui_kv "Setup token" "$token"
    ui_kv "Token file" "${PG_BACKUP_DIR}/backup_panel/.setup_token"
    ui_info "First login: open URL, paste setup token, set a strong password."
  else
    ui_info "Setup token already consumed (password was set) — log in with your password."
  fi
  if _pgmg_service_active "$PG_BACKUP_SERVICE"; then
    ui_success "Service is active"
  else
    ui_warn "Service is not active — try: systemctl start ${PG_BACKUP_SERVICE}"
  fi
  ui_box_end
}

_pgmg_status_line() {
  local name="$1"
  local dir="$2"
  local svc="$3"
  local port="$4"
  if [[ -d "$dir" ]]; then
    if _pgmg_service_active "$svc"; then
      ui_success "${name}: installed · active · port ${port} · ${dir}"
    else
      ui_warn "${name}: installed · stopped · port ${port} · ${dir}"
    fi
  else
    ui_info "${name}: not installed"
  fi
}
