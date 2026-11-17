#!/usr/bin/env bats
# PGClockMG bridge helper tests

load helpers

setup() {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/lib/pgclockmg.sh"
  PG_WIZARD_DIR="${PGCTB_STATE_DIR}/fake-wizard"
  PG_BACKUP_DIR="${PGCTB_STATE_DIR}/fake-backup"
  mkdir -p "$PG_WIZARD_DIR" "${PG_BACKUP_DIR}/backup_panel"
}

@test "_pgmg_detect_service_port reads --port from unit file" {
  local unit="${PGCTB_STATE_DIR}/pg-migrator.service"
  cat >"$unit" <<'EOF'
[Service]
ExecStart=/opt/pg-migrator/.venv/bin/python -m uvicorn app:app --port 7010
EOF
  run _pgmg_detect_service_port "$unit" "7000"
  [ "$status" -eq 0 ]
  [ "$output" = "7010" ]
}

@test "_pgmg_detect_service_port falls back to default" {
  run _pgmg_detect_service_port "${PGCTB_STATE_DIR}/missing.service" "7001"
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
  PGCTB_DRY_RUN=1
  run _pgmg_run_installer install-backup 7001
  [ "$status" -eq 0 ]
}

@test "PGClockMG installer is pinned with SHA-256" {
  [[ "$PGCLOCKMG_INSTALL_URL" == *"/v"* ]]
  [[ -n "$PGCLOCKMG_INSTALL_SHA256" ]]
  [[ "$PGCLOCKMG_INSTALL_SHA256" =~ ^[a-fA-F0-9]{64}$ ]]
  grep -q 'PGCLOCKMG_INSTALL_SHA256' "${REPO_ROOT}/lib/pgclockmg.sh"
  grep -q 'SHA-256 mismatch' "${REPO_ROOT}/lib/pgclockmg.sh"
}

@test "wizard access does not embed token in URL" {
  ! grep -qE '\?token=\$\{token\}' "${REPO_ROOT}/lib/pgclockmg.sh"
  grep -q 'Local URL' "${REPO_ROOT}/lib/pgclockmg.sh"
  grep -q 'ssh -L' "${REPO_ROOT}/lib/pgclockmg.sh"
}

@test "backup and restore menus expose Install Open Status Uninstall" {
  grep -q 'Install / Update PGClockBackup' "${REPO_ROOT}/modules/pgbackup.sh"
  grep -q 'Open / Show access URL' "${REPO_ROOT}/modules/pgbackup.sh"
  grep -q 'Install / Update PGClockMG wizard' "${REPO_ROOT}/modules/pgrestore.sh"
  grep -q 'Redirect server' "${REPO_ROOT}/modules/pgrestore.sh"
  grep -q 'lib/pgclockmg.sh' "${REPO_ROOT}/install.sh"
}

@test "_pgmg_download_installer prints only the verified path on stdout" {
  local src="${BATS_TEST_TMPDIR}/install.sh"
  printf 'echo hi\n' >"$src"
  PGCLOCKMG_INSTALL_URL="file://${src}"
  PGCLOCKMG_INSTALL_SHA256="$(sha256sum "$src" | awk '{print $1}')"
  # Real (non-silenced) UI so stray stdout output would be caught
  ui_info() { printf '* %s\n' "$*"; }
  ui_success() { printf '+ %s\n' "$*"; }
  local out
  out="$(_pgmg_download_installer 2>/dev/null)"
  [ -f "$out" ]
  [ "$(cat "$out")" = "echo hi" ]
  rm -f "$out"
}

@test "_pgmg_download_installer refuses a SHA-256 mismatch" {
  local src="${BATS_TEST_TMPDIR}/install.sh"
  printf 'echo evil\n' >"$src"
  PGCLOCKMG_INSTALL_URL="file://${src}"
  PGCLOCKMG_INSTALL_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
  run _pgmg_download_installer
  [ "$status" -ne 0 ]
}
