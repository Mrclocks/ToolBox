#!/usr/bin/env bats
load helpers

@test "is_dry_run respects SECUREBOX_DRY_RUN" {
  SECUREBOX_DRY_RUN=0
  run is_dry_run
  [ "$status" -ne 0 ]
  SECUREBOX_DRY_RUN=1
  run is_dry_run
  [ "$status" -eq 0 ]
}

@test "backup_file is no-op in dry-run" {
  SECUREBOX_DRY_RUN=1
  local target="${BATS_TEST_TMPDIR}/etc-fake.conf"
  mkdir -p "$(dirname "$target")"
  echo hi >"$target"
  # Point backup root into tmp
  SECUREBOX_BACKUP_ROOT="${BATS_TEST_TMPDIR}/bak"
  mkdir -p "$SECUREBOX_BACKUP_ROOT"
  run backup_file "$target"
  [ "$status" -eq 0 ]
  # No backup tree created for the file
  [ ! -e "${SECUREBOX_BACKUP_ROOT}/${SECUREBOX_RUN_ID}${target}" ]
}

@test "write_sysctl_dropin is no-op in dry-run" {
  SECUREBOX_DRY_RUN=1
  local f="${BATS_TEST_TMPDIR}/sysctl-test.conf"
  run write_sysctl_dropin "$f" "net.ipv4.ip_forward = 1"
  [ "$status" -eq 0 ]
  [ ! -f "$f" ]
}
