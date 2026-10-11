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
