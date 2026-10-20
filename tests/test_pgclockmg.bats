#!/usr/bin/env bats
# PGClockMG bridge helper tests

load helpers

setup() {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/lib/pgclockmg.sh"
  PG_WIZARD_DIR="${SECUREBOX_STATE_DIR}/fake-wizard"
  PG_BACKUP_DIR="${SECUREBOX_STATE_DIR}/fake-backup"
  mkdir -p "$PG_WIZARD_DIR" "${PG_BACKUP_DIR}/backup_panel"
}

@test "_pgmg_detect_service_port reads --port from unit file" {
  local unit="${SECUREBOX_STATE_DIR}/pg-migrator.service"
  cat >"$unit" <<'EOF'
[Service]
ExecStart=/opt/pg-migrator/.venv/bin/python -m uvicorn app:app --port 7010
EOF
  run _pgmg_detect_service_port "$unit" "7000"
  [ "$status" -eq 0 ]
  [ "$output" = "7010" ]
}

@test "_pgmg_detect_service_port falls back to default" {
  run _pgmg_detect_service_port "${SECUREBOX_STATE_DIR}/missing.service" "7001"
  [ "$output" = "7001" ]
}

@test "_pgmg_wizard_installed true when dir+service present" {
  mkdir -p "$PG_WIZARD_DIR"
  # Without service file, still true if main markers exist
  touch "${PG_WIZARD_DIR}/main.py"
  _pgmg_wizard_installed
}

@test "_pgmg_backup_installed detects backup_panel" {
  _pgmg_backup_installed
}

@test "_pgmg_read_file_token strips whitespace" {
  printf '  abcdef012345  \n' >"${PG_WIZARD_DIR}/.access_token"
  run _pgmg_read_file_token "${PG_WIZARD_DIR}/.access_token"
  [ "$status" -eq 0 ]
  [ "$output" = "abcdef012345" ]
}

@test "_pgmg_run_installer dry-run succeeds" {
  SECUREBOX_DRY_RUN=1
  run _pgmg_run_installer install-backup 7001
  [ "$status" -eq 0 ]
}

@test "backup and restore menus expose Install Open Status Uninstall" {
  grep -q 'Install / Update PGClockBackup' "${REPO_ROOT}/modules/pgbackup.sh"
  grep -q 'Open / Show access URL' "${REPO_ROOT}/modules/pgbackup.sh"
  grep -q 'Install / Update PGClockMG wizard' "${REPO_ROOT}/modules/pgrestore.sh"
  grep -q 'Redirect server' "${REPO_ROOT}/modules/pgrestore.sh"
  grep -q 'lib/pgclockmg.sh' "${REPO_ROOT}/install.sh"
}
