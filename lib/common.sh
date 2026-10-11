#!/usr/bin/env bash
# SecureBox — shared helpers
# shellcheck shell=bash

set -o pipefail

SECUREBOX_NAME="MrClock"
SECUREBOX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -r "${SECUREBOX_ROOT}/VERSION" ]]; then
  SECUREBOX_VERSION="$(tr -d '[:space:]' <"${SECUREBOX_ROOT}/VERSION")"
fi
SECUREBOX_VERSION="${SECUREBOX_VERSION:-0.2.0}"
SECUREBOX_DATA="${SECUREBOX_ROOT}/data"
SECUREBOX_BACKUP_ROOT="${SECUREBOX_BACKUP_ROOT:-/var/backups/securebox}"
SECUREBOX_LOG_DIR="${SECUREBOX_LOG_DIR:-/var/log/securebox}"
SECUREBOX_STATE_DIR="${SECUREBOX_STATE_DIR:-/var/lib/securebox}"
SECUREBOX_RUN_ID="$(date +%Y%m%d-%H%M%S)"
SECUREBOX_LOG="${SECUREBOX_LOG_DIR}/run-${SECUREBOX_RUN_ID}.log"
SECUREBOX_FAILED_MODULES=()
SECUREBOX_OK_MODULES=()
SECUREBOX_SKIPPED_MODULES=()
SECUREBOX_APT_UPDATED=0

export SECUREBOX_VERSION SECUREBOX_NAME SECUREBOX_ROOT SECUREBOX_DATA
export SECUREBOX_BACKUP_ROOT SECUREBOX_LOG_DIR SECUREBOX_STATE_DIR
export SECUREBOX_RUN_ID SECUREBOX_LOG

mkdir -p "$SECUREBOX_LOG_DIR" "$SECUREBOX_STATE_DIR" "$SECUREBOX_BACKUP_ROOT" 2>/dev/null || true
chmod 700 "$SECUREBOX_BACKUP_ROOT" 2>/dev/null || true

log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" >>"$SECUREBOX_LOG" 2>/dev/null || true
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "MrClock must be run as root. Try: sudo mrclock" >&2
    exit 1
  fi
}

# True when we can prompt the operator (TTY or /dev/tty).
have_tty() {
  [[ -t 0 ]] && return 0
  { exec 3</dev/tty; } 2>/dev/null || return 1
  exec 3<&-
  return 0
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
  local key="$1"
  local mod="$2"
  local why="${3:-not explicitly enabled by user}"
  if answered_yes "$key"; then
    log INFO "Answer check OK: ${mod}: ${key}=${SECUREBOX_ANSWERS[$key]}"
    return 0
  fi
  log INFO "Answer check SKIP: ${mod}: ${key}='${SECUREBOX_ANSWERS[$key]:-}' (${why})"
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

# Single port or UFW-style range (e.g. 1000:2000)
is_port_spec() {
  local p="${1-}"
  if [[ "$p" == *:* ]]; then
    local a="${p%%:*}" b="${p#*:}"
    is_port "$a" && is_port "$b" && (( a <= b ))
  else
    is_port "$p"
  fi
}

is_ipv4() {
  local ip="${1-}"
  # Strict decimal octets — reject leading zeros (08.1.1.1) which break
  # bash arithmetic (octal) and are invalid dotted-quad forms.
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS=.
  local a b c d
  read -r a b c d <<<"$ip"
  [[ "$a" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  [[ "$b" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  [[ "$c" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  [[ "$d" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 ))
}

# Detect live SSH listen ports: SSH_CONNECTION, ss (sshd), then sshd_config.
# Prints one port per line.
detect_live_ssh_ports() {
  local -A seen=()
  local p

  # Current session destination port (most reliable for the admin)
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    # SSH_CONNECTION: client_ip client_port server_ip server_port
    p="$(awk '{print $4}' <<<"$SSH_CONNECTION")"
    if is_port "$p"; then
      seen["$p"]=1
    fi
  fi

  # Listening sshd sockets
  if have_cmd ss; then
    while read -r line; do
      [[ -z "$line" ]] && continue
      # Prefer lines mentioning sshd
      if [[ "$line" != *sshd* && "$line" != *"/ssh"* ]]; then
        continue
      fi
      local addr
      addr="$(awk '{print $4}' <<<"$line")"
      if [[ "$addr" == \[*\]* ]]; then
        p="${addr##*]:}"
      else
        p="${addr##*:}"
      fi
      is_port "$p" && seen["$p"]=1
    done < <(ss -tlnp 2>/dev/null || true)
  fi

  # Configured ports (sshd_config + drop-ins) — first Port wins per OpenSSH, but list all
  if declare -F _ssh_current_port >/dev/null 2>&1; then
    p="$(_ssh_current_port 2>/dev/null || true)"
    is_port "$p" && seen["$p"]=1
  fi
  if [[ -f /etc/ssh/sshd_config ]]; then
    while read -r p; do
      is_port "$p" && seen["$p"]=1
    done < <(awk '/^[Pp]ort[[:space:]]+[0-9]+/{print $2}' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null)
  fi

  if ((${#seen[@]} == 0)); then
    echo 22
    return 0
  fi
  for p in "${!seen[@]}"; do
    printf '%s\n' "$p"
  done | sort -n
}

backup_file() {
  local src="$1"
  local dest_dir="${SECUREBOX_BACKUP_ROOT}/${SECUREBOX_RUN_ID}"
  local manifest="${dest_dir}/MANIFEST.txt"
  mkdir -p "$dest_dir"
  chmod 700 "$SECUREBOX_BACKUP_ROOT" 2>/dev/null || true
  local abs
  if [[ "$src" == /* ]]; then
    abs="$src"
  else
    abs="/${src}"
  fi
  local rel="${abs#/}"

  if [[ -e "$src" ]]; then
    local dest="${dest_dir}/${rel}"
    mkdir -p "$(dirname "$dest")"
    cp -a "$src" "$dest"
    if [[ -f "$manifest" ]] && grep -qxF "RESTORE|${abs}" "$manifest" 2>/dev/null; then
      :
    else
      printf 'RESTORE|%s\n' "$abs" >>"$manifest"
    fi
    log INFO "Backup: $src -> $dest"
  else
    if [[ -f "$manifest" ]] && grep -qxE "(RESTORE|REMOVE)\|${abs}" "$manifest" 2>/dev/null; then
      :
    else
      printf 'REMOVE|%s\n' "$abs" >>"$manifest"
    fi
    log INFO "Backup mark NEW (remove on restore): $abs"
  fi
  record_backup_run
}

# Remember which run id holds the latest toolbox changes (for Undo menu)
record_backup_run() {
  mkdir -p "$SECUREBOX_STATE_DIR"
  # Never overwrite last_recommended_run with a restore safety snapshot
  if [[ "${SECUREBOX_ANSWERS[do_restore]:-}" != "yes" ]]; then
    printf '%s\n' "$SECUREBOX_RUN_ID" >"${SECUREBOX_STATE_DIR}/last_backup_run"
    printf '%s\n' "$SECUREBOX_RUN_ID" >"${SECUREBOX_STATE_DIR}/last_recommended_run"
  fi
  local hist="${SECUREBOX_STATE_DIR}/backup_runs.txt"
  if [[ ! -f "$hist" ]] || ! grep -qxF "$SECUREBOX_RUN_ID" "$hist" 2>/dev/null; then
    printf '%s\n' "$SECUREBOX_RUN_ID" >>"$hist"
  fi
}

# Record a live pre-change value once (first write wins for the session baseline)
state_record_once() {
  local key="$1"
  local value="$2"
  mkdir -p "$SECUREBOX_STATE_DIR"
  local f="${SECUREBOX_STATE_DIR}/${key}"
  if [[ ! -f "$f" ]]; then
    printf '%s\n' "$value" >"$f"
  fi
}

state_get() {
  local key="$1"
  local f="${SECUREBOX_STATE_DIR}/${key}"
  [[ -r "$f" ]] || return 1
  tr -d '[:space:]' <"$f"
}

# Snapshot key sysctl values before BBR / IPv6 modules overwrite them
state_record_sysctl_baseline() {
  local key val
  mkdir -p "${SECUREBOX_STATE_DIR}/sysctl"
  for key in \
    net.ipv4.ip_forward \
    net.ipv4.tcp_congestion_control \
    net.core.default_qdisc \
    net.ipv6.conf.all.disable_ipv6 \
    net.ipv6.conf.default.disable_ipv6 \
    net.netfilter.nf_conntrack_max; do
    val="$(sysctl -n "$key" 2>/dev/null || true)"
    [[ -n "$val" ]] || continue
    if [[ ! -f "${SECUREBOX_STATE_DIR}/sysctl/${key}" ]]; then
      printf '%s\n' "$val" >"${SECUREBOX_STATE_DIR}/sysctl/${key}"
    fi
  done
}

write_sysctl_dropin() {
  local file="$1"
  shift
  mkdir -p "$(dirname "$file")"
  backup_file "$file"
  {
    echo "# Managed by MrClock ${SECUREBOX_VERSION} (${SECUREBOX_RUN_ID})"
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
  # Once per run — Apply All calls many modules that install packages
  if [[ "${SECUREBOX_APT_UPDATED:-0}" == "1" ]]; then
    return 0
  fi
  if retry_cmd 3 3 apt-get update -y; then
    SECUREBOX_APT_UPDATED=1
    return 0
  fi
  return 1
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
  ui_warn "MrClock will continue with remaining tasks when possible."
  if [[ -n "${SECUREBOX_ANSWERS[continue_on_error]:-}" ]] && is_true "${SECUREBOX_ANSWERS[continue_on_error]}"; then
    return 0
  fi
  if ! have_tty; then
    ui_warn "No TTY — continuing automatically."
    return 0
  fi
  if ui_confirm "Continue despite this error?" "Y"; then
    return 0
  fi
  return 1
}
