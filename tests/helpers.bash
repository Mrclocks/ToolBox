#!/usr/bin/env bash
# Shared bats helpers — source lib pieces without requiring root
# Note: avoid nounset here — associative array keys trip set -u in bash 5
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# bats < 1.4 (Ubuntu 22.04) has no BATS_TEST_TMPDIR: give every test its own
# dir so state never leaks between tests via a shared /tmp path.
if [[ -z "${BATS_TEST_TMPDIR:-}" ]]; then
  BATS_TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/bats-test.XXXXXX")"
fi
export BATS_TEST_TMPDIR

# Minimal stubs so sourcing modules does not explode
export PGCTB_ROOT="$REPO_ROOT"
export PGCTB_BACKUP_ROOT="${BATS_TEST_TMPDIR:-/tmp}/pgclocktb-bak"
export PGCTB_LOG_DIR="${BATS_TEST_TMPDIR:-/tmp}/pgclocktb-log"
export PGCTB_STATE_DIR="${BATS_TEST_TMPDIR:-/tmp}/pgclocktb-state"
export PGCTB_RUN_ID="test-run"
mkdir -p "$PGCTB_BACKUP_ROOT" "$PGCTB_LOG_DIR" "$PGCTB_STATE_DIR"

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
