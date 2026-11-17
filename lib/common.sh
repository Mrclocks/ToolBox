#!/usr/bin/env bash
# PGClockTB — shared helpers
# shellcheck shell=bash

set -o pipefail

# Accept pre-0.4.0 overrides (SECUREBOX_DRY_RUN=1 …) as PGCTB_* equivalents.
for __pgctb_v in $(compgen -e); do
  [[ "$__pgctb_v" == SECUREBOX_* ]] || continue
  __pgctb_n="PGCTB_${__pgctb_v#SECUREBOX_}"
  [[ -n "${!__pgctb_n+x}" ]] || export "${__pgctb_n}=${!__pgctb_v}"
done
unset __pgctb_v __pgctb_n

PGCTB_NAME="PGClockTB"
PGCTB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -r "${PGCTB_ROOT}/VERSION" ]]; then
  PGCTB_VERSION="$(tr -d '[:space:]' <"${PGCTB_ROOT}/VERSION")"
fi
PGCTB_VERSION="${PGCTB_VERSION:-0.2.0}"
PGCTB_DATA="${PGCTB_ROOT}/data"
PGCTB_BACKUP_ROOT="${PGCTB_BACKUP_ROOT:-/var/backups/pgclocktb}"
PGCTB_LOG_DIR="${PGCTB_LOG_DIR:-/var/log/pgclocktb}"
PGCTB_STATE_DIR="${PGCTB_STATE_DIR:-/var/lib/pgclocktb}"
PGCTB_RUN_ID="$(date +%Y%m%d-%H%M%S)"
PGCTB_LOG="${PGCTB_LOG_DIR}/run-${PGCTB_RUN_ID}.log"
PGCTB_FAILED_MODULES=()
PGCTB_OK_MODULES=()
PGCTB_SKIPPED_MODULES=()
PGCTB_APT_UPDATED=0

export PGCTB_VERSION PGCTB_NAME PGCTB_ROOT PGCTB_DATA
export PGCTB_BACKUP_ROOT PGCTB_LOG_DIR PGCTB_STATE_DIR
export PGCTB_RUN_ID PGCTB_LOG

mkdir -p "$PGCTB_LOG_DIR" "$PGCTB_STATE_DIR" "$PGCTB_BACKUP_ROOT" 2>/dev/null || true
chmod 700 "$PGCTB_BACKUP_ROOT" 2>/dev/null || true

log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" >>"$PGCTB_LOG" 2>/dev/null || true
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "PGClockTB must be run as root. Try: sudo pgclock" >&2
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
  if "$@" >>"$PGCTB_LOG" 2>&1; then
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

is_dry_run() {
  is_true "${PGCTB_DRY_RUN:-0}"
}

# Strict: only explicit yes. Empty / unset / "no" => false. Never default optional work to on.
answered_yes() {
  local key="$1"
  local val="${PGCTB_ANSWERS[$key]:-}"
  is_true "$val"
}

answered_no() {
  local key="$1"
  local val="${PGCTB_ANSWERS[$key]:-}"
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
    log INFO "Answer check OK: ${mod}: ${key}=${PGCTB_ANSWERS[$key]}"
    return 0
  fi
  log INFO "Answer check SKIP: ${mod}: ${key}='${PGCTB_ANSWERS[$key]:-}' (${why})"
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

# --- migration from MrClock ToolBox / SecureBox (< 0.4.0) ---------------------
# Old dirs are moved to the new names and replaced by a symlink, so anything
# that still points at an old path keeps working: acme.sh hook paths stored in
# domain confs (sometimes base64), armed rollback units, cron entries.
# /etc artifacts (00-securebox.conf, 99-securebox-*.conf, nft table securebox…)
# keep their names on purpose: renaming live sshd/network drop-ins is risky and
# restore/rollback must still find what older versions wrote.
PGCTB_LEGACY_STATE_DIR="${PGCTB_LEGACY_STATE_DIR:-/var/lib/securebox}"
PGCTB_LEGACY_LOG_DIR="${PGCTB_LEGACY_LOG_DIR:-/var/log/securebox}"
PGCTB_LEGACY_BACKUP_ROOT="${PGCTB_LEGACY_BACKUP_ROOT:-/var/backups/securebox}"

_pgctb_migrate_dir() {
  # _pgctb_migrate_dir OLD NEW [drop-aside]
  local old="$1" new="$2" drop_aside="${3:-}"
  [[ -n "$old" && -n "$new" ]] || return 0
  [[ -d "$old" && ! -L "$old" ]] || return 0   # nothing to migrate / already done
  [[ "$old" -ef "$new" ]] && return 0
  if [[ -d "$new" && ! -L "$new" ]] && [[ -z "$(ls -A "$new" 2>/dev/null)" ]]; then
    rmdir "$new" 2>/dev/null || true
  fi
  if [[ ! -e "$new" ]]; then
    mkdir -p "$(dirname "$new")" || return 1
    mv "$old" "$new" || return 1
  else
    # Both hold data (e.g. this run already logged): add what is missing,
    # never overwrite newer files, keep the old tree aside.
    tar -C "$old" -cf - . | tar -C "$new" --skip-old-files -xf - || return 1
    if [[ "$drop_aside" == "drop-aside" ]]; then
      rm -rf "${old:?}" || return 1               # logs: everything was copied
    else
      mv "$old" "${old}.pre-pgclocktb.$(date +%Y%m%d%H%M%S)" || return 1
    fi
  fi
  ln -s "$new" "$old" || return 1
  chmod 700 "$new" 2>/dev/null || true
  log INFO "Migrated ${old} -> ${new}"
}

pgctb_migrate_legacy_dirs() {
  local rc=0
  _pgctb_migrate_dir "$PGCTB_LEGACY_STATE_DIR" "$PGCTB_STATE_DIR" || rc=1
  # This run already logs into the new dir, so logs always merge
  _pgctb_migrate_dir "$PGCTB_LEGACY_LOG_DIR" "$PGCTB_LOG_DIR" drop-aside || rc=1
  _pgctb_migrate_dir "$PGCTB_LEGACY_BACKUP_ROOT" "$PGCTB_BACKUP_ROOT" || rc=1
  return "$rc"
}

# --- safe KEY=VALUE state files ---------------------------------------------
# State files are never `source`d: a value with spaces or $(...) would be run as
# a command. Writers emit raw KEY=value lines; the loader only assigns keys from
# an allow-list via printf -v (no eval).

# kv_line KEY VALUE → prints KEY=VALUE with newlines/CR stripped from VALUE
kv_line() {
  local __k="$1" __v="${2-}"
  __v="${__v//$'\r'/}"
  __v="${__v//$'\n'/ }"
  printf '%s=%s\n' "$__k" "$__v"
}

# kv_load_file FILE KEY... → assigns only the listed keys found in FILE
kv_load_file() {
  local __f="$1"
  shift
  [[ -f "$__f" ]] || return 0
  local __line __key __val __ok __want
  while IFS= read -r __line || [[ -n "$__line" ]]; do
    [[ "$__line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$__line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    __key="${BASH_REMATCH[1]}"
    __val="${BASH_REMATCH[2]}"
    __ok=0
    for __want in "$@"; do
      [[ "$__want" == "$__key" ]] && { __ok=1; break; }
    done
    (( __ok )) || continue
    # Legacy files quoted some values: strip one matching pair of quotes
    if [[ "$__val" =~ ^\"(.*)\"$ ]] || [[ "$__val" =~ ^\'(.*)\'$ ]]; then
      __val="${BASH_REMATCH[1]}"
    fi
    printf -v "$__key" '%s' "$__val"
  done <"$__f"
}

# normalize_port_list "8443, 9000 x 8443" → "8443 9000" (valid, deduped)
normalize_port_list() {
  local raw="${1-}" p out=""
  local -a parts=()
  raw="${raw//,/ }"
  read -r -a parts <<<"$raw"
  for p in "${parts[@]}"; do
    [[ "$p" =~ ^[1-9][0-9]{0,4}$ ]] && is_port "$p" || continue
    [[ " $out " == *" $p "* ]] && continue
    out+="${out:+ }$p"
  done
  printf '%s\n' "$out"
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
  if is_dry_run; then
    log INFO "DRY-RUN skip backup_file: $src"
    return 0
  fi
  local dest_dir="${PGCTB_BACKUP_ROOT}/${PGCTB_RUN_ID}"
  local manifest="${dest_dir}/MANIFEST.txt"
  mkdir -p "$dest_dir"
  chmod 700 "$PGCTB_BACKUP_ROOT" 2>/dev/null || true
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
  mkdir -p "$PGCTB_STATE_DIR"
  # Never overwrite last_recommended_run with a restore safety snapshot
  if [[ "${PGCTB_ANSWERS[do_restore]:-}" != "yes" ]]; then
    printf '%s\n' "$PGCTB_RUN_ID" >"${PGCTB_STATE_DIR}/last_backup_run"
    printf '%s\n' "$PGCTB_RUN_ID" >"${PGCTB_STATE_DIR}/last_recommended_run"
  fi
  local hist="${PGCTB_STATE_DIR}/backup_runs.txt"
  if [[ ! -f "$hist" ]] || ! grep -qxF "$PGCTB_RUN_ID" "$hist" 2>/dev/null; then
    printf '%s\n' "$PGCTB_RUN_ID" >>"$hist"
  fi
}

# Record a live pre-change value (always refresh — baselines go stale otherwise)
state_record() {
  local key="$1"
  local value="$2"
  mkdir -p "$PGCTB_STATE_DIR"
  printf '%s\n' "$value" >"${PGCTB_STATE_DIR}/${key}"
}

# Back-compat alias — now refreshes like state_record (was first-write-wins)
state_record_once() {
  state_record "$@"
}

# Recover SSH_* after sudo env_reset. sudo typically drops SSH_CONNECTION.
# Walk /proc for the invoking user's sshd session environ.
recover_ssh_env() {
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    export SSH_CONNECTION SSH_CLIENT SSH_TTY 2>/dev/null || true
    return 0
  fi

  local uid="" pid environ_file line
  if [[ -n "${SUDO_UID:-}" ]] && is_uint "${SUDO_UID}"; then
    uid="$SUDO_UID"
  elif [[ -n "${SUDO_USER:-}" ]]; then
    uid="$(id -u "$SUDO_USER" 2>/dev/null || true)"
  fi

  # Prefer processes owned by the sudo invoker; also scan sshd sessions
  local -a pids=()
  if [[ -n "$uid" ]] && have_cmd pgrep; then
    mapfile -t pids < <(pgrep -u "$uid" 2>/dev/null || true)
  fi
  if have_cmd pgrep; then
    mapfile -t pids < <(printf '%s\n' "${pids[@]}" "$(pgrep -f 'sshd:' 2>/dev/null || true)" | awk 'NF' | sort -u)
  fi

  for pid in "${pids[@]}"; do
    environ_file="/proc/${pid}/environ"
    [[ -r "$environ_file" ]] || continue
    # Extract SSH_* null-separated vars
    local conn="" client="" tty=""
    while IFS= read -r -d '' line; do
      case "$line" in
        SSH_CONNECTION=*) conn="${line#SSH_CONNECTION=}" ;;
        SSH_CLIENT=*) client="${line#SSH_CLIENT=}" ;;
        SSH_TTY=*) tty="${line#SSH_TTY=}" ;;
      esac
    done <"$environ_file" 2>/dev/null || true
    if [[ -n "$conn" ]]; then
      export SSH_CONNECTION="$conn"
      [[ -n "$client" ]] && export SSH_CLIENT="$client"
      [[ -n "$tty" ]] && export SSH_TTY="$tty"
      log INFO "Recovered SSH_CONNECTION from pid ${pid} (sudo env_reset workaround)"
      return 0
    fi
  done

  # Last resort: infer client from who/ss for the sudo user
  if [[ -n "${SUDO_USER:-}" ]] && have_cmd who; then
    local from
    from="$(who 2>/dev/null | awk -v u="$SUDO_USER" '$1==u && $NF ~ /^\(/ {gsub(/[()]/,"",$NF); print $NF; exit}')"
    if [[ -n "$from" ]]; then
      # Synthesize a minimal SSH_CONNECTION (client_ip 0 server_ip 22)
      local sport
      sport="$(detect_live_ssh_ports 2>/dev/null | head -n1 || echo 22)"
      export SSH_CONNECTION="${from} 0 0.0.0.0 ${sport}"
      export SSH_CLIENT="${from} 0 ${sport}"
      log INFO "Synthesized SSH_CONNECTION from who(1) for ${SUDO_USER}"
      return 0
    fi
  fi
  return 1
}

state_get() {
  local key="$1"
  local f="${PGCTB_STATE_DIR}/${key}"
  [[ -r "$f" ]] || return 1
  tr -d '[:space:]' <"$f"
}

# Snapshot key sysctl values before BBR / IPv6 modules overwrite them
state_record_sysctl_baseline() {
  local key val
  mkdir -p "${PGCTB_STATE_DIR}/sysctl"
  for key in \
    net.ipv4.ip_forward \
    net.ipv4.tcp_congestion_control \
    net.core.default_qdisc \
    net.ipv6.conf.all.disable_ipv6 \
    net.ipv6.conf.default.disable_ipv6 \
    net.netfilter.nf_conntrack_max; do
    val="$(sysctl -n "$key" 2>/dev/null || true)"
    [[ -n "$val" ]] || continue
    # Refresh each run so restore matches the pre-change live value
    printf '%s\n' "$val" >"${PGCTB_STATE_DIR}/sysctl/${key}"
  done
}

write_sysctl_dropin() {
  local file="$1"
  shift
  if is_dry_run; then
    log INFO "DRY-RUN skip write_sysctl_dropin: $file"
    return 0
  fi
  mkdir -p "$(dirname "$file")"
  backup_file "$file"
  {
    echo "# Managed by PGClockTB ${PGCTB_VERSION} (${PGCTB_RUN_ID})"
    echo "# Do not edit by hand unless you know what you are doing."
    printf '%s\n' "$@"
  } >"$file"
  sysctl --system >/dev/null 2>&1 || sysctl -p "$file" >/dev/null 2>&1 || true
}

module_ok() {
  PGCTB_OK_MODULES+=("$1")
  log INFO "Module OK: $1"
}

module_fail() {
  PGCTB_FAILED_MODULES+=("$1|$2")
  log ERROR "Module FAIL: $1 — $2"
}

module_skip() {
  PGCTB_SKIPPED_MODULES+=("$1|$2")
  log WARN "Module SKIP: $1 — $2"
}

apt_update_safe() {
  export DEBIAN_FRONTEND=noninteractive
  # Once per run — Apply All calls many modules that install packages
  if [[ "${PGCTB_APT_UPDATED:-0}" == "1" ]]; then
    return 0
  fi
  if retry_cmd 3 3 apt-get update -y; then
    PGCTB_APT_UPDATED=1
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
  ui_warn "PGClockTB will continue with remaining tasks when possible."
  if [[ -n "${PGCTB_ANSWERS[continue_on_error]:-}" ]] && is_true "${PGCTB_ANSWERS[continue_on_error]}"; then
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
