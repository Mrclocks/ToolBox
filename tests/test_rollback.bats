#!/usr/bin/env bats
# shellcheck shell=bats

load helpers

setup() {
  SECUREBOX_STATE_DIR="${BATS_TEST_TMPDIR}/state"
  SECUREBOX_BACKUP_ROOT="${BATS_TEST_TMPDIR}/bak"
  SECUREBOX_ROLLBACK_DIR="${SECUREBOX_STATE_DIR}/rollback"
  SECUREBOX_RUN_ID="test-run"
  mkdir -p "$SECUREBOX_STATE_DIR" "$SECUREBOX_BACKUP_ROOT" "$SECUREBOX_ROLLBACK_DIR"
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/lib/rollback.sh"
}

@test "schedule_timed_rollback skips without TTY (no false arm)" {
  have_cmd() {
    case "$1" in
      systemd-run|systemctl) return 1 ;;
      *) command -v "$1" >/dev/null 2>&1 ;;
    esac
  }
  have_tty() { return 1; }

  run schedule_timed_rollback ssh 120
  [ "$status" -eq 0 ]
  [ ! -f "${SECUREBOX_ROLLBACK_DIR}/ssh.unit" ]
  shopt -s nullglob
  scripts=("${SECUREBOX_ROLLBACK_DIR}"/ssh-*.sh)
  [ "${#scripts[@]}" -eq 0 ]
}

@test "schedule does not delete the freshly written script (regression)" {
  # Repro of 0.2.0 bug: write script → cancel_* → rm kind-*.sh → false "armed"
  have_tty() { return 0; }
  have_cmd() {
    case "$1" in
      systemctl) return 1 ;;
      systemd-run) return 0 ;;
      *) command -v "$1" >/dev/null 2>&1 ;;
    esac
  }
  systemd-run() { return 0; }

  schedule_timed_rollback ssh 120
  [ -f "${SECUREBOX_ROLLBACK_DIR}/ssh.unit" ]
  [ -f "${SECUREBOX_ROLLBACK_DIR}/ssh.script" ]
  script="$(tr -d '[:space:]' <"${SECUREBOX_ROLLBACK_DIR}/ssh.script")"
  [ -n "$script" ]
  [ -f "$script" ]
  run rollback_is_armed ssh
  [ "$status" -eq 0 ]
  # Script body must restore socket drop-in + clear cutover
  grep -q 'ssh.socket.d' "$script"
  grep -q 'ssh_cutover' "$script"
}

@test "cancel after arm removes script; rollback_is_armed is false" {
  have_tty() { return 0; }
  have_cmd() {
    case "$1" in
      systemctl) return 1 ;;
      systemd-run) return 0 ;;
      *) command -v "$1" >/dev/null 2>&1 ;;
    esac
  }
  systemd-run() { return 0; }

  schedule_timed_rollback ufw 120
  cancel_timed_rollback ufw
  run rollback_is_armed ufw
  [ "$status" -ne 0 ]
  shopt -s nullglob
  scripts=("${SECUREBOX_ROLLBACK_DIR}"/ufw-*.sh)
  [ "${#scripts[@]}" -eq 0 ]
  [ -f "${SECUREBOX_ROLLBACK_DIR}/ufw.confirmed" ]
}

@test "disarm prior does not delete a keep_script path" {
  keep="${SECUREBOX_ROLLBACK_DIR}/ssh-999.sh"
  echo '#!/bin/bash' >"$keep"
  old="${SECUREBOX_ROLLBACK_DIR}/ssh-1.sh"
  echo '#!/bin/bash' >"$old"
  _rollback_disarm_prior ssh "$keep"
  [ -f "$keep" ]
  [ ! -f "$old" ]
}

@test "cancel does not leave a confirmed-only false armed state without script" {
  echo "securebox-rollback-ssh-1" >"${SECUREBOX_ROLLBACK_DIR}/ssh.unit"
  cancel_timed_rollback ssh
  run rollback_is_armed ssh
  [ "$status" -ne 0 ]
}
