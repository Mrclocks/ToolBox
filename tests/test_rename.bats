#!/usr/bin/env bats
# PGClockTB rename (0.4.0): legacy env, dir migration, launchers, markers

load helpers

setup() {
  # shellcheck disable=SC1091
  PGCTB_INSTALL_LIB_ONLY=1 source "${REPO_ROOT}/install.sh"
  T="${BATS_TEST_TMPDIR}/mig"
  mkdir -p "$T"
}

@test "legacy SECUREBOX_* env overrides map to PGCTB_*" {
  run env -u PGCTB_DRY_RUN SECUREBOX_DRY_RUN=1 bash -c \
    'source "$1/lib/common.sh"; printf "%s" "$PGCTB_DRY_RUN"' _ "$REPO_ROOT"
  [ "$output" = "1" ]
  # An explicit new name wins over the legacy one
  run env SECUREBOX_DRY_RUN=1 PGCTB_DRY_RUN=0 bash -c \
    'source "$1/lib/common.sh"; printf "%s" "$PGCTB_DRY_RUN"' _ "$REPO_ROOT"
  [ "$output" = "0" ]
}

@test "migrate: old dir moves to new name and old path becomes a symlink" {
  mkdir -p "$T/old/ssl"
  echo hook >"$T/old/ssl/deploy-hook.sh"
  _pgctb_migrate_dir "$T/old" "$T/new"
  [ -L "$T/old" ]
  [ -d "$T/new" ] && [ ! -L "$T/new" ]
  [ "$(cat "$T/new/ssl/deploy-hook.sh")" = "hook" ]
  # Old absolute paths (acme.sh confs, cron) still resolve
  [ "$(cat "$T/old/ssl/deploy-hook.sh")" = "hook" ]
}

@test "migrate: replaces an empty pre-created new dir" {
  mkdir -p "$T/old" "$T/new"
  echo a >"$T/old/a"
  _pgctb_migrate_dir "$T/old" "$T/new"
  [ -L "$T/old" ]
  [ "$(cat "$T/new/a")" = "a" ]
}

@test "migrate: merges without overwriting when both hold data" {
  mkdir -p "$T/old" "$T/new"
  echo old-a >"$T/old/a"
  echo old-b >"$T/old/b"
  echo new-a >"$T/new/a"
  _pgctb_migrate_dir "$T/old" "$T/new"
  [ "$(cat "$T/new/a")" = "new-a" ]
  [ "$(cat "$T/new/b")" = "old-b" ]
  [ -L "$T/old" ]
  ls -d "$T"/old.pre-pgclocktb.* >/dev/null
}

@test "migrate: drop-aside (logs) leaves no duplicate tree" {
  mkdir -p "$T/old" "$T/new"
  echo o >"$T/old/old.log"
  echo n >"$T/new/current.log"
  _pgctb_migrate_dir "$T/old" "$T/new" drop-aside
  [ -L "$T/old" ]
  [ -f "$T/new/old.log" ] && [ -f "$T/new/current.log" ]
  ! ls -d "$T"/old.pre-pgclocktb.* 2>/dev/null
}

@test "migrate: idempotent and a no-op without legacy dir" {
  mkdir -p "$T/old"
  echo x >"$T/old/x"
  _pgctb_migrate_dir "$T/old" "$T/new"
  _pgctb_migrate_dir "$T/old" "$T/new"
  [ -L "$T/old" ]
  [ "$(cat "$T/new/x")" = "x" ]
  _pgctb_migrate_dir "$T/none" "$T/new2"
  [ ! -e "$T/new2" ]
}

@test "persistent install writes pgclock + legacy mrclock launchers and retires old tree" {
  PGCTB_INSTALL_DIR="$T/opt/pgclocktb"
  PGCTB_BIN_LINK="$T/bin/pgclock"
  PGCTB_LEGACY_BIN_LINK="$T/bin/mrclock"
  PGCTB_LEGACY_INSTALL_DIR="$T/opt/mrclock-toolbox"
  mkdir -p "$PGCTB_LEGACY_INSTALL_DIR"
  cp -a "$REPO_ROOT/lib" "$REPO_ROOT/modules" "$REPO_ROOT/data" "$PGCTB_LEGACY_INSTALL_DIR/"
  _pgctb_install_persistent "$REPO_ROOT"
  _pgctb_have_tree "$PGCTB_INSTALL_DIR"
  [ -x "$PGCTB_BIN_LINK" ] && [ -x "$PGCTB_LEGACY_BIN_LINK" ]
  grep -q "INSTALL_SH=\"$PGCTB_INSTALL_DIR/install.sh\"" "$PGCTB_BIN_LINK"
  grep -q "INSTALL_SH=\"$PGCTB_INSTALL_DIR/install.sh\"" "$PGCTB_LEGACY_BIN_LINK"
  bash -n "$PGCTB_BIN_LINK"
  [ -L "$PGCTB_LEGACY_INSTALL_DIR" ]
  [ "$PGCTB_LEGACY_INSTALL_DIR" -ef "$PGCTB_INSTALL_DIR" ]
}

@test "legacy install dir is never removed unless it is our tree" {
  PGCTB_INSTALL_DIR="$T/opt/pgclocktb"
  PGCTB_LEGACY_INSTALL_DIR="$T/opt/something-else"
  mkdir -p "$PGCTB_LEGACY_INSTALL_DIR" "$PGCTB_INSTALL_DIR"
  echo keep >"$PGCTB_LEGACY_INSTALL_DIR/file"
  _pgctb_retire_legacy_install "$REPO_ROOT"
  [ ! -L "$PGCTB_LEGACY_INSTALL_DIR" ]
  [ "$(cat "$PGCTB_LEGACY_INSTALL_DIR/file")" = "keep" ]
}

@test "HAProxy panel detection accepts pre-0.4.0 config marker" {
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/modules/ssl.sh"
  PROXY_CONFIG_FILE="$T/none.env"
  PROXY_HAPROXY_CFG="$T/haproxy.cfg"
  mkdir -p "$T/bin"
  printf '#!/bin/sh\nexit 0\n' >"$T/bin/systemctl"
  chmod +x "$T/bin/systemctl"
  PATH="$T/bin:$PATH"
  printf '# MrClock ToolBox — PasarGuard panel single-port (HTTP mode)\n' >"$PROXY_HAPROXY_CFG"
  _ssl_panel_behind_haproxy
  printf '# PGClockTB — PasarGuard panel single-port (HTTP mode)\n' >"$PROXY_HAPROXY_CFG"
  _ssl_panel_behind_haproxy
}

@test "release asset name and banner use PGClockTB" {
  grep -q 'PGClockTB-' "$REPO_ROOT/scripts/gen-checksums.sh"
  grep -q 'PGClockTB' "$REPO_ROOT/lib/common.sh"
  ! grep -rq 'SECUREBOX_' "$REPO_ROOT/lib" "$REPO_ROOT/modules" \
    --exclude=common.sh
}
