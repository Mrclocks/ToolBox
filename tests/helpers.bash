#!/usr/bin/env bash
# Shared bats helpers — source lib pieces without requiring root
# Note: avoid nounset here — associative array keys trip set -u in bash 5
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Minimal stubs so sourcing modules does not explode
export SECUREBOX_ROOT="$REPO_ROOT"
export SECUREBOX_BACKUP_ROOT="${BATS_TEST_TMPDIR:-/tmp}/securebox-bak"
export SECUREBOX_LOG_DIR="${BATS_TEST_TMPDIR:-/tmp}/securebox-log"
export SECUREBOX_STATE_DIR="${BATS_TEST_TMPDIR:-/tmp}/securebox-state"
export SECUREBOX_RUN_ID="test-run"
mkdir -p "$SECUREBOX_BACKUP_ROOT" "$SECUREBOX_LOG_DIR" "$SECUREBOX_STATE_DIR"

# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/common.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/lib/ui.sh"

declare -gA SECUREBOX_ANSWERS=()

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
