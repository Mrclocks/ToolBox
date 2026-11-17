#!/usr/bin/env bash
# Shared bats helpers — source lib pieces without requiring root
# Note: avoid nounset here — associative array keys trip set -u in bash 5
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Fresh state dirs for EVERY test. bats < 1.4 (Ubuntu 22.04) has no
# BATS_TEST_TMPDIR and runs this file-level code once per FILE, so each test
# file's setup() must call pgctb_test_dirs first (it is harmless on new bats).
# Our own dir is marked so an inherited (exported) value is not mistaken for
# one that bats provided.
_PGCTB_OWN_TMPDIR=0
if [[ -z "${BATS_TEST_TMPDIR:-}" || "${BATS_TEST_TMPDIR}" == "${PGCTB_TEST_OWN_TMPDIR:-}" ]]; then
  _PGCTB_OWN_TMPDIR=1
fi

pgctb_test_dirs() {
  if (( _PGCTB_OWN_TMPDIR )); then
    BATS_TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/bats-test.XXXXXX")"
    export PGCTB_TEST_OWN_TMPDIR="$BATS_TEST_TMPDIR"
  fi
  export BATS_TEST_TMPDIR
  export PGCTB_ROOT="$REPO_ROOT"
  export PGCTB_BACKUP_ROOT="${BATS_TEST_TMPDIR}/pgclocktb-bak"
  export PGCTB_LOG_DIR="${BATS_TEST_TMPDIR}/pgclocktb-log"
  export PGCTB_STATE_DIR="${BATS_TEST_TMPDIR}/pgclocktb-state"
  export PGCTB_RUN_ID="test-run"
  export PGCTB_LOG="${PGCTB_LOG_DIR}/run-test.log"
  PGCTB_TXN_DIR="${PGCTB_STATE_DIR}/txn"
  PGCTB_LOCK_FILE="${BATS_TEST_TMPDIR}/pgclocktb.lock"
  mkdir -p "$PGCTB_BACKUP_ROOT" "$PGCTB_LOG_DIR" "$PGCTB_STATE_DIR"
}
pgctb_test_dirs

# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/ui.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/safety.sh"

declare -gA PGCTB_ANSWERS=()

# Silence UI in tests
ui_info() { :; }
ui_success() { :; }
ui_warn() { :; }
ui_error() { :; }
ui_step() { :; }
ui_kv() { :; }
ui_box_start() { :; }
ui_box_end() { :; }
log() { :; }

# make_cert DIR DOMAIN... → self-signed DIR/fullchain.cer + DIR/key.pem (SAN = domains)
make_cert() {
  local dir="$1"
  shift
  local san="" d
  for d in "$@"; do san+="${san:+,}DNS:${d}"; done
  mkdir -p "$dir"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "${dir}/key.pem" -out "${dir}/fullchain.cer" -days 2 \
    -subj "/CN=$1" -addext "subjectAltName=${san}" >/dev/null 2>&1
}

# common.sh/safety.sh derive paths at source time — re-point them per test
pgctb_test_dirs
