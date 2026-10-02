#!/usr/bin/env bash
# SecureBox — shared helpers
# shellcheck shell=bash

set -o pipefail

SECUREBOX_VERSION="0.1.3"
SECUREBOX_NAME="MrClock"
SECUREBOX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECUREBOX_DATA="${SECUREBOX_ROOT}/data"
SECUREBOX_BACKUP_ROOT="${SECUREBOX_BACKUP_ROOT:-/var/backups/securebox}"
SECUREBOX_LOG_DIR="${SECUREBOX_LOG_DIR:-/var/log/securebox}"
SECUREBOX_STATE_DIR="${SECUREBOX_STATE_DIR:-/var/lib/securebox}"
SECUREBOX_RUN_ID="$(date +%Y%m%d-%H%M%S)"
SECUREBOX_LOG="${SECUREBOX_LOG_DIR}/run-${SECUREBOX_RUN_ID}.log"
SECUREBOX_FAILED_MODULES=()
SECUREBOX_OK_MODULES=()
SECUREBOX_SKIPPED_MODULES=()

export SECUREBOX_VERSION SECUREBOX_NAME SECUREBOX_ROOT SECUREBOX_DATA
export SECUREBOX_BACKUP_ROOT SECUREBOX_LOG_DIR SECUREBOX_STATE_DIR
export SECUREBOX_RUN_ID SECUREBOX_LOG

mkdir -p "$SECUREBOX_LOG_DIR" "$SECUREBOX_STATE_DIR" "$SECUREBOX_BACKUP_ROOT" 2>/dev/null || true

log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" >>"$SECUREBOX_LOG" 2>/dev/null || true
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "SecureBox must be run as root. Try: sudo bash install.sh" >&2
    exit 1
  fi
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

run_cmd() {
  local desc="$1"; shift
  log INFO "CMD: $desc :: $*"
  if "$@" >>"$SECUREBOX_LOG" 2>&1; then
    return 0
  fi
  local rc=$?
  log ERROR "CMD failed ($rc): $desc :: $*"
  return "$rc"
}

retry_cmd() {
  local tries="${1:-3}"
  local sleep_s="${2:-2}"
  shift 2
  local i=1
  until "$@"; do
    local rc=$?
    if (( i >= tries )); then
      return "$rc"
    fi
    log WARN "Retry $i/$tries after failure: $*"
    sleep "$sleep_s"
    ((i++)) || true
  done
}

is_true() {
  case "${1,,}" in
    1|y|yes|true|on) return 0 ;;
    *) return 1 ;;
  esac
}

# Strict: only explicit yes. Empty / unset / "no" => false. Never default optional work to on.
answered_yes() {
  local key="$1"
  local val="${SECUREBOX_ANSWERS[$key]:-}"
  is_true "$val"
}

answered_no() {
  local key="$1"
  local val="${SECUREBOX_ANSWERS[$key]:-}"
  case "${val,,}" in
    0|n|no|false|off) return 0 ;;
    *) return 1 ;;
  esac
}

require_answer_yes() {
  # usage: require_answer_yes key module_name "human reason"
  local key="$1" mod="$2" why="${3:-not explicitly enabled by user}"
  if answered_yes "$key"; then
    log INFO "Answer check OK: ${key}=${SECUREBOX_ANSWERS[$key]}"
    return 0
  fi
  log INFO "Answer check SKIP: ${key}='${SECUREBOX_ANSWERS[$key]:-}' (${why})"
  return 1
}

trim() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

is_uint() {
  [[ "${1-}" =~ ^[0-9]+$ ]]
}

is_port() {
  is_uint "${1-}" && (( $1 >= 1 && $1 <= 65535 ))
}

is_ipv4() {
  local ip="${1-}"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS=.
  read -r a b c d <<<"$ip"
  (( a <= 255 && b <= 255 && c <= 255 && d <= 255 ))
}

is_cidr_v4() {
  local c="${1-}"
  [[ "$c" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]] || return 1
  local ip="${c%/*}"
  is_ipv4 "$ip"
}

backup_file() {
  local src="$1"
  [[ -e "$src" ]] || return 0
  local dest_dir="${SECUREBOX_BACKUP_ROOT}/${SECUREBOX_RUN_ID}"
  mkdir -p "$dest_dir"
  local rel="${src#/}"
  local dest="${dest_dir}/${rel}"
  mkdir -p "$(dirname "$dest")"
  cp -a "$src" "$dest"
  log INFO "Backup: $src -> $dest"
}

write_sysctl_dropin() {
  local file="$1"
  shift
  mkdir -p "$(dirname "$file")"
  backup_file "$file"
  {
    echo "# Managed by SecureBox ${SECUREBOX_VERSION} (${SECUREBOX_RUN_ID})"
    echo "# Do not edit by hand unless you know what you are doing."
    printf '%s\n' "$@"
  } >"$file"
  sysctl --system >/dev/null 2>&1 || sysctl -p "$file" >/dev/null 2>&1 || true
}

module_ok() {
  SECUREBOX_OK_MODULES+=("$1")
  log INFO "Module OK: $1"
}

module_fail() {
  SECUREBOX_FAILED_MODULES+=("$1|$2")
  log ERROR "Module FAIL: $1 — $2"
}

module_skip() {
  SECUREBOX_SKIPPED_MODULES+=("$1|$2")
  log WARN "Module SKIP: $1 — $2"
}

apt_update_safe() {
  export DEBIAN_FRONTEND=noninteractive
  retry_cmd 3 3 apt-get update -y
}

apt_install_safe() {
  export DEBIAN_FRONTEND=noninteractive
  apt_update_safe || true
  retry_cmd 3 3 apt-get install -y --no-install-recommends "$@"
}

service_enable_start() {
  local svc="$1"
  if have_cmd systemctl; then
    systemctl enable "$svc" >/dev/null 2>&1 || true
    systemctl restart "$svc" >/dev/null 2>&1 || systemctl start "$svc" >/dev/null 2>&1 || true
  fi
}

service_disable_stop() {
  local svc="$1"
  if have_cmd systemctl; then
    systemctl stop "$svc" >/dev/null 2>&1 || true
    systemctl disable "$svc" >/dev/null 2>&1 || true
    systemctl mask "$svc" >/dev/null 2>&1 || true
  fi
}

listening_ports_report() {
  if have_cmd ss; then
    ss -tulpn 2>/dev/null | awk 'NR>1 {print $1,$5}' | sort -u
  elif have_cmd netstat; then
    netstat -tulpn 2>/dev/null | awk 'NR>2 {print $1,$4}' | sort -u
  fi
}

discover_public_ports() {
  # Output: proto port  (only non-localhost listeners)
  if ! have_cmd ss; then
    return 0
  fi
  local out
  out="$(ss -H -tuln 2>/dev/null || ss -tuln 2>/dev/null | tail -n +2 || true)"
  [[ -z "$out" ]] && return 0
  while read -r line; do
    [[ -z "$line" ]] && continue
    local proto local_addr port
    proto="$(awk '{print $1}' <<<"$line")"
    local_addr="$(awk '{print $5}' <<<"$line")"
    [[ -z "$local_addr" || "$local_addr" == "Local" ]] && continue
    case "$local_addr" in
      127.*|\[::1\]*|::1*) continue ;;
    esac
    if [[ "$local_addr" == \[*\]* ]]; then
      port="${local_addr##*]:}"
    else
      port="${local_addr##*:}"
    fi
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    printf '%s %s\n' "${proto%%n}" "$port"
  done <<<"$out" | sort -u
}

default_iface() {
  ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

iface_mtu() {
  local iface="${1-}"
  [[ -n "$iface" ]] || return 1
  cat "/sys/class/net/${iface}/mtu" 2>/dev/null
}

confirm_continue_on_error() {
  local module="$1"
  local err="$2"
  ui_error "${module}: ${err}"
  ui_warn "SecureBox will continue with remaining tasks when possible."
  if [[ -n "${SECUREBOX_ANSWERS[continue_on_error]:-}" ]] && is_true "${SECUREBOX_ANSWERS[continue_on_error]}"; then
    return 0
  fi
  if ui_confirm "Continue despite this error?" "Y"; then
    return 0
  fi
  return 1
}
